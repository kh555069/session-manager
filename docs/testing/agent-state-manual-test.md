# Agent 狀態功能手動測試

對應設計：`docs/design/agent-state-and-orchestration.md` 第 1 節（PR 1 狀態檔）。

自動化測試涵蓋了大部分行為；本文件補上必須用真實 Claude session 才能確認的部分，特別是等待權限（`❓`）與閒置提醒。

所有指令都在 repo 根目錄（或 worktree 根目錄）執行，以下以 `./tm.sh` 表示目前這份程式。

## 0. 自動化測試

```bash
bash tests/run.sh
```

預期：每個測試檔都顯示 `all passed`，結束碼為 0。測試使用獨立的 HOME 與 tmux socket，不會動到真實環境。

## 1. 安裝 hook

```bash
./tm.sh install-claude-hook
```

- 預期：列出新增的 8 個項目（`_record-claude-session` 加上 7 個 `hook-state` 事件），最後印出備份路徑 `~/.claude/settings.json.tm-backup-<時間>`。**記下這個路徑**，第 9 步還原時要用。
- 再執行一次：應顯示 `Claude hooks are already installed`，且不會多產生備份。
- hook 只在 Claude session 啟動時載入；已經在跑的 Claude 要重新啟動才會生效。

## 2. 準備觀察環境

1. 開一個測試 session：`tmux new-session -d -s state-test -c <任一專案目錄>`
2. 另開一個終端機執行 `./tm.sh` 叫出選單；按 `Ctrl-R` 重新整理列表。
3. 回到 `state-test`，執行 `claude` 啟動一個新的 Claude。

## 3. 基本狀態循環

| 步驟 | 操作 | 列表 `ST` 欄預期 |
|------|------|------------------|
| 3-1 | Claude 剛啟動 | `💤` |
| 3-2 | 送出會跑一陣子的 prompt，例如「執行 `sleep 20` 後告訴我結果」 | `⏳` |
| 3-3 | 這一輪結束 | `💤` |
| 3-4 | 等 1～2 分鐘，不送任何東西 | 仍為 `💤`，**不會**變成 `❓`（閒置提醒不算 blocked） |

## 4. 等待權限

| 步驟 | 操作 | 預期 |
|------|------|------|
| 4-1 | 請 Claude 做一件需要核准的事，例如「用 Bash 執行 `touch /tmp/tm-test`」，先**不要**回答權限畫面 | 列表顯示 `❓`，`state-test` 排到最上面 |
| 4-2 | 在選單中移到 `state-test` 看 preview | 出現 `── Agents ──` 區塊，有一行 `blocked (permission)`，下一行是通知文字（例如 `Claude needs your permission to use Bash`） |
| 4-3 | 核准權限 | 工具執行時回到 `⏳`，做完變 `💤` |
| 4-4 | 再請它做一次需要核准的事，這次**拒絕**或按 Esc | `❓` 會留到下一個 prompt（已知限制：Claude 沒有可偵測拒絕或中斷的 hook） |

## 5. 排序與逾時

| 測試 | 指令 | 預期 |
|------|------|------|
| 關閉 blocked 置頂 | 在 4-1 的狀態下執行 `TM_SORT=recent ./tm.sh` | `state-test` 回到最近使用排序，圖示仍為 `❓` |
| working 逾時 | 送一個很長的工作（例如 `sleep 120`），執行期間開 `TM_STALE_AFTER=30 ./tm.sh` | 超過 30 秒沒有 hook 更新後顯示 `⏳?` |

## 6. 多個 agent 的彙總

1. `tmux split-window -t state-test`，在新 pane 再啟動一個 `claude`。
2. 第一個 pane 停在 `💤`，第二個停在權限畫面。

預期：

- 列表顯示 `❓`（優先序 blocked > working > idle）。
- preview 的 Agents 區塊列出兩行（`0.0` 與 `0.1`）。

## 7. 結束與清理

| 步驟 | 操作 | 預期 |
|------|------|------|
| 7-1 | 在 Claude 中輸入 `/exit` | 該 pane 變成 `·`，preview 不再列出它 |
| 7-2 | 關掉一個有狀態檔的 pane，再執行 `./tm.sh save` | 輸出多一行 `Removed N orphan state file(s)` |
| 7-3 | `ls -la ~/.tmux-manager/state/` | 目錄為 `drwx------`、檔案為 `-rw-------`，只剩仍存在的 pane 的檔案 |

## 8. 收掉測試 session

在 `state-test` 中 `exit` 掉所有 pane，或手動執行 `tmux kill-session -t state-test`。

## 9. 還原

不想保留 hook 時，用第 1 步的備份蓋回：

```bash
cp ~/.claude/settings.json.tm-backup-<時間> ~/.claude/settings.json
```

hook 指向安裝當下 `tm.sh` 的絕對路徑。如果是在 worktree 安裝，移除 worktree 後 hook 會找不到檔案；屆時在新位置重跑 `install-claude-hook`，並刪掉 `settings.json` 中指向舊路徑的 hook（安裝器目前只比對指令結尾，不會自動替換舊路徑）。

## 回報內容

- 4-1 的 preview 畫面，或 `cat ~/.tmux-manager/state/*.json` 的輸出，確認 `reason` 為 `permission`。
- 3-4 是否維持 `💤`。
- fzf 畫面中圖示對齊異常的截圖（emoji 寬度問題只在實際畫面看得到）。

## 已驗證紀錄

| 日期 | 環境 | 範圍 | 結果 |
|------|------|------|------|
| 2026-10-21 | macOS、Claude Code 2.1.306、隔離的 HOME 與 tmux socket、`claude -p` | 安裝 7 個事件；SessionStart → UserPromptSubmit → PreToolUse → PostToolUse → Stop → SessionEnd；列表 `·` → `💤` → `⏳` → `💤` → `·`；`tm save` | 通過 |
| — | 互動式 Claude | 第 3-4、4、6 步（`❓`、閒置提醒、多 agent） | 待驗證 |
