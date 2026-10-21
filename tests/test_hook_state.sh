#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# hook <state> <payload> [pane]: run hook-state the way a Claude hook does
hook() {
  printf '%s' "$2" | TMUX_PANE="${3:-%7}" "$TM" hook-state "$1"
}

field() {
  jq -r ".$1" "$STATE_DIR/7.json"
}

test_idle_writes_file() {
  hook idle '{"session_id":"s1","cwd":"/tmp/p","hook_event_name":"Stop"}'
  local f="$STATE_DIR/7.json"
  [[ -f "$f" ]] || { fail "state file missing"; return; }
  assert_eq 1 "$(field v)" v
  assert_eq "%7" "$(field pane)" pane
  assert_eq claude "$(field agent)" agent
  assert_eq s1 "$(field session_id)" session_id
  assert_eq idle "$(field state)" state
  assert_eq Stop "$(field event)" event
  assert_eq /tmp/p "$(field cwd)" cwd
  assert_eq null "$(field reason)" reason
  assert_eq null "$(field message)" message
  [[ "$(field ts)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || fail "ts format: $(field ts)"
  assert_eq "$(field ts)" "$(field since)" since
  assert_eq 600 "$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f")" file-mode
  assert_eq 700 "$(stat -f %Lp "$STATE_DIR" 2>/dev/null || stat -c %a "$STATE_DIR")" dir-mode
}

test_since_kept_when_state_unchanged() {
  hook working '{"hook_event_name":"UserPromptSubmit"}'
  local since1; since1=$(field since)
  sleep 1
  hook working '{"hook_event_name":"PreToolUse"}'
  assert_eq "$since1" "$(field since)" since
  [[ "$(field ts)" > "$since1" ]] || fail "ts not refreshed: $(field ts)"
  assert_eq PreToolUse "$(field event)" event
}

test_since_reset_on_state_change() {
  hook working '{"hook_event_name":"UserPromptSubmit"}'
  local since1; since1=$(field since)
  sleep 1
  hook idle '{"hook_event_name":"Stop"}'
  assert_eq "$(field ts)" "$(field since)" since-equals-ts
  [[ "$(field since)" > "$since1" ]] || fail "since not reset"
}

test_blocked_permission_by_type() {
  hook blocked '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
  assert_eq blocked "$(field state)" state
  assert_eq permission "$(field reason)" reason
  assert_eq "Claude needs your permission to use Bash" "$(field message)" message
}

test_blocked_input_by_type() {
  hook blocked '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
  assert_eq input "$(field reason)" idle_prompt
  hook blocked '{"hook_event_name":"Notification","notification_type":"elicitation_dialog","message":"x"}'
  assert_eq input "$(field reason)" elicitation_dialog
}

test_blocked_fallback_by_message() {
  hook blocked '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}'
  assert_eq permission "$(field reason)" permission
  hook blocked '{"hook_event_name":"Notification","message":"Claude is waiting for your input"}'
  assert_eq input "$(field reason)" input
}

test_ignored_notification_type() {
  hook blocked '{"hook_event_name":"Notification","notification_type":"auth_success","message":"ok"}'
  [[ ! -e "$STATE_DIR/7.json" ]] || fail "file created for auth_success"
  hook idle '{"hook_event_name":"Stop"}'
  local before; before=$(cat "$STATE_DIR/7.json")
  hook blocked '{"hook_event_name":"Notification","notification_type":"auth_success","message":"ok"}'
  assert_eq "$before" "$(cat "$STATE_DIR/7.json")" unchanged
}

test_no_tmux_pane_no_write() {
  printf '{}' | "$TM" hook-state idle
  assert_eq 0 "$?" exit
  assert_eq "" "$(ls "$STATE_DIR" 2>/dev/null)" no-files
}

test_invalid_payload_still_writes() {
  hook working 'not json'
  assert_eq 0 "$?" exit-garbage
  assert_eq working "$(field state)" state-garbage
  assert_eq null "$(field session_id)" session_id
  assert_eq null "$(field cwd)" cwd
  assert_eq null "$(field event)" event
  hook idle ''
  assert_eq 0 "$?" exit-empty
  assert_eq idle "$(field state)" state-empty
}

test_invalid_state_arg() {
  local err
  err=$(printf '{}' | TMUX_PANE=%7 "$TM" hook-state bogus 2>&1 >/dev/null)
  local code=$?
  assert_eq 3 "$code" exit
  assert_contains "$err" "Usage" stderr
  [[ ! -e "$STATE_DIR/7.json" ]] || fail "file written for bogus state"
}

test_reason_cleared_after_blocked() {
  hook blocked '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"m"}'
  hook working '{"hook_event_name":"PreToolUse"}'
  assert_eq null "$(field reason)" reason
  assert_eq null "$(field message)" message
}

test_dead_state() {
  hook dead '{"hook_event_name":"SessionEnd"}'
  assert_eq dead "$(field state)" state
}

run_tests
