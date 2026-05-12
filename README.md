<div align="center">

# tm — tmux Session Manager

**Maintain Claude Code sessions across devices using tmux.**

**Pure Bash + fzf. Single file. Zero friction. Millisecond startup.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Bash 4.0+](https://img.shields.io/badge/Bash-4.0%2B-green.svg)](#dependencies)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20iOS%20%7C%20Android-lightgrey.svg)](#platform-support)

[繁體中文](README.zh-TW.md)

</div>

> **Why tm?** Modern development means running multiple AI agents, Claude Code sessions, and background tasks across tmux — often on a remote server you want to reach from any device. `tm` gives you instant visibility into what's running where, with process trees, AI-powered summaries, and protection locks to keep critical sessions safe. Start a Claude Code session on your desktop, detach, then SSH into the same remote host from your laptop or phone and pick up exactly where you left off. On mobile (iOS / Android), just SSH into your remote server and run `tm` — the fzf interface works great with touch, letting you manage sessions on the go.

---

## Demo

```
╭──────────────── tmux session manager v1.0.0 ──────────────────╮
│ Keys: ↵Enter │ Tab Multi-sel │ ^N New │ ^K Kill │ ^P Protect  │
│                                                               │
│      NAME                  DIRECTORY                W  P IDLE │
│  [▸] my-project            ~/project/my-project     3  4 now  │
│ >[●] web-app               ~/project/web-app        2  2 3m   │
│  [●] api-server 🔒         ~/project/api-server     4  5 15m  │
│  [○] dotfiles              ~/dotfiles               1  1 2h   │
│  [○] notes                 ~/documents/notes        1  1 1d   │
│                                                               │
│╭─────────────────────────────────────────────────────────────╮│
││ ── Session Details ──────────────────                       ││
││ 🏷️  web-app                                                 ││
││ 📂 ~/project/web-app                                        ││
││ 🌿 feat/new-dashboard                                       ││
││ 🪟 2 win · 2 pane · 1 client                                ││
││ 🕒 2026-04-06 08:30 · idle 3m                               ││
││ 💡 Next.js dashboard dev with hot reload                    ││
││                                                             ││
││ ── Running Processes ────────────────                       ││
││   ▸ zsh  (1234)  CPU 0.0% · RAM 12.3M                       ││
││     └─ node  (1250)  CPU 2.1% · RAM 156.8M                  ││
││   ▸ zsh  (1300)  CPU 0.0% · RAM 11.8M                       ││
││     └─ claude  (1315)  CPU 0.5% · RAM 89.2M                 ││
││   Total: CPU 2.6% · RAM 270.1M                              ││
││                                                             ││
││ ── Window List ─────────────────────                        ││
││   0: editor (active)                                        ││
││   1: server                                                 ││
│╰─────────────────────────────────────────────────────────────╯│
╰───────────────────────────────────────────────────────────────╯

Status indicators:  [▸] current   [●] attached   [○] idle   🔒 protected
```

---

## Highlights

| | Feature | Description |
|---|---|---|
| 🤖 | **AI Summaries** | Auto-generate session purpose summaries with Claude Haiku |
| 💾 | **Backup & Restore** | Snapshot sessions with Claude Code state, restore after reboot |
| 🌳 | **Process Tree** | See every pane's shell and child processes with CPU/RAM |
| 🔒 | **Protection Lock** | Prevent critical sessions from accidental termination |
| ⚡ | **Smart Sorting** | Most recently used sessions always on top |
| 🎨 | **Group Colors** | Sessions in the same directory share indicator colors |
| 🌿 | **Git Branch** | Preview panel shows current branch at a glance |
| 📋 | **Session Templates** | Create multi-window layouts in one command |
| 💀 | **Batch Kill** | Multi-select and kill with three-stage safety confirmation |

---

## Quick Start

```bash
git clone <repo-url> && cd session-manager
./install-fzf.sh
chmod +x tm.sh
./tm.sh
```

## Installation

```bash
# Clone or download to any directory
chmod +x tm.sh

# Download fzf (required for interactive mode)
./install-fzf.sh

# (Optional) Create a global shortcut — pick one:
ln -sf "$(pwd)/tm.sh" ~/.local/bin/tm
# or add to ~/.bashrc / ~/.zshrc:
alias tm="~/session-manager/tm.sh"
```

### Dependencies

| Tool | Version | Purpose | Install |
|------|---------|---------|---------|
| `bash` | 4.0+ | Required | See note below |
| `tmux` | — | Required | `brew install tmux` / `apt install tmux` |
| `fzf` | — | Interactive mode | Run `./install-fzf.sh` to auto-download into the project directory |

> [!NOTE]
> CLI mode (`ls`, `kill`, `protect`, etc.) only requires tmux — no fzf needed.

> [!WARNING]
> **macOS users:** The default `/bin/bash` is version 3.2. You need bash 4.0+ for this tool to work. Install a newer version with `brew install bash` and make sure the new bash is in your `$PATH` before `/bin/bash`.

### Platform Support

Works on desktop and mobile — attach to the same remote tmux sessions from anywhere, so your Claude Code work follows you across devices.

| Platform | How to use |
|----------|------------|
| **macOS** (ARM / Intel) | Run directly, or SSH into a remote host |
| **Linux** (amd64 / arm64) | Run directly, or SSH into a remote host |
| **iOS / iPadOS** | SSH into your remote server via [Termius](https://termius.com/) |
| **Android** | SSH into your remote server via [Termux](https://termux.dev/) |

> [!TIP]
> On mobile, `tm`'s fzf-based UI works great with touch and on-screen keyboards — no desktop required. Pair with mosh for a seamless experience over unstable remote connections.

---

## Usage

### Interactive Mode (Recommended)

```bash
./tm.sh          # Launch fzf interactive menu
```

| Shortcut  | Action                              |
|-----------|-------------------------------------|
| `Enter`   | Attach to selected session          |
| `Tab`     | Multi-select (for batch kill with `Ctrl-K`) |
| `Ctrl-N`  | Create new session                  |
| `Ctrl-K`  | Kill session (supports multi-select batch kill) |
| `Ctrl-E`  | Rename session                      |
| `Ctrl-D`  | Detach other clients                |
| `Ctrl-P`  | Toggle protection lock 🔒           |
| `Ctrl-R`  | Refresh list                        |
| `Ctrl-Q`  | Quit                                |
| `Esc`     | Quit                                |

### CLI Mode

```bash
tm                          # Interactive menu
tm <session-name>           # Attach to a specific session
tm new myapp ~/code         # Create a new session
tm new myapp -t dev         # Create session from template (3 windows)
tm kill myapp               # Kill session (with safety checks)
tm attach myapp -d          # Attach and detach other clients
tm rename myapp             # Rename session
tm last                     # Switch to the last session
tm ls                       # List all sessions (plain text)
tm templates                # List available templates
tm protect myapp            # Toggle protection status
tm summarize myapp          # Generate AI summary for a session
tm summarize-all            # Generate AI summaries for all sessions
tm save                     # Snapshot all sessions (for restore after reboot)
tm restore                  # Restore sessions from snapshot
tm restore --claude         # Restore sessions and auto-launch Claude Code
tm snapshots                # Show latest snapshot contents
tm help                     # Show help
```

---

## tmux Keybinding Integration

Add the following to `~/.tmux.conf` to launch the manager with `Prefix + M`:

```tmux
# Popup mode (recommended, tmux 3.2+)
bind M display-popup -w 90% -h 85% -E "/path/to/tm.sh"

# Or open in a new window
bind M new-window -n "tm" "/path/to/tm.sh"
```

## Zsh Completion

```bash
# Option 1: Source directly (add to ~/.zshrc)
source /path/to/session-manager/completions/tm.zsh

# Option 2: Copy to fpath
cp completions/tm.zsh ~/.zsh/completions/_tm
```

---

## Safety Mechanisms

Three layers of protection to prevent accidental session termination:

1. **Protection Lock** — Sessions marked with `Ctrl-P` are blocked from deletion entirely
2. **Current Session Detection** — Cannot kill the session you are currently using
3. **Three-stage Confirmation** — Shows running critical processes (claude, python, node...) and requires typing the full session name to confirm

## Environment Variables

| Variable           | Default                    | Description                          |
|--------------------|----------------------------|--------------------------------------|
| `TM_PROJECT_BASE`  | Two levels above tm.sh     | Directory menu for creating new sessions |

---

<details>
<summary><strong>Backup & Restore</strong> — Survive reboots with Claude Code state</summary>

### How it works

`tm save` captures a JSON snapshot of every session — name, working directory, and whether Claude Code is running (with `continue` vs `fresh` mode detection based on `~/.claude/projects/`).

```bash
tm save                  # Snapshot all sessions
tm restore               # Recreate sessions from snapshot (skip existing)
tm restore --claude      # Also auto-launch Claude Code where it was running
tm snapshots             # Preview the latest snapshot
```

Snapshot is saved to `<tm-dir>/snapshots/sessions.json` (next to `tm.sh`), with the previous version rotated to `sessions.json.bak`. This keeps backup data inside the project directory and avoids overwriting any existing user backups.

### Auto-save via Cron

```bash
crontab -e
# Every 30 minutes:
*/30 * * * * /path/to/tm.sh save >> /tmp/tm-save.log 2>&1
```

> Requires `python3` for safe JSON handling.

</details>

<details>
<summary><strong>AI Summaries</strong> — Setup & Cron</summary>

### How it works

Uses Claude Haiku to generate a one-line summary for each tmux session, inferring its purpose from session name, directory, git branch, window list, and running processes.

```bash
tm summarize myapp       # Single session
tm summarize-all         # All sessions
```

Summary history is stored in JSONL format at `~/.tmux-manager/summaries/<session_name>.jsonl` and is not auto-cleaned. The latest summary is displayed in the fzf preview panel.

### Cron Schedule (Auto-update Hourly)

```bash
crontab -e
# Add the following line (replace with your actual path):
0 * * * * /path/to/tm.sh summarize-all >> /tmp/tm-summary.log 2>&1
```

> Requires [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli) (`claude` command) to be installed.

</details>

<details>
<summary><strong>File Structure</strong></summary>

```
session-manager/
├── tm.sh                              # Main script
├── install-fzf.sh                     # fzf download script
├── completions/
│   └── tm.zsh                         # Zsh completion
├── snapshots/                         # Backup snapshots (gitignored)
│   ├── sessions.json                  # Latest snapshot
│   └── sessions.json.bak             # Previous snapshot
└── ~/.tmux-manager/                   # Runtime data (auto-created)
    ├── protected.txt                  # Protected session list
    ├── last_session                   # Last session record
    ├── templates/                     # Session template directory
    │   └── dev                        # Default dev template (editor/server/logs)
    └── summaries/                     # AI summary history (JSONL)
        └── <session_name>.jsonl       # One summary record per line
```

</details>

---

## License

[MIT](LICENSE)
