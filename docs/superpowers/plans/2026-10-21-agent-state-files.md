# Agent 狀態檔（PR 1）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code hooks 把每個 agent pane 的狀態寫進 `~/.tmux-manager/state/<pane>.json`，fzf 主畫面與 preview 讀這些檔案顯示狀態，`blocked` 置頂。

**Architecture:** 寫入端是新的 `tm hook-state <state>` 子指令，由 6 個 Claude Code hook 呼叫，單次 python3 執行完成解析與原子寫入，不呼叫 tmux。讀取端新增一個 python3 helper `_agent_states`，從 stdin 收 `tmux list-panes -a` 的輸出、讀所有狀態檔，一次算出每個 session 的彙總狀態（給 `_list`）或每個 pane 的狀態（給 `_preview`）。`tm install-claude-hook` 沿用既有的備份與合併邏輯，補上 6 個事件。

**Tech Stack:** Bash（相容 macOS 內建 3.2：不用 associative array、`mapfile`、`${var,,}`）、python3 標準函式庫、tmux 3.x、純 bash 測試腳本（repo 目前沒有測試框架）。

**Spec:** `docs/design/agent-state-and-orchestration.md` 第 1 節與「實作順序」的 PR 1。

## Global Constraints

- 狀態值只有 `working`、`blocked`、`idle`、`dead`；`unknown` 由讀取端推得，不寫檔。
- 事件對應：`SessionStart`→`idle`、`UserPromptSubmit`→`working`、`PreToolUse`→`working`、`Notification`→`blocked`、`Stop`→`idle`、`SessionEnd`→`dead`。
- 狀態檔路徑：`~/.tmux-manager/state/<pane>.json`，`<pane>` 為去掉 `%` 的 `$TMUX_PANE`（`%12` → `12.json`）。
- 狀態檔欄位：`v`（固定 `1`）、`pane`、`agent`（固定 `"claude"`）、`session_id`、`state`、`reason`、`message`、`event`、`cwd`、`ts`、`since`；沒有值輸出 `null`。不寫 `tmux_session`。
- `ts` 是最後一次寫入時間；`since` 是進入目前狀態的時間，狀態不變時保留舊值。時間一律 UTC，格式 `YYYY-MM-DDTHH:MM:SSZ`。
- `reason` 只在 `blocked` 時有值：`permission` 或 `input`。
- 寫入採 tmp 檔加 rename，讀取端不會讀到半個 JSON。
- Hook 每次寫入目標 < 50 ms；hook 內不呼叫 `tmux`，只讀 `$TMUX_PANE`。
- fzf 圖示：`⏳` working、`❓` blocked、`💤` idle、`·` unknown；session 彙總取 blocked > working > idle。
- 預設排序 `blocked` 置頂；`TM_SORT=recent` 改回最近使用排序。
- `working` 超過 `TM_STALE_AFTER`（預設 30 分鐘，單位秒，預設 `1800`）沒有寫入，顯示 `working?`。
- 孤兒狀態檔（pane 已不在 `tmux list-panes -a`）由 `tm save` 清理。
- 不裝 hook 時一切照舊，狀態顯示 `unknown`。

## 本計畫補上的決定（spec 未定或列為待確認）

| 項目 | 決定 | 理由 |
|------|------|------|
| Hook 指令路徑（待確認問題 2） | 用 `$SELF` 的絕對路徑，`shlex.quote` 後寫入，與既有 `_record-claude-session` 相同 | hook 環境的 PATH 不一定有 `~/.local/bin` |
| `reason` 判斷（待確認問題 1） | 先看 payload 的 `notification_type`：`permission_prompt`→`permission`；`idle_prompt`、`elicitation_dialog`→`input`；其他類型（如 `auth_success`）不寫檔。沒有 `notification_type` 時，`message` 含 `permission`（不分大小寫）→`permission`，否則 `input` | 新版 payload 有類型欄位，舊版只能看文字 |
| `ST` 欄位位置 | 圖示接在第 1 欄狀態括號後（`[●] ⏳`），不新增 tab 欄位 | fzf binds 全用 `{2}` 取 session 名，插新欄位要改所有 binds |
| Pane id 重用 | 狀態檔 `ts` 早於該 pane 所屬 session 的 `session_created` 時視為不存在 | tmux server 重啟後 pane id 從頭編號，舊檔會對到新 pane |
| `dead` 顯示 | 與 `unknown` 同樣顯示 `·` | pane 還在、agent 已退出，對使用者等同沒有 agent |
| 權限 | state 目錄 `0700`、狀態檔 `0600` | `message` 可能含指令內容或路徑 |
| Hook exit code | 執行期任何錯誤都 exit 0；只有 state 參數不合法時 exit 3 | exit 2 會擋住 Claude 的動作，hook 不得影響 agent |
| Codex fallback、`SubagentStop` | 不在本 PR | spec 的 PR 1 清單未列 |

## 檔案結構

| 檔案 | 動作 | 職責 |
|------|------|------|
| `tm.sh` | 修改 | 新增 `STATE_DIR`、`STALE_AFTER` 常數；`_cmd_hook_state`；`_agent_states`；改 `_cmd_install_claude_hook`、`_build_list_cache`、`_format_session_line`、`_cmd_list`、`_cmd_preview`、`_cmd_save`、`_cmd_help`、self-routing |
| `tests/lib.sh` | 新增 | 測試共用：隔離 HOME 與 tmux socket、複製 `tm.sh` 到暫存目錄、assert 函式 |
| `tests/run.sh` | 新增 | 依序執行 `tests/test_*.sh`，任一失敗則 exit 1 |
| `tests/test_hook_state.sh` | 新增 | Task 1 |
| `tests/test_install_hook.sh` | 新增 | Task 2 |
| `tests/test_list_state.sh` | 新增 | Task 3 |
| `tests/test_preview_save.sh` | 新增 | Task 4 |
| `README.md`、`README.zh-TW.md` | 修改 | Task 4：說明狀態欄、`TM_SORT`、`TM_STALE_AFTER` |

## Review Focus

1. **tmux server 重啟後 pane id 重用**：舊狀態檔會對到新 pane，顯示錯誤狀態。期望顯示 `unknown`。→ Task 3 `test_state_older_than_session_is_ignored`。
2. **狀態檔損毀或為空**（手動編輯、磁碟滿）：期望 `tm _list`、`tm _preview` 不中斷，該 pane 視為 `unknown`。→ Task 3 `test_corrupt_state_file_is_unknown`。
3. **Hook stdin 不是 JSON 或為空**：期望 exit 0、仍寫入狀態（欄位為 `null`），不影響 Claude。→ Task 1 `test_invalid_payload_still_writes`。
4. **`message` 含換行或 tab**：期望 preview 顯示成單行，不打亂 TSV 解析。→ Task 4 `test_preview_message_single_line`。
5. **`settings.json` 的 `hooks.<Event>` 不是陣列**：期望安裝失敗、原檔不變、不產生備份。→ Task 2 `test_install_rejects_malformed_event`。

---

### Task 0: 測試骨架

**Files:**
- Create: `tests/lib.sh`、`tests/run.sh`

**Interfaces:**
- Produces（`tests/lib.sh`，被所有測試 `source`）：
  - `setup_env`：建立 `TEST_TMP=$(mktemp -d)`；`export HOME="$TEST_TMP/home"`、`TMUX_TMPDIR="$TEST_TMP/tmux"`、`COLUMNS=200`；`unset TMUX TMUX_PANE`；複製 `tm.sh` 到 `$TEST_TMP/bin/tm.sh` 並設 `TM="$TEST_TMP/bin/tm.sh"`（`tm save` 會寫到 script 旁的 `snapshots/`，不能動 repo）。
  - `teardown_env`：`tmux kill-server 2>/dev/null || true`（只作用於隔離 socket），暫存目錄留給系統清理，不刪檔。
  - `assert_eq <expected> <actual> <label>`、`assert_contains <haystack> <needle> <label>`、`assert_not_contains <haystack> <needle> <label>`：失敗時印出 label 與兩邊值並遞增 `FAILURES`。
  - `run_tests`：執行目前檔案中所有 `test_*` 函式，每個前後呼叫 `setup_env`／`teardown_env`；最後 `FAILURES` 非 0 則 exit 1。
- `tests/run.sh`：對 `tests/test_*.sh` 逐一 `bash` 執行，彙總結果。

- [ ] **Step 1:** 寫 `tests/lib.sh`、`tests/run.sh` 與 `tests/test_harness.sh`，後者含兩個測試：`test_tm_version`（`assert_contains "$("$TM" --version)" "tm v1.0.0"`）與 `test_tmux_is_isolated`（`tmux new-session -d -s iso` 後，`tmux ls` 只列出 `iso`）。
- [ ] **Step 2:** Run `bash tests/run.sh`，Expected：兩個測試 PASS，exit 0。
- [ ] **Step 3:** 確認隔離：測試前後在原本的 shell 執行 `tmux ls`，輸出相同。
- [ ] **Step 4:** Commit（`tests/lib.sh`、`tests/run.sh`、`tests/test_harness.sh`）：`test: add isolated bash test harness`

### Task 1: `tm hook-state <state>`

**Files:**
- Modify: `tm.sh`（常數區、新增 `_cmd_hook_state`、self-routing 加 `hook-state)`、`_cmd_help`）
- Create: `tests/test_hook_state.sh`

**Interfaces:**
- Produces：
  - `readonly STATE_DIR="${CONFIG_DIR}/state"`
  - `tm hook-state <working|blocked|idle|dead>`：stdin 為 hook JSON；讀 `session_id`、`cwd`、`hook_event_name`、`message`、`notification_type`。
  - 狀態檔格式見 Global Constraints；Task 3、4 只依賴 `pane`、`state`、`reason`、`message`、`ts`、`since`。
- 路由放在 `_init` 之前判斷也可以，但 `_init` 只做 mkdir，不需特殊處理；`_check_cmd` 不可用（缺 python3 時會 exit 1），改為 `command -v python3 || exit 0`。

- [ ] **Step 1: 寫失敗測試**（每個測試以 `TMUX_PANE=%7` 呼叫，讀 `$HOME/.tmux-manager/state/7.json`，用 `jq -r` 取欄位）

```bash
test_idle_writes_file() {
  echo '{"session_id":"s1","cwd":"/tmp/p","hook_event_name":"Stop"}' \
    | TMUX_PANE=%7 "$TM" hook-state idle
  f="$HOME/.tmux-manager/state/7.json"
  assert_eq 1 "$(jq -r .v "$f")" v
  assert_eq "%7" "$(jq -r .pane "$f")" pane
  assert_eq claude "$(jq -r .agent "$f")" agent
  assert_eq idle "$(jq -r .state "$f")" state
  assert_eq Stop "$(jq -r .event "$f")" event
  assert_eq /tmp/p "$(jq -r .cwd "$f")" cwd
  assert_eq null "$(jq -r .reason "$f")" reason
  assert_eq null "$(jq -r .message "$f")" message
  [[ "$(jq -r .ts "$f")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail ts-format
  assert_eq 600 "$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f")" mode
}
test_since_kept_when_state_unchanged()   # 寫 working → sleep 1 → 寫 working：since 不變、ts 變新
test_since_reset_on_state_change()       # working → sleep 1 → idle：since == ts
test_blocked_permission_by_type()        # {"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"} → reason=permission，message 原樣保存
test_blocked_input_by_type()             # idle_prompt → reason=input
test_blocked_fallback_by_message()       # 無 notification_type、message "Claude needs your permission to use Bash" → permission；"Claude is waiting for your input" → input
test_ignored_notification_type()         # auth_success → 不建立檔案（或既有檔案內容不變）
test_no_tmux_pane_no_write()             # 未設 TMUX_PANE → exit 0、state 目錄沒有檔案
test_invalid_payload_still_writes()      # stdin "not json" 與空 stdin → exit 0；state=working、session_id/cwd/event 為 null
test_invalid_state_arg()                 # hook-state bogus → exit 3、stderr 含 "Usage"、不寫檔
test_reason_cleared_after_blocked()      # blocked → working：reason 與 message 回到 null
```

- [ ] **Step 2:** Run `bash tests/test_hook_state.sh`，Expected：全部 FAIL（`Unknown command or session: hook-state`）。
- [ ] **Step 3: 實作 `_cmd_hook_state()`**：bash 檢查 `$1` 合法（否則 Usage 到 stderr、exit 3）、`$TMUX_PANE` 非空、`python3` 存在；其餘交給一段 python：讀舊檔（讀不到或壞掉當作無舊狀態）、套用 Notification 規則、組新 dict、`tempfile.mkstemp(dir=STATE_DIR)` → 寫入 → `os.chmod 0600` → `os.replace`；`os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)`。python 外層 `try/except Exception: pass`，bash 端 `|| true`，函式 `return 0`。
- [ ] **Step 4:** Run `bash tests/test_hook_state.sh`，Expected：全部 PASS。
- [ ] **Step 5: 量測效能**（決定 PreToolUse 是否需要短路，對應待確認問題 3）

```bash
time (for i in $(seq 20); do echo '{}' | TMUX_PANE=%7 "$TM" hook-state working; done)
```
Expected：平均每次 < 50 ms。超過時，在 bash 端先比對舊檔：舊檔含 `"state": "working"` 且參數為 `working` 時只做 `touch` 不跑 python，並在 `ts` 欄位說明改為「讀取時以檔案 mtime 為準」——此情況需先回報再改，因為會影響 Task 3 的 stale 判斷。把量測結果寫進 commit message。
- [ ] **Step 6:** `_cmd_help` 不列 `hook-state`（給 hook 用）；在 `install-claude-hook` 那行改為 `Install Claude session ID and agent state hooks`。
- [ ] **Step 7:** Commit（`tm.sh`、`tests/test_hook_state.sh`）：`feat: add hook-state to record agent state per pane`

### Task 2: 擴充 `tm install-claude-hook`

**Files:**
- Modify: `tm.sh` 的 `_cmd_install_claude_hook`
- Create: `tests/test_install_hook.sh`

**Interfaces:**
- Consumes：Task 1 的 `hook-state` 子指令名稱。
- Produces：`~/.claude/settings.json` 的 `hooks` 下，6 個事件各有一個 group：`{"hooks":[{"type":"command","command":"<quoted SELF> hook-state <state>"}]}`；既有 `_record-claude-session` 的 SessionStart group 保留。

- [ ] **Step 1: 寫失敗測試**

```bash
test_install_adds_all_events() {
  "$TM" install-claude-hook
  s="$HOME/.claude/settings.json"
  for pair in SessionStart:idle UserPromptSubmit:working PreToolUse:working \
              Notification:blocked Stop:idle SessionEnd:dead; do
    ev=${pair%%:*}; st=${pair##*:}
    n=$(jq --arg st "hook-state $st" "[.hooks.$ev[].hooks[].command | select(endswith(\$st))] | length" "$s")
    assert_eq 1 "$n" "$ev"
  done
  assert_eq 1 "$(jq '[.hooks.SessionStart[].hooks[].command | select(contains("_record-claude-session"))] | length' "$s")" recorder
}
test_install_idempotent()                # 跑兩次：每事件仍只有 1 筆；第二次 stdout 含 "already installed"；只產生 1 個 .tm-backup-*（第一次因為檔案已存在才有）
test_install_preserves_user_hooks()      # 預先放入 PreToolUse 的使用者自訂 hook（matcher "Bash"）→ 安裝後仍在，且原有其他頂層 key（如 "model"）不變
test_install_upgrades_old_install()      # 預先只有舊版的 _record-claude-session → 安裝後補齊 6 事件，recorder 不重複
test_install_rejects_malformed_event()   # hooks.Stop = "x" → exit 非 0、stderr 含 "hooks.Stop must be an array"、settings.json 內容不變、沒有 .tm-backup-*
```

- [ ] **Step 2:** Run `bash tests/test_install_hook.sh`，Expected：FAIL。
- [ ] **Step 3: 改 python 段**：把單一事件改成清單 `[("SessionStart","_record-claude-session" 指令), ("SessionStart","hook-state idle"), ...]`；先驗證所有用到的事件都是 list（任一不合法就整體失敗、不寫檔），再逐項檢查「已有 command 以該字串結尾的 hook」則略過；全部略過時印 `Claude hooks are already installed` 並 exit 0；否則備份一次、原子寫入，印出新增的事件清單。
- [ ] **Step 4:** Run `bash tests/test_install_hook.sh` 與 `bash tests/test_hook_state.sh`，Expected：PASS。
- [ ] **Step 5:** Commit（`tm.sh`、`tests/test_install_hook.sh`）：`feat: install agent state hooks for all Claude events`

### Task 3: fzf 列表的狀態欄、blocked 置頂、stale

**Files:**
- Modify: `tm.sh`：常數區、新增 `_agent_states`、`_build_list_cache`、`_format_session_line`、`_cmd_list`、`_cmd_help`（環境變數段）
- Create: `tests/test_list_state.sh`

**Interfaces:**
- Consumes：Task 1 狀態檔欄位 `pane`、`state`、`ts`、`since`。
- Produces：
  - `readonly STALE_AFTER="${TM_STALE_AFTER:-1800}"`（秒；非正整數時當 1800）
  - `_agent_states <session|pane>`：stdin 每行 `session_name\tpane_id\tsession_created\twindow_index.pane_index`（tab 分隔）。
    - `session` 模式輸出每行 `session_name\tagg_state`，`agg_state` ∈ `blocked`、`working?`、`working`、`idle`、`unknown`；優先序 blocked > working? > working > idle > unknown；沒有任何有效狀態檔的 session 也要輸出 `unknown`。
    - `pane` 模式輸出每行 `target\tpane_id\tstate\tsince_epoch\treason\tmessage`，只輸出有有效狀態檔的 pane；`reason`、`message` 為空時輸出 `-`；`message` 內的 `\t`、`\r`、`\n` 換成空白。
    - 有效狀態檔：可解析為 JSON object、`state` 為四個合法值之一、`ts` 不早於 `session_created`。`dead` 視同 `unknown`。`working` 且 `now - ts > STALE_AFTER` → `working?`。
  - `_CACHED_AGENT_STATE`：`_build_list_cache` 內以一次 `tmux list-panes -a -F` 餵給 `_agent_states session` 的結果。
  - `_session_agent_state <name>`：從快取查 `agg_state`，查無則 `unknown`。
  - `_state_icon <agg_state>`：`blocked`→`❓`、`working`→`⏳`、`working?`→`⏳?`、`idle`→`💤`、其他→`·`。

- [ ] **Step 1: 寫失敗測試**（`tmux new-session -d -s a`、`-s b`；用 `tmux display -p -t a '#{pane_id}'` 取 pane id，以 `TMUX_PANE=<id> "$TM" hook-state <state>` 寫入；`COLUMNS=200 "$TM" _list` 取輸出）

```bash
test_icons_per_state()                   # a=blocked、b=working → a 那行含 "❓"、b 那行含 "⏳"
test_unknown_without_state()             # 沒有狀態檔 → 該行含 "·"
test_blocked_sorted_first()              # detached session 的 last_attached 皆為 0，既有排序下 b 在 a 前；a 寫 blocked → header 之後第一行為 a
test_tm_sort_recent_keeps_order()        # 同上設定加 TM_SORT=recent → 第一行仍為 b
test_aggregate_prefers_blocked()         # session a 開第二個 pane（split-window），pane1=idle、pane2=blocked → a 顯示 "❓"
test_stale_working()                     # TM_STALE_AFTER=1；寫 working；sleep 2 → 顯示 "⏳?"
test_dead_shows_unknown()                # 寫 dead → "·"
test_state_older_than_session_is_ignored()  # 直接寫檔，ts="2000-01-01T00:00:00Z"、state=blocked → "·"
test_corrupt_state_file_is_unknown()     # 檔案內容 "{not json" 與空檔 → exit 0、"·"
test_header_has_st()                     # 第 1 行（header）含 "ST"
```

- [ ] **Step 2:** Run `bash tests/test_list_state.sh`，Expected：FAIL。
- [ ] **Step 3:** 實作 `_agent_states`（python3，讀 `STATE_DIR/*.json`、比對 stdin 的 pane）、`_build_list_cache` 加一次呼叫、`_format_session_line` 在 `status` 後接 ` $(_state_icon ...)`（純 bash，不 fork）、header 第 1 欄改為 `ST`（寬度與既有第 1 欄對齊）。python3 不存在時 `_CACHED_AGENT_STATE` 為空、全部 `unknown`，列表照常。
- [ ] **Step 4:** `_cmd_list` 排序：`TM_SORT` 不是 `recent` 時，先依 `agg_state == blocked` 分兩組（blocked 在前），組內維持既有 `session_last_attached` 由新到舊；在現有 `sort -t';' -k5,5 -rn` 之後以 bash 迴圈兩趟輸出，不新增 fork。
- [ ] **Step 5:** Run `bash tests/test_list_state.sh`，Expected：PASS；並跑 `bash tests/run.sh` 確認前面的 task 仍 PASS。
- [ ] **Step 6:** 手動檢查：在真實 tmux 執行 `./tm.sh`，fzf 欄位對齊、Enter／Ctrl-K／Ctrl-E 仍取到正確 session 名（`{2}` 未位移）。
- [ ] **Step 7:** `_cmd_help` 環境變數段加入 `TM_SORT`（`recent` 停用 blocked 置頂）與 `TM_STALE_AFTER`（秒，預設 1800）。
- [ ] **Step 8:** Commit（`tm.sh`、`tests/test_list_state.sh`）：`feat: show agent state column and float blocked sessions`

### Task 4: Preview 的 agent 區塊、`tm save` 清理孤兒狀態檔、README

**Files:**
- Modify: `tm.sh` 的 `_cmd_preview`、`_cmd_save`
- Modify: `README.md`、`README.zh-TW.md`
- Create: `tests/test_preview_save.sh`

**Interfaces:**
- Consumes：Task 3 的 `_agent_states pane`、`_state_icon`、既有 `_relative_time`（吃 epoch）。
- Produces：preview 在「Session Details」之後新增 `── Agents ──` 區塊；沒有任何有效狀態檔時整個區塊不顯示。每個 pane 一行：`<icon> <window.pane> <state>[ (reason)] · <relative since>`，blocked 且有 message 時下一行縮排顯示 message。

- [ ] **Step 1: 寫失敗測試**

```bash
test_preview_shows_blocked_agent()       # pane 寫 blocked（permission_prompt，message "Claude needs your permission to use Bash"）→ `"$TM" _preview a` 含 "── Agents"、"❓"、"blocked (permission)"、該 message
test_preview_hides_section_without_state()  # 無狀態檔 → 不含 "── Agents"
test_preview_message_single_line()       # message "line1\nline2\tx" → preview 中 "line1 line2 x" 出現在同一行
test_save_removes_orphan_state()         # 直接放 state/99999.json（不存在的 pane）與一個真實 pane 的狀態檔 → `"$TM" save` 後前者不存在、後者仍在；stdout 含 "Removed 1 orphan state file"
test_save_keeps_state_when_none_orphan() # 無孤兒 → 不印 Removed 訊息
```

- [ ] **Step 2:** Run `bash tests/test_preview_save.sh`，Expected：FAIL。
- [ ] **Step 3:** 實作 preview 區塊：`tmux list-panes -t "$name" -s -F` 產生 `_agent_states` 需要的 4 欄輸入，依輸出逐行印。
- [ ] **Step 4:** 實作孤兒清理：`_cmd_save` 結尾以一次 `tmux list-panes -a -F '#{pane_id}'` 取得存活 pane，python 段刪除 `STATE_DIR` 中 `%<檔名>` 不在清單內的 `*.json`，回傳刪除數量；數量 > 0 時印 `Removed N orphan state file(s)`。`tm save` 由 cron 執行，清理失敗只印警告到 stderr，不影響 snapshot 結果與 exit code。
- [ ] **Step 5:** Run `bash tests/run.sh`，Expected：全部 PASS。
- [ ] **Step 6:** README（中英各一）：在 `install-claude-hook` 段落補「同時安裝 agent 狀態 hooks」、狀態圖示表、blocked 置頂與 `TM_SORT`、`TM_STALE_AFTER`；安裝後需重啟既有 Claude session 才會載入新 hook。
- [ ] **Step 7:** Commit（`tm.sh`、`tests/test_preview_save.sh`、`README.md`、`README.zh-TW.md`）：`feat: show agent states in preview and clean orphan state files`

### Task 5: 收尾

- [ ] **Step 1:** 在 spec 的「實作順序」把 PR 1 勾選；「待確認問題」1、2 註記本計畫的決定，3 填入 Task 1 Step 5 的量測結果。
- [ ] **Step 2:** 真機驗證：`./tm.sh install-claude-hook` 後開新的 Claude session，依序觸發送 prompt（⏳）、權限確認（❓ permission）、完成（💤）、`/exit`（·），截圖或記錄 `state/*.json` 的轉變。
- [ ] **Step 3:** Commit（`docs/design/agent-state-and-orchestration.md`）：`docs: mark PR 1 done and record decisions`
