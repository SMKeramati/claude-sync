# claude-sync: make local Claude Code sessions visible across all your
# Claude Desktop accounts on this PC.
#
# Claude Desktop keeps a separate Claude Code session index per account+org
# (one <account-uuid>\<org-uuid> folder under
# %APPDATA%\Claude\claude-code-sessions, small local_*.json files). Switch
# account or org and your session list looks empty, even though every
# transcript is still on disk in ~\.claude\projects.
#
# v4 (Windows) fixes this STRUCTURALLY instead of copying files around:
#   - UNIFY (one-time, needs Claude fully closed): the union of every
#     <account>\<org>'s local_*.json moves into one real folder,
#     claude-code-sessions\_shared, and every <account>\<org> folder is
#     replaced by a directory junction to _shared. One physical list;
#     every account and org reads and writes the same files; new sessions
#     appear everywhere instantly; nothing is ever copied again.
#     Union conflicts resolve like v3 did: newest lastActivityAt wins,
#     archived-in-one means archived-everywhere. The whole tree is
#     backed up first (junction-aware) and -Revert restores it fully.
#   - SELF-HEAL (every run, safe with Claude open): scans every transcript
#     in ~\.claude\projects and, for any session that has a transcript but
#     no list entry in _shared (the app sometimes never writes one after a
#     restart or a rewound session), generates a minimal entry from the
#     transcript itself (title from the first user message or the recorded
#     custom title; cwd, timestamps and model read from the transcript).
#     Existing entries are never edited; transcripts are never touched. A
#     heal ledger (heal-ledger.tsv) remembers every session id ever listed,
#     so an entry the user deletes in the app is never resurrected from its
#     transcript. The ONLY entry ever deleted is one self-heal wrote itself
#     that the app has since replaced with its own copy of the same
#     conversation (heal-made.tsv is the record of what we wrote; the app's
#     copy always survives). Without that the chat shows up twice, and an
#     archived one looks un-archived, because our copy carries isArchived
#     false while the app's carries the real flag.
#   - NEWCOMERS: when the app later creates a fresh real <account>\<org>
#     folder (first login of a new account/org), the next run with Claude
#     closed absorbs its entries into _shared and junctions it too.
#   - ARCHIVE REPLAY (every run, safe with Claude open): current MSIX
#     builds of Claude Desktop log every archive/unarchive to their
#     main.log but fail to persist the isArchived flag into the session
#     index, so the whole cleanup silently reverts on the next launch
#     (verified 2026-07-21: the archive action produces log lines and
#     zero index writes; the app also re-asserts stale entries from
#     memory within seconds if a loaded entry changes under it). Every
#     run therefore tails each profile's main.log (offsets kept in
#     archive-log-offsets.tsv), turns "Archived/Unarchived session
#     local_*" lines into intents (archive-intents.tsv, newest event per
#     id wins), and applies any intent the index disagrees with. Applied
#     -and-stable intents are dropped; intents whose entry is gone are
#     dropped (deletes are never resurrected); intents expire after 14
#     days. Flag writes are backed up into the run manifest, so -Revert
#     undoes them too. The watcher also tails the logs, so an archive
#     lands in the index seconds after you click it, restart-proof.
# The v3 copy machinery (winner distribution, deletion ledger) is gone for
# sessions: with one physical list there is nothing to reconcile and a
# delete in the app is already a delete everywhere. ledger.tsv is read one
# last time during UNIFY (its ids seed the heal ledger, so sessions deleted
# after their last full v3 sync are not resurrected) and never written
# again. The macOS script (claude-sync.sh) still implements the v3 copy
# design; this junction design is Windows-only for now.
#
# It also syncs customization across PROFILES: multi-profile launchers
# (claude-deck) give each profile its own data dir under
# %APPDATA%\Claude Profiles\<name>\, so local MCP servers (the mcpServers
# block of claude_desktop_config.json) and installed Desktop Extensions
# diverge per profile. Every sync reconciles mcpServers across all data
# dirs: missing servers are added everywhere, and when two profiles define
# the SAME server differently, the definition from the config file with the
# newest EFFECTIVE mtime wins and overwrites the others (edit a server in
# any profile, it propagates). A REMOVAL needs a witness: the name goes
# everywhere only when some config C (a) is recorded in mcp-ledger.tsv as
# having held it, (b) does not hold it now, (c) still holds at least one
# other server, and (d) did not lose several servers at once. The ledger is
# PER CONFIG ("cfgPath<TAB>serverName" rows), which is what makes "the user
# deleted it here" distinguishable from "this profile never had it": the
# older flat ledger of bare names could not tell them apart, so one fresh
# profile holding a single auto-registered server wiped every server from
# every profile on 2026-07-23 (7 servers x 10 profiles here).
# Rule (d) is what tells a deletion from a STALE WRITEBACK: a running
# Claude Desktop holds its config in memory from launch and rewrites the
# whole file later, silently dropping every server added since, which on
# disk is indistinguishable from a bulk delete (it wiped eight servers
# across eleven configs on macOS on 2026-07-27). Servers are deleted one at
# a time through the UI, so a config losing CLAUDE_SYNC_MCP_RESET_MIN (2)
# or more of its ledgered servers in ONE run votes for nothing and wins no
# conflict in EITHER block (its contents are old by definition even though
# its file mtime is the newest on disk), while the ordinary union-add path
# refills it on the same run. -NoDeletes skips (and thereby restores) all
# removals.
# The app's own settings (the "preferences" block: bypass-permissions,
# scheduled tasks, sidebar mode, ...) are reconciled the same way, but
# ADD-ONLY: a key present anywhere is propagated everywhere, nothing is
# ever removed, and on a conflict the newest effective mtime wins, so the
# last change you made is the one that spreads. The per-account maps
# (*ByAccount) merge entry by entry (also by effective mtime), so turning a
# setting on for one account never drops another account's entry. A profile
# that has never been opened has no preferences of its own and therefore
# can never blank a setting for the rest -- the failure mode the MCP ledger
# guards against.
# Every other key of each config file is untouched. Extensions stay
# copy-only (additive). Config writes are backed up into the run's
# manifest, so -Revert undoes them too. (No claude-deck profiles on this
# machine yet? The whole layer is dormant and costs nothing.)
# Logins and cookies are deliberately never synced: separate accounts are
# the whole point of profiles. Per-profile window/workspace state (the
# launchPreview* lists) is left alone for the same reason. Claude Code
# customization (plugins, skills, hooks, memory in ~\.claude) is already
# machine-global and needs no syncing.
#
# Deliberately NOT synced either: %APPDATA%\Claude\local-agent-mode-sessions
# (a parallel index tree that appeared in mid-2026 builds). Its semantics
# are unknown; restructuring it blindly could corrupt agent state.
# Revisit once Claude ships whatever it is for.
#
# Safety notes for the structural work (learned the hard way elsewhere):
#   - A junction is removed with the non-recursive Directory.Delete (or an
#     rmdir), NEVER Remove-Item -Recurse: recursing through a reparse point
#     deletes the TARGET's contents, i.e. the shared index itself.
#   - Restructure and structural revert refuse to run while Claude Desktop
#     is up. Detection is by ExecutablePath (MSIX \WindowsApps\Claude_* or
#     legacy Squirrel \AnthropicClaude\app-*), never by process name: the
#     Claude Code CLI is also a claude.exe and must not count.
#   - Existing list files are only ever regex-scanned, never JSON-parsed:
#     real files exist whose enabledMcpTools map has case-colliding keys
#     that ConvertFrom-Json rejects.
#
# JSON handling uses PowerShell's built-in ConvertFrom-Json/ConvertTo-Json:
# no dependencies. Works on Windows PowerShell 5.1 and PowerShell 7+.
#
# https://github.com/SMKeramati/claude-sync

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoDeletes,
    [switch]$Revert,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$AutoInstall,
    [switch]$AutoUninstall,
    [switch]$Watch,
    [switch]$Status,
    [switch]$Version,
    [switch]$Help,
    # GNU-style spellings (--dry-run, --status, ...) land here as loose
    # strings and are mapped onto the switches above, so muscle memory from
    # the macOS script keeps working. Anything unrecognized prints usage.
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '4.3.0'

# $env:APPDATA fallback keeps the script parseable on non-Windows for testing.
$AppData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME 'AppData\Roaming' }

# MSIX write-virtualization escape (2026-07-21): the packaged app's
# AppData writes land in %LOCALAPPDATA%\Packages\Claude_...\LocalCache,
# not the real Roaming, so the app and this script were editing two
# different copies of every file. Once the migrated ~\ClaudeProfiles root
# exists, all data dirs live there (default included, as
# ~\ClaudeProfiles\default, whose claude-code-sessions dir is the
# physical shared root) and both sides see the same files again.
$EscapedRoot    = Join-Path $HOME 'ClaudeProfiles'
$UseEscapedRoot = Test-Path -LiteralPath $EscapedRoot

# CLAUDE_SYNC_* overrides exist so tests can point the script at a
# throwaway tree instead of the real one (same names as the macOS script).
$SessionsDir = if ($env:CLAUDE_SYNC_SESSIONS_DIR) { $env:CLAUDE_SYNC_SESSIONS_DIR }
               elseif ($UseEscapedRoot) { Join-Path $EscapedRoot 'default\claude-code-sessions' }
               else { Join-Path $AppData 'Claude\claude-code-sessions' }
$DefaultRoot = if ($env:CLAUDE_SYNC_DEFAULT_ROOT) { $env:CLAUDE_SYNC_DEFAULT_ROOT }
               elseif ($UseEscapedRoot) { Join-Path $EscapedRoot 'default' }
               else { Join-Path $AppData 'Claude' }
$ProfilesDir = if ($env:CLAUDE_SYNC_PROFILES_DIR) { $env:CLAUDE_SYNC_PROFILES_DIR }
               elseif ($UseEscapedRoot) { $EscapedRoot }
               else { Join-Path $AppData 'Claude Profiles' }
# The real (non-test-override) sessions dir, for is-this-the-real-tree
# guards. Under the escaped root the default dir sits INSIDE $ProfilesDir,
# so profile enumerations skip it by full path (see Get-DataRoots).
$RealSessionsDir = if ($UseEscapedRoot) { Join-Path $EscapedRoot 'default\claude-code-sessions' }
                   else { Join-Path $AppData 'Claude\claude-code-sessions' }
$ProjectsDir = if ($env:CLAUDE_SYNC_PROJECTS_DIR) { $env:CLAUDE_SYNC_PROJECTS_DIR }
               else { Join-Path $HOME '.claude\projects' }
$CanonicalDir = if ($env:CLAUDE_SYNC_HOME) { $env:CLAUDE_SYNC_HOME }
                else { Join-Path $HOME '.claude\scripts' }

$CanonicalPath      = Join-Path $CanonicalDir 'claude-sync.ps1'
$LogPath            = Join-Path $CanonicalDir 'claude-sync.log'
$BackupsDir         = Join-Path $CanonicalDir 'backups'
$LedgerPath         = Join-Path $CanonicalDir 'ledger.tsv'
$LedgerAccountsPath = Join-Path $CanonicalDir '.ledger-accounts.tsv'
# Profile layer ledger: "cfgPath<TAB>serverName" rows recording which MCP
# servers EACH config held at the end of the last sync (see Read-McpLedger).
$McpLedgerPath      = Join-Path $CanonicalDir 'mcp-ledger.tsv'
$HealLedgerPath     = Join-Path $CanonicalDir 'heal-ledger.tsv'
# "fileName<TAB>cliSessionId" for every list entry SELF-HEAL itself created,
# so the duplicate cleanup can drop OUR copy and keep the app's without ever
# guessing (see Remove-DuplicateHealedEntries).
$HealMadePath       = Join-Path $CanonicalDir 'heal-made.tsv'
$ArchiveIntentsPath = Join-Path $CanonicalDir 'archive-intents.tsv'
$ArchiveOffsetsPath = Join-Path $CanonicalDir 'archive-log-offsets.tsv'
$RcBegin            = '# >>> claude-sync shortcut >>>'
$RcEnd              = '# <<< claude-sync shortcut <<<'
$TaskName           = 'claude-sync-watcher'
$KeepBackups        = 10

# How many ledgered MCP servers ONE config must lose in ONE run before that
# loss is read as a stale Claude Desktop writeback instead of a deliberate
# deletion (see Get-ConfigStates). 2 = "removals happen one server at a
# time", which is how they actually happen in the UI. Raise it only if you
# really do delete servers in batches and are willing to trade the guard.
$McpResetMin = 2
if ($env:CLAUDE_SYNC_MCP_RESET_MIN) {
    $parsedMin = 0
    if ([int]::TryParse($env:CLAUDE_SYNC_MCP_RESET_MIN, [ref]$parsedMin) -and $parsedMin -gt 0) {
        $McpResetMin = $parsedMin
    }
}

# Backups for one run live in one dir with one manifest, shared by the
# profile config sync and the session module, so -Revert undoes a whole
# run no matter which layer wrote. Created lazily on first write.
$script:RunDir       = $null
$script:ManifestPath = $null

function Write-Log {
    param([string]$Message)
    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    # Add-Content opens the log FileShare-Read, so two writers (watcher +
    # manual run) contend; a locked log must never hang or kill a sync.
    for ($try = 0; $try -lt 3; $try++) {
        try { Add-Content -Path $LogPath -Value $line -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds (50 * ($try + 1)) }
    }
}

# Dry runs print to the console only; nothing on disk changes, log included.
function Out-Sync {
    param([string]$Message)
    if ($DryRun) { Write-Host $Message } else { Write-Log $Message }
}

function Initialize-RunDir {
    if ($script:RunDir) { return }
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    # Two syncs in the same second (a manual run racing the watcher) must
    # never land in the same dir: their manifests would merge, so one -Revert
    # would undo both runs at once and the first run's whole-tree backup
    # would sit on disk unreachable. Names stay pure integers, so the numeric
    # sorts in the prune and revert paths keep working.
    while (Test-Path -LiteralPath (Join-Path $BackupsDir "$epoch")) { $epoch++ }
    $script:RunDir = Join-Path $BackupsDir "$epoch"
    $script:ManifestPath = Join-Path $script:RunDir 'manifest.tsv'
    New-Item -ItemType Directory -Force -Path $script:RunDir | Out-Null
    if (-not (Test-Path -LiteralPath $script:ManifestPath)) {
        [System.IO.File]::WriteAllText($script:ManifestPath, '')
    }
}

function Add-ManifestRow {
    param([string]$Row)
    [System.IO.File]::AppendAllText($script:ManifestPath, $Row + "`n")
}

function Get-LongDirPath {
    # Expand 8.3 short components (C:\Users\MOHAMM~1\...) of an existing
    # directory path. Windows stores junction targets long-form, so every
    # path we compare against a junction target must be long-form too.
    # Component walk via GetFileSystemEntries: a short name used as the
    # search pattern matches its own directory entry, and the returned
    # path carries the real long name.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        if ($full -notmatch '~') { return $full }
        $root = [System.IO.Path]::GetPathRoot($full)
        $cur = $root.TrimEnd('\')
        foreach ($part in $full.Substring($root.Length).Split('\')) {
            if (-not $part) { continue }
            $hit = @([System.IO.Directory]::GetFileSystemEntries("$cur\", $part))
            if ($hit.Count -ge 1) { $cur = $hit[0] } else { $cur = "$cur\$part" }
        }
        return $cur
    } catch { return $Path }
}

# Canonicalize once: a short-form %APPDATA%/%TEMP% from the environment
# would otherwise make every junction-target comparison fail.
$SessionsDir     = Get-LongDirPath -Path $SessionsDir
$SharedDir       = Join-Path $SessionsDir '_shared'
# DefaultRoot/ProfilesDir feed full-path comparisons too (the escaped root
# puts default INSIDE ProfilesDir, skipped by -ieq against enumerated
# long-form paths), so they need the same canonicalization.
$DefaultRoot     = Get-LongDirPath -Path $DefaultRoot
$ProfilesDir     = Get-LongDirPath -Path $ProfilesDir
$RealSessionsDir = Get-LongDirPath -Path $RealSessionsDir

# ---------- profile customization sync ------------------------------------
function Get-DataRoots {
    # Every Claude data dir on this machine: the default one, plus one per
    # profile when a multi-profile launcher (claude-deck) is in use. The
    # default root comes first so its definitions win union conflicts.
    $roots = New-Object System.Collections.Generic.List[string]
    $roots.Add($DefaultRoot)
    if (Test-Path -LiteralPath $ProfilesDir) {
        foreach ($d in @(Get-ChildItem -Path $ProfilesDir -Directory -ErrorAction SilentlyContinue)) {
            if ($d.FullName -ieq $DefaultRoot) { continue }  # escaped root: default lives inside ProfilesDir
            $roots.Add($d.FullName)
        }
    }
    return ,$roots
}

function ConvertTo-CanonicalJson {
    # Stable one-line rendering used ONLY to compare two server definitions,
    # mirroring the macOS script's JSON.stringify comparison (property order
    # as parsed; two configs that agree byte-for-byte compare equal).
    param($Value)
    return (ConvertTo-Json -InputObject $Value -Compress -Depth 64)
}

function Read-McpLedger {
    # "cfgPath<TAB>serverName" rows recording which MCP servers EACH config
    # held at the end of the last sync, returned as
    # @{ cfgPath = @{ serverName = $true } }. A row that exists while the
    # config no longer holds that server = the user removed it THERE, which
    # is the only thing that may propagate a removal. No rows for a config =
    # it never synced, so it can never vote. Without this file no MCP removal
    # can ever propagate, which is the safe direction.
    #
    # A v4.1-era ledger (bare names, no tab) carries no per-config knowledge:
    # its lines are ignored here and the whole file is rewritten in the new
    # format after this run, so the first run under the new rule can only
    # ADD, never remove.
    $byCfg = @{}
    if (-not (Test-Path -LiteralPath $McpLedgerPath)) { return $byCfg }
    foreach ($line in @(Get-Content -LiteralPath $McpLedgerPath -ErrorAction SilentlyContinue)) {
        if (-not $line) { continue }
        $tab = $line.IndexOf("`t")
        if ($tab -lt 1) { continue }
        $cfgPath = $line.Substring(0, $tab)
        $name    = $line.Substring($tab + 1)
        if (-not $name) { continue }
        if (-not $byCfg.ContainsKey($cfgPath)) { $byCfg[$cfgPath] = @{} }
        $byCfg[$cfgPath][$name] = $true
    }
    return $byCfg
}

function Get-ConfigStates {
    # One read of every profile's claude_desktop_config.json, shared by the
    # mcpServers and the preferences pass so both judge the same snapshot,
    # the same mtimes and the same staleness. (Reading twice would also let
    # the first pass' own write reset every mtime under the second one.)
    # Returns $null when a config is unparseable: the whole config layer is
    # then skipped, exactly as before.
    #
    # STALE, the rule that makes rule (d) work: a config missing $McpResetMin
    # or more of its LEDGERED servers AT ONCE did not lose them to a person.
    # Servers are deleted one at a time through the UI; losing several in one
    # run is the signature of a Claude Desktop instance that has been open
    # since before those servers existed and has just rewritten the whole
    # file from its stale in-memory copy. Such a config gets an EFFECTIVE
    # mtime of -1: it votes for no removal and wins no conflict in either
    # block, because its contents are old by definition even though its file
    # mtime is the newest on disk (the app just wrote it). -1 still loses to
    # nothing when a name or key exists ONLY there, so the guard never
    # subtracts, it only refuses; the union-add path refills it on this run.
    param($Roots)
    $ledger = Read-McpLedger
    $states = New-Object System.Collections.Generic.List[object]
    foreach ($root in $Roots) {
        $cfgPath = Join-Path $root 'claude_desktop_config.json'
        if (-not (Test-Path -LiteralPath $cfgPath)) {
            if ($DryRun) { continue }
            try { [System.IO.File]::WriteAllText($cfgPath, "{}`n") } catch { continue }
        }
        $raw = [System.IO.File]::ReadAllText($cfgPath)
        if (-not $raw.Trim()) { $raw = '{}' }
        $json = $null
        try { $json = ConvertFrom-Json $raw } catch {
            Out-Sync "Profile config: not valid JSON, profile sync skipped: $cfgPath"
            return $null
        }
        $mt = [long]([DateTimeOffset](Get-Item -LiteralPath $cfgPath).LastWriteTimeUtc).ToUnixTimeSeconds()
        $set = @{}
        $mProp = $json.PSObject.Properties['mcpServers']
        if ($mProp -and $null -ne $mProp.Value) {
            foreach ($prop in @($mProp.Value.PSObject.Properties)) { $set[$prop.Name] = $true }
        }
        $had = @{}
        if ($ledger.ContainsKey($cfgPath)) { $had = $ledger[$cfgPath] }
        $lost = New-Object System.Collections.Generic.List[string]
        foreach ($name in @($had.Keys)) { if (-not $set.ContainsKey($name)) { $lost.Add($name) } }
        $stale = ($lost.Count -ge $McpResetMin)
        # McpCount, not Count: a hashtable key named Count would read like the
        # hashtable's own entry count to anyone skimming this.
        $states.Add(@{
            Path     = $cfgPath
            Json     = $json
            Mt       = $mt
            EffMt    = $(if ($stale) { [long]-1 } else { $mt })
            Stale    = $stale
            Lost     = @($lost | Sort-Object)
            Set      = $set
            McpCount = $set.Count
            Had      = $had
        })
    }
    return ,$states
}

function Sync-McpServers {
    # Reconcile the mcpServers block of claude_desktop_config.json across
    # every root; every other key of each file is preserved. Decisions, per
    # server name across all configs:
    #   - definitions differ -> the one from the newest EFFECTIVE-mtime
    #     config wins and overwrites the rest (tie: the default root, listed
    #     first, wins),
    #   - name missing from a config -> added there,
    #   - REMOVAL needs a witness: the name is removed everywhere only when
    #     some config C (a) is recorded in the ledger as having held it,
    #     (b) does not hold it now, (c) still holds at least one other
    #     server, and (d) is not STALE (see Get-ConfigStates). That is the
    #     only state that means "the user deleted it there", and the config
    #     that justified it is logged.
    #     (a) is why the ledger is per config: a flat set of names cannot
    #     tell "this profile never had it" from "this profile lost it", so
    #     one fresh profile was enough to wipe every server everywhere
    #     (2026-07-23). (c) excludes a config the app reset to zero servers.
    #     (d) excludes a stale Claude Desktop writeback, which passes (a),
    #     (b) and (c) cleanly and looks exactly like a bulk delete.
    #     -NoDeletes drops (a)-(d) entirely: nothing is removed and the
    #     missing copies are re-added, which is exactly the restore path.
    # The plan is computed once in memory and then applied, so narration and
    # writes can never disagree on the decision logic.
    param($States, [bool]$Deletes)

    if ($States.Count -lt 2) { return }

    # Union pass: pick a winning definition per server name. Effective mtime
    # throughout, so a stale config never wins a conflict with its old copy.
    $order    = New-Object System.Collections.Generic.List[string]
    $chosen   = @{}
    $chosenMt = @{}
    foreach ($cfg in $States) {
        $mProp = $cfg.Json.PSObject.Properties['mcpServers']
        if (-not $mProp -or $null -eq $mProp.Value) { continue }
        foreach ($prop in @($mProp.Value.PSObject.Properties)) {
            $k = $prop.Name
            if (-not $chosen.ContainsKey($k)) {
                $chosen[$k] = $prop.Value; $chosenMt[$k] = $cfg.EffMt; $order.Add($k)
            } elseif ($cfg.EffMt -gt $chosenMt[$k] -and
                      (ConvertTo-CanonicalJson $prop.Value) -ne (ConvertTo-CanonicalJson $chosen[$k])) {
                $chosen[$k] = $prop.Value; $chosenMt[$k] = $cfg.EffMt
            }
        }
    }

    $removed = @{}
    $votes   = New-Object System.Collections.Generic.List[string]
    if ($Deletes) {
        foreach ($k in $order) {
            foreach ($cfg in $States) {
                if ($cfg.McpCount -eq 0) { continue }           # (c) fresh or app-reset
                if ($cfg.Stale) { continue }                    # (d) stale writeback
                if ($cfg.Set.ContainsKey($k)) { continue }      # (b) still there
                if (-not $cfg.Had.ContainsKey($k)) { continue } # (a) never had it
                $removed[$k] = 1
                $votes.Add(('  MCP removal witness: [{0}] was recorded in {1} and is gone there now' -f $k, $cfg.Path))
                break
            }
        }
    }

    # Per-config plan: what to add, update, remove.
    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($cfg in $States) {
        $mProp = $cfg.Json.PSObject.Properties['mcpServers']
        $m = if ($mProp) { $mProp.Value } else { $null }
        $add = New-Object System.Collections.Generic.List[string]
        $upd = New-Object System.Collections.Generic.List[string]
        $del = New-Object System.Collections.Generic.List[string]
        foreach ($k in $order) {
            $hasProp = ($null -ne $m -and $null -ne $m.PSObject.Properties[$k])
            if ($removed.ContainsKey($k)) {
                if ($hasProp) { $del.Add($k) }
                continue
            }
            if (-not $hasProp) { $add.Add($k) }
            elseif ((ConvertTo-CanonicalJson $m.$k) -ne (ConvertTo-CanonicalJson $chosen[$k])) { $upd.Add($k) }
        }
        if (($add.Count + $upd.Count + $del.Count) -gt 0) {
            $plans.Add(@{ Cfg = $cfg; Add = $add; Upd = $upd; Del = $del })
        }
    }

    if ($DryRun) {
        foreach ($v in $votes) { Write-Host $v }
        foreach ($p in $plans) {
            if ($p.Add.Count) { Write-Host ('  would add MCP server(s) [{0}] -> {1}' -f ($p.Add -join ','), $p.Cfg.Path) }
            if ($p.Upd.Count) { Write-Host ('  would update MCP server(s) [{0}] -> {1}' -f ($p.Upd -join ','), $p.Cfg.Path) }
            if ($p.Del.Count) { Write-Host ('  would remove MCP server(s) [{0}] -> {1}' -f ($p.Del -join ','), $p.Cfg.Path) }
        }
        return
    }

    foreach ($v in $votes) { Write-Log $v }

    foreach ($p in $plans) {
        $cfg = $p.Cfg
        Initialize-RunDir
        $cfgBackupDir = Join-Path $script:RunDir 'configs'
        New-Item -ItemType Directory -Force -Path $cfgBackupDir | Out-Null
        $backupPath = Join-Path $cfgBackupDir ($cfg.Path -replace '[:\\/]', '_')
        Copy-Item -LiteralPath $cfg.Path -Destination $backupPath

        # Mutate the parsed config in place: existing servers keep their
        # position, new ones are appended, every other key is untouched.
        $mProp = $cfg.Json.PSObject.Properties['mcpServers']
        if (-not $mProp -or $null -eq $mProp.Value) {
            $m = New-Object PSObject
            $cfg.Json | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue $m -Force
        } else {
            $m = $mProp.Value
        }
        foreach ($k in $p.Del) { $m.PSObject.Properties.Remove($k) }
        foreach ($k in $p.Upd) { $m.$k = $chosen[$k] }
        foreach ($k in $p.Add) { $m | Add-Member -NotePropertyName $k -NotePropertyValue $chosen[$k] }

        [System.IO.File]::WriteAllText($cfg.Path, ((ConvertTo-Json -InputObject $cfg.Json -Depth 64) + "`n"))
        Add-ManifestRow ("overwrote`t{0}`t{1}" -f $cfg.Path, $backupPath)

        $parts = @()
        if ($p.Add.Count) { $parts += ('added [{0}]'  -f ($p.Add -join ',')) }
        if ($p.Upd.Count) { $parts += ('updated [{0}]' -f ($p.Upd -join ',')) }
        if ($p.Del.Count) { $parts += ('removed [{0}]' -f ($p.Del -join ',')) }
        Write-Log ('  MCP server(s) {0} -> {1}' -f ($parts -join ', '), $cfg.Path)
    }

    # Persist the per-config "holds these servers" ledger for the next run,
    # every run and not just the ones that wrote: an unchanged run is also
    # what replaces a stale v4.1-format ledger with the new one. Every config
    # ends this pass holding the same set (the union-add path adds every
    # non-removed name everywhere), so one list feeds all the rows. Written
    # atomically (temp file then move) so a crash mid-write never leaves a
    # truncated ledger; a missing or empty ledger is a normal, safe starting
    # state (no votes).
    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
    $fin = New-Object System.Collections.Generic.List[string]
    foreach ($k in $order) { if (-not $removed.ContainsKey($k)) { $fin.Add($k) } }
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($cfg in $States) {
        foreach ($k in $fin) { $rows.Add(("{0}`t{1}" -f $cfg.Path, $k)) }
    }
    $tmp = "$McpLedgerPath.tmp.$PID"
    if ($rows.Count -eq 0) { [System.IO.File]::WriteAllText($tmp, '') }
    else { [System.IO.File]::WriteAllText($tmp, (($rows -join "`n") + "`n")) }
    Move-Item -LiteralPath $tmp -Destination $McpLedgerPath -Force
}

function Sync-Extensions {
    # Copy installed Desktop Extensions across roots, additively. Best
    # effort: a Claude build that also tracks extensions in per-profile
    # preferences may still want one enable-click in that profile.
    param($Roots)
    $copied = 0
    foreach ($srcRoot in $Roots) {
        $srcExt = Join-Path $srcRoot 'Claude Extensions'
        if (-not (Test-Path -LiteralPath $srcExt)) { continue }
        foreach ($ext in @(Get-ChildItem -Path $srcExt -Directory -ErrorAction SilentlyContinue)) {
            foreach ($dstRoot in $Roots) {
                if ($dstRoot -eq $srcRoot) { continue }
                $dst = Join-Path (Join-Path $dstRoot 'Claude Extensions') $ext.Name
                if (Test-Path -LiteralPath $dst) { continue }
                if ($DryRun) {
                    Write-Host ('  would copy extension {0} -> {1}' -f $ext.Name, (Split-Path -Leaf $dstRoot))
                    $copied++
                    continue
                }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
                Copy-Item -LiteralPath $ext.FullName -Destination $dst -Recurse
                Initialize-RunDir
                Add-ManifestRow ("created`t$dst")
                $copied++
            }
        }
    }
    if ($copied -gt 0 -and -not $DryRun) {
        Write-Log "Extensions: $copied copied across profiles."
    }
}

# Preference keys that are per-profile window/session STATE rather than
# settings: syncing them would cross-contaminate what each window has open.
$script:PrefsNoSync = @('launchPreviewPersistedWorkspaces', 'launchPreviewSessionScopedSessions')

function Sync-Preferences {
    # Reconcile the "preferences" block of claude_desktop_config.json across
    # every root, so a setting changed in one profile reaches all of them.
    # ADD-ONLY on purpose: a key present in any config is propagated to the
    # rest and nothing is ever deleted, so a profile that has never been
    # opened (and therefore has no preferences at all) can never blank a
    # setting everywhere. On a genuine conflict the newest-mtime config wins,
    # which is what makes "the last change I made" the one that spreads.
    # Per-account maps (*ByAccount) merge entry by entry, so switching a
    # setting on for one account never drops another account's entry -- the
    # reason a profile could look "off" even when the flag was on elsewhere.
    # Every "newest wins" comparison here uses the EFFECTIVE mtime, this one
    # included: a config a running app just rewrote from its stale memory is
    # the newest file on disk and holds the OLDEST settings, so its real
    # mtime would spread every value it still remembers back over all the
    # others. It can still introduce a key that exists only there.
    param($States)

    $cfgs = $States
    if ($cfgs.Count -lt 2) { return }

    # Winner per key. Plain keys: newest mtime wins. Per-account maps:
    # accumulated entry by entry, newest mtime wins per account.
    $order    = New-Object System.Collections.Generic.List[string]
    $chosen   = @{}
    $chosenMt = @{}
    $acctVal  = @{}
    $acctMt   = @{}
    foreach ($cfg in $cfgs) {
        $pProp = $cfg.Json.PSObject.Properties['preferences']
        if (-not $pProp -or $null -eq $pProp.Value) { continue }
        foreach ($prop in @($pProp.Value.PSObject.Properties)) {
            $k = $prop.Name
            if ($script:PrefsNoSync -contains $k) { continue }
            if ($k -like '*ByAccount') {
                if (-not $acctVal.ContainsKey($k)) {
                    $acctVal[$k] = @{}; $acctMt[$k] = @{}; $order.Add($k)
                }
                if ($null -ne $prop.Value) {
                    foreach ($e in @($prop.Value.PSObject.Properties)) {
                        if ((-not $acctVal[$k].ContainsKey($e.Name)) -or ($cfg.EffMt -gt $acctMt[$k][$e.Name])) {
                            $acctVal[$k][$e.Name] = $e.Value
                            $acctMt[$k][$e.Name]  = $cfg.EffMt
                        }
                    }
                }
                continue
            }
            if (-not $chosen.ContainsKey($k)) {
                $chosen[$k] = $prop.Value; $chosenMt[$k] = $cfg.EffMt; $order.Add($k)
            } elseif ($cfg.EffMt -gt $chosenMt[$k] -and
                      (ConvertTo-CanonicalJson $prop.Value) -ne (ConvertTo-CanonicalJson $chosen[$k])) {
                $chosen[$k] = $prop.Value; $chosenMt[$k] = $cfg.EffMt
            }
        }
    }
    # Materialize the merged per-account maps as plain objects.
    foreach ($k in @($acctVal.Keys)) {
        $obj = New-Object PSObject
        foreach ($a in @($acctVal[$k].Keys | Sort-Object)) {
            $obj | Add-Member -NotePropertyName $a -NotePropertyValue $acctVal[$k][$a]
        }
        $chosen[$k] = $obj
    }
    if ($order.Count -eq 0) { return }

    # Per-config plan: keys that are missing there or differ from the winner.
    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($cfg in $cfgs) {
        $pProp = $cfg.Json.PSObject.Properties['preferences']
        $p = if ($pProp) { $pProp.Value } else { $null }
        $set = New-Object System.Collections.Generic.List[string]
        foreach ($k in $order) {
            $has = ($null -ne $p -and $null -ne $p.PSObject.Properties[$k])
            if (-not $has) { $set.Add($k) }
            elseif ((ConvertTo-CanonicalJson $p.$k) -ne (ConvertTo-CanonicalJson $chosen[$k])) { $set.Add($k) }
        }
        if ($set.Count -gt 0) { $plans.Add(@{ Cfg = $cfg; Set = $set }) }
    }
    if ($plans.Count -eq 0) { return }

    if ($DryRun) {
        foreach ($pl in $plans) {
            Write-Host ('  would sync preference(s) [{0}] -> {1}' -f (($pl.Set | Select-Object -First 6) -join ','), $pl.Cfg.Path)
        }
        return
    }

    foreach ($pl in $plans) {
        $cfg = $pl.Cfg
        Initialize-RunDir
        $cfgBackupDir = Join-Path $script:RunDir 'configs'
        New-Item -ItemType Directory -Force -Path $cfgBackupDir | Out-Null
        $backupPath = Join-Path $cfgBackupDir ($cfg.Path -replace '[:\\/]', '_')
        # The mcpServers pass may already have backed this file up this run;
        # that copy is the pre-run original, so never overwrite it.
        if (-not (Test-Path -LiteralPath $backupPath)) {
            Copy-Item -LiteralPath $cfg.Path -Destination $backupPath
        }

        $pProp = $cfg.Json.PSObject.Properties['preferences']
        if (-not $pProp -or $null -eq $pProp.Value) {
            $p = New-Object PSObject
            $cfg.Json | Add-Member -NotePropertyName 'preferences' -NotePropertyValue $p -Force
        } else {
            $p = $pProp.Value
        }
        foreach ($k in $pl.Set) {
            if ($null -ne $p.PSObject.Properties[$k]) { $p.$k = $chosen[$k] }
            else { $p | Add-Member -NotePropertyName $k -NotePropertyValue $chosen[$k] }
        }

        [System.IO.File]::WriteAllText($cfg.Path, ((ConvertTo-Json -InputObject $cfg.Json -Depth 64) + "`n"))
        Add-ManifestRow ("overwrote`t{0}`t{1}" -f $cfg.Path, $backupPath)
        Write-Log ('  preference(s) synced [{0}] -> {1}' -f (($pl.Set | Select-Object -First 6) -join ','), $cfg.Path)
    }
}

function Sync-Profiles {
    # Orchestrates the profile layer. Fast, runs before the session
    # machinery, and independent of it (profiles exist even with a single
    # account). With no "Claude Profiles" dir there is one root and every
    # step returns immediately.
    param([bool]$Deletes)
    $roots = Get-DataRoots
    if ($roots.Count -lt 2) { return }
    # One snapshot for both passes: they are separate here (macOS does both
    # in a single program), so they must not disagree about which config is
    # stale or how old each one is.
    $states = Get-ConfigStates -Roots $roots
    if ($null -ne $states -and $states.Count -ge 2) {
        foreach ($st in $states) {
            if (-not $st.Stale) { continue }
            # Loud on purpose: this is the exact shape of the bug that wiped
            # every server across every profile, and the user should know
            # that app instance is running on an out-of-date config.
            if ($DryRun) {
                Write-Host ('  stale config ignored: {0} lost [{1}] at once' -f $st.Path, ($st.Lost -join ','))
                Write-Host '    -> treated as a Claude Desktop writeback, not a deletion; would be restored'
            } else {
                Write-Log ('  MCP reset ignored: {0} lost [{1}] at once, which is a stale' -f $st.Path, ($st.Lost -join ','))
                Write-Log '  Claude Desktop writeback, not a deletion. Restoring them and'
                Write-Log '  ignoring that config this run. Quit and reopen that profile.'
            }
        }
        Sync-McpServers -States $states -Deletes $Deletes
        Sync-Preferences -States $states
    }
    Sync-Extensions -Roots $roots
}

# ---------- session module: one _shared index behind junctions -------------
# UNIFY once (Claude closed), then SELF-HEAL every run. See the header
# comment for the design. Everything here is Set-StrictMode clean and
# 5.1-safe; the structural entry points enable strict mode for themselves.

$script:UuidNameRe  = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:LocalNameRe = '^local_([0-9a-fA-F-]{36})\.json$'

function Test-ClaudeDesktopRunning {
    # TRUE iff any live process belongs to the Claude DESKTOP install.
    # Match by ExecutablePath, never by name: the Claude Code CLI is also a
    # claude.exe (under ...\claude-code\<ver>\claude.exe) and must not
    # count, while Desktop and all its Electron children live under the
    # MSIX package dir (or the legacy Squirrel dir). When the sessions dir
    # is overridden to a throwaway tree (tests), the check is skipped: it
    # exists to protect the real tree only. The FORCE_RUNNING hook lets
    # tests exercise the postpone paths; it can only make the tool MORE
    # conservative, never less.
    if ($env:CLAUDE_SYNC_TEST_FORCE_RUNNING) { return $true }
    $realSessions = Get-LongDirPath -Path $RealSessionsDir
    if ($env:CLAUDE_SYNC_SESSIONS_DIR -and ($SessionsDir -ine $realSessions)) { return $false }
    $paths = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop)) {
            if ($p.ExecutablePath) { $paths.Add([string]$p.ExecutablePath) }
        }
    } catch {
        foreach ($p in @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue)) {
            $exe = $null
            try { $exe = $p.Path } catch { $exe = $null }
            if ($exe) { $paths.Add([string]$exe) }
        }
    }
    foreach ($path in $paths) {
        if ($path -match '\\WindowsApps\\Claude_' -or $path -match '\\AnthropicClaude\\app-') { return $true }
    }
    return $false
}

function Remove-DirectorySafe {
    # Junction-aware delete. A reparse point is unlinked with the
    # NON-recursive Directory.Delete, which can never descend into the
    # target (Remove-Item -Recurse through a junction deletes the target's
    # contents -- here that would be the shared index itself). Real dirs are
    # walked manually for the same reason: a real dir may CONTAIN junctions.
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ([bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        [System.IO.Directory]::Delete($Path, $false)
    } else {
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
            if ($child.PSIsContainer) { Remove-DirectorySafe -Path $child.FullName }
            else { Remove-Item -LiteralPath $child.FullName -Force }
        }
        Remove-Item -LiteralPath $Path -Force
    }
    if (Test-Path -LiteralPath $Path) { throw "Failed to remove: $Path" }
}

function Test-JunctionTo {
    param([string]$Path, [string]$Target)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
    $t = @($item.Target)
    if ($t.Count -eq 0 -or -not $t[0]) { return $false }
    $got = [string]$t[0]
    if ($got.StartsWith('\\?\')) { $got = $got.Substring(4) }
    $want = $Target
    if ($want.StartsWith('\\?\')) { $want = $want.Substring(4) }
    $want = Get-LongDirPath -Path $want
    return ($got.TrimEnd('\') -ieq $want.TrimEnd('\'))
}

function New-JunctionSafe {
    # New-Item can silently no-op (a lesson from claude-deck), so trust only
    # the re-read: the path must exist, be a reparse point, and resolve to
    # the target. One clear-and-retry, then fail loudly (the unify catch
    # rolls the whole tree back).
    param([string]$Path, [string]$Target)
    try { New-Item -ItemType Junction -Path $Path -Value $Target -ErrorAction Stop | Out-Null } catch { }
    if (-not (Test-JunctionTo -Path $Path -Target $Target)) {
        if (Test-Path -LiteralPath $Path) { Remove-DirectorySafe -Path $Path }
        New-Item -ItemType Junction -Path $Path -Value $Target -ErrorAction Stop | Out-Null
    }
    if (-not (Test-JunctionTo -Path $Path -Target $Target)) {
        throw "Could not create junction: $Path -> $Target"
    }
}

function Copy-TreeSnapshot {
    # Junction-aware recursive copy: junctions become rows in $JunRows
    # (relative path + target), never followed; real files and dirs are
    # copied (Copy-Item keeps file mtimes).
    param([string]$Src, [string]$Dst, [string]$Rel, $JunRows)
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    foreach ($f in @(Get-ChildItem -LiteralPath $Src -File -Force -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Dst $f.Name)
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $Src -Directory -Force -ErrorAction SilentlyContinue)) {
        $childRel = if ($Rel) { Join-Path $Rel $d.Name } else { $d.Name }
        if ([bool]($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $t = @($d.Target)
            $tgt = if ($t.Count -gt 0 -and $t[0]) { [string]$t[0] } else { '' }
            $JunRows.Add("$childRel`t$tgt")
        } else {
            Copy-TreeSnapshot -Src $d.FullName -Dst (Join-Path $Dst $d.Name) -Rel $childRel -JunRows $JunRows
        }
    }
}

function Backup-SessionsTree {
    # Full snapshot of the sessions tree into this run's backup dir, plus
    # one 'tree' manifest row, written BEFORE any mutation, so -Revert (and
    # the unify rollback path) can always restore the exact pre-run tree.
    Initialize-RunDir
    $treeDir = Join-Path $script:RunDir 'sessions-tree'
    $junTsv  = "$treeDir.junctions.tsv"
    New-Item -ItemType Directory -Force -Path $treeDir | Out-Null
    $junRows = New-Object System.Collections.Generic.List[string]
    Copy-TreeSnapshot -Src $SessionsDir -Dst $treeDir -Rel '' -JunRows $junRows
    if ($junRows.Count -eq 0) { [System.IO.File]::WriteAllText($junTsv, '') }
    else { [System.IO.File]::WriteAllText($junTsv, (($junRows -join "`n") + "`n")) }
    Add-ManifestRow ("tree`t{0}`t{1}" -f $SessionsDir, $treeDir)
}

function Copy-TreeRestore {
    param([string]$Src, [string]$Dst)
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    foreach ($f in @(Get-ChildItem -LiteralPath $Src -File -Force -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Dst $f.Name) -Force
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $Src -Directory -Force -ErrorAction SilentlyContinue)) {
        Copy-TreeRestore -Src $d.FullName -Dst (Join-Path $Dst $d.Name)
    }
}

function Get-RelFileMap {
    # relpath -> true for every file under $Dir, keys built by the same
    # Join-Path walk the wipe below uses. Never string-prefix arithmetic:
    # enumerated FullNames can come back long-form under a short-form
    # root, which silently breaks Substring-based keys.
    param([string]$Dir, [string]$BaseRel, $Map)
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue)) {
        $fileRel = if ($BaseRel) { Join-Path $BaseRel $f.Name } else { $f.Name }
        $Map[$fileRel.ToLowerInvariant()] = $true
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue)) {
        $childRel = if ($BaseRel) { Join-Path $BaseRel $d.Name } else { $d.Name }
        Get-RelFileMap -Dir $d.FullName -BaseRel $childRel -Map $Map
    }
}

function Clear-TreeForRestore {
    # Junction-aware wipe with salvage: a file created AFTER the snapshot
    # (its relative path is not in $SnapFiles) is MOVED into the salvage
    # dir instead of deleted, so a revert can never destroy data the
    # snapshot does not carry. Junctions are only ever unlinked.
    # NOTE: PowerShell variable names are case-insensitive; a local $rel
    # here would BE the $Rel parameter and accumulate across iterations.
    param([string]$Dir, [string]$Rel, $SnapFiles, [string]$SalvageDir, [ref]$Salvaged)
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue)) {
        $fileRel = if ($Rel) { Join-Path $Rel $f.Name } else { $f.Name }
        if ($SalvageDir -and -not $SnapFiles.ContainsKey($fileRel.ToLowerInvariant())) {
            $dst = Join-Path $SalvageDir $fileRel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
            Move-Item -LiteralPath $f.FullName -Destination $dst -Force
            $Salvaged.Value++
        } else {
            Remove-Item -LiteralPath $f.FullName -Force
        }
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue)) {
        if ([bool]($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            [System.IO.Directory]::Delete($d.FullName, $false)
        } else {
            $childRel = if ($Rel) { Join-Path $Rel $d.Name } else { $d.Name }
            Clear-TreeForRestore -Dir $d.FullName -Rel $childRel -SnapFiles $SnapFiles -SalvageDir $SalvageDir -Salvaged $Salvaged
            Remove-Item -LiteralPath $d.FullName -Force
        }
    }
}

function Restore-SessionsTree {
    # Put the live tree back exactly as the snapshot recorded it: wipe the
    # current children (junction-safe; anything newer than the snapshot is
    # salvaged, not deleted, when a salvage dir is given), copy the
    # snapshot back, recreate the recorded junctions. The wipe only starts
    # after the snapshot has been verified present. Returns the number of
    # salvaged files.
    param([string]$TreeBackupDir, [string]$LiveDir, [string]$SalvageDir = '')
    if (-not $LiveDir) { throw 'Restore-SessionsTree: empty live dir' }
    if (-not (Test-Path -LiteralPath $TreeBackupDir)) { throw "Tree backup missing: $TreeBackupDir" }
    $junTsv = "$TreeBackupDir.junctions.tsv"
    New-Item -ItemType Directory -Force -Path $LiveDir | Out-Null
    $snapFiles = @{}
    Get-RelFileMap -Dir $TreeBackupDir -BaseRel '' -Map $snapFiles
    $salvaged = 0
    Clear-TreeForRestore -Dir $LiveDir -Rel '' -SnapFiles $snapFiles -SalvageDir $SalvageDir -Salvaged ([ref]$salvaged)
    Copy-TreeRestore -Src $TreeBackupDir -Dst $LiveDir
    if (Test-Path -LiteralPath $junTsv) {
        foreach ($line in @(Get-Content -LiteralPath $junTsv -ErrorAction SilentlyContinue)) {
            if (-not $line) { continue }
            $parts = $line -split "`t"
            if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) { continue }
            $jPath = Join-Path $LiveDir $parts[0]
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $jPath) | Out-Null
            if (Test-Path -LiteralPath $jPath) { Remove-DirectorySafe -Path $jPath }
            New-JunctionSafe -Path $jPath -Target $parts[1]
        }
    }
    return $salvaged
}

function Read-EntryMeta {
    # Regex-only field extraction from an index file. Existing entries are
    # NEVER JSON-parsed: real files exist whose enabledMcpTools map has
    # case-colliding keys that ConvertFrom-Json rejects.
    param([string]$Path)
    $raw = [System.IO.File]::ReadAllText($Path)
    # Both serializations exist on disk: the compact form most entries carry
    # and the pretty-printed one ("isArchived": false) the app writes when it
    # re-persists an entry. Every isArchived read/write must tolerate both.
    $ts = [long]0
    if ($raw -match '"lastActivityAt"\s*:\s*(\d+)') { $ts = [long]$Matches[1] }
    $arch = $false
    if ($raw -match '"isArchived"\s*:\s*(true|false)') { $arch = ($Matches[1] -eq 'true') }
    return @{ Ts = $ts; Arch = $arch }
}

function Get-SessionTreeState {
    # One read-only walk: which org dirs are real, which already junction to
    # _shared, which junction somewhere unexpected, and whether _shared
    # exists as a real dir.
    $realOrgs      = New-Object System.Collections.Generic.List[object]
    $oddJunctions  = New-Object System.Collections.Generic.List[string]
    $junctionCount = 0
    $accountCount  = 0
    foreach ($acct in @(Get-ChildItem -Path $SessionsDir -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($acct.Name -notmatch $script:UuidNameRe) { continue }
        if ([bool]($acct.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $oddJunctions.Add($acct.FullName); continue
        }
        $accountCount++
        foreach ($org in @(Get-ChildItem -Path $acct.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($org.Name -notmatch $script:UuidNameRe) { continue }
            if ([bool]($org.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                if (Test-JunctionTo -Path $org.FullName -Target $SharedDir) { $junctionCount++ }
                else { $oddJunctions.Add($org.FullName) }
            } else {
                $realOrgs.Add([PSCustomObject]@{ Path = $org.FullName; Account = $acct.Name; Org = $org.Name })
            }
        }
    }
    $sharedExists = $false
    $sharedIsRealDir = $false
    if (Test-Path -LiteralPath $SharedDir) {
        $sh = Get-Item -LiteralPath $SharedDir -Force
        $sharedExists = $true
        $sharedIsRealDir = -not [bool]($sh.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    }
    return [PSCustomObject]@{
        RealOrgs = $realOrgs; OddJunctions = $oddJunctions
        JunctionCount = $junctionCount; AccountCount = $accountCount
        SharedExists = $sharedExists; SharedIsRealDir = $sharedIsRealDir
    }
}

function Invoke-SessionUnify {
    # The structural pass: absorb every real <account>\<org> folder's
    # entries into _shared (newest lastActivityAt wins, archived-in-one
    # means archived-everywhere), then replace the folder with a junction.
    # Idempotent: already-junctioned orgs are not in $State.RealOrgs, and a
    # later fresh real org folder (a newcomer) takes exactly this same path.
    # The plan is computed once and then either printed (dry run) or
    # executed, so narration and writes can never disagree.
    param($State)
    Set-StrictMode -Version 2

    if ($State.SharedExists -and -not $State.SharedIsRealDir) {
        throw "_shared exists but is not a real directory, refusing to touch anything: $SharedDir"
    }

    # ---- gather candidates per filename --------------------------------
    $byName         = @{}   # fname -> List of @{Path;Ts;Arch;Mt;IsShared}
    $orgCounts      = @{}   # org path -> entry count
    $orgsWithStrays = @{}   # org path -> short description
    $copyTotal      = 0
    foreach ($org in $State.RealOrgs) {
        $entries = @(Get-ChildItem -LiteralPath $org.Path -Force -ErrorAction SilentlyContinue)
        $strays = @($entries | Where-Object { $_.PSIsContainer -or ($_.Name -notmatch $script:LocalNameRe) })
        if ($strays.Count -gt 0) {
            $orgsWithStrays[$org.Path] = (@($strays | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ', ')
        }
        $n = 0
        foreach ($f in @($entries | Where-Object { (-not $_.PSIsContainer) -and ($_.Name -match $script:LocalNameRe) })) {
            $meta = Read-EntryMeta -Path $f.FullName
            $n++; $copyTotal++
            if (-not $byName.ContainsKey($f.Name)) { $byName[$f.Name] = New-Object System.Collections.Generic.List[object] }
            $byName[$f.Name].Add(@{ Path = $f.FullName; Ts = $meta.Ts; Arch = $meta.Arch
                                    Mt = [long]([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeMilliseconds()
                                    IsShared = $false })
        }
        $orgCounts[$org.Path] = $n
    }
    if ($State.SharedExists) {
        foreach ($f in @(Get-ChildItem -LiteralPath $SharedDir -File -Force -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -match $script:LocalNameRe })) {
            $meta = Read-EntryMeta -Path $f.FullName
            if (-not $byName.ContainsKey($f.Name)) { $byName[$f.Name] = New-Object System.Collections.Generic.List[object] }
            $byName[$f.Name].Add(@{ Path = $f.FullName; Ts = $meta.Ts; Arch = $meta.Arch
                                    Mt = [long]([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeMilliseconds()
                                    IsShared = $true })
        }
    }

    # ---- pick winners ---------------------------------------------------
    $moves = New-Object System.Collections.Generic.List[object]
    $conflicts = 0
    $archFlips = 0
    foreach ($fname in @($byName.Keys | Sort-Object)) {
        $cands = $byName[$fname]
        $winner = $null
        $minTs = $cands[0].Ts; $maxTs = $cands[0].Ts; $archOr = $false
        foreach ($c in $cands) {
            if ($null -eq $winner) { $winner = $c }
            elseif ($c.Ts -gt $winner.Ts) { $winner = $c }
            elseif ($c.Ts -eq $winner.Ts -and $c.Mt -gt $winner.Mt) { $winner = $c }
            if ($c.Ts -lt $minTs) { $minTs = $c.Ts }
            if ($c.Ts -gt $maxTs) { $maxTs = $c.Ts }
            if ($c.Arch) { $archOr = $true }
        }
        if ($maxTs -gt $minTs) { $conflicts++ }
        $flip = ($archOr -and -not $winner.Arch)
        if ($flip) { $archFlips++ }
        if ($winner.IsShared -and -not $flip) { continue }   # already in place
        $moves.Add(@{ Fname = $fname; SrcPath = $winner.Path; Flip = $flip })
    }

    $junctionable = New-Object System.Collections.Generic.List[object]
    foreach ($org in $State.RealOrgs) {
        if (-not $orgsWithStrays.ContainsKey($org.Path)) { $junctionable.Add($org) }
    }

    # ---- dry run: narrate the plan --------------------------------------
    if ($DryRun) {
        Write-Host "Restructure plan for $($SessionsDir):"
        if (-not $State.SharedExists) { Write-Host "  would create the shared index dir: $SharedDir" }
        Write-Host ('  would place {0} unique session entries into _shared ({1} per-org copies collapse into them; {2} had diverging copies, resolved by newest activity; {3} archive flags propagated)' -f `
            $byName.Count, $copyTotal, $conflicts, $archFlips)
        foreach ($org in $junctionable) {
            Write-Host ('  would replace {0}\{1} ({2} entries) with a junction -> _shared' -f $org.Account, $org.Org, $orgCounts[$org.Path])
        }
        foreach ($orgPath in @($orgsWithStrays.Keys | Sort-Object)) {
            Write-Host ('  would LEAVE REAL (unexpected content: {0}): {1}' -f $orgsWithStrays[$orgPath], $orgPath)
        }
        Write-Host '  the whole tree would be backed up first (claude-sync -Revert restores it)'
        return
    }

    # ---- execute --------------------------------------------------------
    if (Test-ClaudeDesktopRunning) {
        throw 'Claude Desktop is running; refusing to restructure the sessions tree.'
    }
    Write-Log ("Restructuring sessions index: {0} entries -> _shared, {1} org folder(s) to junction..." -f $byName.Count, $junctionable.Count)
    Backup-SessionsTree
    try {
        if (-not (Test-Path -LiteralPath $SharedDir)) {
            New-Item -ItemType Directory -Force -Path $SharedDir | Out-Null
        }
        foreach ($mv in $moves) {
            $dst = Join-Path $SharedDir $mv.Fname
            if ($mv.Flip) {
                $raw = [System.IO.File]::ReadAllText($mv.SrcPath)
                [System.IO.File]::WriteAllText($dst, [regex]::Replace($raw, '("isArchived"\s*:\s*)false', '${1}true'))
                (Get-Item -LiteralPath $dst).LastWriteTimeUtc = (Get-Item -LiteralPath $mv.SrcPath).LastWriteTimeUtc
            } else {
                [System.IO.File]::Copy($mv.SrcPath, $dst, $true)
            }
        }
        foreach ($org in $junctionable) {
            # Belt and suspenders: nothing may be lost by the removal.
            foreach ($f in @(Get-ChildItem -LiteralPath $org.Path -File -Force -ErrorAction SilentlyContinue)) {
                if (-not (Test-Path -LiteralPath (Join-Path $SharedDir $f.Name))) {
                    throw "entry was not absorbed into _shared: $($f.FullName)"
                }
            }
            Remove-DirectorySafe -Path $org.Path
            New-JunctionSafe -Path $org.Path -Target $SharedDir
        }
        # Seed the heal ledger: every id visible now, plus every id the old
        # v3 ledger ever saw fully synced. An id whose entry is absent from
        # the union but present in the v3 ledger was deleted by the user
        # after its last full sync -- seeding it keeps self-heal from
        # resurrecting it out of its transcript.
        $ids = Get-HealLedger
        foreach ($fname in @($byName.Keys)) {
            if ($fname -match $script:LocalNameRe) { $ids[$Matches[1].ToLowerInvariant()] = $true }
        }
        if (Test-Path -LiteralPath $LedgerPath) {
            foreach ($line in @(Get-Content -LiteralPath $LedgerPath -ErrorAction SilentlyContinue)) {
                if ($line -and $line -match '^local_([0-9a-fA-F-]{36})\.json\t') {
                    $ids[$Matches[1].ToLowerInvariant()] = $true
                }
            }
        }
        Save-HealLedger -Ids $ids
    } catch {
        Write-Log ("RESTRUCTURE FAILED: {0}" -f $_)
        Write-Log "Restoring the pre-run tree from this run's backup..."
        $null = Restore-SessionsTree -TreeBackupDir (Join-Path $script:RunDir 'sessions-tree') -LiveDir $SessionsDir
        Write-Log 'Restored. The sessions tree is back to its pre-run state.'
        throw
    }
    Write-Log ('Unified: {0} session entries in _shared; {1} org folder(s) junctioned ({2} diverging copies resolved by newest activity, {3} archive flags propagated).' -f `
        $byName.Count, $junctionable.Count, $conflicts, $archFlips)
    foreach ($orgPath in @($orgsWithStrays.Keys | Sort-Object)) {
        Write-Log ('  left REAL, unexpected content ({0}): {1}' -f $orgsWithStrays[$orgPath], $orgPath)
    }
}

# ---------- self-heal: rebuild missing entries from transcripts ------------
function ConvertTo-EpochMs {
    param([string]$Iso)
    try {
        return [long]([DateTimeOffset]::Parse($Iso, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUnixTimeMilliseconds()
    } catch { return [long]0 }
}

function ConvertFrom-JsonEscapedString {
    # $S is the inside of a well-formed JSON string literal (captured by
    # regex); wrapping it back into a tiny JSON doc is the safest unescape.
    param([string]$S)
    try { return (ConvertFrom-Json ('{"v":"' + $S + '"}')).v } catch { return $S }
}

function Read-FileTailText {
    # Last chunk of a (possibly live, possibly huge) file, opened with a
    # ReadWrite share so an open transcript never fails the scan. A partial
    # first multibyte char decodes as garbage and is harmless: only complete
    # matches later in the chunk are used.
    param([string]$Path, [int]$MaxBytes = 65536)
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        if ($len -le 0) { return '' }
        $take = [int]([Math]::Min([long]$MaxBytes, $len))
        $fs.Seek(-$take, [System.IO.SeekOrigin]::End) | Out-Null
        $buf = New-Object byte[] $take
        $read = $fs.Read($buf, 0, $take)
        return [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } finally { $fs.Close() }
}

function Read-TranscriptMeta {
    # Streaming metadata extraction from a transcript: head lines give the
    # custom title / first user message, cwd, first timestamp and model;
    # the tail chunk gives the last timestamp (and any late rename). The
    # transcript is only ever read, line by line, never loaded whole.
    param([string]$Path)
    $title = $null; $titleSource = 'auto'; $summaryTitle = $null
    $cwd = $null; $createdIso = $null; $model = $null
    $isSidechain = $false

    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $reader = New-Object System.IO.StreamReader($fs)
    try {
        $lineNo = 0
        $sawMessageEntry = $false
        while (-not $reader.EndOfStream -and $lineNo -lt 250) {
            $line = $reader.ReadLine()
            $lineNo++
            if (-not $line) { continue }
            if ($line.StartsWith('{"type":"custom-title"') -and $line -match '"customTitle":"((?:[^"\\]|\\.)*)"') {
                $t = ConvertFrom-JsonEscapedString $Matches[1]
                $t = ($t -replace '\s+', ' ').Trim()
                if ($t) { $title = $t; $titleSource = 'custom' }
            }
            if ((-not $summaryTitle) -and $line.StartsWith('{"type":"summary"') -and $line -match '"summary":"((?:[^"\\]|\\.)*)"') {
                $summaryTitle = ConvertFrom-JsonEscapedString $Matches[1]
            }
            if ((-not $createdIso) -and $line -match '"timestamp":"([0-9TZ:.+-]{10,40})"') { $createdIso = $Matches[1] }
            if ((-not $cwd) -and $line -match '"cwd":"((?:[^"\\]|\\.)*)"') {
                $cwd = ConvertFrom-JsonEscapedString $Matches[1]
            }
            if ((-not $model) -and $line -match '"model":"(claude-[A-Za-z0-9.\[\]_-]{1,60})"') { $model = $Matches[1] }
            if ($line.StartsWith('{"parentUuid"')) {
                if (-not $sawMessageEntry) {
                    $sawMessageEntry = $true
                    # Only the file's own first message entry decides
                    # sidechain-ness; quoted content later can't.
                    if ($line.Contains('"isSidechain":true')) { $isSidechain = $true; break }
                }
                if (($titleSource -ne 'custom') -and (-not $title) -and $line.Contains('"type":"user"') -and
                    (-not $line.Contains('"isMeta":true')) -and (-not $line.Contains('"type":"tool_result"'))) {
                    $cand = $null
                    if ($line -match '"role":"user","content":"((?:[^"\\]|\\.)*)"') {
                        $cand = ConvertFrom-JsonEscapedString $Matches[1]
                    } elseif ($line -match '"type":"text","text":"((?:[^"\\]|\\.)*)"') {
                        $cand = ConvertFrom-JsonEscapedString $Matches[1]
                    }
                    if ($cand) {
                        $cand = ($cand -replace '\s+', ' ').Trim()
                        $bad = ($cand -eq '') -or $cand.StartsWith('Caveat:') -or $cand.StartsWith('<command-') -or
                               $cand.StartsWith('<local-command') -or $cand.StartsWith('[Request interrupted') -or
                               $cand.StartsWith('<system')
                        if (-not $bad) {
                            if ($cand.Length -gt 60) { $cand = $cand.Substring(0, 60).TrimEnd() }
                            $title = $cand
                        }
                    }
                }
            }
            if ($title -and ($titleSource -eq 'custom') -and $cwd -and $createdIso -and $model) { break }
        }
    } finally { $reader.Close() }

    if ((-not $title) -and $summaryTitle) {
        $t = ($summaryTitle -replace '\s+', ' ').Trim()
        if ($t) {
            if ($t.Length -gt 60) { $t = $t.Substring(0, 60).TrimEnd() }
            $title = $t
        }
    }

    $lastIso = $null
    if (-not $isSidechain) {
        $tailText = Read-FileTailText -Path $Path
        $mts = [regex]::Matches($tailText, '"timestamp":"([0-9TZ:.+-]{10,40})"')
        if ($mts.Count -gt 0) { $lastIso = $mts[$mts.Count - 1].Groups[1].Value }
        $cts = [regex]::Matches($tailText, '"customTitle":"((?:[^"\\]|\\.)*)"')
        if ($cts.Count -gt 0) {
            $t = ConvertFrom-JsonEscapedString $cts[$cts.Count - 1].Groups[1].Value
            $t = ($t -replace '\s+', ' ').Trim()
            if ($t) {
                if ($t.Length -gt 60) { $t = $t.Substring(0, 60).TrimEnd() }
                $title = $t; $titleSource = 'custom'
            }
        }
    }

    $item = Get-Item -LiteralPath $Path
    $createdMs = [long]0
    if ($createdIso) { $createdMs = ConvertTo-EpochMs $createdIso }
    if ($createdMs -le 0) { $createdMs = [long]([DateTimeOffset]$item.CreationTimeUtc).ToUnixTimeMilliseconds() }
    $lastMs = [long]0
    if ($lastIso) { $lastMs = ConvertTo-EpochMs $lastIso }
    if ($lastMs -le 0) { $lastMs = [long]([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeMilliseconds() }
    if ($lastMs -lt $createdMs) { $lastMs = $createdMs }
    if (-not $cwd) { $cwd = [string]$HOME }
    if (-not $model) { $model = 'claude-opus-4-8' }
    return @{ Title = $title; TitleSource = $titleSource; Cwd = $cwd
              CreatedMs = $createdMs; LastMs = $lastMs; Model = $model; IsSidechain = $isSidechain }
}

function Get-HealLedger {
    # Every session id self-heal has ever seen listed (or generated). An id
    # here whose entry is gone was deleted by the user in the app; without
    # this file every deletion would be resurrected from its transcript on
    # the next run.
    $ids = @{}
    if (-not (Test-Path -LiteralPath $HealLedgerPath)) { return $ids }
    foreach ($line in @(Get-Content -LiteralPath $HealLedgerPath -ErrorAction SilentlyContinue)) {
        if ($line -and $line -match $script:UuidNameRe) { $ids[$line.ToLowerInvariant()] = $true }
    }
    return $ids
}

function Save-HealLedger {
    # Atomic (temp + move), backed into the run manifest, and skipped
    # entirely when nothing changed so idle runs stay write-free.
    param($Ids)
    $lines = @($Ids.Keys | Sort-Object)
    $new = ''
    if ($lines.Count -gt 0) { $new = (($lines -join "`n") + "`n") }
    $old = ''
    if (Test-Path -LiteralPath $HealLedgerPath) { $old = [System.IO.File]::ReadAllText($HealLedgerPath) }
    if ($new -eq $old) { return }
    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
    Initialize-RunDir
    if ($old -ne '') {
        $bak = Join-Path $script:RunDir 'heal-ledger.tsv.pre'
        if (-not (Test-Path -LiteralPath $bak)) {
            [System.IO.File]::WriteAllText($bak, $old)
            Add-ManifestRow ("overwrote`t{0}`t{1}" -f $HealLedgerPath, $bak)
        }
    } else {
        Add-ManifestRow ("created`t{0}" -f $HealLedgerPath)
    }
    $tmp = "$HealLedgerPath.tmp.$PID"
    [System.IO.File]::WriteAllText($tmp, $new)
    Move-Item -LiteralPath $tmp -Destination $HealLedgerPath -Force
}

function Get-HealMade {
    # File names of every list entry SELF-HEAL itself created, from
    # heal-made.tsv ("fileName<TAB>cliSessionId" rows). Only a file recorded
    # here may ever be deleted by the duplicate cleanup.
    $made = @{}
    if (-not (Test-Path -LiteralPath $HealMadePath)) { return $made }
    foreach ($line in @(Get-Content -LiteralPath $HealMadePath -ErrorAction SilentlyContinue)) {
        if (-not $line) { continue }
        $name = ($line -split "`t")[0]
        if ($name) { $made[$name] = $true }
    }
    return $made
}

function Add-HealMadeRow {
    param([string]$FileName, [string]$CliSessionId)
    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
    [System.IO.File]::AppendAllText($HealMadePath,
        ("{0}`t{1}`n" -f $FileName, $CliSessionId.ToLowerInvariant()))
}

function Initialize-HealMade {
    # One-time migration for machines that healed entries before this file
    # existed. The log records every entry self-heal ever wrote, so it is an
    # exact source; each candidate is still confirmed against the file on
    # disk (its name must BE its cliSessionId, which is only ever true of our
    # own writes) before it is trusted. Created even when empty, so this runs
    # exactly once.
    if (Test-Path -LiteralPath $HealMadePath) { return }
    if ($DryRun) { return }
    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
    $rows = New-Object System.Collections.Generic.List[string]
    if ((Test-Path -LiteralPath $LogPath) -and (Test-Path -LiteralPath $SharedDir)) {
        $seen = @{}
        foreach ($line in @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)) {
            if (-not $line) { continue }
            if ($line -notmatch 'generated from transcript: (local_[0-9a-fA-F-]{36}\.json)') { continue }
            $fname = $Matches[1]
            if ($seen.ContainsKey($fname)) { continue }
            $seen[$fname] = $true
            $path = Join-Path $SharedDir $fname
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $id = $fname.Substring(6, $fname.Length - 11).ToLowerInvariant()
            $txt = ''
            try { $txt = [System.IO.File]::ReadAllText($path) } catch { continue }
            if ($txt -notmatch '"cliSessionId"\s*:\s*"([0-9a-fA-F-]{36})"') { continue }
            if ($Matches[1].ToLowerInvariant() -ne $id) { continue }
            $rows.Add(("{0}`t{1}" -f $fname, $id))
        }
    }
    $text = ''
    if ($rows.Count -gt 0) { $text = (($rows -join "`n") + "`n") }
    [System.IO.File]::WriteAllText($HealMadePath, $text)
    if ($rows.Count -gt 0) {
        Write-Log ('Heal record seeded from the log: {0} entry(ies) self-heal created before.' -f $rows.Count)
    }
}

function Remove-DuplicateHealedEntries {
    # Drop a self-heal entry once the app has written its OWN entry for the
    # same conversation. Self-heal must name its file after the TRANSCRIPT
    # id, because that is the only id it knows; the app names its entry after
    # its OWN session id and keeps the transcript id inside as cliSessionId.
    # So when the app later persists its own entry for a conversation we
    # already healed (reproducible by closing and reopening an account), the
    # list holds two entries for one chat: it shows up twice, and an archived
    # one looks un-archived, because our copy carries isArchived false while
    # the app's carries the real flag.
    # Only files recorded in heal-made.tsv are ever removed, and only while a
    # NON-ours entry for the same cliSessionId exists, so the app's copy is
    # always the survivor and nothing we did not write is ever touched. The
    # deletion goes into the run manifest, so -Revert puts it back.
    Set-StrictMode -Version 2
    if (-not (Test-Path -LiteralPath $SharedDir)) { return }
    $made = Get-HealMade
    if ($made.Count -eq 0) { return }

    # Group the list by cliSessionId, ours against the app's. Regex, never
    # ConvertFrom-Json: a few real entries carry case-colliding
    # enabledMcpTools keys that ConvertFrom-Json rejects.
    $mine   = @{}
    $theirs = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $SharedDir -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -notmatch $script:LocalNameRe) { continue }
        $txt = ''
        try { $txt = [System.IO.File]::ReadAllText($f.FullName) } catch { continue }
        if ($txt -notmatch '"cliSessionId"\s*:\s*"([0-9a-fA-F-]{36})"') { continue }
        $id = $Matches[1].ToLowerInvariant()
        if ($made.ContainsKey($f.Name)) {
            if (-not $mine.ContainsKey($id)) { $mine[$id] = New-Object System.Collections.Generic.List[string] }
            $mine[$id].Add($f.Name)
        } elseif ($theirs.ContainsKey($id)) {
            $theirs[$id]++
        } else {
            $theirs[$id] = 1
        }
    }
    $drop = New-Object System.Collections.Generic.List[string]
    foreach ($id in @($mine.Keys)) {
        if (-not $theirs.ContainsKey($id)) { continue }
        foreach ($name in $mine[$id]) { $drop.Add($name) }
    }
    if ($drop.Count -eq 0) { return }

    if ($DryRun) {
        foreach ($name in $drop) {
            Write-Host ('  would drop duplicate list entry {0} (the app now has its own)' -f $name)
        }
        Write-Host ('Duplicate cleanup: {0} entry(ies) the app has since re-created itself.' -f $drop.Count)
        return
    }

    $dropped = New-Object System.Collections.Generic.List[string]
    foreach ($name in $drop) {
        $src = Join-Path $SharedDir $name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        Initialize-RunDir
        $entryBackupDir = Join-Path $script:RunDir 'entries'
        New-Item -ItemType Directory -Force -Path $entryBackupDir | Out-Null
        $bak = Join-Path $entryBackupDir $name
        try {
            Copy-Item -LiteralPath $src -Destination $bak -Force
            Remove-Item -LiteralPath $src -Force
        } catch { continue }
        Add-ManifestRow ("deleted`t{0}`t{1}" -f $src, $bak)
        $dropped.Add($name)
    }
    if ($dropped.Count -eq 0) { return }

    # Forget the rows we just dropped: the app owns those conversations now,
    # and the heal ledger already holds their ids, so self-heal will not
    # remake them.
    $gone = @{}
    foreach ($name in $dropped) { $gone[$name] = $true }
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-Content -LiteralPath $HealMadePath -ErrorAction SilentlyContinue)) {
        if (-not $line) { continue }
        if ($gone.ContainsKey((($line -split "`t")[0]))) { continue }
        $keep.Add($line)
    }
    $text = ''
    if ($keep.Count -gt 0) { $text = (($keep -join "`n") + "`n") }
    $tmp = "$HealMadePath.tmp.$PID"
    [System.IO.File]::WriteAllText($tmp, $text)
    Move-Item -LiteralPath $tmp -Destination $HealMadePath -Force
    Write-Log ('Duplicate cleanup: dropped {0} self-heal entry(ies) the app has since re-created itself.' -f $dropped.Count)
}

function Invoke-SessionHeal {
    # For every transcript with no list entry in _shared and no heal-ledger
    # record, generate a minimal entry the app can render and resume.
    # Additive only: existing entries are never edited or deleted, and
    # transcripts are never touched. Safe with Claude open (the app reads
    # the index at launch). $ListedOverride lets a pre-restructure dry run
    # preview the heal against the ids the restructure WOULD leave listed.
    param([hashtable]$ListedOverride = $null)
    Set-StrictMode -Version 2
    if (($null -eq $ListedOverride) -and -not (Test-Path -LiteralPath $SharedDir)) { return }
    $listed = @{}
    if ($null -ne $ListedOverride) {
        $listed = $ListedOverride
    } else {
        foreach ($f in @(Get-ChildItem -LiteralPath $SharedDir -File -Force -ErrorAction SilentlyContinue)) {
            if ($f.Name -notmatch $script:LocalNameRe) { continue }
            $listed[$Matches[1].ToLowerInvariant()] = $true
            # An app-created entry is named after the app's OWN session id and
            # carries the transcript id inside as cliSessionId; only the
            # heal-generated shape has the two equal. Keying on the filename
            # alone therefore made every app-created session look unlisted and
            # got it healed a second time (53 duplicate pairs on this machine
            # before the key was widened). Regex, never ConvertFrom-Json: a few
            # real entries carry case-colliding enabledMcpTools keys.
            try {
                $txt = [System.IO.File]::ReadAllText($f.FullName)
                if ($txt -match '"cliSessionId"\s*:\s*"([0-9a-fA-F-]{36})"') {
                    $listed[$Matches[1].ToLowerInvariant()] = $true
                }
            } catch { }
        }
    }
    if (-not (Test-Path -LiteralPath $ProjectsDir)) {
        Out-Sync "Self-heal: transcripts dir not found ($ProjectsDir), nothing to scan."
        return
    }
    $seen = Get-HealLedger
    # Ids the v3 ledger saw fully synced are tombstones forever: an id
    # there with no entry now was deleted by the user post-sync. Merging
    # here (not only at unify time) keeps dry runs and real runs agreeing.
    if (Test-Path -LiteralPath $LedgerPath) {
        foreach ($line in @(Get-Content -LiteralPath $LedgerPath -ErrorAction SilentlyContinue)) {
            if ($line -and $line -match '^local_([0-9a-fA-F-]{36})\.json\t') {
                $seen[$Matches[1].ToLowerInvariant()] = $true
            }
        }
    }
    $plan = New-Object System.Collections.Generic.List[object]
    $scanned = 0; $skipSeen = 0; $skipEmpty = 0; $skipSide = 0; $skipNoTitle = 0
    foreach ($projDir in @(Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue)) {
        foreach ($f in @(Get-ChildItem -Path $projDir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
            if ($f.BaseName -notmatch $script:UuidNameRe) { continue }
            $scanned++
            $id = $f.BaseName.ToLowerInvariant()
            if ($listed.ContainsKey($id)) { continue }
            if ($seen.ContainsKey($id)) { $skipSeen++; continue }
            if ($f.Length -eq 0) { $skipEmpty++; continue }
            $tm = Read-TranscriptMeta -Path $f.FullName
            if ($tm.IsSidechain) { $skipSide++; continue }
            if (-not $tm.Title) { $skipNoTitle++; continue }
            $plan.Add(@{ Id = $f.BaseName; Meta = $tm })
        }
    }

    if ($DryRun) {
        if ($plan.Count -eq 0) {
            Write-Host ('Self-heal: nothing to generate ({0} transcripts scanned).' -f $scanned)
        } else {
            Write-Host ('Self-heal: would generate {0} missing list entries from transcripts:' -f $plan.Count)
            foreach ($p in $plan) { Write-Host ('  would create: local_{0}.json  [{1}]' -f $p.Id, $p.Meta.Title) }
        }
        return
    }

    $made = 0
    foreach ($p in $plan) {
        $m = $p.Meta
        $dst = Join-Path $SharedDir ('local_{0}.json' -f $p.Id)
        if (Test-Path -LiteralPath $dst) { continue }
        $obj = [ordered]@{
            sessionId       = ('local_{0}' -f $p.Id)
            cliSessionId    = $p.Id
            cwd             = $m.Cwd
            originCwd       = $m.Cwd
            lastFocusedAt   = [long]$m.LastMs
            createdAt       = [long]$m.CreatedMs
            lastActivityAt  = [long]$m.LastMs
            model           = $m.Model
            effort          = 'high'
            isArchived      = $false
            title           = $m.Title
            titleSource     = $m.TitleSource
            permissionMode  = 'bypassPermissions'
            enabledMcpTools = @{}
        }
        $json = ConvertTo-Json -InputObject $obj -Compress -Depth 8
        Initialize-RunDir
        [System.IO.File]::WriteAllText($dst, $json)
        try {
            (Get-Item -LiteralPath $dst).LastWriteTimeUtc = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$m.LastMs).UtcDateTime
        } catch { }
        Add-ManifestRow ("created`t{0}" -f $dst)
        # Record it as ours, so that if the app later writes its own entry
        # for the same conversation the dedupe pass knows which of the two
        # copies it is allowed to remove.
        Add-HealMadeRow -FileName ('local_{0}.json' -f $p.Id) -CliSessionId $p.Id
        $listed[$p.Id.ToLowerInvariant()] = $true
        $made++
        Write-Log ('  generated from transcript: local_{0}.json  [{1}]' -f $p.Id, $m.Title)
    }

    # Every id listed right now becomes 'seen': if the user later deletes
    # its entry in the app, self-heal will never bring it back.
    $changed = $false
    foreach ($id in @($listed.Keys)) {
        if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $changed = $true }
    }
    if ($changed) { Save-HealLedger -Ids $seen }

    if ($made -gt 0) {
        Write-Log ('Self-heal: generated {0} entries ({1} transcripts scanned; skipped {2} seen-before, {3} sidechain, {4} empty, {5} with no usable first message).' -f `
            $made, $scanned, $skipSeen, $skipSide, $skipEmpty, $skipNoTitle)
    } else {
        Out-Sync ('Self-heal: nothing to generate ({0} transcripts scanned).' -f $scanned)
    }
}

# ---------- archive replay: app log -> index flags --------------------------
# Current MSIX builds log every archive/unarchive but never write the flag
# into the index, and rewrite loaded entries from stale memory when the file
# changes under them. The app's own log is therefore the only durable record
# of what the user archived; these functions replay it onto _shared.

function Get-AppLogPaths {
    # Every main.log the app can write: the default data dir plus one per
    # named profile. Missing files are skipped by the reader.
    $paths = New-Object System.Collections.Generic.List[string]
    $paths.Add((Join-Path $DefaultRoot 'logs\main.log'))
    if (Test-Path -LiteralPath $ProfilesDir) {
        foreach ($d in @(Get-ChildItem -Path $ProfilesDir -Directory -ErrorAction SilentlyContinue)) {
            if ($d.FullName -ieq $DefaultRoot) { continue }  # escaped root: default lives inside ProfilesDir
            $paths.Add((Join-Path $d.FullName 'Logs\main.log'))
        }
    }
    return $paths
}

# One archive/unarchive event per log line; the app writes each line twice
# and both spellings ("LocalSessions.archive: sessionId=..." then "Archived
# session ..."), so consumers dedupe by newest-timestamp-per-id.
$script:ArchiveLineRe = '^(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \[info\] (?:LocalSessions\.(?<v1>archive|unarchive): sessionId=|(?<v2>Archived|Unarchived) session )(?<id>local_[0-9a-fA-F-]{36})\s*$'

function Read-AppLogTail {
    # Appended bytes of one log since $Offset, read shared so a live app is
    # never blocked. Returns the text and the new offset; offset resets to 0
    # when the file shrank (rotation).
    param([string]$Path, [long]$Offset)
    $r = @{ Text = ''; Offset = $Offset }
    if (-not (Test-Path -LiteralPath $Path)) { return $r }
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            if ($fs.Length -lt $Offset) { $Offset = 0 }
            $null = $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
            $sr = New-Object System.IO.StreamReader($fs)
            $r.Text = $sr.ReadToEnd()
            $r.Offset = $fs.Length
        } finally { $fs.Close() }
    } catch { }
    return $r
}

function Get-ArchiveOffsets {
    $map = @{}
    if (-not (Test-Path -LiteralPath $ArchiveOffsetsPath)) { return $map }
    foreach ($line in @(Get-Content -LiteralPath $ArchiveOffsetsPath -ErrorAction SilentlyContinue)) {
        $parts = $line -split "`t"
        if ($parts.Count -eq 2 -and $parts[1] -match '^\d+$') { $map[$parts[0]] = [long]$parts[1] }
    }
    return $map
}

function Get-ArchiveIntents {
    # id -> @{ State = '0'|'1'; Ts = 'yyyy-MM-dd HH:mm:ss' }
    $map = @{}
    if (-not (Test-Path -LiteralPath $ArchiveIntentsPath)) { return $map }
    foreach ($line in @(Get-Content -LiteralPath $ArchiveIntentsPath -ErrorAction SilentlyContinue)) {
        $parts = $line -split "`t"
        if ($parts.Count -eq 3 -and $parts[1] -match '^[01]$') {
            $map[$parts[0]] = @{ State = $parts[1]; Ts = $parts[2] }
        }
    }
    return $map
}

function Save-ArchiveState {
    # Both ledgers, atomic (temp + move), written only when content changed.
    param($Intents, $Offsets)
    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
    $iLines = @($Intents.Keys | Sort-Object | ForEach-Object {
        "{0}`t{1}`t{2}" -f $_, $Intents[$_].State, $Intents[$_].Ts })
    $iNew = ''
    if ($iLines.Count -gt 0) { $iNew = (($iLines -join "`n") + "`n") }
    $iOld = ''
    if (Test-Path -LiteralPath $ArchiveIntentsPath) { $iOld = [System.IO.File]::ReadAllText($ArchiveIntentsPath) }
    if ($iNew -ne $iOld) {
        $tmp = "$ArchiveIntentsPath.tmp.$PID"
        [System.IO.File]::WriteAllText($tmp, $iNew)
        Move-Item -LiteralPath $tmp -Destination $ArchiveIntentsPath -Force
    }
    $oLines = @($Offsets.Keys | Sort-Object | ForEach-Object { "{0}`t{1}" -f $_, $Offsets[$_] })
    $oNew = ''
    if ($oLines.Count -gt 0) { $oNew = (($oLines -join "`n") + "`n") }
    $oOld = ''
    if (Test-Path -LiteralPath $ArchiveOffsetsPath) { $oOld = [System.IO.File]::ReadAllText($ArchiveOffsetsPath) }
    if ($oNew -ne $oOld) {
        $tmp = "$ArchiveOffsetsPath.tmp.$PID"
        [System.IO.File]::WriteAllText($tmp, $oNew)
        Move-Item -LiteralPath $tmp -Destination $ArchiveOffsetsPath -Force
    }
}

function Invoke-ArchiveReplay {
    # Tail every app log for archive/unarchive events, fold them into the
    # intent ledger (newest event per id wins), and make _shared agree with
    # every live intent. Safe with the app open: worst case a loaded entry
    # gets re-asserted stale by the app and the next run reapplies; state
    # converges the moment the app quits. Dry runs preview and consume
    # nothing.
    Set-StrictMode -Version 2
    if (-not (Test-Path -LiteralPath $SharedDir)) { return }
    $offsets = Get-ArchiveOffsets
    $intents = Get-ArchiveIntents
    $firstRun = -not (Test-Path -LiteralPath $ArchiveOffsetsPath)
    # First run has no offsets and would replay the app's whole log history;
    # bound it to the recent past so long-settled states are not disturbed.
    $historyFloor = (Get-Date).AddHours(-48).ToString('yyyy-MM-dd HH:mm:ss')

    $newOffsets = @{}
    $events = 0
    foreach ($logPath in Get-AppLogPaths) {
        $off = [long]0
        if ($offsets.ContainsKey($logPath)) { $off = $offsets[$logPath] }
        $tail = Read-AppLogTail -Path $logPath -Offset $off
        $newOffsets[$logPath] = $tail.Offset
        if (-not $tail.Text) { continue }
        foreach ($line in ($tail.Text -split "`r?`n")) {
            $m = [regex]::Match($line, $script:ArchiveLineRe)
            if (-not $m.Success) { continue }
            $ts = $m.Groups['ts'].Value
            if ($firstRun -and ($ts -lt $historyFloor)) { continue }
            $verb = $m.Groups['v1'].Value
            if (-not $verb) { $verb = $m.Groups['v2'].Value }
            $state = '1'
            if ($verb -match '^[Uu]narchive') { $state = '0' }
            $id = $m.Groups['id'].Value.ToLowerInvariant()
            # Timestamps in this format sort lexically; newest event wins.
            if ($intents.ContainsKey($id) -and ($intents[$id].Ts -gt $ts)) { continue }
            $intents[$id] = @{ State = $state; Ts = $ts }
            $events++
        }
    }

    # Apply: every intent the index disagrees with gets its flag written.
    # Drop an intent once it is applied and stable, once its entry is gone
    # (a delete in the app must never be resurrected), or after 14 days.
    $ttlFloor = (Get-Date).AddDays(-14).ToString('yyyy-MM-dd HH:mm:ss')
    $applied = 0; $pending = 0
    foreach ($id in @($intents.Keys)) {
        $it = $intents[$id]
        if ($it.Ts -lt $ttlFloor) { $intents.Remove($id); continue }
        $entry = Join-Path $SharedDir "$id.json"
        if (-not (Test-Path -LiteralPath $entry)) { $intents.Remove($id); continue }
        # A read/write race with the live app keeps the intent for next run.
        try { $raw = [System.IO.File]::ReadAllText($entry) } catch { $pending++; continue }
        if ($raw -notmatch '"isArchived"\s*:\s*(true|false)') { $intents.Remove($id); continue }
        $current = '0'
        if ($Matches[1] -eq 'true') { $current = '1' }
        if ($current -eq $it.State) { $intents.Remove($id); continue }
        if ($DryRun) {
            $word = 'archive'
            if ($it.State -eq '0') { $word = 'unarchive' }
            Write-Host ('  would {0} (from app log {1}): {2}.json' -f $word, $it.Ts, $id)
            $pending++
            continue
        }
        Initialize-RunDir
        $bakDir = Join-Path $script:RunDir 'archive-flags'
        New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
        $bak = Join-Path $bakDir "$id.json"
        if (-not (Test-Path -LiteralPath $bak)) {
            [System.IO.File]::WriteAllText($bak, $raw)
            Add-ManifestRow ("overwrote`t{0}`t{1}" -f $entry, $bak)
        }
        if ($it.State -eq '1') {
            $raw = [regex]::Replace($raw, '("isArchived"\s*:\s*)false', '${1}true')
        } else {
            $raw = [regex]::Replace($raw, '("isArchived"\s*:\s*)true', '${1}false')
        }
        try { [System.IO.File]::WriteAllText($entry, $raw) } catch { $pending++; continue }
        Write-Log ('  archive replay: set isArchived={0} on {1}.json (app log event {2})' -f ($it.State -eq '1').ToString().ToLower(), $id, $it.Ts)
        $applied++
        $pending++   # stays in the ledger until observed stable next run
    }

    if ($DryRun) {
        if (($events -gt 0) -or ($pending -gt 0)) {
            Write-Host ('Archive replay: {0} new log event(s); {1} flag(s) would be applied. Nothing written.' -f $events, $pending)
        }
        return
    }
    Save-ArchiveState -Intents $intents -Offsets $newOffsets
    if ($applied -gt 0) {
        Write-Log ('Archive replay: applied {0} flag(s) from app logs ({1} intent(s) pending confirmation).' -f $applied, $pending)
    }
}

function Invoke-SessionModule {
    # Session work for one run: restructure when needed and possible
    # (Claude fully closed), then self-heal. The restructure is never
    # attempted under a live app: writing into a tree the app has open
    # is externally silent but can be overwritten or half-read.
    Set-StrictMode -Version 2
    if (-not (Test-Path $SessionsDir)) {
        Out-Sync "Sessions folder not found: $SessionsDir"
        Out-Sync 'Open Claude Desktop, go to Claude Code, and start one session first.'
        return 1
    }
    $state = Get-SessionTreeState
    foreach ($odd in $state.OddJunctions) {
        Out-Sync "  NOTE: junction to an unexpected target, left alone: $odd"
    }
    $needsStructure = (($state.RealOrgs.Count -gt 0) -or (-not $state.SharedExists))
    if ($needsStructure) {
        if ($DryRun) {
            Invoke-SessionUnify -State $state
            # Preview the heal too, against the ids the restructure would
            # leave listed, so the dry run shows the WHOLE first real run.
            $wouldList = @{}
            foreach ($org in $state.RealOrgs) {
                foreach ($f in @(Get-ChildItem -Path $org.Path -Filter 'local_*.json' -File -ErrorAction SilentlyContinue)) {
                    if ($f.Name -match $script:LocalNameRe) { $wouldList[$Matches[1].ToLowerInvariant()] = $true }
                }
            }
            if ($state.SharedExists) {
                foreach ($f in @(Get-ChildItem -LiteralPath $SharedDir -Filter 'local_*.json' -File -ErrorAction SilentlyContinue)) {
                    if ($f.Name -match $script:LocalNameRe) { $wouldList[$Matches[1].ToLowerInvariant()] = $true }
                }
            }
            # Preview the duplicate cleanup too (it is a no-op until _shared
            # exists), so the dry run shows the whole first real run.
            Remove-DuplicateHealedEntries
            Invoke-SessionHeal -ListedOverride $wouldList
            return 0
        } elseif (Test-ClaudeDesktopRunning) {
            Out-Sync ('Claude Desktop is running: the restructure ({0} org folder(s) -> _shared junctions) is postponed. Close Claude Desktop fully and run claude-sync again.' -f $state.RealOrgs.Count)
        } else {
            Invoke-SessionUnify -State $state
            $state = Get-SessionTreeState
        }
    }
    if ($state.SharedExists) {
        # Dedupe first, so the "already listed" scan inside the heal sees the
        # cleaned-up list. Both passes are id-based, so the order cannot
        # loop: a conversation whose app entry survives is listed, so it is
        # never re-healed.
        Initialize-HealMade
        Remove-DuplicateHealedEntries
        Invoke-SessionHeal
        Invoke-ArchiveReplay
        $n = @(Get-ChildItem -LiteralPath $SharedDir -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count
        Out-Sync ('Sessions: one unified index, {0} entries in _shared, visible to every account and org.' -f $n)
    } else {
        Out-Sync 'Self-heal skipped: no _shared index yet (it runs after the restructure).'
    }
    return 0
}

# ---------- sync entry point ------------------------------------------------
function Invoke-Sync {
    $doDeletes = -not $NoDeletes

    # Profile customization first: fast, and independent of the session
    # machinery (profiles exist even with a single account or no sessions).
    Sync-Profiles -Deletes $doDeletes

    $rc = Invoke-SessionModule
    if ($DryRun) {
        Write-Host 'Nothing was written.'
        return $rc
    }
    if ($rc -ne 0) { return $rc }

    # Prune old backup runs (keep the newest N, reverted ones included).
    # Runs that wrote a claude_desktop_config.json (they have a configs\
    # subdir) are counted SEPARATELY from session-only runs: they are the
    # only ones worth reverting for an MCP or settings mistake and they are
    # rare next to session runs. The watcher fires on every transcript write,
    # so ten session runs can happen in an hour; with one shared window the
    # one backup that could undo a server wipe is pruned within hours, before
    # anyone notices (macOS, 2026-07-27). Two independent windows fix that.
    # Run dirs contain only real copies (junctions are recorded as tsv rows,
    # never materialized), so a recursive delete here is safe.
    if (Test-Path $BackupsDir) {
        $runs = @(Get-ChildItem -Path $BackupsDir -Directory |
                  Where-Object { $_.Name -match '^\d+(\.reverted)?$' } |
                  Sort-Object { [long](($_.Name -replace '\.reverted$', '')) } -Descending)
        $pruneGroup = {
            param($Group)
            if ($Group.Count -gt $KeepBackups) {
                foreach ($old in $Group[$KeepBackups..($Group.Count - 1)]) {
                    Remove-Item -LiteralPath $old.FullName -Recurse -Force
                }
            }
        }
        $configRuns  = @($runs | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'configs') })
        $sessionRuns = @($runs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $_.FullName 'configs')) })
        & $pruneGroup $configRuns
        & $pruneGroup $sessionRuns
    }

    if ($script:RunDir) {
        Write-Log "Sync complete. Backup: $($script:RunDir) (claude-sync -Revert undoes this run)"
    } else {
        Write-Log 'Sync complete. Nothing needed changing.'
    }
    return $rc
}

# ---------- revert ---------------------------------------------------------
function Invoke-Revert {
    # Undo the most recent sync run: replay its manifest in REVERSE order
    # (later writes undo first, which is what makes the structural rows
    # compose with file rows), then mark the backup dir .reverted so a
    # second -Revert targets the run before it. A run that restructured the
    # tree ('tree' row) restores the whole pre-run tree, junction-aware,
    # and -- like the restructure itself -- only with Claude fully closed.
    Set-StrictMode -Version 2
    $runs = @()
    if (Test-Path $BackupsDir) {
        $runs = @(Get-ChildItem -Path $BackupsDir -Directory |
                  Where-Object { $_.Name -match '^\d+$' } |
                  Sort-Object { [long]$_.Name } -Descending)
    }
    if ($runs.Count -eq 0) {
        Write-Host "No backups found ($BackupsDir). Nothing to revert."
        return 1
    }
    $run = $null
    foreach ($candidate in $runs) {
        if (Test-Path (Join-Path $candidate.FullName 'manifest.tsv')) { $run = $candidate; break }
    }
    if (-not $run) {
        Write-Host 'No backup run left to revert.'
        return 1
    }
    $manifestPath = Join-Path $run.FullName 'manifest.tsv'
    $lines = @(Get-Content -LiteralPath $manifestPath)

    $hasTree = $false
    foreach ($line in $lines) {
        if ($line -and ($line -split "`t")[0] -eq 'tree') { $hasTree = $true; break }
    }
    if ($hasTree -and (Test-ClaudeDesktopRunning)) {
        Write-Host 'This revert restores the sessions tree structure and must run with Claude Desktop fully closed. Close Claude and run -Revert again.'
        return 1
    }

    Write-Log "Reverting sync run $($run.Name)..."
    $removed = 0; $restored = 0; $undeleted = 0; $trees = 0
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not $line) { continue }
        $parts = $line -split "`t"
        switch ($parts[0]) {
            'created' {
                if (Test-Path -LiteralPath $parts[1]) {
                    # Extension rows point at directories; -Recurse handles both.
                    Remove-Item -LiteralPath $parts[1] -Recurse -Force
                    $removed++
                }
            }
            'overwrote' {
                Copy-Item -LiteralPath $parts[2] -Destination $parts[1] -Force
                $restored++
            }
            'deleted' {
                # The file does not exist at revert time (that is the point
                # of a delete row); a plain copy-back is correct.
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $parts[1]) | Out-Null
                Copy-Item -LiteralPath $parts[2] -Destination $parts[1] -Force
                $undeleted++
            }
            'tree' {
                $salvageDir = Join-Path $run.FullName 'revert-salvage'
                $salvaged = Restore-SessionsTree -TreeBackupDir $parts[2] -LiveDir $parts[1] -SalvageDir $salvageDir
                if ($salvaged -gt 0) {
                    Write-Log ("  {0} file(s) newer than this run's snapshot were moved aside to {1} (nothing deleted)." -f $salvaged, $salvageDir)
                }
                $trees++
            }
        }
    }
    Rename-Item -LiteralPath $run.FullName -NewName ($run.Name + '.reverted')
    $msg = "Reverted: removed $removed created file(s), restored $restored overwritten file(s), restored $undeleted deleted file(s)."
    if ($trees -gt 0) { $msg += " Restored the full pre-run sessions tree ($trees snapshot(s), junctions included)." }
    Write-Log $msg
    Write-Log "Backup kept at $($run.Name).reverted. Run -Revert again to undo the previous run."
    return 0
}

# ---------- watcher (hands-off mode) ---------------------------------------
function Invoke-Watch {
    # Purely event-driven: a FileSystemWatcher on the transcripts dir wakes
    # the loop the moment any *.jsonl is created or appended (a conversation
    # exists the instant its transcript does, before the reply even lands).
    # Trailing debounce: sync fires after QUIET seconds of write silence, at
    # most once per MININT seconds. Quit needs no trigger of its own: a
    # quitting app's final writes are themselves events. Self-heal is
    # additive and safe with instances open; the restructure part
    # self-postpones while any instance runs.
    $QUIET = 8; $MININT = 45
    New-Item -ItemType Directory -Force -Path $ProjectsDir | Out-Null
    $fsw = New-Object System.IO.FileSystemWatcher $ProjectsDir, '*.jsonl'
    $fsw.IncludeSubdirectories = $true
    $fsw.InternalBufferSize = 65536
    Register-ObjectEvent $fsw Created -SourceIdentifier 'claude-sync-fs-created' | Out-Null
    Register-ObjectEvent $fsw Changed -SourceIdentifier 'claude-sync-fs-changed' | Out-Null
    $fsw.EnableRaisingEvents = $true

    # App logs too: an archive click writes a log line and nothing else (no
    # transcript event), so without this an archive-then-quit-then-relaunch
    # still loses. main.log is chatty (memory stats every few seconds), so a
    # log event only counts as activity when the appended lines actually
    # contain archive/unarchive verbs; offsets here are in-memory only and
    # seed at the current file length (history belongs to Invoke-ArchiveReplay).
    $logWatchers = New-Object System.Collections.Generic.List[object]
    $logDirs = New-Object System.Collections.Generic.List[string]
    # Escaped root: the default dir sits inside ProfilesDir, whose recursive
    # watcher below already covers it; a second watcher would double-fire.
    if (-not ($ProfilesDir -and $DefaultRoot.StartsWith($ProfilesDir, [StringComparison]::OrdinalIgnoreCase))) {
        $logDirs.Add((Join-Path $DefaultRoot 'logs'))
    }
    if (Test-Path -LiteralPath $ProfilesDir) { $logDirs.Add($ProfilesDir) }
    $i = 0
    foreach ($dir in $logDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $lw = New-Object System.IO.FileSystemWatcher $dir, 'main.log'
        $lw.IncludeSubdirectories = ($dir -eq $ProfilesDir)
        Register-ObjectEvent $lw Changed -SourceIdentifier ("claude-sync-applog-$i") | Out-Null
        $lw.EnableRaisingEvents = $true
        $logWatchers.Add($lw)
        $i++
    }
    $logOffsets = @{}
    foreach ($logPath in Get-AppLogPaths) {
        if (Test-Path -LiteralPath $logPath) { $logOffsets[$logPath] = (Get-Item -LiteralPath $logPath).Length }
    }

    Write-Log '[watcher] Watcher started (transcript + app-log events).'
    $lastRun = Get-Date
    $lastEventAt = $null
    while ($true) {
        # Wait-Event doubles as the sleep: returns on the first event,
        # times out quietly otherwise.
        $ev = Wait-Event -Timeout 3 -ErrorAction SilentlyContinue
        if ($ev) {
            # Process the whole queue: every event is either transcript
            # activity (counts as-is) or an app-log append (counts only when
            # the new lines carry archive/unarchive verbs).
            $queue = @($ev) + @(Get-Event -ErrorAction SilentlyContinue)
            foreach ($e in $queue) {
                if ($e.SourceIdentifier -like 'claude-sync-applog-*') {
                    $evPath = $null
                    try { $evPath = $e.SourceEventArgs.FullPath } catch { }
                    if ($evPath) {
                        $off = [long]0
                        if ($logOffsets.ContainsKey($evPath)) { $off = $logOffsets[$evPath] }
                        $tail = Read-AppLogTail -Path $evPath -Offset $off
                        $logOffsets[$evPath] = $tail.Offset
                        if ($tail.Text -and ($tail.Text -match 'LocalSessions\.(archive|unarchive)|(Archived|Unarchived) session local_')) {
                            $lastEventAt = Get-Date
                        }
                    }
                } else {
                    $lastEventAt = Get-Date
                }
                Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
            }
            continue
        }
        if (-not $lastEventAt) { continue }
        $now = Get-Date
        if ((($now - $lastEventAt).TotalSeconds) -lt $QUIET) { continue }
        if ((($now - $lastRun).TotalSeconds) -lt $MININT) { continue }
        Write-Log '[watcher] Transcript activity: running sync...'
        # Fresh run state per iteration (one backup run dir per sync).
        $script:RunDir = $null
        $script:ManifestPath = $null
        try { Invoke-Sync | Out-Null } catch { Write-Log ('[watcher] sync failed: {0}' -f $_.Exception.Message) }
        $lastRun = Get-Date
        $lastEventAt = $null
    }
}

function Install-AutoSync {
    if (-not (Test-Path $CanonicalPath)) {
        Write-Host "Run -Install first ($CanonicalPath not found)."
        return 1
    }
    $argLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Watch' -f $CanonicalPath
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host 'Auto-sync enabled. Sessions sync every time Claude Desktop quits (deletes included).'
    Write-Host "Log: $LogPath"
    return 0
}

function Uninstall-AutoSync {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host 'Auto-sync task not installed. Nothing to do.'
        return 0
    }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host 'Auto-sync disabled.'
    return 0
}

# ---------- install / uninstall --------------------------------------------
function Install-ClaudeSync {
    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
    if ($PSCommandPath -ne $CanonicalPath) {
        Write-Host "Installing script -> $CanonicalPath"
        Copy-Item -Path $PSCommandPath -Destination $CanonicalPath -Force
    } else {
        Write-Host 'Running from canonical location; script already in place.'
    }
    Unblock-File -Path $CanonicalPath -ErrorAction SilentlyContinue

    $profilePath = $PROFILE
    if (-not (Test-Path $profilePath)) {
        New-Item -ItemType File -Force -Path $profilePath | Out-Null
    }
    $content = Get-Content -Path $profilePath -Raw -ErrorAction SilentlyContinue
    if ($content -and $content.Contains($RcBegin)) {
        Write-Host "Command already registered in $profilePath; leaving it alone."
        Write-Host "(Script at $CanonicalPath was refreshed.)"
    } else {
        Write-Host "Registering 'claude-sync' command in $profilePath"
        $block = @"

$RcBegin
function claude-sync { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "`$HOME\.claude\scripts\claude-sync.ps1" @args }
$RcEnd
"@
        Add-Content -Path $profilePath -Value $block
    }

    # If hands-off mode is on, restart the watcher so it runs the new script.
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Write-Host 'Restarting auto-sync task with the updated script...'
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $TaskName
    }

    Write-Host 'Installed. Open a new terminal (or run ". $PROFILE"), then run: claude-sync'
}

function Uninstall-ClaudeSync {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Uninstall-AutoSync | Out-Null
    }
    $profilePath = $PROFILE
    $content = if (Test-Path $profilePath) { Get-Content -Path $profilePath -Raw } else { $null }
    if (-not $content -or -not $content.Contains($RcBegin)) {
        Write-Host "No claude-sync block found in $profilePath. Nothing to remove."
        return
    }
    Write-Host "Removing 'claude-sync' command from $profilePath"
    Copy-Item -Path $profilePath -Destination ("{0}.bak.{1}" -f $profilePath, (Get-Date -Format 'yyyyMMddHHmmss'))
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in @(Get-Content -Path $profilePath)) {
        if ($line -eq $RcBegin) { $skip = $true; continue }
        if ($line -eq $RcEnd)   { $skip = $false; continue }
        if (-not $skip) { $out.Add($line) }
    }
    Set-Content -Path $profilePath -Value $out
    Write-Host 'Removed. Open a new terminal for it to take effect.'
    Write-Host 'To delete the script, log, ledgers and backups too:'
    Write-Host "  Remove-Item `"$CanonicalPath`", `"$LogPath`", `"$LedgerPath`", `"$LedgerAccountsPath`", `"$McpLedgerPath`", `"$HealLedgerPath`", `"$HealMadePath`", `"$ArchiveIntentsPath`", `"$ArchiveOffsetsPath`"; Remove-Item -Recurse `"$BackupsDir`""
}

# ---------- status / help ---------------------------------------------------
function Show-Status {
    Write-Host "claude-sync v$ScriptVersion"
    $roots = Get-DataRoots
    if ($roots.Count -gt 1) {
        Write-Host ("Data dirs: {0} (default + {1} profile(s) in 'Claude Profiles')" -f $roots.Count, ($roots.Count - 1))
        foreach ($root in $roots) {
            $cfg = Join-Path $root 'claude_desktop_config.json'
            $n = 0
            $s = 0
            if (Test-Path -LiteralPath $cfg) {
                try {
                    $json = ConvertFrom-Json ([System.IO.File]::ReadAllText($cfg))
                    $mProp = $json.PSObject.Properties['mcpServers']
                    if ($mProp -and $null -ne $mProp.Value) { $n = @($mProp.Value.PSObject.Properties).Count }
                    $pProp = $json.PSObject.Properties['preferences']
                    if ($pProp -and $null -ne $pProp.Value) { $s = @($pProp.Value.PSObject.Properties).Count }
                } catch { $n = '?'; $s = '?' }
            }
            Write-Host ('  {0}: {1} MCP server(s), {2} setting(s)' -f (Split-Path -Leaf $root), $n, $s)
        }
        $ledgerRows = 0
        foreach ($cfgSet in (Read-McpLedger).Values) { $ledgerRows += $cfgSet.Count }
        if ($ledgerRows -gt 0) {
            Write-Host ('  MCP ledger: {0} (config, server) row(s)' -f $ledgerRows)
        }
    }
    Write-Host "Sessions dir: $SessionsDir"
    if (-not (Test-Path $SessionsDir)) {
        Write-Host '  (not found: open Claude Code in Claude Desktop once)'
        return
    }
    $state = Get-SessionTreeState
    if ($state.SharedExists) {
        $n = @(Get-ChildItem -LiteralPath $SharedDir -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count
        Write-Host ('  unified: {0} session entries in _shared; {1} org junction(s) across {2} account(s)' -f `
            $n, $state.JunctionCount, $state.AccountCount)
    }
    if ($state.RealOrgs.Count -gt 0) {
        Write-Host ('  pending restructure: {0} real org folder(s); run claude-sync with Claude Desktop closed' -f $state.RealOrgs.Count)
        foreach ($org in $state.RealOrgs) {
            $n = @(Get-ChildItem -Path $org.Path -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count
            Write-Host ('    {0}\{1}: {2} entries' -f $org.Account, $org.Org, $n)
        }
    }
    foreach ($odd in $state.OddJunctions) {
        Write-Host "  junction to an unexpected target (left alone): $odd"
    }
    $healN = (Get-HealLedger).Count
    if ($healN -gt 0) { Write-Host ('  heal ledger: {0} session id(s) tracked (deleted entries stay deleted)' -f $healN) }
    if (Test-Path -LiteralPath $HealMadePath) {
        $madeN = (Get-HealMade).Count
        Write-Host ('  heal record: {0} entry(ies) written by self-heal (dropped if the app writes its own)' -f $madeN)
    }
    if (Test-Path -LiteralPath $ProjectsDir) {
        $tn = 0
        foreach ($pd in @(Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue)) {
            $tn += @(Get-ChildItem -Path $pd.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue).Count
        }
        Write-Host ('  transcripts on disk: {0}' -f $tn)
    }
    if (Test-Path $CanonicalPath) {
        Write-Host "Script: installed at $CanonicalPath"
    } else {
        Write-Host 'Script: not installed (run -Install)'
    }
    $content = if (Test-Path $PROFILE) { Get-Content -Path $PROFILE -Raw -ErrorAction SilentlyContinue } else { $null }
    if ($content -and $content.Contains($RcBegin)) {
        Write-Host "Command: registered in $PROFILE"
    } else {
        Write-Host 'Command: not registered'
    }
    $task = $null
    try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
    if ($task) {
        Write-Host 'Auto-sync: enabled (syncs when Claude Desktop quits)'
    } else {
        Write-Host 'Auto-sync: disabled'
    }
    $lastSync = $null
    if (Test-Path $LogPath) {
        # 'Sync complete' is the completion line since v3; 'Done.' covers
        # logs from the v1/v2 scripts so history stays readable.
        $doneLines = @(Get-Content -Path $LogPath -ErrorAction SilentlyContinue |
                       Where-Object { $_ -match '\] (Sync complete|Done\.)' })
        if ($doneLines.Count -gt 0 -and $doneLines[$doneLines.Count - 1] -match '^\[([^\]]+)\]') {
            $lastSync = $Matches[1]
        }
    }
    if ($lastSync) { Write-Host "Last sync: $lastSync" } else { Write-Host 'Last sync: never' }
    $runCount = 0
    if (Test-Path $BackupsDir) {
        $runCount = @(Get-ChildItem -Path $BackupsDir -Directory).Count
    }
    Write-Host "Backups: $runCount stored run(s) (use -Revert to undo the newest)"
}

function Show-Help {
    Write-Host @"
claude-sync v$ScriptVersion
One shared Claude Code session list for every Claude Desktop account and
org on this PC, plus customization sync (MCP servers, preferences,
Desktop Extensions) across claude-deck profiles.

Sessions work structurally since v4 (Windows): a one-time restructure
(needs Claude fully closed) moves the union of every <account>\<org>
index into claude-code-sessions\_shared and replaces the org folders
with directory junctions to it. After that there is one physical list:
new sessions appear under every account instantly, a delete in the app
is a delete everywhere, nothing is copied on a schedule. Every run also
self-heals: a session whose transcript exists but whose list entry was
never written (app restart, rewound session) gets a minimal entry
generated from the transcript. Existing entries are never edited;
transcripts are never touched; deletes are never resurrected (tracked
in heal-ledger.tsv). The only entry ever deleted is a self-heal copy the
app has since replaced with its own (heal-made.tsv records what we
wrote), which is what used to show one chat twice. The restructure backs
up the whole tree first and -Revert restores it completely (also only
with Claude closed).

Customization syncs across claude-deck profiles too: MCP servers, app
settings (the preferences block) and Desktop Extensions. The newest
change wins a conflict, settings are add-only, and an MCP removal
propagates only when mcp-ledger.tsv can name the config that lost it.
A config that lost two or more servers at once is read as a stale
Claude Desktop writeback instead: it decides nothing that run and is
refilled from the others (CLAUDE_SYNC_MCP_RESET_MIN raises the two).

Usage: claude-sync [command]   (--gnu-style spellings work too)

  (no command)     Run the sync. With Claude closed: restructure (first
                   run), then self-heal. With Claude open: self-heal only;
                   the restructure waits and says so.
  -DryRun          Show everything a run would do, write nothing.
  -NoDeletes       MCP servers only: skip removal propagation (and thereby
                   restore a server deleted on one side). Sessions no
                   longer need it: one physical list has no copies to
                   reconcile.
  -Revert          Undo the most recent run from its backup. A run that
                   restructured the tree restores it fully (Claude must
                   be closed for that).
  -Status          Show tree state, entry counts, per-profile MCP and
                   settings counts, ledger sizes, install state.
  -Install         Copy this script to ~\.claude\scripts\ and register the
                   'claude-sync' command in your PowerShell profile.
                   Re-run to update.
  -Uninstall       Remove the command and the auto-sync task (if enabled).
  -AutoInstall     Auto-sync every time Claude Desktop quits (per-user
                   Scheduled Task, no admin rights).
  -AutoUninstall   Disable auto-sync.
  -Version         Print version.
  -Help            This text.

First run: close Claude Desktop fully, run claude-sync once, reopen.
Everything after that can run anytime (self-heal is safe with the app
open; structural changes simply wait for a closed app).
"@
}

# ---------- dispatcher -------------------------------------------------------
# Map GNU-style spellings onto the switches, so the macOS muscle memory
# (claude-sync --dry-run --no-deletes) works here too.
$flagMap = @{
    '--dry-run' = 'DryRun'; '--no-deletes' = 'NoDeletes'; '--revert' = 'Revert'
    '--status' = 'Status'; '--install' = 'Install'; '--uninstall' = 'Uninstall'
    '--auto-install' = 'AutoInstall'; '--auto-uninstall' = 'AutoUninstall'
    '--watch' = 'Watch'; '--version' = 'Version'; '-v' = 'Version'
    '--help' = 'Help'; '-h' = 'Help'
}
$badArg = $false
foreach ($arg in @($Rest)) {
    if ($null -eq $arg -or $arg -eq '') { continue }
    $key = $arg.ToLowerInvariant()
    if ($flagMap.ContainsKey($key)) {
        Set-Variable -Name $flagMap[$key] -Value ([switch]$true)
    } else {
        $badArg = $true
    }
}

if     ($badArg)        { Show-Help; exit 1 }
elseif ($Help)          { Show-Help }
elseif ($Version)       { Write-Host "claude-sync v$ScriptVersion" }
elseif ($Install)       { Install-ClaudeSync }
elseif ($Uninstall)     { Uninstall-ClaudeSync }
elseif ($AutoInstall)   { exit (Install-AutoSync) }
elseif ($AutoUninstall) { exit (Uninstall-AutoSync) }
elseif ($Watch)         { Invoke-Watch }
elseif ($Status)        { Show-Status }
elseif ($Revert)        { exit (Invoke-Revert) }
else                    { exit (Invoke-Sync) }
