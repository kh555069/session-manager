#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# ─── Task 1: session fields ───────────────────────────

test_session_fields() {
  new_session a
  tmux new-window -d -t a "sleep 600"
  tmux split-window -d -t a:1 "sleep 600"
  local out; out=$("$TM" ls --json)
  assert_eq 1 "$(json 'd["v"]' <<< "$out")" v
  assert_eq '["generated_at", "host", "sessions", "v"]' "$(json 'sorted(d)' <<< "$out")" top-keys
  assert_eq '["agents", "clients", "dir", "git_branch", "last_activity", "name", "panes", "protected", "state", "summary", "windows"]' \
    "$(json 'sorted(d["sessions"][0])' <<< "$out")" session-keys
  assert_eq a "$(json 'd["sessions"][0]["name"]' <<< "$out")" name
  assert_eq 2 "$(json 'd["sessions"][0]["windows"]' <<< "$out")" windows
  assert_eq 3 "$(json 'd["sessions"][0]["panes"]' <<< "$out")" panes
  assert_eq 0 "$(json 'd["sessions"][0]["clients"]' <<< "$out")" clients
  assert_eq false "$(json 'd["sessions"][0]["protected"]' <<< "$out")" protected
  assert_eq null "$(json 'd["sessions"][0]["summary"]' <<< "$out")" summary
  assert_eq unknown "$(json 'd["sessions"][0]["state"]' <<< "$out")" state
  assert_eq '[]' "$(json 'd["sessions"][0]["agents"]' <<< "$out")" agents
  [[ "$(json 'd["generated_at"]' <<< "$out")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "generated_at format"
  [[ "$(json 'd["sessions"][0]["last_activity"]' <<< "$out")" =~ Z$ ]] || fail "last_activity format"
}

test_sessions_sorted_by_name() {
  new_session b; new_session a
  assert_eq '["a", "b"]' "$("$TM" ls --json | json '[s["name"] for s in d["sessions"]]')" order
}

test_protected_and_summary() {
  new_session a
  mkdir -p "$HOME/.tmux-manager/summaries"
  echo a > "$HOME/.tmux-manager/protected.txt"
  printf '%s\n' '{"ts":1,"summary":"old"}' '{"ts":2,"summary":"web \"dev\""}' > "$HOME/.tmux-manager/summaries/a.jsonl"
  local out; out=$("$TM" ls --json)
  assert_eq true "$(json 'd["sessions"][0]["protected"]' <<< "$out")" protected
  assert_eq 'web "dev"' "$(json 'd["sessions"][0]["summary"]' <<< "$out")" summary
}

test_corrupt_summary_is_null() {
  new_session a
  mkdir -p "$HOME/.tmux-manager/summaries"
  echo 'not json' > "$HOME/.tmux-manager/summaries/a.jsonl"
  local out code
  out=$("$TM" ls --json 2>/dev/null); code=$?
  assert_eq 0 "$code" exit
  assert_eq null "$(json 'd["sessions"][0]["summary"]' <<< "$out")" summary
}

test_git_branch() {
  mkdir -p "$TEST_TMP/repo/sub"
  git -C "$TEST_TMP/repo" init -q -b feat/x
  tmux new-session -d -s g -c "$TEST_TMP/repo/sub" "sleep 600"
  new_session plain
  local out; out=$("$TM" ls --json)
  assert_eq feat/x "$(json '[s for s in d["sessions"] if s["name"] == "g"][0]["git_branch"]' <<< "$out")" branch
  assert_eq null "$(json '[s for s in d["sessions"] if s["name"] == "plain"][0]["git_branch"]' <<< "$out")" no-repo
}

test_names_with_spaces_and_quotes() {
  mkdir -p "$TEST_TMP/my dir \"q\" 中文"
  tmux new-session -d -s 'my "s" 中' -c "$TEST_TMP/my dir \"q\" 中文" "sleep 600"
  local out; out=$("$TM" ls --json)
  assert_eq 'my "s" 中' "$(json 'd["sessions"][0]["name"]' <<< "$out")" name
  assert_eq "$TEST_TMP/my dir \"q\" 中文" "$(json 'd["sessions"][0]["dir"]' <<< "$out")" dir
}

test_no_server_exit_4() {
  local out code
  out=$("$TM" ls --json 2>/dev/null); code=$?
  assert_eq 4 "$code" exit
  assert_eq "" "$out" stdout-empty
}

test_plain_ls_unchanged() {
  new_session a
  assert_contains "$("$TM" ls)" "NAME" header
}

# ─── Task 2: agents ───────────────────────────────────

test_hook_agent_fields() {
  agent_pane new a
  set_state a blocked '{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","session_id":"s-1"}'
  local out; out=$("$TM" ls --json)
  assert_eq '["agent", "message", "pane", "pid", "reason", "session_id", "since", "source", "stale", "state", "target"]' \
    "$(json 'sorted(d["sessions"][0]["agents"][0])' <<< "$out")" agent-keys
  assert_eq "$(pane_id a)" "$(json 'd["sessions"][0]["agents"][0]["pane"]' <<< "$out")" pane
  assert_eq a:0.0 "$(json 'd["sessions"][0]["agents"][0]["target"]' <<< "$out")" target
  assert_eq claude "$(json 'd["sessions"][0]["agents"][0]["agent"]' <<< "$out")" agent
  assert_eq "$(agent_pid claude)" "$(json 'd["sessions"][0]["agents"][0]["pid"]' <<< "$out")" pid
  assert_eq s-1 "$(json 'd["sessions"][0]["agents"][0]["session_id"]' <<< "$out")" session_id
  assert_eq blocked "$(json 'd["sessions"][0]["agents"][0]["state"]' <<< "$out")" state
  assert_eq permission "$(json 'd["sessions"][0]["agents"][0]["reason"]' <<< "$out")" reason
  assert_eq 'Claude needs your permission to use Bash' "$(json 'd["sessions"][0]["agents"][0]["message"]' <<< "$out")" message
  assert_eq hook "$(json 'd["sessions"][0]["agents"][0]["source"]' <<< "$out")" source
  assert_eq false "$(json 'd["sessions"][0]["agents"][0]["stale"]' <<< "$out")" not-stale
  assert_eq blocked "$(json 'd["sessions"][0]["state"]' <<< "$out")" session-state
  [[ "$(json 'd["sessions"][0]["agents"][0]["since"]' <<< "$out")" =~ Z$ ]] || fail "since format"
}

test_process_only_agent_is_heuristic() {
  fake_agent codex
  tmux new-session -d -s a -c "$TEST_TMP" "$TEST_TMP/bin/codex"
  sleep 0.3
  local out; out=$("$TM" ls --json)
  assert_eq codex "$(json 'd["sessions"][0]["agents"][0]["agent"]' <<< "$out")" agent
  assert_eq "$(agent_pid codex)" "$(json 'd["sessions"][0]["agents"][0]["pid"]' <<< "$out")" pid
  assert_eq unknown "$(json 'd["sessions"][0]["agents"][0]["state"]' <<< "$out")" state
  assert_eq heuristic "$(json 'd["sessions"][0]["agents"][0]["source"]' <<< "$out")" source
  assert_eq null "$(json 'd["sessions"][0]["agents"][0]["since"]' <<< "$out")" since
}

test_hook_and_process_merge() {
  fake_agent claude
  tmux new-session -d -s a -c "$TEST_TMP" "$TEST_TMP/bin/claude"
  sleep 0.3
  set_state a working
  local out; out=$("$TM" ls --json)
  assert_eq 1 "$(json 'len(d["sessions"][0]["agents"])' <<< "$out")" one-agent
  assert_eq hook "$(json 'd["sessions"][0]["agents"][0]["source"]' <<< "$out")" source
  assert_eq "$(agent_pid claude)" "$(json 'd["sessions"][0]["agents"][0]["pid"]' <<< "$out")" pid
}

test_aggregate_and_target_order() {
  agent_pane new a
  agent_pane split a
  set_state a:0.0 idle
  set_state a:0.1 working
  local out; out=$("$TM" ls --json)
  assert_eq '["a:0.0", "a:0.1"]' "$(json '[x["target"] for x in d["sessions"][0]["agents"]]' <<< "$out")" order
  assert_eq working "$(json 'd["sessions"][0]["state"]' <<< "$out")" aggregate
}

test_stale_working_flag() {
  agent_pane new a
  set_state a working
  local f created; f="$STATE_DIR/$(pane_id a | tr -d %).json"
  created=$(tmux display-message -p -t a '#{session_created}')
  # ts one second after the session was created: valid, but older than TM_STALE_AFTER=1
  python3 - "$f" "$created" <<'PY2'
import json, sys, time
p, created = sys.argv[1], int(sys.argv[2])
d = json.load(open(p))
d["ts"] = d["since"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(created + 1))
json.dump(d, open(p, "w"))
PY2
  sleep 2
  local out; out=$(TM_STALE_AFTER=1 "$TM" ls --json)
  assert_eq working "$(json 'd["sessions"][0]["agents"][0]["state"]' <<< "$out")" state
  assert_eq true "$(json 'd["sessions"][0]["agents"][0]["stale"]' <<< "$out")" stale
}

test_dead_without_process_is_dropped() {
  new_session a
  set_state a dead
  assert_eq '[]' "$("$TM" ls --json | json 'd["sessions"][0]["agents"]')" dropped
}

test_corrupt_state_with_process_is_heuristic() {
  fake_agent claude
  tmux new-session -d -s a -c "$TEST_TMP" "$TEST_TMP/bin/claude"
  sleep 0.3
  mkdir -p "$STATE_DIR"
  echo '{broken' > "$STATE_DIR/$(pane_id a | tr -d %).json"
  local out code
  out=$("$TM" ls --json 2>/dev/null); code=$?
  assert_eq 0 "$code" exit
  assert_eq heuristic "$(json 'd["sessions"][0]["agents"][0]["source"]' <<< "$out")" source
  assert_eq unknown "$(json 'd["sessions"][0]["agents"][0]["state"]' <<< "$out")" state
}

test_state_older_than_session_ignored() {
  new_session a
  set_state a blocked
  local f; f="$STATE_DIR/$(pane_id a | tr -d %).json"
  python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["ts"] = d["since"] = "2000-01-01T00:00:00Z"; json.dump(d, open(p, "w"))
PY
  assert_eq '[]' "$("$TM" ls --json | json 'd["sessions"][0]["agents"]')" ignored
}

test_claude_named_file_is_not_agent() {
  printf '#!/bin/bash\nsleep 600\n' > "$TEST_TMP/claude.md"
  tmux new-session -d -s a -c "$TEST_TMP" "bash $TEST_TMP/claude.md"
  sleep 0.3
  assert_eq '[]' "$("$TM" ls --json | json 'd["sessions"][0]["agents"]')" not-agent
}

# ─── Final review fixes ───────────────────────────────

# An agent killed without SessionEnd leaves its last state behind; without a
# live agent process it must not look idle (a Leader would type into a shell)
test_hook_state_without_process_is_unknown() {
  new_session a
  set_state a idle
  local out; out=$("$TM" ls --json)
  assert_eq unknown "$(json 'd["sessions"][0]["agents"][0]["state"]' <<< "$out")" state
  assert_eq null "$(json 'd["sessions"][0]["agents"][0]["pid"]' <<< "$out")" pid
  assert_eq unknown "$(json 'd["sessions"][0]["state"]' <<< "$out")" session-state
}

# A dead record from an earlier agent must not label the agent running now
test_dead_record_with_new_process_is_heuristic() {
  fake_agent codex
  tmux new-session -d -s a -c "$TEST_TMP" "$TEST_TMP/bin/codex"
  sleep 0.3
  set_state a dead '{"session_id":"old-claude"}'
  local out; out=$("$TM" ls --json --agent codex)
  assert_eq codex "$(json 'd["sessions"][0]["agents"][0]["agent"]' <<< "$out")" agent
  assert_eq heuristic "$(json 'd["sessions"][0]["agents"][0]["source"]' <<< "$out")" source
  assert_eq null "$(json 'd["sessions"][0]["agents"][0]["session_id"]' <<< "$out")" session_id
}

# ─── Task 3: filters and exit codes ───────────────────

names() { json '[s["name"] for s in d["sessions"]]'; }

test_filter_state() {
  agent_pane new a; agent_pane new b; new_session c
  agent_pane split a
  set_state a:0.0 blocked; set_state a:0.1 idle; set_state b idle
  assert_eq '["a"]' "$("$TM" ls --json --state blocked | names)" blocked
  assert_eq '["a", "b"]' "$("$TM" ls --json --state=idle | names)" idle-equals-form
  assert_eq '["a", "b"]' "$("$TM" ls --json --state blocked,idle | names)" csv
  assert_eq 2 "$("$TM" ls --json --state blocked | json 'len(d["sessions"][0]["agents"])')" keeps-all-agents
}

test_filter_agent_recomputes_state() {
  fake_agent codex
  agent_pane new a
  tmux split-window -d -t a "$TEST_TMP/bin/codex"
  sleep 0.3
  set_state a:0.0 blocked
  local out; out=$("$TM" ls --json --agent codex)
  assert_eq '["codex"]' "$(json '[x["agent"] for x in d["sessions"][0]["agents"]]' <<< "$out")" only-codex
  assert_eq unknown "$(json 'd["sessions"][0]["state"]' <<< "$out")" recomputed
  assert_eq '[]' "$("$TM" ls --json --agent nope | names)" no-match
}

test_filter_session() {
  new_session a; new_session b
  assert_eq '["b"]' "$("$TM" ls --json --session b | names)" one
  local code; "$TM" ls --json --session zz >/dev/null 2>&1; code=$?
  assert_eq 2 "$code" missing-exit-2
}

test_empty_result_exit_0() {
  new_session a
  local out code; out=$("$TM" ls --json --state blocked); code=$?
  assert_eq 0 "$code" exit
  assert_eq '[]' "$(json 'd["sessions"]' <<< "$out")" empty
}

test_no_summary() {
  new_session a
  mkdir -p "$HOME/.tmux-manager/summaries"
  echo '{"ts":1,"summary":"x"}' > "$HOME/.tmux-manager/summaries/a.jsonl"
  assert_eq null "$("$TM" ls --json --no-summary | json 'd["sessions"][0]["summary"]')" null
}

test_bad_args_exit_3() {
  new_session a
  local args code
  for args in "--bogus" "--json --state" "--json --state nope" "--json --agent" "--json --session" "--state blocked" "--no-summary"; do
    # shellcheck disable=SC2086
    "$TM" ls $args >/dev/null 2>&1; code=$?
    assert_eq 3 "$code" "args <$args>"
  done
}

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

run_tests
