#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# Parking closes a session but keeps its row; reviving recreates it and
# resumes each Claude conversation. TM_CLAUDE_CMD points at a fake claude
# that records its arguments, so no real Claude ever starts.

ID1=11111111-1111-4111-8111-111111111111
ID2=22222222-2222-4222-8222-222222222222

park_env() {
  export TM_GROUPS=on
  printf '#!/bin/bash\nprintf "%%s|%%s\\n" "$PWD" "$*" >> "%s"\nsleep 600\n' "$TEST_TMP/resumed.log" > "$TEST_TMP/bin/fake-claude"
  chmod +x "$TEST_TMP/bin/fake-claude"
  export TM_CLAUDE_CMD="$TEST_TMP/bin/fake-claude"
  mkdir -p "$TEST_TMP/proj" "$TEST_TMP/proj/sub"
}

# agent_session <name> [state]: a session in proj with a live fake claude
# (the agent process check) and a hook state carrying session ID $ID1
agent_session() {
  [[ -x "$TEST_TMP/bin/claude" ]] || fake_agent claude
  tmux new-session -d -s "$1" -c "$TEST_TMP/proj" "$TEST_TMP/bin/claude"
  sleep 0.3
  set_state "$1" "${2:-idle}" "{\"session_id\":\"$ID1\",\"cwd\":\"$TEST_TMP/proj\",\"transcript_path\":\"$TEST_TMP/t1.jsonl\"}"
}

parked_file() { echo "$HOME/.tmux-manager/parked/$1.json"; }

row_of() {
  "$TM" _list | awk -F'\t' -v n="$1" '{x = $2; sub(/^ +/, "", x); sub(/ +$/, "", x); if (x == n) print}'
}

# wait_resumed <n>: wait until the fake claude has been started n times
wait_resumed() {
  local i
  for i in $(seq 50); do
    [[ -f "$TEST_TMP/resumed.log" && $(wc -l < "$TEST_TMP/resumed.log") -ge $1 ]] && return 0
    sleep 0.1
  done
  return 1
}

test_park_closes_session_and_keeps_row() {
  park_env
  agent_session a
  printf 'y\n' | "$TM" _park a >/dev/null
  tmux has-session -t =a 2>/dev/null && fail "session still running"
  [[ -f "$(parked_file a)" ]] || fail "no parked record"
  assert_contains "$(json 'd["agents"][0]["session_id"]' < "$(parked_file a)")" "$ID1" session-id
  assert_contains "$(json 'd["agents"][0]["cwd"]' < "$(parked_file a)")" "$TEST_TMP/proj" cwd
  local row; row=$(row_of a)
  assert_contains "$row" "⏸" icon
  assert_contains "$row" "parked" label
}

test_parked_file_is_private() {
  park_env
  agent_session a
  printf 'y\n' | "$TM" _park a >/dev/null
  assert_eq 600 "$(stat -f %Lp "$(parked_file a)" 2>/dev/null || stat -c %a "$(parked_file a)")" mode
}

test_park_cancel_keeps_session() {
  park_env
  agent_session a
  printf 'n\n' | "$TM" _park a >/dev/null
  tmux has-session -t =a 2>/dev/null || fail "session closed on cancel"
  [[ ! -f "$(parked_file a)" ]] || fail "record written on cancel"
}

test_park_working_agent_needs_the_name() {
  park_env
  agent_session a working
  printf 'y\n' | "$TM" _park a >/dev/null
  tmux has-session -t =a 2>/dev/null || fail "working agent parked with y"
  printf 'a\n' | "$TM" _park a >/dev/null
  tmux has-session -t =a 2>/dev/null && fail "not parked with the name"
  return 0
}

test_park_refuses_protected_session() {
  park_env
  agent_session a
  "$TM" protect a >/dev/null
  printf 'y\n' | "$TM" _park a >/dev/null 2>&1
  tmux has-session -t =a 2>/dev/null || fail "protected session parked"
}

test_park_refuses_session_without_claude() {
  park_env
  new_session plain
  local out; out=$(printf 'y\n' | "$TM" _park plain 2>&1)
  tmux has-session -t =plain 2>/dev/null || fail "session without agent parked"
  assert_contains "$out" "No Claude agent" message
}

test_revive_resumes_each_agent_in_its_directory() {
  park_env
  agent_session a
  tmux split-window -d -t a -c "$TEST_TMP/proj/sub" "$TEST_TMP/bin/claude"
  sleep 0.3
  set_state a:0.1 working "{\"session_id\":\"$ID2\",\"cwd\":\"$TEST_TMP/proj/sub\"}"
  printf 'a\n' | "$TM" _park a >/dev/null
  "$TM" revive a >/dev/null
  tmux has-session -t =a 2>/dev/null || fail "session not recreated"
  wait_resumed 2 || fail "agents not resumed: $(cat "$TEST_TMP/resumed.log" 2>/dev/null)"
  local log; log=$(cat "$TEST_TMP/resumed.log")
  assert_contains "$log" "$TEST_TMP/proj|--resume $ID1" first-agent
  assert_contains "$log" "$TEST_TMP/proj/sub|--resume $ID2" second-agent
  assert_eq 2 "$(tmux list-windows -t =a | wc -l | tr -d ' ')" one-window-per-agent
  [[ ! -f "$(parked_file a)" ]] || fail "record kept after revive"
}

test_revive_passes_resume_flags() {
  park_env
  agent_session a
  printf 'y\n' | "$TM" _park a >/dev/null
  "$TM" revive a >/dev/null
  wait_resumed 1 || fail "not resumed"
  assert_contains "$(cat "$TEST_TMP/resumed.log")" "--dangerously-skip-permissions" flags
}

test_revive_refuses_when_name_is_taken() {
  park_env
  agent_session a
  printf 'y\n' | "$TM" _park a >/dev/null
  new_session a
  "$TM" revive a >/dev/null 2>&1
  assert_eq 1 "$?" exit-code
  [[ -f "$(parked_file a)" ]] || fail "record dropped"
  # A live session hides the parked row of the same name
  assert_not_contains "$(row_of a)" "parked" live-wins
}

test_revive_unknown_name_fails() {
  park_env
  "$TM" revive nope >/dev/null 2>&1
  assert_eq 2 "$?" exit-code
}

test_enter_on_parked_row_accepts() {
  park_env
  agent_session a
  printf 'y\n' | "$TM" _park a >/dev/null
  assert_eq accept "$("$TM" _enter a)" enter
}

test_forget_parked_row_with_ctrl_k() {
  park_env
  agent_session a
  printf 'y\n' | "$TM" _park a >/dev/null
  printf 'n\n' | "$TM" _kill-selected a >/dev/null
  [[ -f "$(parked_file a)" ]] || fail "forgot without confirmation"
  printf 'y\n' | "$TM" _kill-selected a >/dev/null
  [[ ! -f "$(parked_file a)" ]] || fail "record kept"
  assert_eq "" "$(row_of a)" row-gone
}

test_parked_row_stays_in_its_groups() {
  park_env
  agent_session a; agent_session b
  printf 'y\n' | "$TM" _park a >/dev/null
  # a and b share proj: still a group of two
  local list; list=$("$TM" _list | cut -f2 | sed 's/ *$//')
  assert_contains "$list" "$TEST_TMP/proj:" path-group
  assert_contains "$list" "  a" member
  assert_contains "$("$TM" _list | grep "$TEST_TMP/proj:")" "⏸1" parked-count
  "$TM" group crew a >/dev/null 2>&1
  assert_eq 0 "$?" group-parked
  assert_contains "$("$TM" _list | cut -f2)" "crew:" manual-group
}

test_parked_preview_lists_agents() {
  park_env
  printf '{"type":"user","message":{"role":"user","content":"ship it"},"timestamp":"2026-10-24T01:00:00.000Z"}\n' > "$TEST_TMP/t1.jsonl"
  agent_session a
  printf 'y\n' | "$TM" _park a >/dev/null
  local out; out=$("$TM" _preview a | sed 's/\x1b\[[0-9;]*m//g')
  assert_contains "$out" "Parked" title
  assert_contains "$out" "$ID1" session-id
  assert_contains "$out" "You: ship it" last-prompt
  assert_not_contains "$out" "Session not found" not-missing
}

test_session_actions_skip_parked_rows() {
  park_env
  agent_session a
  printf 'y\n' | "$TM" _park a >/dev/null
  "$TM" _toggle-protect a >/dev/null 2>&1
  printf 'x\n' | "$TM" _rename a >/dev/null 2>&1
  [[ ! -s "$HOME/.tmux-manager/protected.txt" ]] || fail "parked row protected"
  [[ -f "$(parked_file a)" ]] || fail "rename touched the record"
}

run_tests
