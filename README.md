# claude-sync has moved into claude-deck

This repo is archived. claude-sync now lives in **[smk-labs/claude-deck](https://github.com/smk-labs/claude-deck)**, under [`sync/`](https://github.com/smk-labs/claude-deck/tree/main/sync).

Nothing about the tool changed. Same two scripts, same behaviour, same install target (`~/.claude/scripts/`). Only the download URL is different, so an existing install keeps working until you next update.

## Install or update

macOS:

```bash
curl -fsSLo /tmp/cs.sh https://raw.githubusercontent.com/smk-labs/claude-deck/main/sync/claude-sync.sh && chmod +x /tmp/cs.sh && /tmp/cs.sh --install && source ~/.zshrc
```

Windows (PowerShell):

```powershell
iwr -useb https://raw.githubusercontent.com/smk-labs/claude-deck/main/sync/claude-sync.ps1 -OutFile "$env:TEMP\cs.ps1"; & "$env:TEMP\cs.ps1" -Install
```

Full documentation: [claude-deck/sync/README.md](https://github.com/smk-labs/claude-deck/blob/main/sync/README.md).

## Why

claude-sync was never independent of claude-deck. Its profile layer (MCP servers, app settings, extensions) only means anything when you run claude-deck profiles, and claude-deck's own `doctor` command already ran it for you. Two repos for one tool meant installing twice and letting the docs drift apart.

MIT license, unchanged. See [LICENSE](LICENSE).
