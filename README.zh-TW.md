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

![tm session manager interface](docs/images/tm-demo.png)

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
| 💾 | **備份與還原** | 備份 session 含 Claude Code 與 Codex 狀態，重開機後可還原 |
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
tm install-claude-hook      # 啟用 Claude session ID 追蹤與 agent 狀態
tm save                     # 備份所有 session（重開機後可還原）
tm restore                  # 從快照還原 session
tm restore --claude         # 還原 session 並自動啟動 Claude Code
tm restore --codex          # 還原 session 並續接 Codex
tm snapshots                # 顯示最新快照內容
tm snapshots --list         # 列出帶時間戳的快照歷史
tm screens myapp            # 顯示上次備份時擷取的 pane 畫面
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

## Agent 狀態

執行 `tm install-claude-hook` 後，Claude Code hooks 會回報每個 agent 的狀態，選單在 session 狀態旁顯示：

| 圖示 | 狀態 | 意義 |
|------|------|------|
| `⏳` | working | 正在處理 prompt |
| `⏳?` | working（逾時） | 超過 `TM_STALE_AFTER` 秒沒有 hook 更新，可能卡住或 hook 失效 |
| `❓` | blocked | 等你回應：權限確認或要求輸入 |
| `💤` | idle | 一輪結束，等待下一個 prompt |
| `·` | unknown | 沒有 agent、agent 已結束，或沒裝 hook |

- 一個 session 有多個 agent 時，顯示最需要注意的狀態（blocked > working > idle）。
- 有 blocked agent 的 session 會排到最上面；設定 `TM_SORT=recent` 可維持單純的最近使用排序。
- Preview 面板列出每個 agent pane 的狀態、持續多久，blocked 時另外顯示通知訊息。
- 狀態依 pane 存放在 `~/.tmux-manager/state/<pane>.json`（僅擁有者可讀）；`tm save` 會清掉已不存在的 pane 的檔案。
- Hook 在 Claude session 啟動時載入，安裝後需重啟執行中的 Claude session。

## 機器介面（`tm ls --json`）

`tm ls --json` 輸出單一 JSON 物件，涵蓋所有 session 與其中的 agent pane，給腳本與 Leader agent 使用。純文字的 `tm ls` 維持不變。

```json
{
  "v": 1, "host": "vm-crawler-01", "generated_at": "2026-10-22T09:51:00Z",
  "sessions": [{
    "name": "web-app", "dir": "/home/yuan/project/web-app", "git_branch": "main",
    "windows": 2, "panes": 2, "clients": 1, "last_activity": "2026-10-22T09:48:00Z",
    "protected": false, "summary": null, "state": "blocked",
    "agents": [{
      "pane": "%12", "target": "web-app:1.0", "agent": "claude", "pid": 1315,
      "session_id": "8f3c…", "state": "blocked", "stale": false,
      "since": "2026-10-22T09:50:12Z", "reason": "permission",
      "message": "Claude needs your permission to use Bash", "source": "hook"
    }]
  }]
}
```

| 參數 | 作用 |
|------|------|
| `--state <s>[,<s>]` | 只留下至少有一個 agent 處於這些狀態的 session（`blocked`、`working`、`idle`、`unknown`） |
| `--agent <name>` | 只留下指定類型的 agent（`claude`、`codex`），session 的 `state` 依剩下的 agent 重算 |
| `--session <name>` | 只輸出這個 session |
| `--no-summary` | 不讀 AI 摘要（`summary` 為 `null`） |

| Exit code | 意義 |
|-----------|------|
| `0` | 成功，包含結果為空 |
| `2` | `--session` 指定的 session 不存在 |
| `3` | 參數錯誤 |
| `4` | tmux server 未啟動 |

- stdout 只放 JSON，警告與錯誤寫 stderr。沒有值的欄位輸出 `null`，不省略 key。
- `source` 為 `hook` 表示狀態來自 Claude hook；`heuristic` 表示找到 agent 行程但沒有 hook 狀態（Codex 或沒裝 hook），此時狀態為 `unknown`。Hook 狀態只在 agent 行程還在時才採信：agent 被強制結束、沒有執行結束 hook 時，pane 仍會列出，但 `pid` 為 `null`、狀態為 `unknown`，不會顯示 `idle`。
- `stale: true` 表示 `working` 的 agent 已超過 `TM_STALE_AFTER` 秒沒有 hook 更新。
- `target` 可直接交給 `tmux send-keys -t`。`v` 只在破壞相容時遞增，呼叫端應忽略不認得的 key。

```bash
# 列出所有在等你回應的 agent
tm ls --json --state blocked | jq -r '.sessions[].agents[] | select(.state == "blocked") | .target'

# 查看某個 session 裡的 agent 狀態
tm ls --json --session web-app --no-summary | jq '.sessions[0].agents[] | {target, state, reason}'
```

## 防呆機制

三道防線，防止誤殺 session：

1. **保護鎖** — `Ctrl-P` 標記的 session 直接阻擋刪除，連確認的機會都不給
2. **當前 Session 偵測** — 無法關閉你正在使用的 session
3. **三階段確認** — 顯示執行中的重要程序（claude, python, node...），必須手打完整名稱才能刪除

## 環境變數

| 變數                | 預設值              | 說明                     |
|--------------------|---------------------|--------------------------|
| `TM_PROJECT_BASE`  | tm.sh 上兩層目錄     | 新建 session 時的目錄選單 |
| `TM_SNAPSHOT_KEEP` | `48`                 | `tm save` 保留的帶時間戳快照份數 |
| `TM_SORT`          | （未設定）            | 設為 `recent` 時不把 blocked 排到最上面 |
| `TM_STALE_AFTER`   | `1800`               | working 超過幾秒沒有 hook 更新就顯示 `⏳?` |

---

<details>
<summary><strong>備份與還原</strong> — 重開機後保留 Claude Code 與 Codex 狀態</summary>

### 運作方式

`tm save` 會將每個 session 的名稱、工作目錄、執行中的 agent，以及可取得的 Claude Code 或 Codex 精確 session ID 寫入 JSON 快照。還原時會優先使用記錄的 ID，因此即使同一工作目錄有多個 agent session，也能分別續接。

首次使用前執行一次 Claude `SessionStart` hook 安裝指令，建立 tmux pane 與 session ID 的對應。安裝器會保留既有設定與 hooks，修改既有 `~/.claude/settings.json` 前也會建立含時間戳的備份。session hook 只記錄 pane ID、session UUID、工作目錄與時間戳，不會讀取對話內容。同一個指令也會安裝 [agent 狀態](#agent-狀態) hooks；agent 處於 blocked 時，會另外保存 Claude 的通知文字（例如 `Claude needs your permission to use Bash`）。

```bash
tm install-claude-hook   # 一次性設定，啟用 Claude session 追蹤與 agent 狀態
tm save                  # 備份所有 session
tm restore               # 從快照還原（已存在的 session 會跳過）
tm restore --claude      # 還原 session 並自動啟動 Claude Code
tm restore --codex       # 還原 session 並續接 Codex
tm restore --claude --codex  # 同時還原兩種 agent
tm snapshots             # 預覽最新快照
tm snapshots --list      # 列出快照歷史（新到舊）
tm snapshots 20261012T033000Z         # 預覽指定的歷史快照
tm restore --from 20261012T033000Z    # 從指定的歷史快照還原
tm screens                            # 列出有擷取畫面的 session
tm screens myapp                      # 顯示 myapp 上次備份時的畫面
tm screens myapp --from 20261012T033000Z  # 顯示指定歷史快照的畫面
tm screens myapp --pane 0.1           # 只看 window 0 的 pane 1
tm screens myapp | less -R            # 分頁查看；輸入 /═══ 後按 n 在 pane 間跳轉
```

Codex ID 會直接從執行中的 pane 偵測。若無法取得精確 ID，還原時會退回 Claude 的 `--continue` 或 Codex 依工作目錄選取的 `--last` 行為。

最新快照儲存於 `<tm-dir>/snapshots/sessions.json`（與 `tm.sh` 同層目錄），每次儲存也會另寫一份帶時間戳的副本到 `snapshots/history/sessions-<YYYYMMDDTHHMMSSZ>.json`（UTC）。`tm save` 保留最新 48 份歷史快照（以 30 分鐘間隔約為一天），更舊的會自動刪除；可用 `TM_SNAPSHOT_KEEP` 調整份數。`--from` 可接時間戳、歷史檔名或檔案路徑。

每次儲存也會擷取每個 pane 的可見畫面（保留 ANSI 顏色，使用 `tmux capture-pane -e`），存到 `snapshots/history/screens-<stamp>/<session>/<window>.<pane>.ans`，每個 pane 一個檔案。`tm screens` 依快照 JSON 列出各 session 的 pane，並在每個 pane 前加上一行標題，即可看到當時各 session 的最後畫面；畫面會和對應快照一起清除。由於 pane 輸出可能含敏感資訊，畫面目錄權限為僅擁有者可讀（`700`）。備份資料存在專案目錄內，不會覆蓋使用者既有的備份。

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
│   └── history/                       # 帶時間戳的快照（保留最新 48 份）
│       ├── sessions-<stamp>.json      # Session 結構
│       └── screens-<stamp>/           # Pane 畫面：<session>/<window>.<pane>.ans
└── ~/.tmux-manager/                   # 執行時資料（自動建立）
    ├── protected.txt                  # 受保護的 session 名單
    ├── last_session                   # 上一個 session 記錄
    ├── claude_sessions.jsonl          # tmux pane 與 Claude session ID 紀錄
    ├── templates/                     # Session 模板目錄
    │   └── dev                        # 預設 dev 模板（editor/server/logs）
    └── summaries/                     # AI 摘要歷史（JSONL）
        └── <session_name>.jsonl       # 每行一筆摘要記錄
```

</details>

---

## License

[MIT](LICENSE)
