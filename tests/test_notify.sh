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
    | TMUX_PANE="$(pane_id a)" TM_NOTIFY_CMD="sleep 37" "$TM" hook-state blocked
  python3 -c "import sys, time; sys.exit(0 if time.time() - $start < 1 else 1)" || fail "hook waited for the notify command"
  sleep 6
  assert_contains "$(cat "$HOME/.tmux-manager/notify.log" 2>/dev/null)" "timeout" logged
  assert_eq "" "$(pgrep -f 'sleep 37')" killed
}

test_failing_notify_is_logged() {
  new_session a
  set_state a working
  printf '{"notification_type":"permission_prompt"}' \
    | TMUX_PANE="$(pane_id a)" TM_NOTIFY_CMD="exit 7" "$TM" hook-state blocked
  sleep 1
  assert_contains "$(cat "$HOME/.tmux-manager/notify.log" 2>/dev/null)" "exit 7" logged
  assert_eq 600 "$(stat -f %Lp "$HOME/.tmux-manager/notify.log" 2>/dev/null || stat -c %a "$HOME/.tmux-manager/notify.log" 2>/dev/null)" mode
}

run_tests
