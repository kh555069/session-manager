#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# set_state <target> <state> [payload]: write a state file via the real hook.
# The default payload is a permission prompt so "blocked" is recorded
# (other states ignore notification_type).
set_state() {
  local payload='{"notification_type":"permission_prompt"}'
  [[ $# -ge 3 ]] && payload="$3"
  printf '%s' "$payload" | TMUX_PANE="$(pane_id "$1")" "$TM" hook-state "$2"
}

# line_for <session>: the _list row whose NAME column is exactly the session
line_for() {
  "$TM" _list | awk -F'\t' -v n="$1" '{x=$2; sub(/ +$/, "", x); if (x == n) print}'
}

# first_session: NAME of the first row after the header
first_session() {
  "$TM" _list | awk -F'\t' 'NR==2 {x=$2; sub(/ +$/, "", x); print x}'
}

test_icons_per_state() {
  new_session a; new_session b
  set_state a blocked '{"notification_type":"permission_prompt"}'
  set_state b working
  assert_contains "$(line_for a)" "❓" blocked
  assert_contains "$(line_for b)" "⏳" working
  set_state b idle
  assert_contains "$(line_for b)" "💤" idle
}

test_unknown_without_state() {
  new_session a
  assert_contains "$(line_for a)" "·" unknown
}

test_blocked_sorted_first() {
  new_session a; new_session b
  assert_eq b "$(first_session)" baseline-order
  set_state a blocked
  assert_eq a "$(first_session)" blocked-first
}

test_tm_sort_recent_keeps_order() {
  new_session a; new_session b
  set_state a blocked
  assert_eq b "$(TM_SORT=recent first_session)" recent-order
}

test_aggregate_prefers_blocked() {
  new_session a
  tmux split-window -d -t a "sleep 600"
  set_state a:0.0 idle
  set_state a:0.1 blocked
  assert_contains "$(line_for a)" "❓" aggregate
}

test_stale_working() {
  new_session a
  set_state a working
  sleep 2
  assert_contains "$(TM_STALE_AFTER=1 line_for a)" "⏳?" stale
  assert_not_contains "$(line_for a)" "⏳?" fresh-with-default
}

test_dead_shows_unknown() {
  new_session a
  set_state a dead
  assert_contains "$(line_for a)" "·" dead
}

test_state_older_than_session_is_ignored() {
  new_session a
  local id; id=$(pane_id a)
  mkdir -p "$STATE_DIR"
  printf '{"v":1,"pane":"%s","state":"blocked","ts":"2000-01-01T00:00:00Z","since":"2000-01-01T00:00:00Z"}' \
    "$id" > "$STATE_DIR/${id#%}.json"
  assert_contains "$(line_for a)" "·" stale-pane-id
  assert_not_contains "$(line_for a)" "❓" not-blocked
}

test_corrupt_state_file_is_unknown() {
  new_session a; new_session b
  mkdir -p "$STATE_DIR"
  local ida idb; ida=$(pane_id a); idb=$(pane_id b)
  printf '{not json' > "$STATE_DIR/${ida#%}.json"
  : > "$STATE_DIR/${idb#%}.json"
  local out; out=$("$TM" _list); local code=$?
  assert_eq 0 "$code" exit
  assert_contains "$(line_for a)" "·" corrupt
  assert_contains "$(line_for b)" "·" empty
}

test_header_has_st() {
  new_session a
  assert_contains "$("$TM" _list | head -1)" "ST" header
}

run_tests
