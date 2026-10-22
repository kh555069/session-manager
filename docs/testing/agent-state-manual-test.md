# Agent 狀態功能手動測試

對應設計：`docs/design/agent-state-and-orchestration.md`，涵蓋第 1 至 4 節（PR 1 狀態檔、PR 2 `tm ls --json`、PR 3 `tm wait`、PR 4 `tm dash`、`tm state-count`、推播通知）。

自動化測試涵蓋了大部分行為；本文件補上必須用真實 Claude session 才能確認的部分：等待權限（`❓`）、閒置提醒、subagent、信任資料夾對話框、`kill -9`，以及 fzf 與 tmux 的實際畫面。

所有指令都在 repo 根目錄執行，以下以 `./tm.sh` 表示目前這份程式。需要絕對路徑的地方（tmux 綁定、狀態列）用 `$PWD/tm.sh`。

第 1～9 步驗證 PR 1，第 10～16 步驗證 PR 2～4 與設計文件的待確認問題。第 10 步以後都沿用第 2 步的 `state-test` session，所以第 8、9 步的收尾留到全部做完再執行。

## 0. 自動化測試

```bash
bash tests/run.sh
```

- 預期：每個測試檔都顯示 `all passed`，結束碼為 0。測試使用獨立的 HOME 與 tmux socket，不會動到真實環境。
- 在 worktree 執行時，worktree 裡沒有 fzf（gitignored），要先連結主 repo 的版本：`ln -s <主 repo>/fzf fzf`。

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
| 4-2 | 在選單中移到 `state-test` 看 preview | 出現 `── Agents ──` 區塊，有一行 `blocked (permission)`，下一行是通知文字（例如 `Claude needs your permission to use Bash`），再下面是該 pane 最後 15 行畫面，看得到權限選項 |
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

做完後在 `state-test` 的 pane `0.0` 重新執行 `claude`，給第 10 步以後使用。

## 8. 收掉測試 session

全部步驟做完後，在 `state-test` 中 `exit` 掉所有 pane，或手動執行 `tmux kill-session -t state-test`。

## 9. 還原

不想保留 hook 時，用第 1 步的備份蓋回：

```bash
cp ~/.claude/settings.json.tm-backup-<時間> ~/.claude/settings.json
```

hook 指向安裝當下 `tm.sh` 的絕對路徑。如果是在 worktree 安裝，移除 worktree 後 hook 會找不到檔案；屆時在新位置重跑 `install-claude-hook`，並刪掉 `settings.json` 中指向舊路徑的 hook（安裝器目前只比對指令結尾，不會自動替換舊路徑）。

## 10. Subagent 會不會蓋掉主 agent 的狀態

這是設計文件的待確認問題。`tm wait` 與推播都依賴狀態轉換，subagent 若提早寫入 `idle`，Leader 會在工作還沒完成時就以為完成。

| 步驟 | 操作 | 預期 |
|------|------|------|
| 10-1 | 請 Claude「用 Task tool 開一個 subagent，讓它執行 `sleep 30` 再回報」 | 列表顯示 `⏳` |
| 10-2 | subagent 執行期間，每隔幾秒執行 `cat ~/.tmux-manager/state/<pane>.json`（`<pane>` 是 `tmux display -p -t state-test:0.0 '#{pane_id}'` 去掉 `%`） | `state` 一直是 `working`；記下 `event` 欄出現過哪些事件 |
| 10-3 | subagent 結束、主 agent 還在整理結果時 | 仍為 `⏳`，**不會**先變成 `💤` |
| 10-4 | 主 agent 這一輪結束 | `💤` |

若 10-3 提早變成 `💤`，記下當時的 `event`，這代表需要依 `session_id` 區分或忽略 subagent 的事件。

## 11. 信任資料夾對話框

確認「hook 執行前出現的對話框，狀態會是 `unknown`」（README 的 Leader 範例依賴這一點）。

| 步驟 | 操作 | 預期 |
|------|------|------|
| 11-1 | 建一個 Claude 從沒信任過的目錄，例如 `mkdir ~/tm-trust-test`，在新 session 裡啟動：`tmux new-session -d -s trust-test -c ~/tm-trust-test` 後，在該 session 執行 `claude`，停在信任對話框不要回答 | — |
| 11-2 | `./tm.sh ls --json --session trust-test \| jq '.sessions[0].agents'` | 一個 agent，`source` 為 `heuristic`、`state` 為 `unknown` |
| 11-3 | `./tm.sh wait trust-test --until done --timeout 20s; echo "exit=$?"` | 約 20 秒後 `exit=1`（逾時），stdout 印出 `unknown` 的 agent |
| 11-4 | 回答信任對話框 | `ls --json` 變成 `source: hook`、`state: idle` |

若 11-2 顯示 `idle`，代表 hook 在對話框前就執行了，README 的 Leader 範例與「啟動逾時視為需要人看一下」的說明都要修正。做完後收掉 `trust-test`，並自行刪除 `~/tm-trust-test`。

## 12. `tm ls --json`

| 步驟 | 操作 | 預期 |
|------|------|------|
| 12-1 | `./tm.sh ls --json \| jq '.sessions[] \| {name, state, agents: [.agents[] \| {target, agent, pid, state, source}]}'` | `state-test` 的 agent 有 `pid`、`source: hook`，狀態與 fzf 列表一致 |
| 12-2 | `./tm.sh ls --json --state blocked` 在 4-1 的狀態下執行 | 只列出 `state-test` |
| 12-3 | `./tm.sh ls --json --session nope; echo "exit=$?"` | stdout 為空，`exit=2` |
| 12-4 | 取得 12-1 的 `pid`，在 Claude 停在 `💤` 時執行 `kill -9 <pid>`（只對 `state-test` 的 Claude） | `ls --json` 的該 agent 變成 `pid: null`、`state: unknown`；fzf 列表仍顯示 `💤`（已知差異：fzf 不檢查行程） |
| 12-5 | 在同一個 pane 重新執行 `claude` | 在 SessionStart 寫入前不會顯示舊的 `idle`；啟動完成後為 `idle`、`source: hook` |

## 13. `tm wait`

在第二個終端機執行 `tm wait`，在 `state-test` 操作 Claude。`<pane>` 是 `state-test:0.0`。

| 步驟 | 操作 | 預期 |
|------|------|------|
| 13-1 | 先執行 `./tm.sh wait state-test:0.0 --until done --after-change --timeout 5m`，再到 Claude 送出「執行 `sleep 10` 後告訴我結果」 | 送出前不會立即返回；這一輪結束時返回 `exit=0`，stdout 一行 `state: idle` 的 JSON |
| 13-2 | 同上，但 prompt 改成需要權限的事（例如 4-1） | 出現權限畫面時返回，`state: blocked`、`reason: permission`，`message` 為權限訊息 |
| 13-3 | 不加 `--after-change`，在 Claude 已是 `💤` 時執行 `--until idle` | 立即返回 |
| 13-4 | 執行 `--until done --timeout 2m` 期間，對該 Claude `kill -9` | 數秒內返回，`exit=2`，stdout 的 `state` 為 `dead` |
| 13-5 | 執行 `--until done` 期間按 Ctrl-C | `exit=130`；`pgrep -fl inotifywait` 沒有殘留（macOS 沒有 inotifywait，這項只在 Linux 有意義） |

## 14. `tm dash`

先加一個只在本次 tmux server 生效的綁定（不寫進 `~/.tmux.conf`）：

```bash
tmux bind D display-popup -w 90% -h 85% -E "$PWD/tm.sh dash --popup"
```

| 步驟 | 操作 | 預期 |
|------|------|------|
| 14-1 | 按 `prefix D` 開 popup | 出現 `tm dash` 的列表 |
| 14-2 | 不碰鍵盤，讓 `state-test` 的 Claude 進入權限畫面 | 2 秒內列表自動更新成 `❓`，不用按 `Ctrl-R` |
| 14-3 | 游標停在另一個 session 時讓 `state-test` 變成 blocked（它會排到最上面） | 游標仍停在原本的 session |
| 14-4 | 輸入搜尋字串，同時讓其他 session 狀態改變 | 游標不會跳走 |
| 14-5 | 按 Tab 選取一個 session，等 5 秒 | 選取標記還在 |
| 14-6 | 按 `Ctrl-E` 進入改名提示，再按 Ctrl-C | 只取消提示，回到 dash 列表 |
| 14-7 | 選一個 session 按 Enter | 切換到該 session，popup 關閉 |
| 14-8 | 再開 popup 後按 Esc，接著執行 `ls ~/.tmux-manager/run/` 與 `pgrep -fl _dash-watch` | `run/` 是空的，沒有殘留的監看迴圈 |
| 14-9 | 不加 `--popup`：`tmux new-window -n dash "$PWD/tm.sh dash"`，按 Enter 切換到別的 session，再切回 `dash` window | dash 仍在執行 |

做完後執行 `tmux unbind D`，並關掉 14-9 的 `dash` window。

## 15. `tm state-count`

| 步驟 | 操作 | 預期 |
|------|------|------|
| 15-1 | `./tm.sh state-count --format plain` | 例如 `💤1`；數量為 0 的項目不出現 |
| 15-2 | 先記下目前的設定：`tmux show -gv status-right`，再執行 `tmux set -g status-right "#($PWD/tm.sh state-count) \| %H:%M"` | 狀態列出現計數；Claude 進入權限畫面後，5 秒內（依 `status-interval`）出現紅色 `❓1` |
| 15-3 | 用空的 socket 目錄模擬沒有 tmux server：`env -u TMUX TMUX_TMPDIR=$(mktemp -d) ./tm.sh state-count; echo "exit=$?"`（`-u TMUX` 是必要的，否則會連到目前的 server） | 沒有輸出，`exit=0` |

做完後用 15-2 記下的值還原：`tmux set -g status-right '<原本的值>'`。

## 16. 推播通知

`TM_NOTIFY_CMD` 從 Claude 執行時的環境讀取，所以要在啟動 Claude 的那一行設定。先用寫檔的指令測試，確認後再接 Telegram。

1. 結束 `state-test` 的 Claude，改用以下指令重新啟動：

   ```bash
   TM_NOTIFY_CMD='cat >> /tmp/tm-notify.jsonl' claude
   ```

| 步驟 | 操作 | 預期 |
|------|------|------|
| 16-1 | 觸發權限畫面（同 4-1） | `/tmp/tm-notify.jsonl` 多一行 JSON：`state: blocked`、`tmux_session: state-test`、`target: state-test:0.0`、`host` 為本機名稱 |
| 16-2 | 核准後 1 分鐘內再觸發一次權限畫面 | 不會多一行（每個 pane 每分鐘最多一次） |
| 16-3 | 等超過 1 分鐘再觸發 | 多一行 |
| 16-4 | 一輪結束（變 `💤`） | 預設不通知 |
| 16-5 | 改用 `TM_NOTIFY_ON=blocked,idle TM_NOTIFY_CMD='cat >> /tmp/tm-notify.jsonl' claude` 重啟，送一個簡單 prompt | 這一輪結束時多一行 `state: idle`；剛啟動時（SessionStart）不會通知 |
| 16-6 | 改用 `TM_NOTIFY_CMD='sleep 30' claude` 重啟並觸發權限畫面 | Claude 不會變慢；約 5 秒後 `~/.tmux-manager/notify.log` 多一行 `timeout`，`pgrep -f 'sleep 30'` 沒有殘留 |
| 16-7 | `ls -la ~/.tmux-manager/notify.log` | 權限為 `-rw-------`，內容只有時間、pane、狀態與結果，沒有訊息文字 |
| 16-8 | （選用）接 Telegram：照 README 的範例設定 `TM_NOTIFY_CMD`，觸發權限畫面 | 手機收到 `<host>/state-test blocked: <訊息>` |

`message` 可能含指令內容或路徑，16-8 送到外部服務前請確認可接受。做完後自行刪除 `/tmp/tm-notify.jsonl`。

## 回報內容

- 4-1 的 preview 畫面，或 `cat ~/.tmux-manager/state/*.json` 的輸出，確認 `reason` 為 `permission`。
- 3-4 是否維持 `💤`。
- 10-2 看到的 `event` 列表，以及 10-3 是否提早變成 `💤`。
- 11-2 的 `ls --json` 輸出。
- 13-1、13-2 的 `tm wait` 輸出。
- 16-1 的通知 JSON（可遮掉 `message`）。
- fzf 畫面中圖示對齊異常的截圖（emoji 寬度問題只在實際畫面看得到）。

## 已驗證紀錄

| 日期 | 環境 | 範圍 | 結果 |
|------|------|------|------|
| 2026-10-21 | macOS、Claude Code 2.1.306、隔離的 HOME 與 tmux socket、`claude -p` | 安裝 7 個事件；SessionStart → UserPromptSubmit → PreToolUse → PostToolUse → Stop → SessionEnd；列表 `·` → `💤` → `⏳` → `💤` → `·`；`tm save` | 通過 |
| 2026-10-22 | macOS、隔離的 HOME 與 tmux socket、假的 claude/codex 行程 | PR 2～4 的自動化測試（107 個）；`tm dash` 的 Enter、`--popup`、Esc 與 SIGTERM 清理（手動在隔離 tmux 確認） | 通過 |
| — | 互動式 Claude | 第 3-4、4、6 步（`❓`、閒置提醒、多 agent） | 待驗證 |
| — | 互動式 Claude | 第 10 步 subagent、第 11 步信任資料夾 | 待驗證 |
| — | 互動式 Claude 與真實 tmux | 第 12～16 步（`ls --json`、`tm wait`、`tm dash`、`state-count`、推播） | 待驗證 |
