# 延後 Minor 清理（PR 5）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修掉 PR 1～4 最終 review 延後的 Minor 問題，不新增功能，也不改變已文件化的行為（新增的 exit 5 除外）。

**Architecture:** 依程式區塊分成 6 個 Task：狀態檔與 hook 的健壯性、agent 偵測與 `tm ls --json`、`tm wait`、fzf 相關（dash、preview、state-count）、hook 安裝器、文件。每個修正先寫一個重現問題的測試，看它失敗，再修。

**Tech Stack:** Bash（相容 macOS 內建 3.2）、python3 標準函式庫（`-I -S`）、tmux 3.x、repo 內附的 fzf 0.68.0、`tests/` 下的純 bash 測試。

**Spec:** `docs/design/agent-state-and-orchestration.md`（第 1～4 節及各「PR N 決定」）。問題來源是各 PR 計畫的 ledger 裡 `minor (deferred)` 的項目，已整理在下方清單。

## Global Constraints

- Hook 每次寫入 < 50 ms，hook 執行期任何錯誤都 exit 0，只有 state 參數不合法時 exit 3（PR 1）。
- `tm ls --json`：stdout 只放 JSON；exit 0 成功、2 session 不存在、3 參數錯誤、4 tmux server 未啟動；`v` 不升版（PR 2）。
- `tm wait`：exit 0 達成、1 逾時、2 target 不存在或 agent 結束、3 參數錯誤、130 SIGINT、143 SIGTERM（PR 3）。
- `tm state-count` 任何錯誤都輸出空字串、exit 0，只有參數錯誤 exit 3（PR 4）。
- 刪除只限程式自己建立、可確認歸屬的檔案（狀態檔、`.tmp`、dash 的 `run/` 檔案）。

## 問題清單與處理方式

| 編號 | 來源 | 問題 | 處理 |
|------|------|------|------|
| A1 | PR 1 | hook 寫入中途崩潰會留下 `<pane>.json.<pid>.tmp` | Task 1：`tm save` 一併清掉超過 60 秒的 `.tmp` |
| A2 | PR 1 | `_init` 在 HOME 無法寫入時 exit 1，連 `hook-state` 也跟著失敗 | Task 1：`hook-state` 在 `_init` 之前 route |
| A3 | PR 2 M2 | 結構極度巢狀的狀態檔讓 `load_state` 拋出 `RecursionError` | Task 1 |
| A4 | PR 2 M4 | `reason`、`message`、`session_id` 不檢查型別，原樣輸出 | Task 1：在 `load_state` 統一處理，非字串一律 `None` |
| B1 | PR 2 M1 | `less claude`、`ssh codex` 被判成 agent | Task 2 |
| B2 | PR 2 M3 | session 路徑含 tab 時，整個 session 消失 | Task 2 |
| B3 | PR 2 M5 | `--state '*'` 會做萬用字元展開 | Task 2 |
| B4 | PR 2 M6 | C1 控制字元（U+0080–U+009F）原樣寫到 stdout | Task 2 |
| B5 | PR 2 M7 | `--agent` 接受任何值 | Task 2：只接受 `claude`、`codex`，其他 exit 3 |
| C1 | PR 3 M1 | `--until dead --match all` 只印出最後一個結束的 agent | Task 3 |
| C2 | PR 3 M2 | `--timeout ""` 等於不逾時 | Task 3 |
| C3 | PR 3 M3 | 超大的 `--timeout` 讓 bash 算術溢位 | Task 3 |
| C4 | PR 3 M4 | python 內部錯誤也回 exit 1，跟逾時分不出來 | Task 3：改回 exit 5 |
| C5 | PR 3 M7 | SIGINT 剛好在啟動 `inotifywait` 時送達，子行程會殘留 | Task 3 |
| D1 | PR 4 M1 | `state-count --format` 沒給值時回 1 而不是 3 | Task 4 |
| D2 | PR 4 M2 | 連結到兩個 session 的 window 被算兩次 | Task 4 |
| D3 | PR 4 M4 | fzf action 裡的 `$SELF` 沒加引號，路徑含空白或 `)` 時壞掉 | Task 4：主選單與 dash 一起改 |
| D4 | PR 4 M5 | dash 被 `kill -9` 後，`run/` 的檔案留下來 | Task 4：dash 啟動時清掉 pid 已不存在的檔案 |
| D5 | PR 1 | preview 用 `echo -e` 印 target 與 reason，session 名稱裡的 `\` 會被解讀 | Task 4 |
| E1 | PR 1 | 安裝器只比對指令結尾，tm.sh 換位置後舊路徑不會更新 | Task 5 |
| F1 | PR 4 M3 | 文件寫「最後 15 個非空白行」，跟程式不符 | Task 6 |
| F2 | PR 3 M6 | README 與 help 沒寫 SIGTERM 回 143 | Task 6 |
| — | PR 1 | `join-pane` 搬到別的 session 的 pane，在下一個 hook 前顯示 `unknown` | **不修**：tmux 沒有 pane 建立時間可比對；下一個 hook 寫入就恢復，影響短暫 |
| — | PR 1 | `_session_agent_state` 是 O(n²) | **不修**：30 個 session 時影響不到 1 ms，改寫會動到 bash 3.2 不支援的 associative array |
| — | PR 4 M6 | 「Enter 選取 session」沒有自動化測試 | **不修**：需要真的 tmux client 連線，已在手動測試文件 14-7 涵蓋 |

## 本計畫補上的決定

| 項目 | 決定 | 理由 |
|------|------|------|
| B1 的直譯器清單 | 第 1 個 token 的 basename 是 `node`、`bun`、`deno`、`bash`、`sh`、`zsh`、`env`、`npx`，或符合 `python[0-9.]*` 時，才看第 2 個 token；否則只看第 1 個 | 涵蓋 npm 安裝（`node …/claude`）、`npx`、測試用的 `/bin/bash …/claude`；`less claude`、`ssh codex` 不再誤判 |
| B4 | 序列化後把 U+0080–U+009F 換成 `\u00XX` | 不改 `ensure_ascii=False`，中文仍維持可讀 |
| B5 | `--agent` 只接受 `claude`、`codex` | 目前只偵測這兩種；之後新增 agent 時一起擴充 |
| C3 | `--timeout` 的數字最多 7 位（`9999999h` 約 1141 年） | 不會溢位，也不會限制到實際用途 |
| C4 | 未預期的例外：stderr 印一行 `✗ tm wait internal error: <例外類別>`，exit 5 | 5 是新的 exit code，不與 0～3、130、143 衝突；Leader 不會把它當成「仍在 working」 |
| C5 | 啟動 `inotifywait` 前後用 `signal.pthread_sigmask` 擋住 SIGINT 與 SIGTERM，`watcher` 指派完成後才解除 | 解除後，被擋住的信號會立刻送達，`stop()` 這時已能看到子行程 |
| D2 | `state-count` 以 pane id 去重 | 同一個 pane 只算一次 |
| D3 | 用 `printf -v _SELF_Q '%q' "$SELF"` 產生一次跳脫過的路徑，所有 fzf action 改用 `$_SELF_Q` | fzf 以 `$SHELL -c` 執行 action，`%q` 的結果對 sh、bash、zsh 都安全 |
| D4 | dash 啟動時，清掉 `run/dash-<pid>.{sock,out,list}` 中 pid 已不存在、或 pid 不是 `tm.sh dash` 的檔案 | 只清 dash 自己的命名格式；pid 被重用時，看行程參數判斷 |
| E1 | 以 `shlex.split` 解析既有指令：第 1 個 token 的 basename 是 `tm.sh`，其餘 token 與 suffix 相同，就算 tm 的 hook。路徑相同 → 已安裝；路徑不同 → 改成目前的路徑，並列為 `updated` | 使用者換過 tm.sh 位置（例如 worktree 移除後）時不必手改 `settings.json` |
| E1 輸出 | 有新增或更新時印出清單（`Added: …`、`Updated: …`）與備份路徑；都沒有時維持 `Claude hooks are already installed` | 沿用既有格式 |

## 檔案結構

| 檔案 | 動作 | 職責 |
|------|------|------|
| `tm.sh` | 修改 | 所有修正 |
| `tests/test_hook_state.sh`、`tests/test_preview_save.sh` | 修改 | Task 1、4 |
| `tests/test_ls_json.sh` | 修改 | Task 1、2 |
| `tests/test_wait.sh` | 修改 | Task 3 |
| `tests/test_state_count.sh`、`tests/test_dash.sh` | 修改 | Task 4 |
| `tests/test_install_hook.sh` | 修改 | Task 5 |
| `README.md`、`README.zh-TW.md`、`docs/design/agent-state-and-orchestration.md` | 修改 | Task 6 |

## Review Focus

1. **hook 路徑更新**：`settings.json` 裡同時有 tm 的 hook 和使用者自己的 hook，而且使用者的 hook 指令剛好以 `hook-state idle` 結尾（例如自己寫的包裝腳本）。期望只更新第 1 個 token 是 `tm.sh` 的項目，使用者的 hook 不動。→ Task 5 `test_installer_leaves_foreign_hooks`。
2. **路徑含空白的安裝位置**：`/Users/x/My Tools/tm.sh`。期望主選單和 dash 的 reload、preview、Ctrl 快捷鍵都正常。→ Task 4 `test_dash_with_space_in_path`。
3. **pid 被重用**：dash 被 `kill -9` 後，同一個 pid 被別的行程拿去用。期望啟動時不會誤刪仍在執行的其他 dash 的檔案。→ Task 4 `test_dash_keeps_files_of_live_dash`。
4. **安裝器遇到格式異常的既有指令**（例如引號沒關、`command` 不是字串）：期望跳過該項目，不中斷整個安裝。→ Task 5 `test_installer_skips_unparsable_command`。
5. **Agent 偵測放寬範圍後的漏判**：npm 全域安裝的 Claude（`node /usr/local/bin/claude`）仍要偵測到。→ Task 2 `test_node_launched_agent_detected`。

---

### Task 1: 狀態檔與 hook 的健壯性（A1–A4）

**Files:**
- Modify: `tm.sh`（`_PY_STATE_LIB` 的 `load_state`、`_clean_orphan_states`、self-routing）
- Test: `tests/test_hook_state.sh`、`tests/test_ls_json.sh`、`tests/test_preview_save.sh`

**Interfaces:**
- Produces:
  - `load_state` 回傳的 `record` 中，`reason`、`message`、`session_id`、`agent` 不是字串時改成 `None`
  - 所有讀取者都不會因為狀態檔內容拋出例外

- [ ] **Step 1: 寫失敗的測試**

```bash
# tests/test_preview_save.sh
test_save_removes_stale_tmp_files() {
  new_session a
  set_state a idle '{}'
  local stale="$STATE_DIR/$(pane_id a | tr -d %).json.99999.tmp" fresh="$STATE_DIR/1.json.88888.tmp"
  echo '{' > "$stale"; echo '{' > "$fresh"
  touch -t 202001010000 "$stale"
  "$TM" save >/dev/null
  [[ ! -e "$stale" ]] || fail "stale tmp kept"
  [[ -e "$fresh" ]] || fail "fresh tmp removed (a hook may be writing it)"
}

# tests/test_hook_state.sh
test_hook_ignores_unwritable_home() {
  local ro="$TEST_TMP/ro-home"; mkdir -p "$ro"; chmod 500 "$ro"
  local code
  printf '{}' | HOME="$ro" TMUX_PANE=%1 "$TM" hook-state idle; code=$?
  chmod 700 "$ro"
  assert_eq 0 "$code" exit
}

# tests/test_ls_json.sh
test_deeply_nested_state_file() {
  agent_pane new a
  mkdir -p "$STATE_DIR"
  python3 -c 'print("[" * 100000)' > "$STATE_DIR/$(pane_id a | tr -d %).json"
  local out code; out=$("$TM" ls --json 2>/dev/null); code=$?
  assert_eq 0 "$code" exit
  assert_eq heuristic "$(json 'd["sessions"][0]["agents"][0]["source"]' <<< "$out")" source
  assert_contains "$("$TM" _list)" "a" fzf-list-still-works
}

test_non_string_fields_become_null() {
  agent_pane new a
  set_state a blocked
  local f; f="$STATE_DIR/$(pane_id a | tr -d %).json"
  python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d.update(reason={"x": 1}, message=5, session_id=[1]); json.dump(d, open(p, "w"))
PY
  local out; out=$("$TM" ls --json)
  assert_eq '[null, null, null]' \
    "$(json '[d["sessions"][0]["agents"][0][k] for k in ("reason", "message", "session_id")]' <<< "$out")" nulls
}
```

- [ ] **Step 2: 執行，確認失敗**

Run: `bash tests/test_preview_save.sh; bash tests/test_hook_state.sh; bash tests/test_ls_json.sh`
Expected: 上面 4 個測試失敗（tmp 檔還在、exit 1、traceback 且 exit 1、輸出原始型別）

- [ ] **Step 3: 實作**

- `_clean_orphan_states` 的 python 加上：`glob("*.json.*.tmp")` 中 mtime 超過 60 秒的刪除，計入 removed。
- routing：`hook-state)` 那一行移到 `_init` 之前的 `case`，其餘不變。
- `load_state`：`json.load` 的 except 加上 `RecursionError`；回傳前把 4 個欄位中非字串的值換成 `None`（`record` 是新 dict，不改檔案）。

- [ ] **Step 4: 執行，確認通過**

Run: `bash tests/run.sh`
Expected: 全數通過

- [ ] **Step 5: Commit**

```bash
git add tm.sh tests/test_hook_state.sh tests/test_ls_json.sh tests/test_preview_save.sh
git commit -m "fix: harden state file readers and the hook against bad files and an unwritable HOME" -- tm.sh tests/test_hook_state.sh tests/test_ls_json.sh tests/test_preview_save.sh
```

---

### Task 2: Agent 偵測與 `tm ls --json`（B1–B5）

**Files:**
- Modify: `tm.sh`（`_PY_SNAPSHOT_LIB` 的 `detect_agent` 與 tmux 欄位順序、`_cmd_ls`、`_ls_json`）
- Test: `tests/test_ls_json.sh`

- [ ] **Step 1: 寫失敗的測試**

```bash
test_program_with_agent_argument_is_not_agent() {
  printf 'x\n' > "$TEST_TMP/claude"; printf 'x\n' > "$TEST_TMP/codex"
  # ps shows "less claude": a pager is not an interpreter
  tmux new-session -d -s a -c "$TEST_TMP" "less claude"
  tmux new-session -d -s b -c "$TEST_TMP" "less codex"
  sleep 0.5
  assert_eq '[[], []]' "$("$TM" ls --json | json '[s["agents"] for s in d["sessions"]]')" not-agents
}

test_node_launched_agent_detected() {
  # perl renamed to node runs the script and keeps argv as "node <path>/claude"
  mkdir -p "$TEST_TMP/nodebin"
  ln -s "$(command -v perl)" "$TEST_TMP/nodebin/node"
  printf 'sleep 600;\n' > "$TEST_TMP/claude"
  tmux new-session -d -s a -c "$TEST_TMP" "$TEST_TMP/nodebin/node $TEST_TMP/claude"
  sleep 0.5
  assert_eq claude "$("$TM" ls --json | json 'd["sessions"][0]["agents"][0]["agent"]')" node-claude
}

test_session_path_with_tab() {
  mkdir -p "$TEST_TMP/wo"$'\t'"rk"
  tmux new-session -d -s tabdir -c "$TEST_TMP/wo"$'\t'"rk" "sleep 600"
  assert_eq "$TEST_TMP/wo"$'\t'"rk" "$("$TM" ls --json --session tabdir | json 'd["sessions"][0]["dir"]')" dir
}

test_state_value_not_globbed() {
  new_session a
  touch "$TEST_TMP/claude"
  local err; err=$(cd "$TEST_TMP" && "$TM" ls --json --state '*' 2>&1 >/dev/null)
  assert_contains "$err" "Invalid state: *" literal
}

test_c1_controls_escaped() {
  agent_pane new a
  set_state a blocked "{\"notification_type\":\"permission_prompt\",\"message\":\"x$(printf '\xc2\x9b')31my\"}"
  local raw; raw=$("$TM" ls --json)
  assert_not_contains "$raw" "$(printf '\xc2\x9b')" raw-c1
  assert_contains "$raw" '\u009b' escaped
}

test_unknown_agent_type_exit_3() {
  new_session a
  local code; "$TM" ls --json --agent Claude >/dev/null 2>&1; code=$?
  assert_eq 3 "$code" exit
}
```

- [ ] **Step 2: 執行，確認失敗**

Run: `bash tests/test_ls_json.sh`
Expected: 上面 6 個測試中，除了 `test_node_launched_agent_detected` 以外都失敗；這一個目前就會通過，因為現在的規則看任意第 2 個 token。它是收緊規則後的保護網，Step 4 要確認仍然通過。

- [ ] **Step 3: 實作**

- `detect_agent` 依決定表的直譯器清單判斷。
- tmux `-F` 欄位把 `session_path` 移到最後，解析時用 `line.split("\t", len(fields) - 1)`。
- `_cmd_ls` 的 `--state` 檢查改成 `IFS=, read -r -a` 拆成陣列，不再經過萬用字元展開；`--agent` 只接受 `claude`、`codex`。
- `_ls_json` 用 `json.dumps` 取得字串，把 U+0080–U+009F 換成 `\u00XX` 後再寫出；`tm wait` 與 `_notify` 的輸出也要套同一個函式。這個函式放在 `_PY_SNAPSHOT_LIB`，名稱為 `dumps_safe(obj) -> str`。

- [ ] **Step 4: 執行，確認通過**

Run: `bash tests/run.sh`
Expected: 全數通過

- [ ] **Step 5: Commit**

```bash
git add tm.sh tests/test_ls_json.sh
git commit -m "fix: tighten agent detection and ls --json input and output handling" -- tm.sh tests/test_ls_json.sh
```

---

### Task 3: `tm wait`（C1–C5）

**Files:**
- Modify: `tm.sh`（`_cmd_wait`）
- Test: `tests/test_wait.sh`

**Interfaces:**
- Consumes: Task 2 的 `dumps_safe`
- Produces: 新的 exit 5（內部錯誤）

- [ ] **Step 1: 寫失敗的測試**

```bash
test_until_dead_all_prints_every_agent() {
  agent_pane new a
  agent_pane split a
  set_state a:0.0 idle; set_state a:0.1 idle
  local p0 p1
  p0=$(tmux display-message -p -t a:0.0 '#{pane_pid}'); p1=$(tmux display-message -p -t a:0.1 '#{pane_pid}')
  # Killing a pane's process closes the pane; the second one ends the session
  later 0.5 kill "$p0"
  later 1.5 kill "$p1"
  local out; out=$("$TM" wait a --until dead --match all --interval 0.2 --timeout 6s)
  wait
  assert_eq 2 "$(printf '%s\n' "$out" | grep -c '"dead"')" both-printed
}

test_empty_or_huge_timeout_exit_3() {
  new_session a
  local args code
  for args in "--timeout=" "--timeout 99999999h"; do
    # shellcheck disable=SC2086
    "$TM" wait a --until idle $args >/dev/null 2>&1; code=$?
    assert_eq 3 "$code" "args <$args>"
  done
  "$TM" wait a --until idle --timeout "" >/dev/null 2>&1; code=$?
  assert_eq 3 "$code" empty-separate-arg
}

# A closed stdout makes writing the result fail: an internal error, not a timeout
test_internal_error_exit_5() {
  agent_pane new a
  set_state a idle
  local code; "$TM" wait a --until idle --timeout 2s >&- 2>/dev/null; code=$?
  assert_eq 5 "$code" exit
}
```

C5（Popen 期間的 SIGINT）只有在極短的時間窗內才會發生，沒辦法穩定重現，不寫自動化測試；實作後在 ledger 記錄「以程式碼審閱驗證」。

- [ ] **Step 2: 執行，確認失敗**

Run: `bash tests/test_wait.sh`
Expected: 3 個新測試失敗（只印出 1 行；空值或超大值 exit 0 或 1；stdout 關閉時 traceback 並 exit 1）

- [ ] **Step 3: 實作**

- dead 的 agent 累積到一個串列；`--until dead` 達成時全部印出。
- bash：`--timeout` 給了值就必須非空；regex 改成 `^([1-9][0-9]{0,6})([smh]?)$`。
- python 主迴圈用 `try/except Exception` 包起來，依決定表 exit 5；`SystemExit` 不攔。
- `sleep_until_next`：`Popen` 前 `signal.pthread_sigmask(SIG_BLOCK, {SIGINT, SIGTERM})`，`watcher` 指派後 `SIG_UNBLOCK`。
- `emit` 改用 `dumps_safe`。

- [ ] **Step 4: 執行，確認通過**

Run: `bash tests/run.sh`
Expected: 全數通過

- [ ] **Step 5: Commit**

```bash
git add tm.sh tests/test_wait.sh
git commit -m "fix: report every dead agent, validate --timeout and exit 5 on internal errors in tm wait" -- tm.sh tests/test_wait.sh
```

---

### Task 4: fzf 相關（D1–D5）

**Files:**
- Modify: `tm.sh`（`_cmd_state_count`、`_fzf_menu`、`_cmd_dash`、`_dash_watch`、`_cmd_dash_reload`、`_cmd_preview`）
- Test: `tests/test_state_count.sh`、`tests/test_dash.sh`、`tests/test_preview_save.sh`

**Interfaces:**
- Produces: 全域變數 `_SELF_Q`（`printf -v _SELF_Q '%q' "$SELF"`，在常數區設定）

- [ ] **Step 1: 寫失敗的測試**

```bash
# tests/test_state_count.sh
test_format_without_value_exit_3() {
  local code; "$TM" state-count --format >/dev/null 2>&1; code=$?
  assert_eq 3 "$code" exit
}

test_linked_window_counted_once() {
  new_session a; new_session b
  set_state a blocked
  tmux link-window -s a:0 -t b:9
  assert_eq "❓1" "$("$TM" state-count --format plain)" once
}

# tests/test_preview_save.sh
test_preview_prints_backslashes_literally() {
  tmux new-session -d -s 'x\ty' -c "$TEST_TMP" "sleep 600"
  set_state 'x\ty' idle '{}'
  assert_contains "$("$TM" _preview 'x\ty')" 'x\ty:0.0' literal-target
}

# tests/test_dash.sh
test_dash_with_space_in_path() {
  mkdir -p "$TEST_TMP/my tools"
  cp "$TM" "$TEST_TMP/my tools/tm.sh"; ln -s "$REPO_ROOT/fzf" "$TEST_TMP/my tools/fzf"
  TM="$TEST_TMP/my tools/tm.sh"
  new_session a
  tmux new-session -d -s dash -x 120 -y 40 "'$TM' dash"
  local i; for i in $(seq 50); do DASH_SOCK=$(ls "$HOME"/.tmux-manager/run/dash-*.sock 2>/dev/null | head -1); [[ -n "$DASH_SOCK" ]] && break; sleep 0.1; done
  sleep 0.5
  set_state a blocked
  sleep 3
  assert_contains "$(fzf_state '[m["text"] for m in d["matches"]]')" "❓" reload-works
}

test_dash_sweeps_dead_dash_files() {
  mkdir -p "$HOME/.tmux-manager/run"
  local dead=99999; while kill -0 "$dead" 2>/dev/null; do dead=$((dead - 1)); done
  touch "$HOME/.tmux-manager/run/dash-$dead.out" "$HOME/.tmux-manager/run/dash-$dead.list"
  new_session a
  start_dash
  [[ ! -e "$HOME/.tmux-manager/run/dash-$dead.out" ]] || fail "stale out file kept"
}

test_dash_sweeps_reused_pid_files() {
  mkdir -p "$HOME/.tmux-manager/run"
  sleep 600 &
  local other=$!
  touch "$HOME/.tmux-manager/run/dash-$other.out"
  new_session a
  start_dash
  kill "$other"
  # The pid is alive but is not a tm dash, so the file is someone else's leftover
  [[ ! -e "$HOME/.tmux-manager/run/dash-$other.out" ]] || fail "file of a reused pid kept"
}

test_dash_keeps_files_of_live_dash() {
  new_session a
  start_dash
  local first="$DASH_SOCK"
  tmux new-session -d -s dash2 -x 120 -y 40 "$TM dash"
  sleep 1.5
  [[ -S "$first" ]] || fail "second dash removed the first dash's socket"
}
```

- [ ] **Step 2: 執行，確認失敗**

Run: `bash tests/test_state_count.sh; bash tests/test_preview_save.sh; bash tests/test_dash.sh`
Expected: 新測試失敗（exit 1、`❓2`、`\t` 被解讀成 tab、路徑含空白時 reload 失效、殘留檔案還在）

- [ ] **Step 3: 實作**

- `_cmd_state_count`：`--format` 後面沒有值 → exit 3；計數前以 pane id 去重（在 bash 迴圈用 `$'\n'` 串接的已見清單比對，相容 bash 3.2）。
- `_SELF_Q` 用在 `_fzf_menu` 的 preview 與所有 bind、`_dash_watch` 送出的 `transform:`、`_cmd_dash_reload` 的 `reload-sync(...)`。`cat '<list_file>'` 也改用 `printf %q` 跳脫。
- `_cmd_dash` 在建立 `run/` 後掃描 `dash-*.{sock,out,list}`，依決定表 D4 刪除。判斷「是不是 tm.sh dash」用 `ps -o args= -p <pid>`，比對是否包含 ` dash`。
- `_cmd_preview` 的兩行 `echo -e` 改成 `printf`：顏色碼用 `%s` 帶入，target 與 label 不經 escape 解讀。

- [ ] **Step 4: 執行，確認通過**

Run: `bash tests/run.sh`
Expected: 全數通過；另外在隔離 tmux 開一次主選單，確認 `Ctrl-R` 與 preview 正常（`_SELF_Q` 會影響主選單的所有 bind），結果記進 ledger

- [ ] **Step 5: Commit**

```bash
git add tm.sh tests/test_state_count.sh tests/test_dash.sh tests/test_preview_save.sh
git commit -m "fix: quote tm.sh in fzf actions, sweep stale dash files and tidy state-count and preview output" -- tm.sh tests/test_state_count.sh tests/test_dash.sh tests/test_preview_save.sh
```

---

### Task 5: hook 安裝器更新舊路徑（E1）

**Files:**
- Modify: `tm.sh`（`_cmd_install_claude_hook` 的 python）
- Test: `tests/test_install_hook.sh`

- [ ] **Step 1: 寫失敗的測試**

```bash
test_installer_updates_moved_tm_path() {
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'JSON'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/old/place/tm.sh hook-state idle"}]}]}}
JSON
  local out; out=$("$TM" install-claude-hook)
  assert_contains "$out" "Updated" reported
  python3 - "$HOME/.claude/settings.json" "$TM" <<'PY' || fail "Stop hook not updated"
import json, shlex, sys
d = json.load(open(sys.argv[1]))
cmds = [h["command"] for g in d["hooks"]["Stop"] for h in g["hooks"]]
assert cmds == [shlex.quote(sys.argv[2]) + " hook-state idle"], cmds
PY
}

test_installer_leaves_foreign_hooks() {
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'JSON'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/my/wrapper.sh hook-state idle"}]}]}}
JSON
  "$TM" install-claude-hook >/dev/null
  python3 - "$HOME/.claude/settings.json" "$TM" <<'PY' || fail "foreign hook changed or tm hook missing"
import json, shlex, sys
d = json.load(open(sys.argv[1]))
cmds = [h["command"] for g in d["hooks"]["Stop"] for h in g["hooks"]]
assert "/my/wrapper.sh hook-state idle" in cmds, cmds
assert shlex.quote(sys.argv[2]) + " hook-state idle" in cmds, cmds
PY
}

test_installer_skips_unparsable_command() {
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'JSON'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "'unclosed tm.sh hook-state idle"}, {"type": "command", "command": 7}]}]}}
JSON
  local code; "$TM" install-claude-hook >/dev/null 2>&1; code=$?
  assert_eq 0 "$code" exit
}
```

- [ ] **Step 2: 執行，確認失敗**

Run: `bash tests/test_install_hook.sh`
Expected：

- 失敗：`test_installer_updates_moved_tm_path`（舊路徑以結尾比對視為已安裝，沒有更新）、`test_installer_leaves_foreign_hooks`（使用者的包裝腳本以結尾比對被當成 tm 的 hook，所以沒有新增 tm 的 hook）。
- `test_installer_skips_unparsable_command` 可能已經通過，Step 4 要再確認一次。

- [ ] **Step 3: 實作**

依決定表 E1 改寫 `installed()`，回傳 `"same"`、`"other-path"` 或 `None`；`"other-path"` 時就地改寫該項目的 `command`。`shlex.split` 失敗（`ValueError`）或 `command` 不是字串時，視為不是 tm 的 hook。

- [ ] **Step 4: 執行，確認通過**

Run: `bash tests/run.sh`
Expected: 全數通過

- [ ] **Step 5: Commit**

```bash
git add tm.sh tests/test_install_hook.sh
git commit -m "fix: update tm hooks that point to an old tm.sh path on install-claude-hook" -- tm.sh tests/test_install_hook.sh
```

---

### Task 6: 文件（F1、F2 與本 PR 的行為變更）

**Files:**
- Modify: `README.md`、`README.zh-TW.md`、`tm.sh`（`_cmd_help`）、`docs/design/agent-state-and-orchestration.md`、`docs/testing/agent-state-manual-test.md`

- [ ] **Step 1: 修正與補充**

- F1：README 與設計文件裡「最後 15 個非空白行」改成「去掉結尾空白行後的最後 15 行」。
- F2：README 的 `tm wait` exit code 表與 `_cmd_help` 補上 `143`（SIGTERM）與 `5`（內部錯誤）。
- `tm ls --json` 參數表：`--agent` 只接受 `claude`、`codex`。
- `install-claude-hook` 的說明：會把指向舊 tm.sh 路徑的 hook 改成目前的路徑；手動測試文件第 9 步「安裝器只比對指令結尾」那段改寫。
- 設計文件新增「PR 5 決定」，摘要決定表與 3 個不修的項目。

- [ ] **Step 2: 跑完整測試**

Run: `bash tests/run.sh`
Expected: 全數通過

- [ ] **Step 3: Commit**

```bash
git add README.md README.zh-TW.md tm.sh docs/design/agent-state-and-orchestration.md docs/testing/agent-state-manual-test.md
git commit -m "docs: document the cleanup changes and exit codes" -- README.md README.zh-TW.md tm.sh docs/design/agent-state-and-orchestration.md docs/testing/agent-state-manual-test.md
```
