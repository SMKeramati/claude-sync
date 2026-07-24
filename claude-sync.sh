#!/bin/bash
# claude-sync: make local Claude Code sessions visible across all your
# Claude Desktop accounts on this Mac.
#
# Claude Desktop keeps a separate Claude Code session list per account+org
# (one <accountUuid>/<orgUuid> folder of local_*.json entries under
# ~/Library/Application Support/Claude/claude-code-sessions). Switch
# accounts and your session list looks empty, even though every transcript
# is still on disk in ~/.claude/projects.
#
# v4 fixes that structurally instead of copying files around:
#   - UNIFY: one physical list at claude-code-sessions/_shared; every
#     <account>/<org> folder becomes a symlink to it. Each list entry
#     exists once, every account sees it, and a new session written by the
#     app lands in _shared and appears everywhere instantly. The one-time
#     restructure (and absorbing any fresh real folder the app creates
#     later) runs only while Claude Desktop is fully closed, after a
#     whole-tree backup; --revert restores the tree verbatim.
#   - SELF-HEAL: the app sometimes never writes a list entry for a session
#     (seen after restarts and rewound sessions), so it vanishes from the
#     list although its transcript is intact. Every run scans
#     ~/.claude/projects/*/*.jsonl and recreates a missing entry from the
#     transcript itself (custom title or first user message; cwd, model
#     and timestamps from the transcript). "Missing" is judged against
#     entry file names AND each entry's inner cliSessionId AND the heal
#     ledger of everything ever listed, so app-created entries are never
#     duplicated and an entry deleted in the app is never resurrected.
#     Existing entries are never edited or deleted; transcripts are only
#     ever read.
#
# It also syncs customization across PROFILES: multi-profile launchers
# (claude-deck) give each profile its own data dir under
# ~/Library/Application Support/Claude Profiles/<name>/, so local MCP
# servers (the mcpServers block of claude_desktop_config.json) and installed
# Desktop Extensions diverge per profile. Every sync reconciles mcpServers
# across all data dirs: missing servers are added everywhere, and when two
# profiles define the SAME server differently, the definition from the
# config file with the newest mtime wins and overwrites the others (edit a
# server in any profile, it propagates). Removing a server from any profile
# removes it everywhere too, tracked by an MCP ledger so "deleted" is never
# confused with "never had it"; --no-deletes skips (and thereby restores)
# removals. Every other key of each config file is untouched. Extensions
# stay copy-only (additive). Config writes are backed up into the run's
# manifest, so --revert undoes them too.
# Logins, cookies, and UI preferences are deliberately never synced:
# separate accounts are the whole point of profiles. Claude Code
# customization (plugins, skills, hooks, memory in ~/.claude) is already
# machine-global and needs no syncing. Session dirs inside profiles are
# claude-deck's job (it symlinks them to the shared one), not ours.
#
# Compatible with the stock macOS /bin/bash (3.2). No dependencies
# (JSON merging runs in macOS's built-in osascript JavaScript runtime).
#
# https://github.com/SMKeramati/claude-sync

VERSION="4.1.0"

# Absolute path: /usr/local/bin may shadow osascript with a wrapper (seen in
# the wild: a VPN toggle shim), and LaunchAgent PATH is minimal anyway.
OSASCRIPT="/usr/bin/osascript"

# CLAUDE_SYNC_SESSIONS_DIR / CLAUDE_SYNC_PROJECTS_DIR / CLAUDE_SYNC_HOME
# (and the two profile-root overrides) exist so tests can point the script
# at a throwaway tree instead of the real one.
SESSIONS_DIR="${CLAUDE_SYNC_SESSIONS_DIR:-$HOME/Library/Application Support/Claude/claude-code-sessions}"
SHARED_DIR="$SESSIONS_DIR/_shared"
# Transcripts: read-only source of truth for the self-heal step. Nothing
# under ~/.claude is ever written by the session machinery.
PROJECTS_DIR="${CLAUDE_SYNC_PROJECTS_DIR:-$HOME/.claude/projects}"
DEFAULT_ROOT="${CLAUDE_SYNC_DEFAULT_ROOT:-$HOME/Library/Application Support/Claude}"
PROFILES_DIR="${CLAUDE_SYNC_PROFILES_DIR:-$HOME/Library/Application Support/Claude Profiles}"
CANONICAL_DIR="${CLAUDE_SYNC_HOME:-$HOME/.claude/scripts}"
CANONICAL_PATH="$CANONICAL_DIR/claude-sync.sh"
LOG="$CANONICAL_DIR/claude-sync.log"
BACKUPS_DIR="$CANONICAL_DIR/backups"
BACKUP_KEEP=10
# Profile layer ledger: the MCP server names that were present in EVERY
# profile's config at the end of the last sync. A name in this ledger but
# missing from some profile now = the user removed it there, so it is
# removed everywhere. A name absent from the ledger = new, so it is added
# everywhere. Without this file no MCP removal can ever propagate.
MCP_LEDGER="$CANONICAL_DIR/mcp-ledger.tsv"
# Heal ledger: every session id self-heal has ever seen listed (or
# generated). An id here whose entry is gone was deleted by the user in
# the app; without this file every deletion would be resurrected from its
# transcript on the next run.
HEAL_LEDGER="$CANONICAL_DIR/heal-ledger.tsv"
# The retired v3 session ledger, read once (never written): its ids seed
# the heal ledger, so anything deleted in the app before the v4 migration
# stays deleted. .ledger-accounts.tsv stays obsolete and harmless.
V3_LEDGER="$CANONICAL_DIR/ledger.tsv"

RC_FILE="$HOME/.zshrc"
RC_BEGIN="# >>> claude-sync shortcut >>>"
RC_END="# <<< claude-sync shortcut <<<"

AGENT_LABEL="com.claude-sync.watcher"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

SOURCE_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# ---------- output helpers ----------------------------------------------
if [ -t 1 ]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; DIM=""; RESET=""
fi

log() {
  mkdir -p "$CANONICAL_DIR"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

die() { echo "${YELLOW}$*${RESET}" >&2; exit 1; }

# ---------- account discovery --------------------------------------------
# Globs only, no find: on macOS, find (getattrlistbulk) can return empty
# results inside freshly created session dirs while plain readdir works.
collect_accounts() {
  # One UUID folder per account. Underscore-prefixed dirs are not accounts:
  # "_shared" is ours (the unified list itself), anything else _-prefixed
  # was left by other tools.
  accounts=()
  for d in "$SESSIONS_DIR"/*/; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in _*) continue ;; esac
    accounts+=("${d%/}")
  done
}

count_shared_entries() {
  n=0
  for f in "$SHARED_DIR"/local_*.json; do
    [ -f "$f" ] && n=$((n + 1))
  done
  echo "$n"
}

# ---------- profile customization sync ------------------------------------
collect_roots() {
  # Every Claude data dir on this machine: the default one, plus one per
  # profile when a multi-profile launcher (claude-deck) is in use. The
  # default root comes first so its definitions win union conflicts.
  roots=("$DEFAULT_ROOT")
  for d in "$PROFILES_DIR"/*/; do
    [ -d "$d" ] || continue
    roots+=("${d%/}")
  done
}

ensure_run_dir() {
  # Backups for THIS run live in one dir with one manifest, shared by the
  # session plan executor and the profile config sync, so --revert undoes
  # a whole run no matter which layer wrote. Created lazily on first write.
  [ -n "${RUN_DIR:-}" ] && return 0
  RUN_DIR="$BACKUPS_DIR/$(date +%s)"
  MANIFEST="$RUN_DIR/manifest.tsv"
  mkdir -p "$RUN_DIR"
  : > "$MANIFEST"
}

# One JS program, run twice per sync ("plan" narrates, "write" applies), so
# both passes can never disagree on the decision logic. argv:
#   [0] mode "plan"|"write"   [1] "deletes"|"nodeletes"   [2] MCP ledger path
#   [3..] cfg-path, mtime pairs (default root's config always first).
# Decisions, per server name across all configs:
#   - name in the ledger but missing from >=1 config that HAS servers ->
#     removed everywhere (only when deletes are on; with --no-deletes the
#     missing copy is re-added instead, which is exactly the restore path).
#     A config with NO servers at all never votes for removal: that is a
#     fresh or app-reset profile, not a deliberate mass-delete (on Windows,
#     2026-07-23, one blank profile config made the watcher remove every
#     server from all ten profiles),
#   - definitions differ -> the one from the newest-mtime config wins and
#     overwrites the rest (tie: the default root, listed first, wins),
#   - name missing from a config -> added there.
# Output: "CHG<TAB>cfg<TAB>added<TAB>updated<TAB>removed" per touched file
# (comma-joined names, "-" for an empty list: bash read squeezes consecutive
# tabs, see the delete_rows comment), then "LEDGER<TAB>names" = the set every
# config holds after the write, which bash persists as the next ledger.
MCP_SYNC_JS='function run(argv) {
  ObjC.import("Foundation");
  function read(p) {
    var s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, $());
    return s.isNil() ? null : ObjC.unwrap(s);
  }
  function write(p, s) {
    $(s).writeToFileAtomicallyEncodingError($(p), true, $.NSUTF8StringEncoding, $());
  }
  var mode = argv[0], deletes = (argv[1] == "deletes"), ledgerPath = argv[2];
  var files = [], mts = [], cfgs = [];
  for (var i = 3; i < argv.length; i += 2) {
    files.push(argv[i]);
    mts.push(parseInt(argv[i + 1], 10) || 0);
  }
  for (var i = 0; i < files.length; i++) {
    var t = read(files[i]), j;
    try { j = t ? JSON.parse(t) : {}; }
    catch (e) { return "ERR not valid JSON, profile sync skipped: " + files[i]; }
    cfgs.push(j);
  }
  var ledger = {}, lt = read(ledgerPath);
  if (lt) {
    var ln = lt.split("\n");
    for (var i = 0; i < ln.length; i++) { if (ln[i]) ledger[ln[i]] = 1; }
  }
  var chosen = {}, chosenMt = {}, order = [], pcount = {}, voters = 0;
  for (var i = 0; i < files.length; i++) {
    var m = cfgs[i].mcpServers || {};
    var any = false;
    for (var k in m) {
      any = true;
      pcount[k] = (pcount[k] || 0) + 1;
      if (!(k in chosen)) { chosen[k] = m[k]; chosenMt[k] = mts[i]; order.push(k); }
      else if (mts[i] > chosenMt[k] && JSON.stringify(m[k]) !== JSON.stringify(chosen[k])) {
        chosen[k] = m[k]; chosenMt[k] = mts[i];
      }
    }
    if (any) voters++;
  }
  var removed = {};
  if (deletes) {
    for (var q = 0; q < order.length; q++) {
      var k = order[q];
      if (ledger[k] && pcount[k] < voters) removed[k] = 1;
    }
  }
  var out = [];
  for (var i = 0; i < files.length; i++) {
    var m = cfgs[i].mcpServers || {}, add = [], upd = [], del = [];
    for (var q = 0; q < order.length; q++) {
      var k = order[q];
      if (removed[k]) { if (k in m) { del.push(k); delete m[k]; } continue; }
      if (!(k in m)) { add.push(k); m[k] = chosen[k]; }
      else if (JSON.stringify(m[k]) !== JSON.stringify(chosen[k])) { upd.push(k); m[k] = chosen[k]; }
    }
    if (add.length || upd.length || del.length) {
      if (mode == "write") {
        cfgs[i].mcpServers = m;
        write(files[i], JSON.stringify(cfgs[i], null, 2) + "\n");
      }
      out.push("CHG\t" + files[i] + "\t" + (add.join(",") || "-") + "\t" + (upd.join(",") || "-") + "\t" + (del.join(",") || "-"));
    }
  }
  var fin = [];
  for (var q = 0; q < order.length; q++) { if (!removed[order[q]]) fin.push(order[q]); }
  out.push("LEDGER\t" + (fin.join(",") || "-"));
  return out.join("\n");
}'

sync_mcp_servers() {
  # Reconcile the mcpServers block of claude_desktop_config.json across
  # every root; every other key of each file is preserved. $1 = "dry"
  # narrates the plan and writes nothing; $2 = "deletes"/"nodeletes".
  # Real writes back the previous file into the run manifest as an
  # overwrite, so --revert restores it (removals included). JSON runs in
  # osascript's JS runtime: no deps.
  mode="$1"
  deletes="$2"
  [ ${#roots[@]} -lt 2 ] && return 0

  cfg_args=()
  n_cfgs=0
  for root in "${roots[@]}"; do
    cfg="$root/claude_desktop_config.json"
    if [ ! -f "$cfg" ]; then
      [ "$mode" = "dry" ] && continue
      printf '{}\n' > "$cfg" 2>/dev/null || continue
    fi
    cfg_args+=("$cfg" "$(stat -f %m "$cfg" 2>/dev/null || echo 0)")
    n_cfgs=$((n_cfgs + 1))
  done
  [ "$n_cfgs" -lt 2 ] && return 0

  plan_out=$("$OSASCRIPT" -l JavaScript -e "$MCP_SYNC_JS" plan "$deletes" "$MCP_LEDGER" "${cfg_args[@]}" 2>&1)
  case "$plan_out" in
    ERR*) log "MCP servers: ${plan_out#ERR }"; return 0 ;;
    "")   return 0 ;;
  esac

  # In dry mode just narrate the plan; otherwise back up every file the
  # write pass will touch, into this run's backup dir.
  has_changes=""
  while IFS=$'\t' read -r tag cfg add upd del; do
    case "$tag" in
      CHG) ;;
      *)   continue ;;
    esac
    has_changes=1
    if [ "$mode" = "dry" ]; then
      [ "$add" != "-" ] && echo "  ${DIM}would add MCP server(s)${RESET} [$add] -> $cfg"
      [ "$upd" != "-" ] && echo "  ${DIM}would update MCP server(s)${RESET} [$upd] -> $cfg"
      [ "$del" != "-" ] && echo "  ${DIM}would remove MCP server(s)${RESET} [$del] -> $cfg"
      continue
    fi
    ensure_run_dir
    mkdir -p "$RUN_DIR/configs"
    cp -p "$cfg" "$RUN_DIR/configs/$(echo "$cfg" | tr '/' '_')"
  done <<EOF_PLAN
$plan_out
EOF_PLAN

  if [ "$mode" = "dry" ]; then
    return 0
  fi

  merge_out=$("$OSASCRIPT" -l JavaScript -e "$MCP_SYNC_JS" write "$deletes" "$MCP_LEDGER" "${cfg_args[@]}" 2>&1)
  case "$merge_out" in
    ERR*) log "MCP servers: ${merge_out#ERR }"; return 0 ;;
  esac

  ledger_csv=""
  while IFS=$'\t' read -r tag cfg add upd del; do
    case "$tag" in
      LEDGER)
        ledger_csv="$cfg"
        continue
        ;;
      CHG) ;;
      *)   continue ;;
    esac
    ensure_run_dir
    parts=""
    [ "$add" != "-" ] && parts="added [$add]"
    [ "$upd" != "-" ] && parts="$parts${parts:+, }updated [$upd]"
    [ "$del" != "-" ] && parts="$parts${parts:+, }removed [$del]"
    log "  MCP server(s) $parts -> $cfg"
    printf 'overwrote\t%s\t%s\n' "$cfg" "$RUN_DIR/configs/$(echo "$cfg" | tr '/' '_')" >> "$MANIFEST"
  done <<EOF_OUT
$merge_out
EOF_OUT

  # Persist the post-write "present everywhere" set. Written atomically for
  # the same crash-safety reason as the session ledger.
  if [ -n "$ledger_csv" ]; then
    mcp_tmp="$CANONICAL_DIR/.mcp-ledger.tmp.$$"
    mkdir -p "$CANONICAL_DIR"
    if [ "$ledger_csv" = "-" ]; then
      : > "$mcp_tmp"
    else
      echo "$ledger_csv" | tr ',' '\n' > "$mcp_tmp"
    fi
    mv "$mcp_tmp" "$MCP_LEDGER"
  fi
}

sync_extensions() {
  # Copy installed Desktop Extensions across roots, additively. Best
  # effort: a Claude build that also tracks extensions in per-profile
  # preferences may still want one enable-click in that profile.
  mode="$1"
  [ ${#roots[@]} -lt 2 ] && return 0
  copied=0
  for src_root in "${roots[@]}"; do
    src_ext="$src_root/Claude Extensions"
    [ -d "$src_ext" ] || continue
    for ext in "$src_ext"/*/; do
      [ -d "$ext" ] || continue
      name=$(basename "$ext")
      for dst_root in "${roots[@]}"; do
        [ "$src_root" = "$dst_root" ] && continue
        dst="$dst_root/Claude Extensions/$name"
        if [ ! -e "$dst" ]; then
          if [ "$mode" = "dry" ]; then
            echo "  ${DIM}would copy extension${RESET} $name -> $(basename "$dst_root")"
            copied=$((copied + 1))
            continue
          fi
          mkdir -p "$dst_root/Claude Extensions"
          if cp -R "${ext%/}" "$dst"; then
            ensure_run_dir
            printf 'created\t%s\n' "$dst" >> "$MANIFEST"
            copied=$((copied + 1))
          fi
        fi
      done
    done
  done
  if [ "$copied" -gt 0 ] && [ "$mode" != "dry" ]; then
    log "Extensions: $copied copied across profiles."
  fi
  return 0
}

sync_profiles() {
  # Orchestrates the profile layer. Fast, runs before the session machinery,
  # and independent of it (profiles exist even with a single account).
  mode="$1"
  deletes="$2"
  collect_roots
  [ ${#roots[@]} -lt 2 ] && return 0
  sync_mcp_servers "$mode" "$deletes"
  sync_extensions "$mode"
}

# ---------- session list: one shared list + self-heal ---------------------
# v4 replaced the copy-everywhere session sync with a symlink design:
#   claude-code-sessions/_shared/          one physical set of local_*.json
#   <account>/<org>  ->  ../_shared        every subfolder is a symlink
# Every account/org sees the same list, a new session written by the app
# lands in _shared and appears everywhere instantly, and there is nothing
# left to reconcile (the v2/v3 winner/ledger/deletion machinery is gone).
# The self-heal step then recreates list entries the app lost: any
# transcript in ~/.claude/projects with no matching entry gets one
# generated from the transcript itself. Entries are never edited or
# deleted; transcripts are only ever read.
#
# v4.1 ports the lessons of the Windows v4 migration (the same design
# shipped there first and hit real data bugs within days):
#   - an app-created entry is named after the app's OWN session id and
#     carries the transcript id inside as cliSessionId, so "already
#     listed" must match BOTH, or every app-saved chat gets healed into a
#     duplicate (674 of 715 entries on this machine have differing ids);
#   - heal-ledger.tsv remembers every id ever listed, so an entry the
#     user deleted in the app is never resurrected from its transcript;
#     ids from the old v3 ledger.tsv seed it (an id there with no entry
#     now was deleted post-sync);
#   - transcripts are healed only when they are real conversations: UUID
#     filename, not a sidechain, and a usable title (custom title, first
#     user message, or summary);
#   - a config entry can be pretty-printed by the app ("isArchived": x),
#     so every field read tolerates both serializations;
#   - absorbing an org folder ORs the archived flag across copies (v3
#     semantics: archived-in-one means archived), verifies every file
#     landed in _shared before the folder is removed, leaves any folder
#     with unexpected content real (reported, never forced), and a hard
#     failure mid-restructure auto-restores the whole tree from this
#     run's backup.
# The Windows archive-replay subsystem (tailing the app's main.log) is
# deliberately NOT ported: it works around an MSIX packaging bug where
# the app logs archive clicks but never persists the flag. On macOS the
# flag demonstrably persists (verified 2026-07-23 across four profiles:
# the newest logged archive event and the entry on disk agree). If a
# macOS build ever ships the same bug, port Invoke-ArchiveReplay from
# claude-sync.ps1.
#
# Intermediate state lives in $WORK_DIR (a mktemp dir, removed on exit):
#   real_orgs.tsv   account<TAB>orgPath   (org dirs still needing absorb)
#   listed_ids.txt  ids already listed (file names + cliSessionId values)
#   seen_ids.txt    heal-ledger ids + v3-ledger ids (tombstones)
#   heal_list.txt   transcript paths needing a regenerated entry
# Paths contain spaces ("Application Support") but never tabs or newlines,
# so TSV is a safe interchange format as long as every expansion is quoted.

claude_desktop_running() {
  # Structural work moves the app's live data dirs, so it may only run
  # while Claude Desktop is fully closed. A test tree (env override) is
  # invisible to the real app, so the guard does not apply there; an
  # override pointed AT the real tree does not disable the guard.
  if [ -n "${CLAUDE_SYNC_SESSIONS_DIR:-}" ]; then
    [ "$SESSIONS_DIR" != "$HOME/Library/Application Support/Claude/claude-code-sessions" ] && return 1
  fi
  pgrep -x "Claude" > /dev/null 2>&1
}

session_meta() {
  # "lastActivityAt<TAB>isArchived(0/1)" of one list file. Entries come in
  # two serializations: the compact one most files carry and the
  # pretty-printed one ("isArchived": false) the app writes when it
  # re-persists an entry, so both reads tolerate optional whitespace. The
  # JSON is a single line with no trailing newline, so RS is a byte that
  # never appears in the file: one file, exactly one awk record.
  awk 'BEGIN { RS = "\3" }
    {
      ts = 0
      if (match($0, /"lastActivityAt"[ \t]*:[ \t]*[0-9]+/)) {
        t = substr($0, RSTART, RLENGTH)
        sub(/^"lastActivityAt"[ \t]*:[ \t]*/, "", t)
        ts = t + 0
      }
      arch = ($0 ~ /"isArchived"[ \t]*:[ \t]*true/) ? 1 : 0
      print ts "\t" arch
      exit
    }' "$1"
}

find_real_orgs() {
  # account-name<TAB>org-path for every org subfolder that is still a real
  # directory (first run, or a fresh folder the app created after logging
  # in to a new account/org). Symlinks never qualify: ours point at
  # _shared and are already unified; foreign ones are left alone.
  : > "$WORK_DIR/real_orgs.tsv"
  for acct in "${accounts[@]}"; do
    for org in "$acct"/*/; do
      org="${org%/}"
      [ -e "$org" ] || continue
      [ -L "$org" ] && continue
      [ -d "$org" ] || continue
      printf '%s\t%s\n' "$(basename "$acct")" "$org" >> "$WORK_DIR/real_orgs.tsv"
    done
  done
}

backup_sessions_tree() {
  # Whole-tree safety net, taken before any restructure. -RP copies
  # symlinks as symlinks (a later absorb run backs up an already-linked
  # tree). The manifest row lets --revert restore the tree verbatim.
  ensure_run_dir
  cp -RP "$SESSIONS_DIR" "$RUN_DIR/claude-code-sessions" || return 1
  printf 'tree\t%s\t%s\n' "$SESSIONS_DIR" "$RUN_DIR/claude-code-sessions" >> "$MANIFEST"
}

org_has_strays() {
  # Anything in the org dir that is not a regular local_*.json file (and
  # not Finder junk) means we do not understand this folder; it stays a
  # real dir and is reported, never forced (Windows v4 semantics).
  for f in "$1"/* "$1"/.[!.]*; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    b="${f##*/}"
    case "$b" in
      local_*.json) [ -f "$f" ] && [ ! -L "$f" ] || return 0 ;;
      .DS_Store|.localized) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

absorb_org_dir() {
  # $1 = account name, $2 = org dir path. Move every list file into
  # _shared; on a name collision the copy with the newer lastActivityAt
  # wins and the archived flag is OR-ed across copies (v3 semantics:
  # archived-in-one means archived; the tree backup keeps every loser).
  # Before the emptied dir is swapped for a relative symlink, every file
  # must verifiably exist in _shared; any failure returns 1 and the
  # caller aborts the whole restructure and restores the tree.
  acct_name="$1"
  org_path="$2"
  org_name=$(basename "$org_path")
  absorbed=0
  for f in "$org_path"/local_*.json; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    dst="$SHARED_DIR/$fname"
    if [ -f "$dst" ]; then
      # v3 synced copies are usually byte-identical: cmp short-circuits
      # the common case so we don't fork awk twice per collision (~10k
      # files on a long-lived tree).
      if ! cmp -s "$f" "$dst"; then
        IFS=$'\t' read -r o_ts o_arch <<EOF_M
$(session_meta "$f")
EOF_M
        IFS=$'\t' read -r s_ts s_arch <<EOF_M
$(session_meta "$dst")
EOF_M
        # OR of the ORIGINAL flags, decided before either copy can be
        # overwritten: archived-in-one means archived (v3 semantics).
        or_arch=0
        { [ "$o_arch" = "1" ] || [ "$s_arch" = "1" ]; } && or_arch=1
        if [ "$o_ts" -gt "$s_ts" ]; then
          cp -p "$f" "$dst"
          n_conflicts=$((n_conflicts + 1))
        fi
        if [ "$or_arch" = "1" ]; then
          if [ "$(session_meta "$dst" | cut -f2)" = "0" ]; then
            # Flip in place, tolerant of both serializations; command
            # substitution strips the trailing newline sed adds, keeping
            # the app's exact no-trailing-newline format; keep the mtime.
            flip_tmp="$WORK_DIR/.flip.$$"
            printf '%s' "$(sed 's/\("isArchived"[ \t]*:[ \t]*\)false/\1true/' "$dst")" > "$flip_tmp"
            touch -r "$dst" "$flip_tmp"
            mv "$flip_tmp" "$dst"
            n_archflips=$((n_archflips + 1))
          fi
        fi
      fi
      rm -f "$f"
    else
      mv "$f" "$dst"
    fi
    absorbed=$((absorbed + 1))
  done
  rm -f "$org_path/.DS_Store" "$org_path/.localized"
  # Belt and suspenders: nothing may be lost by the removal.
  for f in "$org_path"/* "$org_path"/.[!.]*; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    log "  ${YELLOW}entry was not absorbed into _shared: $f${RESET}"
    return 1
  done
  rmdir "$org_path" || return 1
  # The link lives at <sessions>/<acct>/<org>, so it resolves relative to
  # <acct>: ../_shared lands on <sessions>/_shared. Relative on purpose,
  # so a moved or renamed home directory cannot orphan the links.
  ln -s "../_shared" "$org_path" || return 1
  log "  $acct_name/$org_name: absorbed $absorbed file(s), now a symlink to _shared"
}

restore_tree_from_run_backup() {
  # Emergency path for a failure mid-restructure: put the pre-run tree
  # back exactly as it was, from THIS run's backup.
  [ -d "$RUN_DIR/claude-code-sessions" ] || return 1
  rm -rf "$SESSIONS_DIR"
  cp -RP "$RUN_DIR/claude-code-sessions" "$SESSIONS_DIR"
}

unify_sessions() {
  # One-time restructure, and the absorber for any fresh real folder the
  # app creates later. Idempotent: an already-linked tree has no real org
  # dirs and this is a no-op. Returns 0 (done or nothing to do),
  # 1 (hard failure, tree restored), 2 (postponed: Claude is running;
  # self-heal still runs, the restructure waits for a closed app).
  mode="$1"
  find_real_orgs
  [ -s "$WORK_DIR/real_orgs.tsv" ] || return 0

  # Folders holding anything unexpected are left real and reported.
  : > "$WORK_DIR/absorb_orgs.tsv"
  while IFS=$'\t' read -r acct_name org_path; do
    if org_has_strays "$org_path"; then
      if [ "$mode" = "dry" ]; then
        echo "  ${DIM}would leave REAL (unexpected content):${RESET} $org_path"
      else
        log "  ${YELLOW}left REAL, unexpected content: $org_path${RESET}"
      fi
    else
      printf '%s\t%s\n' "$acct_name" "$org_path" >> "$WORK_DIR/absorb_orgs.tsv"
    fi
  done < "$WORK_DIR/real_orgs.tsv"
  [ -s "$WORK_DIR/absorb_orgs.tsv" ] || return 0

  if [ "$mode" = "dry" ]; then
    while IFS=$'\t' read -r acct_name org_path; do
      n=0
      for f in "$org_path"/local_*.json; do
        [ -f "$f" ] && n=$((n + 1))
      done
      echo "  ${DIM}would absorb${RESET} $acct_name/$(basename "$org_path") ($n file(s)) ${DIM}into _shared and replace it with a symlink${RESET}"
    done < "$WORK_DIR/absorb_orgs.tsv"
    return 0
  fi

  if claude_desktop_running; then
    log "Claude Desktop is running: the session-list restructure is postponed"
    log "until it is fully closed (Cmd+Q, all profiles). Self-heal still runs."
    return 2
  fi

  if ! backup_sessions_tree; then
    log "Backup of $SESSIONS_DIR failed; not touching it."
    return 1
  fi
  mkdir -p "$SHARED_DIR"
  log "Unifying session lists into _shared..."
  n_conflicts=0
  n_archflips=0
  while IFS=$'\t' read -r acct_name org_path; do
    if ! absorb_org_dir "$acct_name" "$org_path"; then
      log "${YELLOW}RESTRUCTURE FAILED at $org_path. Restoring the pre-run tree from this run's backup...${RESET}"
      if restore_tree_from_run_backup; then
        log "Restored. The sessions tree is back to its pre-run state."
      else
        log "${YELLOW}AUTOMATIC RESTORE FAILED. Restore manually from: $RUN_DIR/claude-code-sessions${RESET}"
      fi
      return 1
    fi
  done < "$WORK_DIR/absorb_orgs.tsv"
  log "Unified: $(count_shared_entries) session entries in _shared ($n_conflicts diverging copies resolved by newest activity, $n_archflips archive flags propagated)."

  # Seed the heal ledger: every id visible now, plus every id the old v3
  # ledger ever saw fully synced. An id whose entry is absent from the
  # union but present in the v3 ledger was deleted by the user after its
  # last full sync; seeding it keeps self-heal from resurrecting it out
  # of its transcript.
  {
    for f in "$SHARED_DIR"/local_*.json; do
      [ -f "$f" ] || continue
      b="${f##*/}"; b="${b%.json}"
      printf '%s\n' "${b#local_}"
    done
    # v3 ids persist as tombstones from day one, exactly like Windows.
    read_tombstones "$WORK_DIR/.v3seed.txt"
    cat "$WORK_DIR/.v3seed.txt"
  } > "$WORK_DIR/seed_ids.txt"
  save_heal_ledger "$WORK_DIR/seed_ids.txt"
  return 0
}

# ---------- heal ledger (tombstones) ---------------------------------------
read_tombstones() {
  # Union of the heal ledger and the old v3 session ledger into $1, one
  # lowercase id per line. An id here whose entry is gone was deleted by
  # the user in the app; without this file every deletion would be
  # resurrected from its transcript on the next run. Merging the v3 ids
  # at read time (not only at unify time) keeps dry and real runs agreeing.
  {
    [ -f "$HEAL_LEDGER" ] && cat "$HEAL_LEDGER"
    if [ -f "$V3_LEDGER" ]; then
      awk -F'\t' '$1 ~ /^local_[0-9a-fA-F-]+\.json$/ {
        id = substr($1, 7, length($1) - 11)
        if (length(id) == 36) print id
      }' "$V3_LEDGER"
    fi
  } | tr 'A-F' 'a-f' | awk 'length($0) == 36' | sort -u > "$1"
}

save_heal_ledger() {
  # $1 = file of ids to merge in. Atomic (temp + mv), backed into the run
  # manifest, and skipped entirely when nothing changed so idle runs stay
  # write-free.
  merged="$WORK_DIR/.ledger_merged.$$"
  {
    [ -f "$HEAL_LEDGER" ] && cat "$HEAL_LEDGER"
    cat "$1"
  } | tr 'A-F' 'a-f' | awk 'length($0) == 36' | sort -u > "$merged"
  if [ -f "$HEAL_LEDGER" ] && cmp -s "$merged" "$HEAL_LEDGER"; then
    rm -f "$merged"
    return 0
  fi
  ensure_run_dir
  if [ -f "$HEAL_LEDGER" ]; then
    if [ ! -f "$RUN_DIR/heal-ledger.tsv.pre" ]; then
      cp -p "$HEAL_LEDGER" "$RUN_DIR/heal-ledger.tsv.pre"
      printf 'overwrote\t%s\t%s\n' "$HEAL_LEDGER" "$RUN_DIR/heal-ledger.tsv.pre" >> "$MANIFEST"
    fi
  else
    printf 'created\t%s\n' "$HEAL_LEDGER" >> "$MANIFEST"
  fi
  mkdir -p "$CANONICAL_DIR"
  ledger_tmp="$CANONICAL_DIR/.heal-ledger.tmp.$$"
  cp "$merged" "$ledger_tmp"
  mv "$ledger_tmp" "$HEAL_LEDGER"
  rm -f "$merged"
}

# Self-heal runs in osascript's JS runtime (no deps), one invocation per
# sync. argv: [0] "plan"|"write"  [1] _shared dir  [2] path of a file
# listing one transcript path per line. Per transcript, from the first
# ~250 lines: cwd, createdAt, model, and the title (a recorded custom
# title wins; else the first real user message, with command wrappers,
# "Caveat:" preambles, interrupted-request markers and isMeta rows
# skipped; else the recorded summary); from the tail chunk: the last
# timestamp and any late custom-title rename. Sidechain transcripts and
# transcripts with no usable title are skipped, mirroring the Windows
# implementation. "write" creates _shared/local_<id>.json compact, no
# trailing newline, exactly like the app's own files, stamps the file
# mtime with lastActivityAt, and refuses to overwrite an existing entry.
# Output per transcript: "MK<TAB>fname<TAB>title" or
# "SKIP<TAB>id<TAB>reason".
HEAL_JS='function run(argv) {
  ObjC.import("Foundation");
  var HEAD = 524288, TAIL = 65536;
  function read(p) {
    var s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, $());
    return s.isNil() ? null : ObjC.unwrap(s);
  }
  function write(p, s) {
    $(s).writeToFileAtomicallyEncodingError($(p), true, $.NSUTF8StringEncoding, $());
  }
  function decode(data, trimStart) {
    // A byte-offset chunk can tear a multibyte UTF-8 char at its edge and
    // make strict decoding fail; shaving up to 3 edge bytes always yields
    // a valid boundary. Torn half-lines then just fail JSON.parse below.
    var len = data.length;
    for (var k = 0; k <= 3 && k < len; k++) {
      var sub = data.subdataWithRange($.NSMakeRange(trimStart ? k : 0, len - k));
      var s = $.NSString.alloc.initWithDataEncoding(sub, $.NSUTF8StringEncoding);
      if (!s.isNil()) return ObjC.unwrap(s);
    }
    return "";
  }
  function readChunks(p) {
    // Transcripts can be tens of MB; everything the heal needs sits in
    // the first and last lines. The file is memory-mapped (no full read)
    // and only the head/tail byte ranges are ever decoded.
    var d = $.NSData.dataWithContentsOfFileOptionsError($(p), $.NSDataReadingMappedIfSafe, $());
    if (d.isNil()) return null;
    var size = Number(d.length);
    if (size == 0) return null;
    if (size <= HEAD + TAIL) {
      var whole = decode(d, false);
      if (!whole) return null;
      var wl = whole.split("\n");
      return { head: wl, tail: wl };
    }
    var hs = decode(d.subdataWithRange($.NSMakeRange(0, HEAD)), false);
    var ts = decode(d.subdataWithRange($.NSMakeRange(size - TAIL, TAIL)), true);
    return { head: hs.split("\n"), tail: ts.split("\n") };
  }
  function cleanTitle(t) {
    t = String(t).replace(/\s+/g, " ").replace(/^ +| +$/g, "");
    if (t.length > 60) t = t.slice(0, 60).replace(/ +$/, "");
    return t;
  }
  function fileDates(p) {
    var a = $.NSFileManager.defaultManager.attributesOfItemAtPathError($(p), $());
    var r = { created: 0, modified: 0 };
    if (a.isNil()) return r;
    var c = a.objectForKey($.NSFileCreationDate), m = a.objectForKey($.NSFileModificationDate);
    if (!c.isNil()) r.created = Math.round(c.timeIntervalSince1970 * 1000);
    if (!m.isNil()) r.modified = Math.round(m.timeIntervalSince1970 * 1000);
    return r;
  }
  var mode = argv[0], shared = argv[1], listText = read(argv[2]);
  if (!listText) return "";
  var home = ObjC.unwrap($.NSHomeDirectory());
  var paths = listText.split("\n");
  var out = [];
  for (var i = 0; i < paths.length; i++) {
    var p = paths[i];
    if (!p) continue;
    var base = p.split("/").pop();
    var id = base.replace(/\.jsonl$/, "");
    var ck = readChunks(p);
    if (!ck) { out.push("SKIP\t" + id + "\tunreadable or empty"); continue; }
    var lines = ck.head;
    var cwd = "", model = "", title = "", titleSource = "auto", summaryTitle = "";
    var created = 0, last = 0, sawUser = false, sawMessageEntry = false, sidechain = false;
    var head = Math.min(lines.length, 250);
    for (var j = 0; j < head; j++) {
      if (!lines[j]) continue;
      var o;
      try { o = JSON.parse(lines[j]); } catch (e) { continue; }
      if (o.type == "custom-title" && o.customTitle) {
        var ct = cleanTitle(o.customTitle);
        if (ct) { title = ct; titleSource = "custom"; }
      }
      if (!summaryTitle && o.type == "summary" && o.summary) summaryTitle = String(o.summary);
      if (!cwd && o.cwd) cwd = String(o.cwd);
      var ts = o.timestamp ? Date.parse(o.timestamp) : 0;
      if (ts > 0) {
        if (!created || ts < created) created = ts;
        if (ts > last) last = ts;
      }
      if (!model && o.message && o.message.model && String(o.message.model).indexOf("claude-") == 0) {
        model = String(o.message.model);
      }
      if (("parentUuid" in o) && !sawMessageEntry) {
        // Only the file own first message entry decides sidechain-ness;
        // quoted content later cannot.
        sawMessageEntry = true;
        if (o.isSidechain === true) { sidechain = true; break; }
      }
      if (!title && o.type == "user" && o.isMeta !== true && o.message && o.message.content != null) {
        sawUser = true;
        var c = o.message.content, txt = "";
        if (typeof c == "string") txt = c;
        else if (Array.isArray(c)) {
          for (var q = 0; q < c.length; q++) {
            if (c[q] && c[q].type == "text" && c[q].text) { txt = String(c[q].text); break; }
          }
        }
        txt = cleanTitle(txt);
        var bad = (txt == "") || txt.indexOf("Caveat:") == 0 || txt.indexOf("<command-") == 0 ||
                  txt.indexOf("<local-command") == 0 || txt.indexOf("[Request interrupted") == 0 ||
                  txt.indexOf("<system") == 0;
        if (!bad) title = txt;
      }
    }
    if (sidechain) { out.push("SKIP\t" + id + "\tsidechain"); continue; }
    var tl = ck.tail;
    for (var j = tl.length - 1; j >= 0; j--) {
      if (!tl[j]) continue;
      var o2;
      try { o2 = JSON.parse(tl[j]); } catch (e) { continue; }
      var ts2 = o2.timestamp ? Date.parse(o2.timestamp) : 0;
      if (ts2 > last) last = ts2;
      // A late rename lives near the end of the file; the newest one wins.
      if (o2.type == "custom-title" && o2.customTitle && titleSource != "tailcustom") {
        var ct2 = cleanTitle(o2.customTitle);
        if (ct2) { title = ct2; titleSource = "tailcustom"; }
      }
      if (ts2 > 0 && titleSource != "auto") break;
      if (ts2 > 0 && j < tl.length - 20) break;
    }
    if (titleSource == "tailcustom") titleSource = "custom";
    if (!title && summaryTitle) {
      var st = cleanTitle(summaryTitle);
      if (st) title = st;
    }
    if (!title) { out.push("SKIP\t" + id + "\tno usable title (no user message)"); continue; }
    var fd = fileDates(p);
    if (!created) created = fd.created;
    if (!created) created = fd.modified;
    if (!last) last = fd.modified;
    if (!created) { out.push("SKIP\t" + id + "\tno timestamps"); continue; }
    if (last < created) last = created;
    if (!cwd) cwd = home;
    if (!model) model = "claude-opus-4-8";
    var entry = {
      sessionId: "local_" + id, cliSessionId: id,
      cwd: cwd, originCwd: cwd,
      lastFocusedAt: last, createdAt: created, lastActivityAt: last,
      model: model, effort: "high",
      isArchived: false, title: title, titleSource: titleSource,
      permissionMode: "bypassPermissions", enabledMcpTools: {}
    };
    var dst = shared + "/local_" + id + ".json";
    if (mode == "write") {
      if ($.NSFileManager.defaultManager.fileExistsAtPath($(dst))) {
        out.push("SKIP\t" + id + "\tentry exists");
        continue;
      }
      write(dst, JSON.stringify(entry));
      var attrs = $.NSDictionary.dictionaryWithObjectForKey(
        $.NSDate.dateWithTimeIntervalSince1970(last / 1000), $("NSFileModificationDate"));
      $.NSFileManager.defaultManager.setAttributesOfItemAtPathError(attrs, $(dst), $());
    }
    out.push("MK\tlocal_" + id + ".json\t" + title);
  }
  return out.join("\n");
}'

heal_missing_entries() {
  # Recreate lost list entries from transcripts. Read-only towards
  # ~/.claude; additive-only towards _shared. Runs every pass, safe with
  # Claude open (the app reads the list at launch).
  mode="$1"
  [ -d "$PROJECTS_DIR" ] || return 0
  if [ "$mode" != "dry" ] && [ ! -d "$SHARED_DIR" ]; then
    return 0
  fi

  # Ids that already have a list entry: entry FILE NAMES are not enough.
  # An app-created entry is named after the app's own session id and
  # carries the transcript id inside as cliSessionId; only the
  # heal-generated shape has the two equal. One awk pass over every entry
  # (xargs -0 batches around ARG_MAX) collects both. Pre-unify dry runs
  # scan the org dirs too, so the preview matches what a real run would do.
  : > "$WORK_DIR/entry_paths.nul"
  for f in "$SHARED_DIR"/local_*.json "$SESSIONS_DIR"/*/*/local_*.json; do
    [ -f "$f" ] || continue
    printf '%s\0' "$f" >> "$WORK_DIR/entry_paths.nul"
  done
  : > "$WORK_DIR/listed_raw.txt"
  if [ -s "$WORK_DIR/entry_paths.nul" ]; then
    xargs -0 awk '
      BEGIN { RS = "\3" }
      FNR == 1 {
        n = split(FILENAME, comp, "/")
        fname = comp[n]
        if (fname ~ /^local_[0-9a-fA-F-]+\.json$/) {
          id = substr(fname, 7, length(fname) - 11)
          if (length(id) == 36) print id
        }
        if (match($0, /"cliSessionId"[ \t]*:[ \t]*"[0-9a-fA-F-]+"/)) {
          s = substr($0, RSTART, RLENGTH)
          sub(/^"cliSessionId"[ \t]*:[ \t]*"/, "", s)
          sub(/"$/, "", s)
          if (length(s) == 36) print s
        }
      }
    ' < "$WORK_DIR/entry_paths.nul" >> "$WORK_DIR/listed_raw.txt"
  fi
  tr 'A-F' 'a-f' < "$WORK_DIR/listed_raw.txt" | sort -u > "$WORK_DIR/listed_ids.txt"

  read_tombstones "$WORK_DIR/seen_ids.txt"

  # Transcripts wanting an entry: UUID filenames only (agent scratch files
  # and other tools' jsonl never qualify).
  {
    for tr in "$PROJECTS_DIR"/*/*.jsonl; do
      [ -f "$tr" ] || continue
      b="${tr##*/}"
      printf '%s\t%s\n' "${b%.jsonl}" "$tr"
    done
  } > "$WORK_DIR/want.tsv"
  [ -s "$WORK_DIR/want.tsv" ] || return 0

  awk -F'\t' -v LISTED="$WORK_DIR/listed_ids.txt" -v SEEN="$WORK_DIR/seen_ids.txt" \
      -v SKIPSEEN="$WORK_DIR/skip_seen.count" '
    BEGIN {
      while ((getline line < LISTED) > 0) listed[line] = 1
      close(LISTED)
      while ((getline line < SEEN) > 0) seen[line] = 1
      close(SEEN)
      nseen = 0
    }
    {
      id = tolower($1)
      if (id !~ /^[0-9a-f-]+$/ || length(id) != 36) next
      if (id in listed) next
      if (id in seen) { nseen++; next }
      print $2
    }
    END { print nseen > SKIPSEEN }
  ' "$WORK_DIR/want.tsv" > "$WORK_DIR/heal_list.txt"
  skip_seen=$(cat "$WORK_DIR/skip_seen.count" 2>/dev/null || echo 0)

  healed=0
  skipped=0
  if [ -s "$WORK_DIR/heal_list.txt" ]; then
    jsmode="write"
    [ "$mode" = "dry" ] && jsmode="plan"
    heal_out=$("$OSASCRIPT" -l JavaScript -e "$HEAL_JS" "$jsmode" "$SHARED_DIR" "$WORK_DIR/heal_list.txt" 2>&1)

    while IFS=$'\t' read -r tag fname title; do
      case "$tag" in
        MK)
          if [ "$mode" = "dry" ]; then
            echo "  ${DIM}would recreate list entry${RESET} $fname (\"$title\")"
          else
            ensure_run_dir
            printf 'created\t%s\n' "$SHARED_DIR/$fname" >> "$MANIFEST"
            log "  generated from transcript: $fname (\"$title\")"
            healed=$((healed + 1))
          fi
          ;;
        SKIP)
          skipped=$((skipped + 1))
          [ "$mode" = "dry" ] && echo "  ${DIM}skip transcript $fname: $title${RESET}"
          ;;
      esac
    done <<EOF_HEAL
$heal_out
EOF_HEAL
  fi

  if [ "$mode" = "dry" ]; then
    [ "$skip_seen" -gt 0 ] && echo "  ${DIM}$skip_seen transcript(s) skipped: deleted in the app before (heal ledger), never resurrected${RESET}"
    return 0
  fi

  # Every id listed right now becomes a tombstone: if the user later
  # deletes its entry in the app, self-heal will never bring it back. The
  # already-known tombstones (heal ledger + v3 ids) are re-saved with
  # them, so the v3 seed persists in heal-ledger.tsv itself (Windows
  # parity: Save-HealLedger writes the merged seen set back).
  {
    cat "$WORK_DIR/listed_ids.txt" "$WORK_DIR/seen_ids.txt"
    if [ "$healed" -gt 0 ]; then
      awk -F'\t' '$1 == "MK" { sub(/^local_/, "", $2); sub(/\.json$/, "", $2); print $2 }' <<EOF_IDS
$heal_out
EOF_IDS
    fi
  } > "$WORK_DIR/now_listed.txt"
  save_heal_ledger "$WORK_DIR/now_listed.txt"

  if [ "$healed" -gt 0 ]; then
    log "Self-heal: $healed lost session(s) restored to the list ($skip_seen deleted-before skipped, $skipped not healable)."
  fi
  return 0
}

sync_sessions() {
  # Orchestrates the session layer: unify (when needed), then self-heal.
  # A postponed restructure (Claude running) does not block healing.
  mode="$1"
  collect_accounts
  if [ ${#accounts[@]} -eq 0 ]; then
    log "No account folders in $SESSIONS_DIR yet; nothing to unify."
    return 0
  fi
  unify_sessions "$mode"
  unify_rc=$?
  [ "$unify_rc" = "1" ] && return 1
  heal_missing_entries "$mode"
  if [ "$mode" != "dry" ] && [ -d "$SHARED_DIR" ] && [ "$unify_rc" = "0" ]; then
    log "Session list: $(count_shared_entries) entries in _shared, seen by all ${#accounts[@]} account(s)."
  fi
  return 0
}
prune_backups() {
  # Keep the newest $BACKUP_KEEP runs. Run dirs are named by epoch (plus a
  # ".reverted" suffix after a revert), so a numeric sort of basenames
  # orders them by age; the names are ours and contain no spaces.
  [ -d "$BACKUPS_DIR" ] || return 0
  old=$(
    for d in "$BACKUPS_DIR"/*/; do
      [ -d "$d" ] && basename "$d"
    done | sort -n | awk -v keep="$BACKUP_KEEP" '
      { a[NR] = $0 } END { for (i = 1; i <= NR - keep; i++) print a[i] }'
  )
  for b in $old; do
    rm -rf "$BACKUPS_DIR/$b"
  done
}

do_sync() {
  # Wrapper owning the temp workspace: the watcher calls do_sync in a loop,
  # so cleanup cannot rely on the EXIT trap alone.
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-sync.XXXXXX") || die "mktemp failed"
  trap 'rm -rf "$WORK_DIR"' EXIT
  sync_run "$@"
  rc=$?
  rm -rf "$WORK_DIR"
  return $rc
}

sync_run() {
  # $1 = "dry" for --dry-run: narrate every action, write nothing.
  # $2 = "nodeletes" for --no-deletes; since v4 it only affects the MCP
  # server layer (one physical session list has no deletions to sync).
  mode="${1:-}"
  sync_deletes="${2:-deletes}"
  [ "$sync_deletes" != "nodeletes" ] && sync_deletes="deletes"

  # Profile customization first: fast, and independent of the session
  # machinery (profiles exist even with a single account or no sessions).
  sync_profiles "$mode" "$sync_deletes"

  if [ ! -d "$SESSIONS_DIR" ]; then
    log "Sessions folder not found: $SESSIONS_DIR"
    log "Open Claude Desktop, go to Claude Code, and start one session first."
    return 1
  fi

  if [ "$mode" = "dry" ]; then
    echo "Dry run. Planned session actions:"
    sync_sessions "dry"
    rc=$?
    echo "${DIM}Nothing was written.${RESET}"
    return $rc
  fi

  sync_sessions "$mode" || return 1
  if [ -n "${RUN_DIR:-}" ]; then
    prune_backups
    log "Sync complete. Backup: $RUN_DIR ${DIM}(claude-sync --revert undoes this run)${RESET}"
  else
    log "Sync complete. Nothing needed writing."
  fi
  return 0
}

cmd_revert() {
  # Undo the most recent sync run, then mark its backup dir .reverted so a
  # second --revert targets the run before it.
  # A run that restructured the session tree left a 'tree' manifest row:
  # the whole claude-code-sessions tree is restored from that backup
  # verbatim (real folders again, no symlinks, no _shared). List entries
  # born AFTER the backup (the app kept writing into _shared) are salvaged
  # into every restored org folder first, so no session disappears.
  # Rows inside the session tree are covered by the tree restore and are
  # skipped; config/extension rows are undone as before.
  [ -d "$BACKUPS_DIR" ] || die "No backups found ($BACKUPS_DIR). Nothing to revert."

  latest=""
  for d in "$BACKUPS_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    case "$name" in *.reverted) continue ;; esac
    [ -f "$d/manifest.tsv" ] || continue
    if [ -z "$latest" ] || [ "$name" -gt "$(basename "$latest")" ]; then
      latest="${d%/}"
    fi
  done
  [ -n "$latest" ] || die "No backup run left to revert."

  tree_path=""; tree_backup=""
  while IFS=$'\t' read -r op path bpath; do
    if [ "$op" = "tree" ]; then
      tree_path="$path"
      tree_backup="$bpath"
    fi
  done < "$latest/manifest.tsv"

  log "Reverting sync run $(basename "$latest")..."

  restored_tree=0
  if [ -n "$tree_backup" ]; then
    [ -d "$tree_backup" ] || die "Tree backup missing: $tree_backup"
    if claude_desktop_running; then
      die "Claude Desktop is running. Quit it completely (Cmd+Q, all profiles), then run --revert again."
    fi
    # Salvage: entries now in _shared that are neither in the backup nor
    # created by this very run (i.e. the app wrote them after the backup).
    salvage=$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-salvage.XXXXXX") || die "mktemp failed"
    n_salvage=0
    for f in "$tree_path/_shared"/local_*.json; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      grep -qF "created"$'\t'"$f" "$latest/manifest.tsv" && continue
      found=""
      for g in "$tree_backup/_shared/$fname" "$tree_backup"/*/*/"$fname"; do
        if [ -f "$g" ]; then
          found=1
          break
        fi
      done
      [ -n "$found" ] && continue
      cp -p "$f" "$salvage/$fname"
      n_salvage=$((n_salvage + 1))
    done

    rm -rf "$tree_path"
    cp -RP "$tree_backup" "$tree_path"
    log "Restored $tree_path from the run's whole-tree backup."

    if [ "$n_salvage" -gt 0 ]; then
      for org in "$tree_path"/*/*/; do
        org="${org%/}"
        [ -L "$org" ] && continue
        [ -d "$org" ] || continue
        cp -p "$salvage"/local_*.json "$org"/
      done
      [ -d "$tree_path/_shared" ] && cp -p "$salvage"/local_*.json "$tree_path/_shared/"
      log "Salvaged $n_salvage newer session entries into the restored folders."
    fi
    rm -rf "$salvage"
    restored_tree=1
  fi

  removed=0; restored=0; undeleted=0
  while IFS=$'\t' read -r op path bpath; do
    [ "$op" = "tree" ] && continue
    if [ "$restored_tree" = "1" ]; then
      case "$path" in "$tree_path"/*) continue ;; esac
    fi
    case "$op" in
      created)
        rm -f "$path"
        removed=$((removed + 1))
        ;;
      overwrote)
        cp -p "$bpath" "$path"
        restored=$((restored + 1))
        ;;
      deleted)
        # Rows from pre-v4 backups. The file does not exist at revert time
        # (that is the point of a delete row); a plain copy-back is right.
        cp -p "$bpath" "$path"
        undeleted=$((undeleted + 1))
        ;;
    esac
  done < "$latest/manifest.tsv"

  mv "$latest" "$latest.reverted"
  log "Reverted: removed $removed created file(s), restored $restored overwritten file(s), restored $undeleted deleted file(s)."
  log "${DIM}Backup kept at $latest.reverted. Run --revert again to undo the previous run.${RESET}"
}

# ---------- watcher (hands-off mode) -------------------------------------
cmd_watch() {
  # Transcript-driven, mirroring the Windows watcher: a conversation
  # exists the moment its .jsonl transcript does, so quit detection is
  # gone entirely (a quitting app's final writes are themselves activity).
  # Self-heal is additive and safe with the app open; the restructure part
  # self-postpones while any instance runs. macOS has no FileSystemWatcher
  # for bash, so activity is a cheap poll: ONE stat call over the projects
  # dir and its project subdirs (a new/removed transcript bumps its
  # directory's mtime; appends to a known transcript never matter, because
  # entries are generated once and never edited). Trailing debounce: sync
  # fires after QUIET seconds of silence, at most once per MININT seconds.
  QUIET=8
  MININT=45
  TICK=3
  log "[watcher] Watcher started (transcript events)."
  last_sig=""
  last_event=0
  last_run=0
  while true; do
    sig=$(stat -f '%N %m' "$PROJECTS_DIR" "$PROJECTS_DIR"/*/ 2>/dev/null | cksum)
    now=$(date +%s)
    if [ "$sig" != "$last_sig" ]; then
      last_sig="$sig"
      last_event=$now
      sleep "$TICK"
      continue
    fi
    if [ "$last_event" -eq 0 ] ||
       [ $((now - last_event)) -lt "$QUIET" ] ||
       [ $((now - last_run)) -lt "$MININT" ]; then
      sleep "$TICK"
      continue
    fi
    log "[watcher] Transcript activity: running sync..."
    # Fresh run state per iteration (one backup run dir per sync).
    RUN_DIR=""
    MANIFEST=""
    do_sync || log "[watcher] sync ended with rc=$? (a postponed restructure logs its reason above)"
    last_run=$(date +%s)
    last_event=0
  done
}

cmd_auto_install() {
  [ -f "$CANONICAL_PATH" ] || die "Run --install first ($CANONICAL_PATH not found)."
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$CANONICAL_PATH</string>
        <string>--watch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF
  launchctl unload "$AGENT_PLIST" 2>/dev/null
  launchctl load "$AGENT_PLIST"
  echo "${GREEN}Auto-sync enabled.${RESET} Sessions sync every time Claude Desktop quits."
  echo "${DIM}Log: $LOG${RESET}"
}

cmd_auto_uninstall() {
  if [ ! -f "$AGENT_PLIST" ]; then
    echo "${YELLOW}Auto-sync agent not installed. Nothing to do.${RESET}"
    return 0
  fi
  launchctl unload "$AGENT_PLIST" 2>/dev/null
  rm -f "$AGENT_PLIST"
  echo "${GREEN}Auto-sync disabled.${RESET}"
}

# ---------- install / uninstall ------------------------------------------
cmd_install() {
  mkdir -p "$CANONICAL_DIR"
  if [ "$SOURCE_PATH" = "$CANONICAL_PATH" ]; then
    echo "${DIM}Running from canonical location; script already in place.${RESET}"
  else
    echo "Installing script -> $CANONICAL_PATH"
    cp -f "$SOURCE_PATH" "$CANONICAL_PATH"
    chmod 755 "$CANONICAL_PATH"
  fi

  [ -e "$RC_FILE" ] || touch "$RC_FILE"
  if grep -qF "$RC_BEGIN" "$RC_FILE"; then
    echo "${YELLOW}Alias already present in $RC_FILE; leaving it alone.${RESET}"
    echo "${DIM}(Script at $CANONICAL_PATH was refreshed.)${RESET}"
  else
    echo "Adding 'claude-sync' alias to $RC_FILE"
    cat >> "$RC_FILE" <<EOF

$RC_BEGIN
alias claude-sync='bash "\$HOME/.claude/scripts/claude-sync.sh"'
$RC_END
EOF
  fi

  # If hands-off mode is on, restart the watcher so it runs the new script.
  if [ -f "$AGENT_PLIST" ]; then
    echo "Restarting auto-sync agent with the updated script..."
    launchctl unload "$AGENT_PLIST" 2>/dev/null
    launchctl load "$AGENT_PLIST"
  fi

  echo "${GREEN}Installed.${RESET} Run: source ~/.zshrc && claude-sync"
}

cmd_uninstall() {
  if [ -f "$AGENT_PLIST" ]; then
    cmd_auto_uninstall
  fi
  if [ ! -f "$RC_FILE" ] || ! grep -qF "$RC_BEGIN" "$RC_FILE"; then
    echo "${YELLOW}No shortcut block found in $RC_FILE. Nothing to remove.${RESET}"
    return 0
  fi
  echo "Removing 'claude-sync' alias from $RC_FILE"
  cp "$RC_FILE" "$RC_FILE.bak.$(date +%s)"
  awk -v b="$RC_BEGIN" -v e="$RC_END" '
    index($0, b) {skip=1; next}
    index($0, e) {skip=0; next}
    !skip
  ' "$RC_FILE" > "$RC_FILE.tmp" && mv "$RC_FILE.tmp" "$RC_FILE"
  echo "${GREEN}Removed.${RESET} Open a new terminal for it to take effect."
  echo "${DIM}To delete the script, log and backups too:${RESET}"
  echo "${DIM}  rm -rf \"$CANONICAL_PATH\" \"$LOG\" \"$BACKUPS_DIR\"${RESET}"
}

# ---------- status / help -------------------------------------------------
cmd_status() {
  echo "claude-sync v$VERSION"
  collect_roots
  if [ ${#roots[@]} -gt 1 ]; then
    echo "Data dirs: ${#roots[@]} (default + $(( ${#roots[@]} - 1 )) profile(s) in 'Claude Profiles')"
    for root in "${roots[@]}"; do
      cfg="$root/claude_desktop_config.json"
      n=0
      if [ -f "$cfg" ]; then
        n=$("$OSASCRIPT" -l JavaScript -e 'function run(a){ObjC.import("Foundation");var s=$.NSString.stringWithContentsOfFileEncodingError($(a[0]),$.NSUTF8StringEncoding,$());if(s.isNil())return 0;try{return Object.keys(JSON.parse(ObjC.unwrap(s)).mcpServers||{}).length}catch(e){return "?"}}' "$cfg" 2>/dev/null)
      fi
      echo "  $(basename "$root"): $n MCP server(s)"
    done
  fi
  echo "Sessions dir: $SESSIONS_DIR"
  if [ ! -d "$SESSIONS_DIR" ]; then
    echo "  ${YELLOW}(not found: open Claude Code in Claude Desktop once)${RESET}"
    return 1
  fi
  if [ -d "$SHARED_DIR" ]; then
    echo "  _shared: $(count_shared_entries) session list entries"
  else
    echo "  ${YELLOW}_shared not created yet (run claude-sync once with Claude Desktop closed)${RESET}"
  fi
  collect_accounts
  for d in "${accounts[@]}"; do
    linked=0; real=0
    for org in "$d"/*/; do
      org="${org%/}"
      [ -e "$org" ] || continue
      if [ -L "$org" ]; then
        linked=$((linked + 1))
      else
        real=$((real + 1))
      fi
    done
    state="unified ($linked org symlink(s) -> _shared)"
    [ "$real" -gt 0 ] && state="${YELLOW}$real real org folder(s) not yet unified${RESET}"
    [ "$linked" -eq 0 ] && [ "$real" -eq 0 ] && state="empty"
    echo "  account $(basename "$d"): $state"
  done
  n_tr=0
  for tr in "$PROJECTS_DIR"/*/*.jsonl; do
    [ -f "$tr" ] && n_tr=$((n_tr + 1))
  done
  echo "  transcripts on disk: $n_tr ${DIM}($PROJECTS_DIR)${RESET}"
  if [ -f "$HEAL_LEDGER" ]; then
    echo "  heal ledger: $(awk 'END { print NR }' "$HEAL_LEDGER") id(s) remembered ${DIM}(deleted entries stay deleted)${RESET}"
  fi
  if [ -f "$CANONICAL_PATH" ]; then
    echo "Script: installed at $CANONICAL_PATH"
  else
    echo "Script: not installed (run --install)"
  fi
  if [ -f "$RC_FILE" ] && grep -qF "$RC_BEGIN" "$RC_FILE"; then
    echo "Alias: registered in $RC_FILE"
  else
    echo "Alias: not registered"
  fi
  if launchctl list 2>/dev/null | grep -qF "$AGENT_LABEL"; then
    echo "Auto-sync: enabled (syncs when Claude Desktop quits)"
  else
    echo "Auto-sync: disabled"
  fi
  last_sync=""
  if [ -f "$LOG" ]; then
    last_sync=$(grep -F "Sync complete" "$LOG" | tail -1 | sed 's/^\[\([^]]*\)\].*/\1/')
  fi
  echo "Last sync: ${last_sync:-never}"
  runs=0
  for d in "$BACKUPS_DIR"/*/; do
    [ -d "$d" ] && runs=$((runs + 1))
  done
  echo "Backups: $runs stored run(s)"
}

usage() {
  cat <<EOF
claude-sync v$VERSION
One shared Claude Code session list for all Claude Desktop accounts: every
<account>/<org> folder under claude-code-sessions is a symlink to one
_shared folder, so each conversation exists once and every account sees
it. Each run also self-heals the list: a transcript in ~/.claude/projects
with no list entry gets one regenerated (the app sometimes loses entries
after restarts or rewound sessions). Existing entries are never edited or
deleted; transcripts are never touched. Customization (MCP servers,
Desktop Extensions) still syncs across profiles (claude-deck): a server
edited in one profile propagates, newest config wins, removals propagate
unless --no-deletes. Logins, cookies, and preferences are never touched.

Usage: claude-sync [command]

  (no command)       Run the sync. The one-time restructure into _shared
                     needs Claude Desktop fully closed; the script stops
                     with a message if it is running.
  --dry-run          Show what a sync would do, write nothing.
  --no-deletes       Sync WITHOUT propagating MCP server removals; a server
                     deleted in one profile is copied back instead (the
                     restore path for an accidental removal).
  --revert           Undo the most recent sync run from its backup. If that
                     run restructured the session tree, this restores the
                     whole tree exactly as it was (Claude must be closed).
  --status           Show unify state, entry counts, install state.
  --install          Copy this script to ~/.claude/scripts/ and register the
                     'claude-sync' alias in ~/.zshrc. Re-run to update.
  --uninstall        Remove the alias and the auto-sync agent (if enabled).
  --auto-install     Auto-sync whenever new conversations appear: a
                     LaunchAgent watches ~/.claude/projects and syncs
                     after 8s of write silence, at most once per 45s.
  --auto-uninstall   Disable auto-sync.
  --version          Print version.
  --help             This text.

First run: quit Claude Desktop completely (Cmd+Q, every profile), then run
claude-sync. It backs up the whole claude-code-sessions tree, moves the
union of all list entries into _shared, and symlinks every account/org
folder to it. After that, runs are maintenance only (absorb new account
folders, regenerate lost entries) and are safe anytime.
EOF
}

# ---------- dispatcher ----------------------------------------------------
# --dry-run and --no-deletes combine in any order; every other command
# stays a single, exact argument.
case "${1:-}" in
  ""|--dry-run|--no-deletes)
    dry=""; deletes="deletes"
    for arg in "$@"; do
      case "$arg" in
        --dry-run)    dry="dry" ;;
        --no-deletes) deletes="nodeletes" ;;
        *)            usage; exit 1 ;;
      esac
    done
    do_sync "$dry" "$deletes"
    exit $?
    ;;
  --revert)          cmd_revert ;;
  --install)         cmd_install ;;
  --uninstall)       cmd_uninstall ;;
  --auto-install)    cmd_auto_install ;;
  --auto-uninstall)  cmd_auto_uninstall ;;
  --watch)           cmd_watch ;;
  --status)          cmd_status ;;
  --version|-v)      echo "claude-sync v$VERSION" ;;
  --help|-h)         usage ;;
  *)                 usage; exit 1 ;;
esac
