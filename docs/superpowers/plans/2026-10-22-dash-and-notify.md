# 狀態總覽與通知（PR 4）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增三個讀狀態檔的出口：`tm state-count` 放在 tmux 狀態列、`tm dash` 自動更新的 fzf 總覽、`TM_NOTIFY_CMD` 在狀態轉換時推播，讓人不必一直盯著 fzf 畫面。

**Architecture:**
- `tm state-count` 沿用 fzf 列表的 `_agent_states`（狀態檔加一次 `tmux list-panes`），不跑 ps。
- `tm dash` 與主選單共用同一段 fzf 呼叫。fzf 以 `--listen=<unix socket>` 啟動，背景監看迴圈在狀態檔變動或每 2 秒時，透過 socket 送出 `transform`，讓 fzf 重新載入並把游標移回原本的 session。
- 推播由 `tm hook-state` 判斷狀態轉換與頻率限制，再以 detached 子行程執行 `tm _notify`。`_notify` 負責查 tmux 位址、組 JSON、加 5 秒 timeout 執行 `TM_NOTIFY_CMD`，hook 本身不等待。

**Tech Stack:** Bash（相容 macOS 內建 3.2）、python3 標準函式庫（`-I -S`）、tmux 3.x、repo 內附的 fzf 0.68.0（支援 `--listen=SOCKET_PATH`、`transform`、`pos`）、curl（`--unix-socket`）、選用的 `inotifywait`。

**Spec:** `docs/design/agent-state-and-orchestration.md` 第 4 節與「實作順序」的 PR 4。

## Global Constraints

- 三個出口都只讀第 1 節的狀態檔，不新增資料來源。
- `tm state-count`：輸出順序 `❓<n> ⏳<n> 💤<n>`，數量為 0 的項目省略；全部為 0 時輸出空字串。`--format tmux`（預設）帶 tmux 色碼，blocked 以紅色顯示；`--format plain` 輸出純文字。只讀狀態檔加一次 `tmux list-panes`，排除已不存在的 pane，目標 < 30 ms。
- `tm dash`：沿用主介面的 fzf 列表與快捷鍵，會自動更新。fzf 加 `--listen`；有 `inotifywait` 時監看 `~/.tmux-manager/state/`，事件發生時送出 reload，沒有就每 2 秒送一次。背景迴圈以 `trap` 綁定 fzf 結束，不留下殭屍程序；reload 保留游標所在的 session；在 popup 裡按 Enter 用 `tmux switch-client`，在 popup 外用 `attach`。
- Preview：`blocked` 的 pane 額外顯示 `capture-pane` 最後 15 行。
- 推播：`TM_NOTIFY_CMD` 從 stdin 收到該 agent 的狀態 JSON，格式同 `tm ls --json` 的 `agents[]` 元素，另加 `host` 與 `tmux_session`；未設定時不通知。
- `TM_NOTIFY_ON`：要通知的轉換，預設 `blocked`；`blocked,idle` 時 working 轉 idle（一輪完成）也通知。
- 只在狀態**轉換**時觸發，同一狀態重複寫入不通知；同一 pane 1 分鐘內最多通知一次。
- 通知指令在背景執行並加 5 秒 timeout，失敗只記 log，絕不拖慢或擋住 hook。
- Hook 內不呼叫 `tmux`；hook 每次寫入目標 < 50 ms（PR 1 的限制）。

## 本計畫補上的決定（spec 未定或與 spec 不同）

| 項目 | 決定 | 理由 |
|------|------|------|
| state-count 的資料 | 用 `_agent_states pane`；`working?`（過期）算進 ⏳；`unknown`、`dead` 不計 | spec 限定「狀態檔加一次 list-panes」，所以不做 PR 2 的行程佐證，與 fzf 列表一致 |
| state-count 的 tmux 色碼 | `#[fg=red]❓<n>#[default]`，其他項目不上色 | spec 只要求 blocked 紅色 |
| state-count 錯誤處理 | 沒有 tmux server、沒有 python3 或參數以外的錯誤都輸出空字串並 exit 0；`--format` 值不合法 → exit 3 | 狀態列不能出現錯誤訊息 |
| fzf 呼叫共用 | 把 `_cmd_main` 的 fzf 參數抽成 `_fzf_menu <border_label> [extra fzf args...]`，主選單與 dash 都呼叫它 | spec：「沿用主介面的 fzf 列表與快捷鍵」 |
| `--listen` 位址 | Unix socket `~/.tmux-manager/run/dash-<pid>.sock`；`run/` 目錄權限 `0700` | `reload(...)` 會執行指令，TCP port 任何本機使用者都能連；socket 放在私有目錄才安全 |
| Socket 清理 | 結束時由 dash 的 `trap` 移除自己建立的 socket（fzf 結束後若還在） | 只清自己這次的檔案，不碰其他 dash 的 socket |
| Reload 與游標 | 監看迴圈送出 `transform($SELF _dash-reload {2})`；`_dash-reload <name>` 印出 `reload-sync($SELF _list)+pos(<n>)`，`<n>` 是該 session 在新列表中的序號（不含標頭，從 1 起算）；找不到時只印 `reload-sync(...)` | fzf 0.68 沒有 `--id-nth`；列表的圖示會變，`--track` 認不出同一列 |
| 監看間隔 | 沒有 `inotifywait`：每 2 秒 reload；有：`inotifywait -qq -t 5 ...` 事件或逾時後 reload | inotify 只看得到狀態檔，新建或關閉 session 要靠逾時補上 |
| 監看迴圈結束 | dash 記下迴圈 PID，`trap` 在 EXIT、INT、TERM 時終止它；迴圈本身在 `curl` 連不上 socket 時也自行結束 | 雙重保險，fzf 異常結束時也不會留下迴圈 |
| Popup 判斷 | 新增 `tm dash --popup`：Enter 後 `switch-client` 並結束 dash（popup 隨之關閉）；沒有 `--popup` 時 Enter 後回到 dash（tmux 內 `switch-client`、外面 `attach`，沿用 `_attach_session`） | tmux 沒有可靠的方式讓 popup 內的程式知道自己在 popup 裡；spec 的綁定改成 `display-popup ... -E "tm dash --popup"` |
| Preview 的 capture | 主選單與 dash 共用 preview，`blocked` pane 都會顯示；只取最後 15 個非空白行，移除控制字元 | 同一個 preview 函式，沒有理由只在 dash 顯示 |
| 推播的「轉換」 | 寫入前讀舊狀態檔：舊狀態存在且與新狀態不同才算轉換。`idle` 只在舊狀態為 `working` 時通知；`blocked`、`working`、`dead` 只要狀態改變就通知 | 否則每次 SessionStart（無 → idle）都會通知 |
| `TM_NOTIFY_ON` 值 | 逗號分隔，可用 `blocked`、`idle`、`working`、`dead`；不認得的值忽略 | hook 絕不能因設定錯誤而失敗 |
| 頻率限制 | 狀態檔新增 `notified_at`（UTC ISO 字串），寫入時保留舊值；距離上次通知不到 60 秒就不通知 | 不需要額外的檔案；新增欄位不升版 |
| 通知內容 | `_notify` 收到 hook 剛寫入的紀錄，用一次 `tmux display-message -p -t <pane>` 補上 `target` 與 `tmux_session`。`pid` 為 `null`、`stale` 為 `false`、`source` 為 `hook` | hook 不能呼叫 tmux；通知只需要描述這次轉換，不跑 ps |
| 背景執行 | hook 以 `subprocess.Popen([SELF, "_notify"], start_new_session=True)` 啟動，紀錄從 stdin 傳入，hook 不等待 | 新的 session 讓通知不受 Claude 結束或 Ctrl-C 影響 |
| Timeout 與 log | `_notify` 以 `subprocess.run(["/bin/sh", "-c", cmd], input=..., timeout=5)` 執行；逾時、非 0 exit、無法執行都寫一行到 `~/.tmux-manager/notify.log`（`0600`），格式 `<UTC ts>\t<pane>\t<state>\t<結果>` | macOS 沒有 `timeout` 指令；log 不記錄 message，避免把敏感內容留在檔案 |

## 檔案結構

| 檔案 | 動作 | 職責 |
|------|------|------|
| `tm.sh` | 修改 | 新增 `_cmd_state_count`、`_fzf_menu`、`_cmd_dash`、`_dash_watch`、`_cmd_dash_reload`、`_cmd_notify`；修改 `_cmd_main`、`_cmd_preview`、`_cmd_hook_state`、routing、`_cmd_help` |
| `tests/lib.sh` | 修改 | `setup_env` 把 repo 的 `fzf` 連結到 `$TEST_TMP/bin/fzf`（dash 測試需要） |
| `tests/test_state_count.sh` | 新增 | Task 1 |
| `tests/test_preview_save.sh` | 修改 | Task 2 |
| `tests/test_dash.sh` | 新增 | Task 3 |
| `tests/test_notify.sh` | 新增 | Task 4 |
| `completions/tm.zsh`、`README.md`、`README.zh-TW.md`、`docs/design/agent-state-and-orchestration.md` | 修改 | Task 5 |

## Review Focus

1. **通知指令很慢或卡住**（例如網路斷線時 `curl` 一直等）：期望 hook 照常在 1 秒內返回，通知 5 秒後被終止並記 log。→ Task 4 `test_slow_notify_does_not_block_hook`。
2. **權限確認連續出現**（blocked → working → blocked 在 1 分鐘內）：期望只通知一次。→ Task 4 `test_rate_limit_per_pane`。
3. **退出 dash**（Esc、或 popup 被關掉時收到 SIGTERM／SIGHUP）：期望監看迴圈一起結束，沒有殘留的 `curl` 或 `sleep`。→ Task 3 `test_dash_exit_stops_watcher`。
4. **Reload 時列表重新排序**（某個 session 變成 blocked 被排到最上面）：期望游標仍停在原本的 session。→ Task 3 `test_reload_keeps_cursor_session`。
5. **tmux server 沒開或還沒有任何 agent**：期望 `tm state-count` 輸出空字串、exit 0，狀態列不出現錯誤訊息。→ Task 1 `test_no_server_prints_nothing`。

---

### Task 1: `tm state-count`

**Files:**
- Modify: `tm.sh`（新增 `_cmd_state_count`、routing）
- Create: `tests/test_state_count.sh`

**Interfaces:**
- Consumes: `_agent_states pane`（PR 1）
- Produces: `_cmd_state_count [--format tmux|plain]`；routing `state-count) _cmd_state_count "${@:2}" ;;`（不經 `_check_cmd tmux`，沒有 tmux 時輸出空字串）

- [ ] **Step 1: 寫失敗的測試**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

test_counts_in_order() {
  new_session a; new_session b; new_session c
  tmux split-window -d -t a "sleep 600"
  set_state a:0.0 blocked; set_state a:0.1 working; set_state b idle; set_state c idle
  assert_eq "❓1 ⏳1 💤2" "$("$TM" state-count --format plain)" plain
  assert_eq "#[fg=red]❓1#[default] ⏳1 💤2" "$("$TM" state-count)" tmux-default
}

test_zero_counts_omitted() {
  new_session a
  set_state a idle
  assert_eq "💤1" "$("$TM" state-count --format plain)" idle-only
}

test_stale_counts_as_working() {
  new_session a
  set_state a working
  local f created; f="$STATE_DIR/$(pane_id a | tr -d %).json"
  created=$(tmux display-message -p -t a '#{session_created}')
  python3 - "$f" "$created" <<'PY'
import json, sys, time
p, created = sys.argv[1], int(sys.argv[2])
d = json.load(open(p)); d["ts"] = d["since"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(created + 1)); json.dump(d, open(p, "w"))
PY
  sleep 2
  assert_eq "⏳1" "$(TM_STALE_AFTER=1 "$TM" state-count --format plain)" stale
}

test_orphan_and_dead_not_counted() {
  new_session a
  set_state a dead
  mkdir -p "$STATE_DIR"
  printf '{"v":1,"state":"blocked","ts":"2099-01-01T00:00:00Z","since":"2099-01-01T00:00:00Z"}' > "$STATE_DIR/999.json"
  assert_eq "" "$("$TM" state-count --format plain)" nothing
}

test_no_server_prints_nothing() {
  local out code; out=$("$TM" state-count 2>&1); code=$?
  assert_eq 0 "$code" exit
  assert_eq "" "$out" empty
}

test_bad_format_exit_3() {
  local code; "$TM" state-count --format nope >/dev/null 2>&1; code=$?
  assert_eq 3 "$code" exit
}

run_tests
```

- [ ] **Step 2: 執行，確認失敗**

Run: `bash tests/test_state_count.sh`
Expected: 全部失敗（`state-count` 被當成 session 名稱，exit 1）

- [ ] **Step 3: 實作 `_cmd_state_count`**

一次 `tmux list-panes -a -F $'#{session_name}\t#{pane_id}\t#{session_created}\t#{window_index}.#{pane_index}'`，交給 `_agent_states pane`，再用 bash 數第 3 欄。

- [ ] **Step 4: 執行，確認通過並量測**

Run: `bash tests/run.sh`
Expected: 全數通過

量測：沿用 PR 2 的量測方式，在隔離環境建立 30 個 session，各寫一份狀態檔，`tm state-count` 執行 20 次取平均。
Expected: < 30 ms。超過時記錄瓶頸與數字，不放寬目標，並在 ledger 記一筆 Ruling。

- [ ] **Step 5: Commit**

```bash
git add tm.sh tests/test_state_count.sh
git commit -m "feat: add tm state-count for the tmux status line" -- tm.sh tests/test_state_count.sh
```

---

### Task 2: Preview 顯示 blocked pane 的畫面

**Files:**
- Modify: `tm.sh`（`_cmd_preview` 的 Agents 區塊，約 597–613 行）
- Test: `tests/test_preview_save.sh`

**Interfaces:**
- Consumes: preview 既有的 `agent_lines`（`_agent_states pane` 的輸出，第 2 欄是 pane id）
- Produces: blocked agent 下方多一個區塊，最多 15 行，每行縮排 5 格並以 dim 顯示

- [ ] **Step 1: 寫失敗的測試**

```bash
test_preview_shows_blocked_screen() {
  tmux new-session -d -s a -c "$TEST_TMP" "printf 'line-%s\n' \$(seq 1 30); printf 'Allow Bash? \033[31m(y/n)\033[0m\n'; sleep 600"
  sleep 0.3
  set_state a blocked
  local out; out=$("$TM" _preview a | sed 's/\x1b\[[0-9;]*m//g')
  assert_contains "$out" "Allow Bash? (y/n)" last-line
  assert_contains "$out" "line-30" within-15
  assert_not_contains "$out" "line-10" older-lines-cut
}

test_preview_no_screen_for_idle() {
  tmux new-session -d -s a -c "$TEST_TMP" "echo SCREEN-MARKER; sleep 600"
  sleep 0.3
  set_state a idle
  assert_not_contains "$("$TM" _preview a)" "SCREEN-MARKER" idle
}
```

- [ ] **Step 2: 執行，確認失敗**

Run: `bash tests/test_preview_save.sh`
Expected: `test_preview_shows_blocked_screen` 失敗；`test_preview_no_screen_for_idle` 通過（目前完全不顯示畫面）

- [ ] **Step 3: 實作**

對每個 blocked pane 執行 `tmux capture-pane -p -t <pane_id>`，去掉結尾的空白行後取最後 15 行，用 `tr -d '\000-\010\013-\037\177'` 移除控制字元，再以 `printf '     %s%s%s\n' "$C_DIM" "$line" "$C_RESET"` 輸出。

- [ ] **Step 4: 執行，確認通過**

Run: `bash tests/run.sh`
Expected: 全數通過

- [ ] **Step 5: Commit**

```bash
git add tm.sh tests/test_preview_save.sh
git commit -m "feat: show the last screen lines of blocked panes in the preview" -- tm.sh tests/test_preview_save.sh
```

---

### Task 3: `tm dash`

**Files:**
- Modify: `tm.sh`（`_cmd_main` 的 fzf 呼叫抽成 `_fzf_menu`；新增 `_cmd_dash`、`_dash_watch`、`_cmd_dash_reload`；routing）
- Modify: `tests/lib.sh`（`setup_env` 加 `ln -s "$REPO_ROOT/fzf" "$TEST_TMP/bin/fzf"`，repo 沒有 fzf 時略過）
- Create: `tests/test_dash.sh`

**Interfaces:**
- Consumes: `_cmd_list`（`_list`）、`_attach_session`
- Produces:
  - `_fzf_menu <border_label> [extra fzf args...]`：印出 fzf 的選取結果，主選單與 dash 共用
  - `_cmd_dash [--popup]`
  - `_dash_watch <socket>`：背景監看迴圈，routing 為 `_dash-watch`
  - `_cmd_dash_reload <name>`：routing 為 `_dash-reload`，印出 fzf action 字串
  - routing：`dash) _check_deps; _check_cmd curl; _cmd_dash "${@:2}" ;;`、`_dash-reload) _cmd_dash_reload "${2:-}" ;;`

- [ ] **Step 0: 確認 fzf 與 curl 的行為**

在 scratchpad 寫一支小腳本，在隔離的 tmux 裡跑 `./fzf --listen=<sock>`，確認以下 4 點：

1. `curl --unix-socket <sock> -XPOST http://localhost -d 'reload(...)'` 能觸發 reload。
2. `GET /` 回傳的 JSON 含目前游標的項目（`current.text`）。
3. `transform(...)` 加上 `pos(n)` 能移動游標。
4. fzf 結束後 socket 檔案是否還在。

把結果記進 ledger。任何一項與本計畫的假設不同時，先記 Ruling 再調整做法。

- [ ] **Step 1: 寫失敗的測試**

測試在隔離的 tmux server 裡開一個 120×40 的 pane 執行 dash，透過 dash 自己的 socket 查詢 fzf 狀態：

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# start_dash [args]: run tm dash in its own session; sets DASH_SOCK
start_dash() {
  tmux new-session -d -s dash -x 120 -y 40 "$TM dash $*"
  local i
  for i in $(seq 50); do
    DASH_SOCK=$(ls "$HOME"/.tmux-manager/run/dash-*.sock 2>/dev/null | head -1)
    [[ -n "$DASH_SOCK" ]] && break
    sleep 0.1
  done
  sleep 0.5
}

# fzf_state <python-expr>: query the dash fzf over its socket
fzf_state() {
  curl -s --unix-socket "$DASH_SOCK" http://localhost | json "$1"
}

test_dash_reloads_on_state_change() {
  new_session a; new_session b
  start_dash
  assert_not_contains "$(fzf_state '[m["text"] for m in d["matches"]]')" "❓" before
  set_state a blocked
  sleep 3
  assert_contains "$(fzf_state '[m["text"] for m in d["matches"]]')" "❓" after
}

test_reload_keeps_cursor_session() {
  new_session a; new_session b; new_session c
  start_dash
  tmux send-keys -t dash Down
  sleep 0.3
  local before; before=$(fzf_state 'd["current"]["text"].split("\t")[1].strip()')
  # Another session turns blocked and jumps to the top of the list
  local other; for other in a b c; do [[ "$other" != "$before" ]] && break; done
  set_state "$other" blocked
  sleep 3
  assert_eq "$before" "$(fzf_state 'd["current"]["text"].split("\t")[1].strip()')" cursor
}

test_dash_exit_stops_watcher() {
  new_session a
  start_dash
  local sock="$DASH_SOCK"
  tmux send-keys -t dash Escape
  sleep 3
  assert_eq "" "$(pgrep -f "$sock")" no-watcher
  [[ ! -e "$sock" ]] || fail "socket left behind: $sock"
}

test_dash_sigterm_stops_watcher() {
  new_session a
  start_dash
  local sock="$DASH_SOCK" pane_pid; pane_pid=$(tmux display-message -p -t dash '#{pane_pid}')
  kill -TERM "$pane_pid"
  sleep 3
  assert_eq "" "$(pgrep -f "$sock")" no-watcher
}

test_dash_reload_action() {
  new_session a; new_session b
  local out; out=$("$TM" _dash-reload b)
  assert_contains "$out" "reload-sync(" reload
  [[ "$out" =~ \+pos\(([0-9]+)\)$ ]] || fail "no pos in <$out>"
  assert_eq b "$("$TM" _list | sed -n "$((BASH_REMATCH[1] + 1))p" | awk -F'\t' '{x=$2; sub(/ +$/, "", x); print x}')" pos-points-at-b
  assert_not_contains "$("$TM" _dash-reload nope)" "pos(" missing-session
}

run_tests
```

監看迴圈必須以 `"$SELF" _dash-watch "$sock"` 這種形式在背景執行，讓行程參數帶著 socket 路徑，測試才能用 `pgrep -f "$sock"` 找到它。routing 要加上 `_dash-watch) _dash_watch "${2:-}" ;;`。

- [ ] **Step 2: 執行，確認失敗**

Run: `bash tests/test_dash.sh`
Expected: 全部失敗（`dash`、`_dash-reload` 都還不存在，找不到 socket）

- [ ] **Step 3: 抽出 `_fzf_menu`，讓 `_cmd_main` 改用它**

Run: `bash tests/run.sh`
Expected: 既有測試全數通過。主選單沒有自動化測試，所以要在隔離 tmux 裡啟動 `tm`、按 `Down` 再按 `Escape`，手動確認可以正常開啟與退出，並把結果記進 ledger。

- [ ] **Step 4: 實作 `_cmd_dash`、`_dash_watch`、`_cmd_dash_reload`**

- `run/` 目錄以 `mkdir -p` 建立後 `chmod 700`。
- 監看迴圈：每輪 `curl -s --max-time 2 --unix-socket "$sock" -XPOST http://localhost -d "transform($SELF _dash-reload {2})"`；`curl` 失敗就結束迴圈。
- `trap` 綁 `EXIT INT TERM HUP`：終止迴圈 PID，並移除仍存在的 socket。
- 有 `--popup` 時，Enter 後呼叫 `_attach_session` 並結束；沒有 `--popup` 時，回到迴圈重新開 fzf，與 `_cmd_main` 相同。
- border label：`tm dash`。

- [ ] **Step 5: 執行，確認通過**

Run: `bash tests/run.sh`
Expected: 全數通過

- [ ] **Step 6: Commit**

```bash
git add tm.sh tests/lib.sh tests/test_dash.sh
git commit -m "feat: add tm dash, an auto-refreshing session overview" -- tm.sh tests/lib.sh tests/test_dash.sh
```

---

### Task 4: 推播通知

**Files:**
- Modify: `tm.sh`（`_cmd_hook_state`；新增 `_cmd_notify` 與 routing `_notify) _cmd_notify ;;`）
- Create: `tests/test_notify.sh`

**Interfaces:**
- Consumes: hook-state 的狀態檔格式
- Produces:
  - 狀態檔新增欄位 `notified_at`
  - `_cmd_notify`：stdin 讀 hook 紀錄 JSON，`$TM_NOTIFY_CMD` 從環境變數讀
  - `~/.tmux-manager/notify.log`

- [ ] **Step 1: 寫失敗的測試**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# notified: lines the notify command received so far
notified() { cat "$TEST_TMP/notified.jsonl" 2>/dev/null; }

# hook <target> <state> [payload]: run the hook with notifications enabled
hook() {
  TM_NOTIFY_CMD="cat >> '$TEST_TMP/notified.jsonl'" set_state "$@"
}

test_blocked_transition_notifies() {
  new_session a
  hook a working
  hook a blocked '{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","session_id":"s-1"}'
  sleep 1
  assert_eq 1 "$(notified | grep -c .)" one-notification
  local line; line=$(notified)
  assert_eq blocked "$(json 'd["state"]' <<< "$line")" state
  assert_eq a "$(json 'd["tmux_session"]' <<< "$line")" tmux_session
  assert_eq a:0.0 "$(json 'd["target"]' <<< "$line")" target
  assert_eq permission "$(json 'd["reason"]' <<< "$line")" reason
  [[ -n "$(json 'd["host"]' <<< "$line")" ]] || fail "host missing"
  assert_eq '["agent", "host", "message", "pane", "pid", "reason", "session_id", "since", "source", "stale", "state", "target", "tmux_session"]' \
    "$(json 'sorted(d)' <<< "$line")" keys
}

test_same_state_does_not_notify() {
  new_session a
  hook a working
  hook a blocked
  hook a blocked
  sleep 1
  assert_eq 1 "$(notified | grep -c .)" once
}

test_session_start_idle_does_not_notify() {
  new_session a
  TM_NOTIFY_ON=blocked,idle hook a idle
  sleep 1
  assert_eq 0 "$(notified | grep -c .)" none
}

test_notify_on_idle_after_working() {
  new_session a
  hook a working
  TM_NOTIFY_ON=blocked,idle hook a idle
  sleep 1
  assert_eq idle "$(notified | json 'd["state"]')" idle
}

test_default_ignores_idle() {
  new_session a
  hook a working
  hook a idle
  sleep 1
  assert_eq 0 "$(notified | grep -c .)" none
}

test_rate_limit_per_pane() {
  new_session a
  hook a working; hook a blocked; hook a working; hook a blocked
  sleep 1
  assert_eq 1 "$(notified | grep -c .)" limited
  # Once the last notification is more than a minute old, notify again
  local f; f="$STATE_DIR/$(pane_id a | tr -d %).json"
  python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["notified_at"] = "2000-01-01T00:00:00Z"; json.dump(d, open(p, "w"))
PY
  hook a working; hook a blocked
  sleep 1
  assert_eq 2 "$(notified | grep -c .)" after-a-minute
}

test_unset_cmd_does_nothing() {
  new_session a
  set_state a working; set_state a blocked
  sleep 1
  [[ ! -e "$HOME/.tmux-manager/notify.log" ]] || fail "log written without TM_NOTIFY_CMD"
}

test_slow_notify_does_not_block_hook() {
  new_session a
  set_state a working
  local start; start=$(python3 -c 'import time; print(time.time())')
  printf '{"notification_type":"permission_prompt"}' \
    | TMUX_PANE="$(pane_id a)" TM_NOTIFY_CMD="sleep 30" "$TM" hook-state blocked
  python3 -c "import sys, time; sys.exit(0 if time.time() - $start < 1 else 1)" || fail "hook waited for the notify command"
  sleep 6
  assert_contains "$(cat "$HOME/.tmux-manager/notify.log")" "timeout" logged
  assert_eq "" "$(pgrep -f 'sleep 30')" killed
}

test_failing_notify_is_logged() {
  new_session a
  set_state a working
  printf '{"notification_type":"permission_prompt"}' \
    | TMUX_PANE="$(pane_id a)" TM_NOTIFY_CMD="exit 7" "$TM" hook-state blocked
  sleep 1
  assert_contains "$(cat "$HOME/.tmux-manager/notify.log")" "exit 7" logged
  assert_eq 600 "$(stat -f %Lp "$HOME/.tmux-manager/notify.log" 2>/dev/null || stat -c %a "$HOME/.tmux-manager/notify.log")" mode
}

run_tests
```

`test_slow_notify_does_not_block_hook` 用 `pgrep -f 'sleep 30'` 檢查行程是否已被終止，執行測試的機器上不能有其他 `sleep 30`。實作時若改用更獨特的秒數，測試裡要一起改。

- [ ] **Step 2: 執行，確認失敗**

Run: `bash tests/test_notify.sh`
Expected：

- 失敗：`test_blocked_transition_notifies`、`test_same_state_does_not_notify`（收到 0 筆，預期 1 筆）、`test_notify_on_idle_after_working`、`test_rate_limit_per_pane`、`test_slow_notify_does_not_block_hook`（沒有 log）、`test_failing_notify_is_logged`。
- 通過：`test_session_start_idle_does_not_notify`、`test_default_ignores_idle`、`test_unset_cmd_does_nothing`。這 3 個驗證「不該通知」，目前完全不通知，所以會先通過；Step 4 要再確認一次。

- [ ] **Step 3: 實作**

- **hook**：在既有 python 裡讀出舊紀錄的 `state` 與 `notified_at`，依決定表判斷是否通知。要通知時，把 `notified_at` 設為現在；不通知時保留舊值。寫完狀態檔後才 `Popen`。
- **`_cmd_notify`**：`exec python3 -I -S`。
  - 讀 stdin 的紀錄。
  - 用 `tmux display-message -p -t <pane> '#{session_name}\t#{session_name}:#{window_index}.#{pane_index}'` 取 `tmux_session` 與 `target`，失敗時兩者為 `null`。
  - 組成決定表規定的 JSON，執行 `TM_NOTIFY_CMD` 並寫 log。

- [ ] **Step 4: 執行，確認通過，並重新量測 hook 延遲**

Run: `bash tests/run.sh`
Expected: 全數通過

量測：沿用 PR 1 的方式，沒有設定 `TM_NOTIFY_CMD` 時，`tm hook-state working` 執行 20 次取平均。
Expected: < 50 ms。

- [ ] **Step 5: Commit**

```bash
git add tm.sh tests/test_notify.sh
git commit -m "feat: notify on agent state transitions via TM_NOTIFY_CMD" -- tm.sh tests/test_notify.sh
```

---

### Task 5: 補全與說明文件

**Files:**
- Modify: `completions/tm.zsh`、`tm.sh`（`_cmd_help`）、`README.md`、`README.zh-TW.md`、`docs/design/agent-state-and-orchestration.md`

- [ ] **Step 1: zsh completion**

新增兩個子指令：

- `dash:Auto-refreshing session overview`，參數 `--popup`。
- `state-count:Agent counts for the tmux status line`，參數 `--format`，值為 `(tmux plain)`。

Run: `zsh -n completions/tm.zsh`
Expected: 沒有輸出，exit 0

- [ ] **Step 2: `_cmd_help`**

- Usage 區塊加入 `tm dash [--popup]` 與 `tm state-count [--format tmux|plain]`。
- 環境變數區塊加入 `TM_NOTIFY_CMD` 與 `TM_NOTIFY_ON`。

- [ ] **Step 3: README 兩個語言版本**

在「Waiting for Agents」之後新增「Overview and Notifications」段落，包含：

- `tm dash` 的說明與 tmux 綁定。popup 版本使用 `display-popup -w 90% -h 85% -E "tm dash --popup"`，並說明為什麼要加 `--popup`。
- `state-count` 的 `status-right` 設定。
- `TM_NOTIFY_CMD`、`TM_NOTIFY_ON` 的說明、轉換規則、頻率限制、timeout 與 log。
- 設計文件的 Telegram 範例。
- 「message 可能含指令內容或路徑」的提醒。

兩個版本的內容要一致；環境變數表也要補上這兩個變數。

- [ ] **Step 4: 設計文件**

- 勾選 PR 4。
- 第 4 節補一段「PR 4 決定」，摘要本計畫的決定表。
- 第 4 節的 popup 綁定範例改成 `tm dash --popup`。

- [ ] **Step 5: 跑完整測試**

Run: `bash tests/run.sh`
Expected: 全數通過

- [ ] **Step 6: Commit**

```bash
git add completions/tm.zsh tm.sh README.md README.zh-TW.md docs/design/agent-state-and-orchestration.md
git commit -m "docs: document tm dash, state-count and notifications" -- completions/tm.zsh tm.sh README.md README.zh-TW.md docs/design/agent-state-and-orchestration.md
```
