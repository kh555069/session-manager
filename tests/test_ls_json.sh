#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# json <python-expr>: evaluate an expression on the JSON read from stdin (bound to d).
# eval is safe here: expressions are literals written in this file, never input.
json() {
  python3 -c 'import json, sys; d = json.load(sys.stdin); v = eval(sys.argv[1]); print(json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list, bool)) or v is None else v)' "$1"
}

# set_state <target> <state> [payload]: same helper as test_list_state.sh
set_state() {
  local payload='{"notification_type":"permission_prompt"}'
  [[ $# -ge 3 ]] && payload="$3"
  printf '%s' "$payload" | TMUX_PANE="$(pane_id "$1")" "$TM" hook-state "$2"
}

# fake_agent <name>: an executable named claude/codex that just sleeps;
# ps shows it as "/bin/bash <path>/<name>", like node-launched agents
fake_agent() {
  printf '#!/bin/bash\nsleep 600\n' > "$TEST_TMP/bin/$1"
  chmod +x "$TEST_TMP/bin/$1"
}

# agent_pid <name>: pid of the fake agent itself, not tmux's "sh -c" wrapper
agent_pid() {
  pgrep -f "bash $TEST_TMP/bin/$1"
}

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
  new_session a
  set_state a blocked '{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","session_id":"s-1"}'
  local out; out=$("$TM" ls --json)
  assert_eq '["agent", "message", "pane", "pid", "reason", "session_id", "since", "source", "stale", "state", "target"]' \
    "$(json 'sorted(d["sessions"][0]["agents"][0])' <<< "$out")" agent-keys
  assert_eq "$(pane_id a)" "$(json 'd["sessions"][0]["agents"][0]["pane"]' <<< "$out")" pane
  assert_eq a:0.0 "$(json 'd["sessions"][0]["agents"][0]["target"]' <<< "$out")" target
  assert_eq claude "$(json 'd["sessions"][0]["agents"][0]["agent"]' <<< "$out")" agent
  assert_eq null "$(json 'd["sessions"][0]["agents"][0]["pid"]' <<< "$out")" pid-without-process
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
  new_session a
  tmux split-window -d -t a "sleep 600"
  set_state a:0.0 idle
  set_state a:0.1 working
  local out; out=$("$TM" ls --json)
  assert_eq '["a:0.0", "a:0.1"]' "$(json '[x["target"] for x in d["sessions"][0]["agents"]]' <<< "$out")" order
  assert_eq working "$(json 'd["sessions"][0]["state"]' <<< "$out")" aggregate
}

test_stale_working_flag() {
  new_session a
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

run_tests
