# tm.sh agent 狀態與編排原語設計草案

Oct 20, 2026 · @Yuan

## 背景與目標

tm.sh 補上三項能力，讓 Leader Agent 可以用 CLI 管理 Worker，不必再靠人盯 fzf 畫面：agent 狀態偵測、`tm ls --json`、`tm wait`。三者是依序相依的：狀態檔是資料來源，`ls --json` 是讀取介面，`wait` 是建立在狀態檔上的阻塞原語。

設計原則：

- **維持單一入口**：所有功能都是 `tm.sh` 的子指令，使用者不需要學新工具。
- **零侵入**：session 仍是一般的 tmux session，不裝 hook 時一切照舊，狀態欄顯示 `unknown`。
- **狀態來自事件，不靠猜測**：以 Claude Code hooks 主動回報為主，`capture-pane` 比對只當 fallback。
- **機器介面優先穩定**：JSON 輸出帶 schema 版本，exit code 有明確語意。

非目標：多主機整合、socket API、取代 tmux。這些等三項穩定後再評估。

## 1. Agent 狀態偵測

每個 agent pane 對應一個狀態檔，由 Claude Code hooks 在事件發生時寫入。tm.sh 只讀檔，不輪詢畫面。

### 狀態定義

| 狀態 | 意義 | 寫入時機 |
| --- | --- | --- |
| `working` | agent 正在處理一輪請求 | `UserPromptSubmit`、`PreToolUse`、`PostToolUse` |
| `blocked` | 等待人類回應（權限確認或輸入） | `Notification` |
| `idle` | 一輪結束，等待下一個 prompt | `Stop`、`SessionStart` |
| `dead` | agent 已結束或 pane 不存在 | `SessionEnd`，或讀取時發現 pane 消失 |
| `unknown` | pane 裡沒有已知 agent，或沒裝 hook | 讀取端推得，不寫檔 |

&#91;embedded content: agent 狀態轉移 · 4 個狀態\]

圖中只畫會寫入狀態檔的 4 個狀態；`unknown` 是讀取端在沒有狀態檔時推得的，不參與轉移，所以不在圖中。正常循環是 idle 與 working 之間來回；只有 blocked 需要人或 Leader 介入，任一狀態都可能因 SessionEnd 進入 dead。

`PreToolUse` 在權限確認**之前**觸發，所以使用者核准後真正把 `blocked` 拉回 `working` 的是 `PostToolUse`；只靠 `PreToolUse` 的話，核准後整段工具執行期間都會停在 `blocked`。使用者拒絕或按 Esc 中斷時沒有 `PostToolUse`，也沒有 `Stop`；讀取端改由 transcript 判斷中斷（見下方待確認問題的實測紀錄）。這兩個 hook 觸發頻繁，寫入必須夠輕（見下方效能限制）。

`Notification` 只有權限確認（`permission_prompt`）與要求輸入（`elicitation_dialog`、`elicitation_url_dialog`）寫 `blocked`。`idle_prompt` 是每次 `Stop` 約 60 秒後的閒置提醒，這時一輪已經結束、狀態已是 `idle`，不寫檔；否則每個做完的 session 都會在一分鐘後變成 `blocked` 並置頂。

### 狀態檔格式

路徑：`~/.tmux-manager/state/<pane>.json`，`<pane>` 為去掉 `%` 的 `$TMUX_PANE`（例如 `%12` → `12.json`）。

```json
{
  "v": 1,
  "pane": "%12",
  "agent": "claude",
  "session_id": "8f3c…",
  "state": "blocked",
  "reason": "permission",
  "message": "Claude needs your permission to use Bash",
  "event": "Notification",
  "cwd": "/home/yuan/project/web-app",
  "ts": "2026-10-20T09:50:12Z",
  "since": "2026-10-20T09:50:12Z"
}
```

- `ts` 是最後一次寫入時間；`since` 是進入目前狀態的時間，狀態不變時保留舊值。`tm wait` 和 idle 時間顯示都依賴 `since`。
- `reason` 只在 `blocked` 時有值：`permission` 或 `input`。
- `tmux_session` 不寫入檔案，讀取時由 `tmux list-panes` 依 pane id 對回，避免 rename 後資料過時。
- 寫入採用 tmp 檔加 `mv`，確保讀取端不會讀到半個 JSON。

### Hook 安裝

擴充既有的 `tm install-claude-hook`，沿用它的備份與合併邏輯，加入以下項目：

```json
"hooks": {
  "SessionStart":     [{ "hooks": [{ "type": "command", "command": "tm hook-state idle" }] }],
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "tm hook-state working" }] }],
  "PreToolUse":       [{ "hooks": [{ "type": "command", "command": "tm hook-state working" }] }],
  "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "tm hook-state working" }] }],
  "Notification":     [{ "hooks": [{ "type": "command", "command": "tm hook-state blocked" }] }],
  "Stop":             [{ "hooks": [{ "type": "command", "command": "tm hook-state idle" }] }],
  "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "tm hook-state dead" }] }]
}
```

`tm hook-state <state>` 從 stdin 讀取 hook 的 JSON，取 `session_id`、`cwd`、`hook_event_name`，Notification 另取 `message`，再合併成狀態檔。既有 SessionStart hook 的 pane 對 session ID 紀錄可以併入同一個子指令。

### 效能限制

- Hook 是同步執行的，每次寫入目標小於 50 ms；`PreToolUse` 在密集工具呼叫時每秒可能觸發多次。
- 狀態未變時只更新 `ts`，不重算其他欄位。若仍太慢，`PreToolUse` 可改為狀態已是 `working` 時直接 return。
- 不在 hook 內呼叫 `tmux` 指令，只讀環境變數 `$TMUX_PANE`。

### 讀取端與顯示

- fzf 列表新增一欄 `ST`：`⏳` working、`❓` blocked、`💤` idle、`·` unknown。一個 session 有多個 agent 時，取最需要注意的狀態（blocked > working > idle）。
- 預設排序把 `blocked` 置頂，可用 `TM_SORT=recent` 改回原本的最近使用排序。
- Preview 面板顯示每個 agent pane 的狀態、`since` 經過時間與 Notification message。
- `dead` 判定：狀態檔存在但 pane 已不在 `tmux list-panes -a` 中。清理交給 `tm save`，順手刪除孤兒狀態檔。
- `working` 超過 `TM_STALE_AFTER`（預設 30 分鐘）沒有任何寫入，顯示為 `working?`，提示可能卡住或 hook 失效。

### Codex 與無 hook 的 agent

Codex 可在 `~/.codex/config.toml` 設定 `notify`，於一輪完成時呼叫 `tm hook-state idle`；`working` 與 `blocked` 沒有對應事件，先用 `capture-pane` 比對提示字串作為 fallback，並在 JSON 中標記 `"source": "heuristic"`。

## 2. tm ls --json

`tm ls --json` 輸出單一 JSON 物件，涵蓋所有 session 與其中的 agent pane。這是 Leader Agent 讀取全局狀態的唯一入口，現有的純文字 `tm ls` 維持不變。

### 輸出 schema

```json
{
  "v": 1,
  "host": "vm-crawler-01",
  "generated_at": "2026-10-20T09:51:00Z",
  "sessions": [
    {
      "name": "web-app",
      "dir": "/home/yuan/project/web-app",
      "git_branch": "feat/new-dashboard",
      "windows": 2,
      "panes": 2,
      "clients": 1,
      "last_activity": "2026-10-20T09:48:00Z",
      "protected": false,
      "summary": "Next.js dashboard dev with hot reload",
      "state": "blocked",
      "agents": [
        {
          "pane": "%12",
          "target": "web-app:1.0",
          "agent": "claude",
          "pid": 1315,
          "session_id": "8f3c…",
          "state": "blocked",
          "since": "2026-10-20T09:50:12Z",
          "reason": "permission",
          "message": "Claude needs your permission to use Bash",
          "source": "hook"
        }
      ]
    }
  ]
}
```

- Session 層的 `state` 是彙總值，規則與 fzf 欄位相同：blocked > working > idle > unknown。
- `target` 是可直接餵給 `tmux send-keys -t` 的位址，Leader 不必自己組。
- 時間一律 UTC ISO 8601；沒有值的欄位輸出 `null`，不省略 key。
- `source` 為 `hook` 或 `heuristic`，讓呼叫端判斷狀態可信度。

### 參數

| 參數 | 作用 |
| --- | --- |
| `--json` | 輸出 JSON |
| `--state <s>[,<s>]` | 只留下含指定狀態 agent 的 session，例如 `--state blocked` |
| `--agent <name>` | 只留下指定 agent 類型，例如 `claude`、`codex` |
| `--session <name>` | 只輸出單一 session，找不到時 exit 2 |
| `--no-summary` | 不讀摘要檔，加快輸出 |

### 介面約定

- stdout 只放 JSON，警告與錯誤一律寫 stderr，確保 `tm ls --json | jq` 永遠可用。
- Exit code：0 成功（包含結果為空）、2 指定的 session 不存在、3 參數錯誤、4 tmux server 未啟動。
- `v` 只在破壞相容時遞增；新增欄位不升版，呼叫端應忽略不認得的 key。

### 實作方式

1. 一次 `tmux list-panes -a -F` 取得所有 pane，欄位用 `\t` 分隔，避免目錄名稱含空白時解析錯誤。
2. 一次 `ps -eo pid,ppid,comm` 建立行程樹，判斷每個 pane 底下是否有 `claude` 或 `codex`，沿用現有行程樹的邏輯。
3. 讀取所有狀態檔、保護清單與最新摘要。
4. 交給 python3 合併並序列化成 JSON；python3 已是 `tm save` 的依賴，不新增需求。

整個流程只呼叫 tmux 和 ps 各一次，目標在 30 個 session 時小於 200 ms。

### PR 2 決定

- **過期的 working**：`state` 仍為 `working`，另加 `stale: true`。狀態維持四個值，`stale` 是新增欄位，不升版。
- **哪些 pane 列入 `agents`**：有效狀態檔（非 `dead`）或行程樹偵測到 agent，兩者有一即列入。只有行程偵測時 `source` 為 `heuristic`、`state` 為 `unknown`；本 PR 不做畫面比對。
- **Hook 狀態需要行程佐證**：狀態檔只在行程樹找得到 agent 時採信，否則該 agent 的 `state` 為 `unknown`（`kill -9` 不會觸發 `SessionEnd`，舊的 `idle` 會讓 Leader 把 prompt 送進 shell）。`dead` 紀錄一律忽略，同一 pane 後來啟動的 agent 以 `heuristic` 呈現。
- **行程偵測**：從 `pane_pid` 走行程樹，args 前兩個 token 的 basename 等於 `claude` 或 `codex` 即為 agent。`vim claude.md` 不會誤判。
- **篩選語意**：`--agent` 先移除其他 agent，session `state` 依剩下的 agent 重算；`--state` 套在其後，session 有任一 agent 符合就保留整個 session。`--session` 找不到時，不論其他篩選都 exit 2。篩選參數沒有搭配 `--json` 時 exit 3。
- **`session_id`** 只取狀態檔的值；Codex 要用 `lsof` 查，會超出效能目標，先輸出 `null`。
- **`git_branch`** 直接讀 `.git/HEAD`（支援 worktree 的 `gitdir:` 檔），不呼叫 `git`；detached 時為 `null`。
- **共用規則**：狀態檔的判斷抽成 `_PY_STATE_LIB`，fzf 畫面與 JSON 共用。
- **效能**：30 個 session、每個都有狀態檔時，平均 139 ms（macOS，10 次平均）。

## 3. tm wait

`tm wait` 阻塞到指定 agent 達成某個狀態才返回，讓 Leader 能寫出「派工、等完成、收結果」的同步流程，不必自己寫輪詢迴圈。

### 語法

```
tm wait <target> --until <cond> [--timeout 30m] [--interval 2] [--match any|all] [--after-change]
```

- `<target>`：session 名稱、pane id（`%12`）或 tmux 位址（`web-app:1.0`）；`--all` 表示所有 agent pane。
- `--until`：`idle`、`blocked`、`done`（= idle 或 blocked，即「不再 working」）、`dead`。
- `--match`：target 含多個 agent 時，`any` 為任一達成即返回（預設），`all` 為全部達成。
- `--timeout`：接受 `90s`、`30m`、`2h`，預設不逾時。
- `--interval`：輪詢秒數，預設 2。

### Exit code

| Code | 意義 |
| --- | --- |
| 0 | 條件達成 |
| 1 | 逾時 |
| 2 | target 不存在，或在等待期間變成 `dead`（`--until dead` 除外） |
| 3 | 參數錯誤 |

返回時 stdout 印出達成條件的 agent 狀態，格式與 `tm ls --json` 的 `agents[]` 元素相同，一行一個 JSON 物件。Leader 可以直接讀 `reason` 與 `message`，判斷是要核准權限還是要補充輸入。

### 競態：呼叫時狀態已經符合

預設行為是條件已符合就立即返回。這在「剛送出 prompt 就呼叫 wait」時會出錯：hook 還沒寫入 `working`，狀態仍是上一輪的 `idle`，wait 會立刻誤判完成。

`--after-change` 解決這個問題：記下呼叫當下的 `since`，只接受 `since` 比它新的狀態。建議 Leader 送出 prompt 後一律加上這個參數。

### Leader 使用範例

範例以 Leader Agent 的派工流程為準（`~/project/catalog-manager` 的 `/dispatch`）：啟動指令由 `worker-session.sh plan` 產生，任務文字一律經 `agent-prompt.sh` 從 stdin 送出，不直接用 `tmux send-keys` 或 `paste-buffer` 注入。`tm wait` 只負責等待，`blocked` 時停下交給使用者，Leader 不代為回答。

```bash
scripts=~/project/catalog-manager/scripts

# 派工前：session 已存在時，確認裡面沒有既有 Worker
# （guard 對不存在的 session 回 3，所以先判斷 session 是否存在）
if tmux has-session -t api-server 2>/dev/null; then
  guard=$(bash "$scripts/agent-instance-guard.sh" api-server); guard_exit=$?
  eval "$guard"   # sets COUNT, PANE, INFO, AGENT
  [ "$guard_exit" -eq 0 ] && [ "$COUNT" -eq 0 ] || exit 1   # 已有 Worker 時改走既有流程或一次性 pane
else
  tm new api-server ~/project/api-server
fi

# 啟動 Worker：指令只能來自 planner，不自行組裝
plan=$(bash "$scripts/worker-session.sh" plan api-server claude-code ~/project/api-server true) || exit 1
eval "$plan"    # sets MODE, SESSION_ID, REASON, CMD
tmux send-keys -t api-server "$CMD" Enter

# 重新跑 guard 取得 Worker 所在 pane，再等它啟動完成
eval "$(bash "$scripts/agent-instance-guard.sh" api-server)"
start=$(tm wait "api-server:$PANE" --until done --timeout 60s)
case $? in
  0) [ "$(jq -r .state <<<"$start")" = blocked ] && { echo "Worker 在等使用者回應，請 attach"; exit 1; } ;;
  1) echo "Worker 沒有回報 idle：可能停在啟動對話框（例如信任資料夾），請 attach"; exit 1 ;;
  *) echo "Worker 沒有啟動或已結束"; exit 1 ;;
esac

# 送出任務：stdin 傳入，避免引號被 shell 解讀
result=$(printf '%s' '實作 /healthz endpoint 並補上測試' \
  | bash "$scripts/agent-prompt.sh" api-server "$PANE")
prompt_exit=$?
eval "$result"  # sets RESULT, REASON, STATE, RULE
case $prompt_exit in
  0) ;;
  12) echo "prompt_stalled：文字可能還在輸入框，不得重送"; exit 1 ;;
  *) echo "未送出：$REASON"; exit 1 ;;
esac

# 等完成或卡住
result=$(tm wait "api-server:$PANE" --until done --after-change --timeout 45m)
case $? in
  0) [ "$(jq -r .state <<<"$result")" = blocked ] \
       && echo "需要使用者處理：$(jq -r .message <<<"$result")" ;;
  1) echo "api-server 逾時，仍在 working" ;;
  2) echo "api-server 已結束" ;;
esac

# 多個 worker：任一完成就先處理
tm wait --all --until done --after-change --match any
```

- 在任何 hook 執行前出現的對話框（例如信任資料夾），狀態會維持 `unknown`，啟動時的等待會以逾時（exit 1）結束，而不是 `blocked`。啟動逾時應視為「需要人看一下」。
- 仍然用 `--until done` 而不是 `idle`：hook 開始執行後，權限確認與要求輸入會以 `blocked` 呈現。
- Codex 不回報 hook 狀態，agent 一律是 `unknown`，永遠不會達成 `done`；Codex Worker 仍以 `agent-state.sh` 判讀。
- `agent-prompt.sh` 回 `12` 時文字可能還留在輸入框，重送會變成兩份任務，必須先交給使用者判斷。
- 本節的 `tm wait` 是 `agent-state.sh wait` 的候選替代，Leader 沒有改用。2026-10-23 決定採混合判讀：Leader 規則仍以 `agent-state.sh` 為唯一來源，由它在 Claude Code pane 讀 `tm ls --json` 的 hook 狀態（catalog-manager `b015ad8`）。畫面判讀為 `unknown` 時採用 hook 狀態（`idle` 另需輸入框為空）；畫面是上一輪的 done 行、hook 是未逾時的 working 且畫面沒有 `Interrupted` 時判為 working；對話框、spinner、`not-running` 一律以畫面為準。不全面改用 `tm wait` 的原因：信任資料夾等啟動對話框在 hook 執行前出現，`tm` 只能回 `unknown`；`do-restart.sh` 要靠 `not-running` 確認 pane 回到 shell；`RULE`／`MATCHED` 的畫面文字會顯示給使用者；中斷（Esc）不送 `Stop`，hook 的 working／blocked 可能殘留。

### 實作方式

- 有 `inotifywait` 時監看 `~/.tmux-manager/state/`，事件驅動、延遲接近零；否則退回 `--interval` 輪詢。兩種模式都每輪檢查 pane 是否仍存在，以偵測 `dead`。
- 純 Bash 即可實作；讀單一欄位時用 python3 one-liner 或 `jq`（有就用），避免每輪啟動完整解析。
- 收到 SIGINT 時乾淨退出並回傳 130，不留下暫存檔。

### PR 3 決定

- **實作**：bash 驗證參數後 `exec` 單一 python3 迴圈，每輪呼叫 tmux、ps 各一次。agent 判斷與 `tm ls --json` 共用 `_PY_SNAPSHOT_LIB`，包括「要有行程才採信 hook 狀態」。python 自行安裝 SIGINT handler（背景 job 會繼承忽略 SIGINT），SIGTERM 回 143，兩者都會先結束 `inotifywait` 子行程。
- **Target**：`%N`、`name:W.P`、`name:W`（整個 window）、session 名稱；`--all` 是所有目前有 agent 的 pane。開始時解析不到、tmux server 未啟動 → exit 2。
- **尚未就緒**：pane 存在但還沒有 agent 時繼續等，不算 dead。
- **Dead**：等待中曾看到有 `pid` 的 agent，之後 pane 消失、agent 不見或 `pid` 變成 `null`（涵蓋 `kill -9`）。輸出最後一次看到的 agent，`state` 改為 `dead`。
- **條件**：`unknown`（含 heuristic）不符合 `idle`、`blocked`、`done`；`stale` 的 working 仍是 working。`--match all` 只計算有 agent 的 pane。
- **`--after-change`**：記下開始時每個 pane 的（`state`, `since`），只採信 `since` 存在且這組值不同的狀態。只比 `since` 會漏掉同一秒內開始又結束的一輪；`since` 只到秒，所以用「不同」而非「較新」比對。
- **舊紀錄**：狀態檔的 `ts` 早於 agent 行程啟動時間（`ps etime`，容許 1 秒誤差）時不採信。同一 pane 先前的 agent 被 `kill -9` 後留下的 `idle`，不會讓新啟動的 agent 被誤判為 done。這條規則在共用 snapshot 裡，`tm ls --json` 同樣適用。
- **逾時**：exit 1，stdout 印出所有 agent 目前的狀態。
- **inotify**：`inotifywait -qq -t <ceil(interval)>` 監看狀態目錄，逾時保證每輪仍檢查 pane；`interval < 1` 或目錄不存在時直接 sleep。

## 4. 狀態總覽與通知

三個出口都只讀第 1 節的狀態檔，不新增資料來源：`tm dash` 給坐在電腦前的人看，`tm state-count` 放在 tmux 狀態列，推播負責離開畫面時的提醒。

| 出口 | 情境 | 更新方式 |
| --- | --- | --- |
| `tm dash` | 常駐總覽，盯多個 agent | 狀態檔變動即 reload |
| `tm state-count` | 工作中順便瞄一眼 | tmux `status-interval` |
| 推播 | 不在電腦前 | 狀態轉為 blocked 時觸發 |

### tm dash：即時總覽

沿用主介面的 fzf 列表與快捷鍵，差別在於會自動更新、不需要手動按 `Ctrl-R`。

- 啟動 fzf 時加上 `--listen`，背景另跑一個監看迴圈：有 `inotifywait` 就監看 `~/.tmux-manager/state/`，事件發生時對 fzf 送出 `reload(tm ls --fzf)`；沒有就每 2 秒送一次。需確認環境的 fzf 版本支援 `--listen`。
- 背景迴圈以 `trap` 綁定 fzf 結束，退出 dash 時一併終止，不留下殭屍程序。
- Reload 保留游標所在的 session，避免列表重排時選取跳走。
- Preview 面板對 `blocked` 的 pane 額外顯示 `capture-pane` 最後 15 行，不用 attach 就能看到它在問什麼。
- 在 popup 裡按 Enter 改用 `tmux switch-client`，在 popup 外才用 `attach`。

建議的 tmux 綁定：

```
bind D display-popup -w 90% -h 85% -E "tm dash --popup"
# 或常駐在專用 window
bind W new-window -n dash "tm dash"
```

### tm state-count：狀態列計數

輸出各狀態的 agent 數量，數量為 0 的項目省略；全部為 0 時輸出空字串，狀態列不留空位。

```
$ tm state-count
❓2 ⏳3 💤5
```

- `--format tmux`（預設）帶 tmux 色碼，blocked 以紅色顯示；`--format plain` 輸出純文字給其他工具使用。
- 只讀狀態檔加一次 `tmux list-panes`，排除已不存在的 pane，目標小於 50 ms（原訂 30 ms，理由見下方「PR 4 決定」）。tmux 以非同步方式執行 `#()`，不會拖慢畫面。

```
set -g status-interval 5
set -g status-right '#(tm state-count) | %H:%M'
```

### 推播通知

`tm hook-state` 偵測到狀態轉換時，呼叫使用者設定的通知指令。tm.sh 本身不綁定任何通知服務。

- `TM_NOTIFY_CMD`：通知指令，從 stdin 收到該 agent 的狀態 JSON（格式同 `tm ls --json` 的 `agents[]` 元素，另加 `host` 與 `tmux_session`）。未設定時不通知。
- `TM_NOTIFY_ON`：要通知的轉換，預設 `blocked`；設為 `blocked,idle` 時，working 轉 idle（一輪完成）也會通知。
- 只在狀態**轉換**時觸發，同一狀態重複寫入不再通知；同一 pane 1 分鐘內最多通知一次，避免權限確認連續出現時洗版。
- 通知指令在背景執行並加 5 秒 timeout，失敗只記 log，絕不拖慢或擋住 hook。

Telegram 範例，可直接接既有的 bot：

```bash
export TM_NOTIFY_CMD='jq -r "\(.host)/\(.tmux_session) \(.state): \(.message // "")" \
  | curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
      --data-urlencode chat_id=$TG_CHAT --data-urlencode text@-'
```

Notification 的 `message` 可能含指令內容或路徑，送到外部服務前要確認可接受；必要時只送 session 名稱與狀態。

### PR 4 決定

- **state-count**：用 fzf 列表的 `_agent_states`（狀態檔加一次 `tmux list-panes`，不跑 ps）；逾時的 working 算進 ⏳，`unknown`、`dead` 不計；任何錯誤都輸出空字串、exit 0，只有 `--format` 不合法時 exit 3。30 個 session 實測 39 ms，未達 30 ms：python3 啟動 18 ms、`import json` 6 ms、bash 解析 tm.sh 10 ms、tmux 7 ms，用 python 無法再降。2026-10-23 重測（42 個 pane、16 個 agent）：整體 36.7 ms，python3 啟動加 `import json` 23.4 ms、bash 解析 tm.sh 約 10 ms、tmux 6.8 ms。決定把目標放寬到 50 ms：tmux 以非同步方式執行 `#()`，預設每 15 秒一次，多出的幾 ms 感覺不到。不採用的做法：在 tm.sh 開頭提早分派 `state-count`（約 27 ms，但要把 `_PY_STATE_LIB`、`_agent_states` 等搬到檔頭，留下隱藏的順序限制，餘裕也很小）；用純 bash 重寫狀態檔判斷（約 15 ms，但判斷規則會出現第二份，與 `ls --json`、dash 分岔）。
- **dash 的控制通道**：fzf `--listen=<Unix socket>`，放在 `~/.tmux-manager/run/`（0700），因為 `reload(...)` 會執行指令，TCP port 任何本機使用者都能連。監看迴圈送出 `transform:tm _dash-reload {2} <dash pid>`，回傳 `reload-sync(cat run/dash-<pid>.list)+pos(n)` 讓游標留在原本的 session：fzf 載入的正是算位置時用的那份列表；有搜尋字串時，位置改用 `fzf --filter` 套同樣的條件計算；列表沒變或有 Tab 選取時不回傳任何 action（不重新載入）；`transform(...)` 的括號寫法會在內層第一個 `)` 截斷，所以用冒號寫法。
- **dash 的結束**：bash 在前景指令執行時會延後處理 trap，所以 fzf 在背景執行、bash 以 `wait` 等待；TERM、HUP 時透過 socket 送 `abort`；SIGINT 只會在 `execute()` 提示中按 Ctrl-C 時出現，與主選單一樣只取消提示，dash 忽略它並繼續等 fzf。所有 `wait` 都容許非 0（`inotifywait` 逾時回 2），否則 `set -e` 會讓 dash 結束。監看迴圈在 dash 行程消失時也會 abort fzf 並結束。fzf 的輸出寫到 `run/dash-<pid>.out`、列表快取寫到 `run/dash-<pid>.list`，結束時與殘留的 socket 一起移除。
- **popup**：tmux 無法可靠判斷程式是否在 popup 內，改用 `tm dash --popup`：Enter 後 switch-client 並結束。
- **preview**：主選單與 dash 共用；blocked pane 顯示去掉結尾空白行後的最後 15 行，並移除控制字元。
- **推播的轉換**：舊狀態存在且不同才算轉換；`idle` 只在舊狀態為 `working` 時通知。頻率限制記在狀態檔新增的 `notified_at`。
- **推播的執行**：hook 寫完狀態檔後以 `start_new_session` 啟動 `tm _notify`，hook 不等待；`_notify` 用一次 `tmux display-message` 補上 `target` 與 `tmux_session`，`pid` 為 `null`。指令在自己的 process group 執行，逾時 5 秒整組終止。只有失敗寫 log（時間、pane、狀態、結果，不含 message）。沒有設定 `TM_NOTIFY_CMD` 時 hook 延遲 36 ms。

### PR 5 決定（延後 Minor 清理）

- **狀態檔健壯性**：`load_state` 攔下 `RecursionError`；`reason`、`message`、`session_id`、`agent` 不是字串時視為 `null`。`tm save` 一併清掉超過 60 秒的 `*.json.*.tmp`。`hook-state` 在 `_init` 之前 route，HOME 無法寫入時仍 exit 0。
- **Agent 偵測**：第 2 個 token 只在第 1 個是直譯器或啟動器（`node`、`bun`、`deno`、`bash`、`sh`、`zsh`、`env`、`npx`、`python*`）時才算，`less claude`、`ssh codex` 不再誤判。
- **`tm ls --json`**：`session_path` 放在 tmux 欄位最後，含 tab 的路徑不會讓 session 消失；`--state` 不做萬用字元展開；`--agent` 只接受 `claude`、`codex`；JSON 輸出（含 `tm wait` 與推播）把 U+0080–U+009F 跳脫成 `\u00XX`。
- **`tm wait`**：`--until dead` 印出等待期間所有結束的 agent；`--timeout` 給了就不能是空值，數字最多 7 位；未預期的例外 exit 5；啟動 `inotifywait` 前後擋住 SIGINT、SIGTERM，子行程在 exec 前解除。
- **fzf 相關**：fzf action 一律使用 `printf %q` 跳脫過的 tm.sh 路徑（路徑含 `)` 仍不支援，fzf 會在第一個 `)` 結束 action）；dash 啟動時清掉 pid 已不存在、或不是 dash 的 `run/dash-<pid>.*`（pid 還在且 socket 有回應就是 dash；沒有 socket 時才看行程參數，`bash tm.sh dash` 等相對路徑也認得）；`state-count` 以 pane id 去重、`--format` 缺值時 exit 3；preview 所有帶外部文字的行改用 `printf %s`，AI 摘要先還原儲存時跳脫的 `\\`。
- **安裝器**：某個字是 `tm.sh` 或 `tm`、而且後面剛好是 suffix 的 hook 才算 tm 的 hook。tm.sh 是第 1 個字、路徑不同時改成目前的路徑並列在 `Updated` 區塊；前面還有東西時（環境變數、`bash tm.sh` 等）視為使用者的包裝，算已安裝但不改寫，也不會再加一份；其他 hook 不動。
- **不修**：`join-pane` 後短暫 `unknown`（tmux 沒有 pane 建立時間可比對）、`_session_agent_state` 的 O(n²)（30 個 session 時不到 1 ms）、「Enter 選取 session」的自動化測試（需要真的 tmux client，手動測試 14-7 涵蓋）。

## 實作順序與待確認問題

依相依順序分四個 PR，每個都能獨立合併、獨立使用。

- [x] **PR 1 狀態檔**：`tm hook-state`、擴充 `install-claude-hook`、fzf 的 `ST` 欄與 blocked 置頂、`tm save` 清理孤兒狀態檔
- [x] **PR 2 機器介面**：`tm ls --json` 與篩選參數、exit code 約定、zsh completion 補上新參數
- [x] **PR 3 等待原語**：`tm wait` 含 `--after-change` 與 inotify 模式，README 補上 Leader 使用範例
- [x] **PR 4 總覽與通知**：`tm dash`、`tm state-count`、`TM_NOTIFY_CMD` 推播，README 補上 tmux 綁定與 Telegram 範例

待確認問題：

- [x] `Notification` 是否能區分權限確認與閒置等待輸入？需對照目前使用的 Claude Code 版本的 hook payload 欄位，決定 `reason` 怎麼填。
  - PR 1 決定：先看 `notification_type`（`permission_prompt` → `permission`；`elicitation_dialog` → `input`；`idle_prompt` 等其他類型不寫檔），沒有此欄位時只有 `message` 含 `permission` 才寫 `blocked`。真機 payload 仍待驗證。
- [x] Hook 內呼叫 `tm`（PATH 上的 symlink）還是絕對路徑？PATH 在 hook 環境中不一定包含 `~/.local/bin`。
  - PR 1 決定：寫入 `tm.sh` 的絕對路徑，與既有 `_record-claude-session` 相同。
- [x] `PreToolUse` 每次寫檔的實際成本，在密集工具呼叫下是否可接受？先量測再決定是否加短路。
  - 量測（macOS，20–40 次平均）：預設 `python3` 為 54.3 ms；改用 `python3 -I -S` 並移除 `tempfile` 後為 39.4 ms，低於 50 ms，不需要短路。
- [x] Subagent（Task tool）的事件是否會覆寫主 agent 的狀態？可能需要忽略 `SubagentStop`，或依 `session_id` 區分。
  - 文件調查（2026-10-22，Claude Code 2.1.308，hooks 與 sub-agents 官方文件；尚未用真機 log 確認）：
    - **前景 subagent 不會造成誤判**：主對話會等 subagent 結束；subagent 的工具呼叫同樣觸發 `PreToolUse`／`PostToolUse`（寫入 `working`），輸入帶 `agent_id`、`agent_type`。`Stop` 的說明是「主 agent 回應結束」，subagent 結束送的是 `SubagentStop`。
    - **背景 subagent 會造成誤判**：從主對話叫出的 subagent 預設在背景執行，主 agent 這一輪的 `Stop` 可能在 subagent 還在跑時就寫入 `idle`，結果在之後的回合才回來。`tm wait --until done` 會因此太早返回；subagent 只在呼叫工具時才會把狀態改回 `working`。
    - `Stop` 的輸入有 `background_tasks` 欄位（範圍是父 session），可用來判斷還有沒有背景工作。
    - 主 agent 與 subagent 的 `session_id` 是否相同，文件沒寫；subagent 的 transcript 放在父 session 目錄下，推測相同。
  - 真機實測（2026-10-23，Claude Code 2.1.308，只記錄 stdin 的 hook）：
    - 即使 prompt 要求等待，subagent 也以背景執行；主 agent 的 `Stop` 在 subagent 還在跑時觸發，原本的對應會寫入 `idle`（實測中有一段 25 秒顯示 💤）。
    - `Stop` 的 `background_tasks` 準確列出還在跑的 subagent（`type: subagent`、`status: running`），全部結束後的 `Stop` 是空陣列。subagent 結束時 Claude 會自動送一個 `UserPromptSubmit` 給主 agent，處理完再觸發一次 `Stop`。
    - 主 agent 的事件沒有 `agent_id`，subagent 的事件有；`session_id` 相同；subagent 的 hook 拿得到相同的 `$TMUX_PANE`。
    - `SubagentStart`／`SubagentStop` 計數不可靠：每次主 agent `Stop` 後 1～2 秒會出現沒有對應 `SubagentStart`、`agent_type` 為空的 `SubagentStop`（推測是 Claude Code 內部 agent）。
  - 決定：`tm hook-state idle` 收到的 `background_tasks` 中有 `type: subagent` 且 `status: running` 的項目時，改寫 `working`（`since` 沿用），不寫 `idle`。只看 subagent，背景 shell（例如 dev server）可能永遠不結束。不安裝 `SubagentStop`。尚未實測背景 Bash 指令在 `background_tasks` 中的 `type`，依此規則不會被計入。
  - 同次調查的其他發現：
    - `notification_type` 文件列出 13 種。其餘（`agent_completed`、`quota_auto_resume_*`、`plugin_notification`、`elicitation_complete`、`elicitation_response`）不是等待使用者的訊號。
    - `elicitation_url_dialog`（MCP server 要求開瀏覽器網址）：與 `elicitation_dialog` 同樣是前景 session 在等使用者，改寫 `blocked`、reason `input`。尚未實測（需要會發出 URL 模式 elicitation 的 MCP server），依文件語意比照 `elicitation_dialog`。
    - `agent_needs_input` 真機實測（2026-10-23，Claude Code 2.1.309，`claude agents` 派出需要權限的背景 session）：通知在 agent view 所在的 pane 觸發，`session_id` 是 agent view 自己的，payload 沒有背景 session 的 id；背景 session 本身的 hook 都沒有 `$TMUX_PANE`，所以它的 `permission_prompt` 會被忽略。背景 session 被核准或結束後，agent view 的 pane 不會再收到任何事件。決定：不寫檔，否則 agent view 的 pane 會停在 `blocked` 直到關閉；背景 session 不屬於任何 pane，由 agent view 自己顯示 Needs input。
    - 權限提示約等 6 秒才送 `permission_prompt`，在那之前會先顯示 `⏳`。
    - 互動模式下，接受信任對話框之前，所有設定檔的 hook（含 `~/.claude/settings.json`）都不會執行，與 README 的說法一致；`-p` 與 SDK 不顯示對話框、視為已信任。
    - 使用者拒絕權限或按 Esc 中斷，沒有對應的 hook（`PermissionDenied` 只用於 auto mode），所以 PR 1 記錄的「`❓` 留到下一個 prompt」是已知限制，文件層面無解。
    - 中斷實測（2026-10-23，Claude Code 2.1.309，logger 掛 21 種事件，排除會改變行為的 `WorktreeCreate`／`WorktreeRemove` 等）：串流中、等待背景工具時、在權限畫面按 Esc，三種情況都沒有任何 hook，狀態停在 `working`／`blocked`。transcript 會在這一輪最後寫一筆 user 訊息 `[Request interrupted by user]`（權限畫面為 `… for tool use]`，後面接 `system/turn_duration` 等 metadata）。還沒輸出就按 Esc 時，Claude Code 把 prompt 還原到輸入框，transcript 不留任何標記。`PermissionRequest` 在權限畫面出現的同一秒觸發，比 `permission_prompt` 通知早約 6 秒（尚未採用）。
    - 決定：狀態檔多記 `transcript_path`；讀取端（`load_state`，`ls --json`、dash、`state-count`、`wait` 共用）對 `working`／`blocked` 讀 transcript 檔尾 64 KB，最後一筆 user／assistant 紀錄（略過 sidechain 與 metadata）是中斷標記、且時間不早於狀態紀錄時，視為 `idle`，`since` 為中斷時間，`reason`／`message` 清空。每個 agent 約 0.1 ms。標記字串沒有文件保證，格式改變時退回原本行為（停在 `working`，由 `TM_STALE_AFTER` 兜底）；還沒輸出就中斷的情況仍偵測不到。
- [x] Codex 的 `working` 與 `blocked` 是否有更可靠的訊號，可以取代畫面比對？（2026-10-23 使用者停用 Codex，不再處理；以下調查結果保留備查）
  - 文件與原始碼調查（2026-10-22，codex-cli 0.163.0，官方 hooks／config 文件與 `openai/codex` 的 `rust-v0.163.0` 原始碼；尚未實測）：
    - **Codex 有與 Claude Code 相容的 hook 系統**，0.163 預設啟用：`~/.codex/hooks.json` 或 `config.toml` 的 `[hooks]`，格式是事件 → matcher → handler，stdin 收 JSON（`session_id`、`cwd`、`hook_event_name`、多數事件有 `turn_id`）。事件有 SessionStart、SessionEnd、PreToolUse、PostToolUse、PermissionRequest、UserPromptSubmit、SubagentStart、SubagentStop、Stop、Interrupt 等。非 managed 的 hook 要在 `/hooks` 審閱信任一次。
    - **舊的 `notify` 設定**只在 `agent-turn-complete`（一輪正常結束）時呼叫，JSON 放在最後一個 argv，fire-and-forget；原始碼標為 legacy，預期會被 hooks 取代，不建議採用。
    - **最大的坑：daemon 模式**。0.163 的 TUI 預設連到每個使用者共用的背景 app-server daemon，hook 在 daemon 裡執行，`$TMUX_PANE` 會不存在或屬於別的 pane。帶 `--no-daemon`、任何非 UI 的 `-c`／`--config` 覆寫（Leader 的 Codex 啟動指令有 `--config 'model_reasoning_effort="medium"'`）、或 `codex exec` 時，Codex 在自己的行程執行，環境變數正確（由原始碼推論）。
  - 建議對應（待實測）：

    | 狀態 | Codex 事件 | 信心 |
    | --- | --- | --- |
    | working | `UserPromptSubmit`；`PreToolUse`／`PostToolUse` 也寫 working（核准後可清掉 blocked） | 高 |
    | blocked | `PermissionRequest`（開啟自動審核時不一定真的出現提示，且沒有「已回應」事件） | 中高 |
    | idle | `Stop`、`Interrupt`；`SessionStart` | Stop 高、Interrupt 中 |
    | dead | 行程消失（沿用現有檢查）；`SessionEnd` 在 daemon 模式下 30 分鐘閒置才觸發，只當參考 | 行程檢查高 |
  - 實作前要先確認：在測試 pane 用 `codex --no-daemon` 掛一個只記錄 stdin 的 hook，確認 `$TMUX_PANE` 有值、事件順序與 `session_id`；錯誤中斷的回合不會觸發 `Stop`，仍需要 `TM_STALE_AFTER` 與行程檢查兜底。安裝方式可比照 `tm install-claude-hook` 新增 `tm install-codex-hook`，但要處理 `/hooks` 的信任步驟。
