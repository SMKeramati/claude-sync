# claude-sync

**See all your Claude Code sessions, no matter which Claude account you're logged into, and keep your local customization in sync across profiles.** Claude Desktop keeps a separate session index per account, so switching accounts makes your local session list look empty even though every transcript is still on disk. And if you run multiple profiles (for example with [claude-deck](https://github.com/smk-labs/claude-deck)), each profile has its own data dir, so a local MCP server you add in one profile does not exist in the others. `claude-sync` fixes both: install once with one command, then just run `claude-sync` (or let auto-sync do it for you).

**macOS** (`claude-sync.sh`) and **Windows** (`claude-sync.ps1`), one script per platform, no dependencies. Both implement the v4 design: one shared physical session list (behind directory junctions on Windows, symlinks on macOS) plus a self-heal step that rebuilds lost list entries from their transcripts. The Windows script works on Windows PowerShell 5.1 and PowerShell 7+ and accepts both `-DryRun`-style switches and the macOS `--dry-run` spellings.

---

> This is a small vibe-coded utility that copies files inside your own home folder. It can't break Claude (it never touches the app itself), but as always: read the script before you run it.

---

## Install & update

Same one-liner does both, fresh install or pulling the latest version. From then on, the `claude-sync` command works in every new terminal.

macOS:

```bash
curl -fsSLo /tmp/cs.sh https://raw.githubusercontent.com/smk-labs/claude-sync/main/claude-sync.sh && chmod +x /tmp/cs.sh && /tmp/cs.sh --install && source ~/.zshrc
```

Windows (PowerShell):

```powershell
iwr -useb https://raw.githubusercontent.com/smk-labs/claude-sync/main/claude-sync.ps1 -OutFile "$env:TEMP\cs.ps1"; & "$env:TEMP\cs.ps1" -Install
```

Then, in a new terminal:

```bash
claude-sync
```

That's it.

---

## What it does (v4, both platforms)

`claude-sync` no longer copies session list files between account folders at all. It restructures once, then keeps the structure healthy:

- **One shared list.** One run with Claude Desktop **fully closed** moves the union of every `<account>/<org>` folder's `local_*.json` into one real folder, `claude-code-sessions/_shared` (union conflicts resolve like v3: newest activity wins, archived-in-one wins), and replaces each folder with a link to it: a directory junction on Windows, a relative symlink on macOS. Every account sees the same list, a new conversation appears everywhere the moment the app writes it, and a rename, archive, or delete is one file edit that is instantly true for all accounts. The whole "newest copy wins" reconciliation, its ledger, and its edge cases are gone, and the v3 un-archive limitation disappears with them.
- **Self-healing.** Claude Desktop sometimes never writes a list entry for a conversation (seen after restarts and rewound sessions), so it vanishes from the list even though the transcript in `~/.claude/projects` is intact. Every run (Claude open or closed) scans the transcripts and regenerates any missing entry: title from the recorded custom title or your first message, cwd, timestamps, and model read from the transcript. Existing entries are never edited; transcripts are only ever read; an entry you deleted in the app is never resurrected (tracked in `heal-ledger.tsv`). If the app later writes its *own* entry for a conversation self-heal already restored, the duplicate is cleaned up: our copy goes, the app's stays (see [Duplicate cleanup](#duplicate-cleanup)).
- **New accounts absorbed.** When the app later creates a fresh real `<account>/<org>` folder (first session under a new account or org), the next closed-app run absorbs it into `_shared` and re-links it too.
- **Profiles stay identical.** MCP servers, app settings (the `preferences` block: bypassPermissions and friends), and Desktop Extensions sync across [claude-deck](https://github.com/smk-labs/claude-deck) profiles. On a conflict the most recently changed config wins; settings are add-only; a server is removed everywhere only when a config the ledger saw holding it lost it. See [Profiles](#profiles-claude-deck).
- **Safe by default.** The restructure (and a structural revert) only runs while Claude Desktop is fully closed; it snapshots the whole `claude-code-sessions` tree first, and `claude-sync --revert` restores that tree exactly as it was, salvaging anything newer instead of deleting it. `claude-sync --dry-run` previews everything without writing a byte.

---

## Profiles (claude-deck)

If `~/Library/Application Support/Claude Profiles/` exists (Windows: `%APPDATA%\Claude Profiles\`), created by a multi-profile launcher such as claude-deck, every sync also reconciles local customization across all data dirs, in the same run and with the same safety rails (no profiles dir means this whole layer is dormant and costs nothing):

- **MCP servers.** The `mcpServers` block of every `claude_desktop_config.json` is reconciled. Add a server in one profile: it appears in every profile. Edit a server (command, args, env) in one profile: the edit propagates, and if two profiles disagree, the config edited most recently wins (key order alone is never a difference). Remove a server: the removal propagates, but **only with a witness**. `~/.claude/scripts/mcp-ledger.tsv` records which servers *each* config held at the end of the last sync, and a server is removed everywhere only when some config (a) is on record as having held it, (b) does not hold it now, (c) still holds at least one other server, and (d) did not lose several servers at once. That is the only state that means "you deleted it here". A profile that has never synced has no ledger rows and can never trigger a removal; a config the app reset to zero servers is excluded by (c); a config that lost two or more servers in one run is excluded by (d), and gets them all back on that same run. `--no-deletes` skips removals entirely and copies the missing servers back, which is the restore path for an accidental delete.
- **App settings.** The `preferences` block (`bypassPermissionsModeEnabled`, `menuBarEnabled`, shortcuts, trusted folders, and the rest) is reconciled **add-only**: a setting you change in any profile spreads to all of them, the most recent change wins a conflict, and nothing is ever deleted, so a profile you have never opened cannot blank a setting for the others. The `*ByAccount` maps (the bypass flags are keyed by account UUID) merge entry by entry, so turning a setting on for one account never drops another account's entry, which is what used to make a freshly migrated profile open with the setting inert. Per-profile window state (`launchPreviewPersistedWorkspaces`, `launchPreviewSessionScopedSessions`) is deliberately left alone.
- **Desktop Extensions.** Extension folders installed in one profile are copied to the profiles that lack them (best effort: some Claude builds may still want one enable-click in the new profile's settings).
- **Backed up and revertible.** Config overwrites land in the same run manifest as session writes, so `claude-sync --revert` restores them too, and `--dry-run` previews them. Every other key of every config file is preserved byte for byte. JSON handling runs in macOS's built-in `osascript` JavaScript runtime (called by absolute path, so a shadowed binary in `/usr/local/bin` can't interfere); on Windows it uses PowerShell's built-in `ConvertFrom-Json`/`ConvertTo-Json`: still no dependency.

Deliberately **not** synced: logins and cookies (separate accounts are the whole point of profiles), and `config.json`, which holds the profile's oauth token cache and per-account app state next to a few UI keys. Claude Code customization (plugins, skills, hooks, memory, `settings.json` in `~/.claude`) is already machine-global: every profile reads the same files, so there is nothing to sync. Per-profile session dirs are claude-deck's job (it symlinks them to the shared one).

> **Why the witness rule exists.** Until v4.2 the ledger was one global set of "servers present in every config", which cannot tell *"this profile never had it"* from *"this profile lost it"*. One fresh profile whose config held a single auto-registered server was therefore enough to delete every other server from every profile: it happened on Windows on 2026-07-23 (7 servers × 10 profiles) and on macOS on 2026-07-26 (9 servers × 10 configs, under the older script). The per-config ledger removes the ambiguity at the root, and every propagated removal now logs the config that justified it.
>
> **Why rule (d), the one-at-a-time rule, exists.** A running Claude Desktop reads its config at launch, keeps it in memory, and later rewrites the whole file. Everything added to that file since the app started is silently dropped by that rewrite, which on disk is indistinguishable from you deleting several servers at once. On 2026-07-27 a profile that had been open since before eight servers were added wrote its stale copy back, and v4.2 read it as eight deliberate deletions and honoured them across all eleven configs. Servers are deleted one at a time through the UI, so losing two or more in one run is the signature of a stale writeback, not of a person. Such a config now votes for nothing, wins no conflict in either block (its contents are old by definition), and is refilled from the others on the same run. Raise the threshold with `CLAUDE_SYNC_MCP_RESET_MIN` if you genuinely delete servers in batches.
>
> **This is also why a config can look "not synced".** The sync writes the file correctly, but a Claude Desktop that is already running will not reload it, and may overwrite it from memory. Quit that profile completely (Cmd+Q) and reopen it to pick up new MCP servers and settings.

---

## Syncing deletes

**Sessions need no delete syncing anymore (v4, both platforms).** There is one physical list, so deleting a session in the app IS the delete everywhere, and self-heal never resurrects it (the heal ledger remembers every id that was ever listed; gone means deliberately deleted). `--no-deletes` now only affects the profile layer.

MCP server removals propagate: remove a server in any profile and the next sync removes it everywhere, but only when the ledger can name the config that lost it (see the witness rule under [Profiles](#profiles-claude-deck)). A fresh profile, or one the app reset, never triggers a removal. Settings are add-only and are never deleted by a sync. Two escape hatches:

```bash
claude-sync --dry-run       # preview, including what would be removed
claude-sync --no-deletes    # sync WITHOUT removals; a removed MCP server
                            # is restored from the profiles that still
                            # have it (undo a removal before it syncs)
```


---

## The problem

You log into a second account in Claude Desktop and your Claude Code session list is suddenly empty. Your sessions are not gone:

- **Transcripts** live in `~/.claude/projects` and are shared by every account.
- **The session index** (what the desktop app's session list shows) is per account: `~/Library/Application Support/Claude/claude-code-sessions/<account-uuid>/<org-uuid>/local_*.json` (Windows: `%APPDATA%\Claude\claude-code-sessions\...`).

`claude-sync` replaces those per-account folders with links to one shared folder (junctions on Windows, symlinks on macOS), so there is nothing left to merge. After a restart of Claude, every account sees the same full, up-to-date list.

---

## Before your first sync (important)

The first real run must happen with Claude Desktop fully closed (quit it, run `claude-sync`, reopen). Every run after that can happen anytime; structural work simply waits for a closed app and says so.

`claude-sync` can only see accounts that already have a session folder, and a freshly added account doesn't have one yet. So, once per new account:

1. **Log in** to the new account in Claude Desktop.
2. Open **Claude Code** and start one **throwaway session**. A plain "hi" is enough. This makes Claude create the session folder for that account, so `claude-sync` can recognize it.
3. **Quit** Claude Desktop: the restructure (first run, or absorbing a new account's folder) refuses to run while the app is open.
4. Run `claude-sync`.
5. Reopen Claude. The full session list is there under the new account.

---

## Commands

Shown in macOS spelling; on Windows the same commands work both ways (`claude-sync --dry-run` or `claude-sync -DryRun`).

| Command | What it does |
|---|---|
| `claude-sync` | Run the sync: unify into `_shared` when needed (Claude must be closed for that), then regenerate lost list entries. Idempotent, safe to re-run anytime. |
| `claude-sync --dry-run` | Show everything a sync would do. Writes nothing, not even backups. |
| `claude-sync --no-deletes` | Sync without propagating MCP server removals; a removed server is restored from the profiles that still have it. |
| `claude-sync --revert` | Undo the last sync. If that run restructured the session tree, the whole tree is restored exactly as it was (entries the app wrote after the backup are salvaged into the restored folders, so nothing is lost). Run again to undo the run before that. |
| `claude-sync --status` | Show detected accounts and profiles, unify state, session entry count, per-profile MCP server and settings counts, ledger sizes, install state, last sync time, stored backup runs. |
| `claude-sync --install` | Copy the script to `~/.claude/scripts/` and register the `claude-sync` alias in `~/.zshrc`. Re-run to update. |
| `claude-sync --uninstall` | Remove the alias (and the auto-sync watcher). |
| `claude-sync --auto-install` | Hands-off mode: auto-sync every time Claude Desktop quits. |
| `claude-sync --auto-uninstall` | Disable hands-off mode. |
| `claude-sync --version` | Print the version. |
| `claude-sync --help` | Print usage. |

---

## Hands-off mode (optional)

Don't want to remember to run `claude-sync`? One command wires up a watcher that syncs automatically whenever new conversations appear:

```bash
claude-sync --auto-install      # enable
claude-sync --auto-uninstall    # disable
```

The watcher is transcript-driven: a conversation exists the moment its transcript file does, so the watcher watches `~/.claude/projects` (FileSystemWatcher events on Windows, a cheap mtime poll on macOS) and syncs after 8 seconds of write silence, at most once every 45 seconds. No quit detection needed; the restructure part simply waits for a closed app. On macOS it runs as a LaunchAgent (plist in `~/Library/LaunchAgents/`), on Windows as a per-user Scheduled Task. No sudo, no admin rights, no system changes. Log at `~/.claude/scripts/claude-sync.log`.

---

## How it works

Each run:

1. **Unify (only when needed).** If any `<account>/<org>` folder is still a real directory, the script waits for Claude Desktop to be closed, backs up the whole `claude-code-sessions` tree, moves the union of all `local_*.json` into `_shared` (on a name collision the copy with the newer activity wins, and archived-in-one wins), and replaces each folder with a link to `_shared`. Already-linked folders are skipped, so this is a no-op after the first run until the app creates a new account/org folder. A folder holding anything unexpected is left real and reported, never forced.
2. **Self-heal.** Every transcript in `~/.claude/projects/*/*.jsonl` is checked against the ids already listed (entry file names AND the `cliSessionId` inside each entry: the app names its own entries after its own session id, so filename alone would double-list every app-saved chat) and against the heal ledger of everything ever listed (so an entry you deleted in the app stays deleted). What is genuinely missing gets an entry regenerated: custom title or first user message, cwd, model, and timestamps from the transcript. Sidechain transcripts and files with no usable first message are skipped. Never overwrites, never writes into `~/.claude`.

3. <a id="duplicate-cleanup"></a>**Duplicate cleanup.** Self-heal has to name its file after the transcript id, because that is the only id it knows; the app names its own entries after its own session id and keeps the transcript id inside as `cliSessionId`. So when the app decides to persist its own entry for a conversation self-heal already restored (seen after closing and reopening an account), the list holds two entries for one chat and the chat shows up twice. Worse, an archived chat looks un-archived, because our copy carries `isArchived: false` while the app's carries the real flag. Every run groups the list by `cliSessionId` and, in a group where both copies exist, deletes ours and keeps the app's. `heal-made.tsv` is the record of the files self-heal wrote, so this only ever removes a file the script itself created; the deletion goes into the run manifest, so `--revert` puts it back.

4. **Profile config.** Both blocks of every `claude_desktop_config.json` (`mcpServers` and `preferences`) are reconciled in one read-backup-write pass per file, so a config is never written twice in a run. Runs whether Claude is open or closed.

The desktop app picks up changes on next launch. The transcripts the list points to are already on disk, shared in `~/.claude/projects`, and are never touched.

---

## Safety

- **Closed-app gate.** The restructure moves the app's live folders, so it only runs while Claude Desktop is fully closed; otherwise the script stops with a clear message and changes nothing.
- **Whole-tree backup before restructuring.** Any run that touches the tree's structure first copies all of `claude-code-sessions` under `~/.claude/scripts/backups/<run>/`, with a manifest. The 10 most recent runs are kept.
- **One-command undo.** `claude-sync --revert` restores the tree from that backup exactly as it was, salvaging entries the app wrote after the backup so no session disappears. Run it again to step back one more run; when the run it just undid changed no folder structure, it names the last restructure run and how many more `--revert` steps away it is.
- **One backup dir per run, always.** Two syncs in the same second (a manual run racing the watcher) get separate backup dirs. They used to share one, and the second run's fresh manifest silently truncated the first one's, leaving its whole-tree backup on disk but unreachable by `--revert`.
- **Config backups get their own retention window.** Runs that wrote a `claude_desktop_config.json` are kept 10-deep *separately* from session-only runs. The watcher fires on every transcript write, so a busy hour used to prune away the one backup that could have undone an MCP mistake before anyone noticed it.
- **Removals need a witness, and come one at a time.** A propagated MCP server removal must name the config that lost it, and a config that lost several servers at once is read as a stale app writeback and refilled instead (see [Profiles](#profiles-claude-deck)); settings are never deleted by a sync.
- **Self-heal is additive, and only ever deletes its own work.** Regenerated entries are new files; an existing entry is never edited or overwritten, the app's own entries are never deleted, and nothing under `~/.claude` is ever written by the session machinery. The one deletion the script performs is dropping a duplicate it created itself once the app has written its own copy, and that is backed up and revertible.
- **Preview mode.** `claude-sync --dry-run` prints every planned action and writes nothing.
- **Index only.** Your actual session transcripts in `~/.claude/projects` are never touched.
- **Sentinel-wrapped shell edits.** The command registration lives between `# >>> claude-sync shortcut >>>` markers in your zshrc, and uninstall removes exactly that block (with a timestamped backup first).

---

## Won't Claude fix this itself?

Maybe someday. As of mid 2026, Claude Desktop keeps the local Claude Code session list strictly per account and doesn't merge it when you switch. Until that changes, `claude-sync` bridges the gap. The day it's obsolete, removal is one command (see below).

---

## Uninstall fully

```bash
claude-sync --uninstall        # removes the alias and the auto-sync agent
rm -rf ~/.claude/scripts/claude-sync.sh ~/.claude/scripts/claude-sync.log ~/.claude/scripts/heal-ledger.tsv ~/.claude/scripts/heal-made.tsv ~/.claude/scripts/mcp-ledger.tsv ~/.claude/scripts/backups
```

Windows: `claude-sync -Uninstall`, then delete `~\.claude\scripts\claude-sync.ps1` plus the log, ledgers and `backups\` folder next to it (the uninstall output prints the exact command).

---

## Troubleshooting

**"Only one account folder found. Nothing to sync."**
The other account has never created a Claude Code session on this machine, so it has no folder yet. Follow [Before your first sync](#before-your-first-sync-important).

**Synced, but the session list didn't change.**
Quit Claude Desktop fully (not just the window) and reopen. The app reads the index at launch.

**A session vanished from the list but the conversation exists.**
macOS: run `claude-sync`. The self-heal step regenerates the missing entry from the transcript.

**I deleted something by mistake and it's gone everywhere.**
That is v4 semantics: one physical list, so a delete is immediate and everywhere. `claude-sync --revert` undoes the last run's writes; an app-side delete of an old entry is not a sync write, so treat deletes in the app as real deletes. The transcript itself is never deleted; ask self-heal to bring the entry back by removing its id line from `~/.claude/scripts/heal-ledger.tsv`.

**All my MCP servers disappeared from every profile.**
That was the v3/v4.1 removal rule (fixed in v4.2 by the witness rule) and its remaining hole, a stale app writeback (fixed in v4.3 by the one-at-a-time rule). To recover: put the servers back in one config (`claude-sync --revert` if the run is still in the backups, otherwise a `claude_desktop_config.json.bak*` next to the live file), then run `claude-sync` once: with no ledger rows for the missing names, it only adds, and every profile is refilled.

**I added an MCP server / changed a setting and this profile still doesn't have it.**
Check the file itself first, not the app: `claude-sync --status` shows the per-profile server count. If the file has it and the app doesn't, the app is running on the copy it read at launch. Quit that profile completely (Cmd+Q) and reopen it. Until you do, that instance may also write its stale copy back over the file, which the log reports as `MCP reset ignored` and repairs on the next run.

**The same chat shows up twice, or an archived chat came back un-archived.**
That is a self-heal entry the app has since duplicated with one of its own. `claude-sync` cleans it up on the next run (its copy goes, the app's stays) and logs `Duplicate cleanup`.

**A sync did something you didn't want.**
Run `claude-sync --revert`. Next time, preview with `claude-sync --dry-run` first.

**A session opens but looks unrelated / belongs to another org.**
The session list is shared across all account and org folders on the machine by design. If you keep strictly separated work and personal data, this tool is not for that machine setup.

---

## License

MIT. See `LICENSE`.
