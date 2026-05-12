<div align="center">

# tm — tmux Session Manager

**透過 tmux 跨裝置維持你的 Claude Code sessions。**
*(Maintain Claude Code sessions across devices using tmux.)*

**純 Bash + fzf。單一檔案。零摩擦。毫秒級啟動。**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Bash 4.0+](https://img.shields.io/badge/Bash-4.0%2B-green.svg)](#相依)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20iOS%20%7C%20Android-lightgrey.svg)](#平台支援)

[English](README.md)

</div>

> **為什麼選 tm？** 現代開發意味著同時運行多個 AI agent、Claude Code session 和背景任務，而且這些通常跑在你希望從任何裝置都能連上的 remote 伺服器上。`tm` 讓你一眼掌握每個 session 的狀態 — 透過程序樹、AI 摘要和保護鎖，確保關鍵 session 不被誤殺。在桌機上啟動 Claude Code session，detach 之後從筆電或手機 SSH 連回同一台 remote host，就能無縫接回剛才的進度。在手機上（iOS / Android）只要 SSH 進你的 remote 伺服器執行 `tm`，fzf 介面搭配觸控操作流暢，隨時隨地管理 sessions。

---

## 示範

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

狀態指示器：[▸] 目前使用中   [●] 已連線   [○] 閒置   🔒 受保護
```

---

## 功能亮點

| | 功能 | 說明 |
|---|---|---|
| 🤖 | **AI 摘要** | 透過 Claude Haiku 自動產生 session 用途摘要 |
| 💾 | **備份與還原** | 備份 session 含 Claude Code 狀態，重開機後可還原 |
| 🌳 | **程序樹** | 顯示每個 pane 的 shell 及子程序，含 CPU/RAM |
| 🔒 | **保護鎖** | 防止關鍵 session 被意外終止 |
| ⚡ | **智慧排序** | 最近使用的 session 永遠在最上面 |
| 🎨 | **分組色彩** | 相同目錄下的 session 共享指示器顏色 |
| 🌿 | **Git 分支** | 預覽面板一眼看到目前分支 |
| 📋 | **Session 模板** | 一個指令建立多視窗佈局 |
| 💀 | **批量刪除** | 多選後批量關閉，每個都經三階段確認 |

---

## 快速開始

```bash
git clone <repo-url> && cd session-manager
./install-fzf.sh
chmod +x tm.sh
./tm.sh
```

## 安裝

```bash
# Clone 或下載到任意目錄
chmod +x tm.sh

# 下載 fzf（互動模式所需）
./install-fzf.sh

# （可選）建立全域捷徑，擇一使用：
ln -sf "$(pwd)/tm.sh" ~/.local/bin/tm
# 或加入 ~/.bashrc / ~/.zshrc：
alias tm="~/session-manager/tm.sh"
```

### 相依

| 工具 | 版本 | 用途 | 安裝方式 |
|------|------|------|----------|
| `bash` | 4.0+ | 必要 | 見下方說明 |
| `tmux` | — | 必要 | `brew install tmux` / `apt install tmux` |
| `fzf` | — | 互動模式 | 執行 `./install-fzf.sh` 自動下載至專案目錄 |

> [!NOTE]
> CLI 模式（`ls`、`kill`、`protect` 等）只需要 tmux，不需要 fzf。

> [!WARNING]
> **macOS 使用者注意：** 系統內建的 `/bin/bash` 版本為 3.2，本工具需要 bash 4.0 以上。請透過 `brew install bash` 安裝新版，並確保新版 bash 在 `$PATH` 中優先於 `/bin/bash`。

### 平台支援

桌面和手機都能用 — 從任何裝置接回同一台 remote 上的 tmux sessions，讓 Claude Code 進度跨裝置延續。

| 平台 | 使用方式 |
|------|----------|
| **macOS**（ARM / Intel） | 直接執行，或 SSH 連進 remote host |
| **Linux**（amd64 / arm64） | 直接執行，或 SSH 連進 remote host |
| **iOS / iPadOS** | 透過 [Termius](https://termius.com/) SSH 連進 remote 伺服器執行 |
| **Android** | 透過 [Termux](https://termux.dev/) SSH 連進 remote 伺服器執行 |

> [!TIP]
> 在手機上，`tm` 的 fzf 互動介面搭配觸控和螢幕鍵盤操作流暢，不需要桌面環境。搭配 mosh 使用，即使 remote 連線不穩定也能保持順暢體驗。

---

## 使用方式

### 互動模式（推薦）

```bash
./tm.sh          # 啟動 fzf 互動選單
```

| 快捷鍵    | 功能                           |
|-----------|--------------------------------|
| `Enter`   | 進入選取的 Session              |
| `Tab`     | 多選（搭配 `Ctrl-K` 批量刪除）  |
| `Ctrl-N`  | 新建 Session                   |
| `Ctrl-K`  | 關閉 Session（支援多選批量刪除）|
| `Ctrl-E`  | 重新命名 Session               |
| `Ctrl-D`  | 踢除其他連線                   |
| `Ctrl-P`  | 切換保護鎖 🔒                   |
| `Ctrl-R`  | 重新整理列表                   |
| `Ctrl-Q`  | 離開                           |
| `Esc`     | 離開                           |

### CLI 模式

```bash
tm                          # 互動選單
tm <session-name>           # 直接進入指定 session
tm new myapp ~/code         # 快速建立 session
tm new myapp -t dev         # 用模板建立 session（3 個視窗）
tm kill myapp               # 關閉 session（有防呆）
tm attach myapp -d          # 進入 session，踢除其他連線
tm rename myapp             # 重新命名 session
tm last                     # 切回上一個 session
tm ls                       # 純文字列出所有 session
tm templates                # 列出可用模板
tm protect myapp            # 切換保護狀態
tm summarize myapp          # 產生單一 session 的 AI 摘要
tm summarize-all            # 產生所有 session 的 AI 摘要
tm save                     # 備份所有 session（重開機後可還原）
tm restore                  # 從快照還原 session
tm restore --claude         # 還原 session 並自動啟動 Claude Code
tm snapshots                # 顯示最新快照內容
tm help                     # 說明
```

---

## tmux 快捷鍵整合

在 `~/.tmux.conf` 加入以下設定，按 `Prefix + M` 就能叫出管理面板：

```tmux
# Popup 模式（推薦，tmux 3.2+）
bind M display-popup -w 90% -h 85% -E "/path/to/tm.sh"

# 或開新視窗
bind M new-window -n "tm" "/path/to/tm.sh"
```

## Zsh 補全

```bash
# 方法一：直接 source（加到 ~/.zshrc）
source /path/to/session-manager/completions/tm.zsh

# 方法二：複製到 fpath
cp completions/tm.zsh ~/.zsh/completions/_tm
```

---

## 防呆機制

三道防線，防止誤殺 session：

1. **保護鎖** — `Ctrl-P` 標記的 session 直接阻擋刪除，連確認的機會都不給
2. **當前 Session 偵測** — 無法關閉你正在使用的 session
3. **三階段確認** — 顯示執行中的重要程序（claude, python, node...），必須手打完整名稱才能刪除

## 環境變數

| 變數                | 預設值              | 說明                     |
|--------------------|---------------------|--------------------------|
| `TM_PROJECT_BASE`  | tm.sh 上兩層目錄     | 新建 session 時的目錄選單 |

---

<details>
<summary><strong>備份與還原</strong> — 重開機後保留 Claude Code 狀態</summary>

### 運作方式

`tm save` 會將每個 session 的名稱、工作目錄，以及 Claude Code 狀態（根據 `~/.claude/projects/` 偵測是否為 `continue` 或 `fresh` 模式）寫入 JSON 快照。

```bash
tm save                  # 備份所有 session
tm restore               # 從快照還原（已存在的 session 會跳過）
tm restore --claude      # 還原 session 並自動啟動 Claude Code
tm snapshots             # 預覽最新快照
```

快照儲存於 `<tm-dir>/snapshots/sessions.json`（與 `tm.sh` 同層目錄），前一版會輪替為 `sessions.json.bak`。備份資料存在專案目錄內，不會覆蓋使用者既有的備份。

### Cron 自動備份

```bash
crontab -e
# 每 30 分鐘備份一次：
*/30 * * * * /path/to/tm.sh save >> /tmp/tm-save.log 2>&1
```

> 需要 `python3` 處理 JSON。

</details>

<details>
<summary><strong>AI 摘要</strong> — 設定與排程</summary>

### 運作方式

用 Claude Haiku 對每個 tmux session 產生一行摘要，根據 session 名稱、目錄、git branch、視窗列表、執行中程序等中繼資料推斷用途。

```bash
tm summarize myapp       # 單一 session
tm summarize-all         # 所有 session
```

摘要歷史以 JSONL 格式儲存在 `~/.tmux-manager/summaries/<session_name>.jsonl`，不自動清理。最新一筆摘要會顯示在 fzf 預覽面板。

### Cron 排程（每小時自動更新）

```bash
crontab -e
# 加入以下行（請替換為你的實際路徑）：
0 * * * * /path/to/tm.sh summarize-all >> /tmp/tm-summary.log 2>&1
```

> 需要先安裝 [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli)（`claude` 指令）。

</details>

<details>
<summary><strong>檔案結構</strong></summary>

```
session-manager/
├── tm.sh                              # 主程式
├── install-fzf.sh                     # fzf 下載腳本
├── completions/
│   └── tm.zsh                         # Zsh 補全
├── snapshots/                         # 備份快照（gitignored）
│   ├── sessions.json                  # 最新快照
│   └── sessions.json.bak             # 前一份快照
└── ~/.tmux-manager/                   # 執行時資料（自動建立）
    ├── protected.txt                  # 受保護的 session 名單
    ├── last_session                   # 上一個 session 記錄
    ├── templates/                     # Session 模板目錄
    │   └── dev                        # 預設 dev 模板（editor/server/logs）
    └── summaries/                     # AI 摘要歷史（JSONL）
        └── <session_name>.jsonl       # 每行一筆摘要記錄
```

</details>

---

## License

[MIT](LICENSE)
