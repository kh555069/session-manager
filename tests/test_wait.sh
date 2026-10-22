#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# later <seconds> <command...>: run a command in the background after a delay
later() {
  local delay="$1"; shift
  ( sleep "$delay"; "$@" ) &
}

# ─── Task 1: conditions, targets, match, timeout ──────

test_returns_immediately_when_already_met() {
  agent_pane new a
  set_state a idle
  local out code; out=$("$TM" wait a --until idle --interval 0.2 --timeout 5s); code=$?
  assert_eq 0 "$code" exit
  assert_eq idle "$(json 'd["state"]' <<< "$out")" state
  assert_eq a:0.0 "$(json 'd["target"]' <<< "$out")" target
  assert_eq '["agent", "message", "pane", "pid", "reason", "session_id", "since", "source", "stale", "state", "target"]' \
    "$(json 'sorted(d)' <<< "$out")" same-keys-as-ls
}

test_waits_for_state_change() {
  agent_pane new a
  set_state a working
  later 0.5 set_state a blocked
  local out code; out=$("$TM" wait a --until done --interval 0.2 --timeout 5s); code=$?
  wait
  assert_eq 0 "$code" exit
  assert_eq blocked "$(json 'd["state"]' <<< "$out")" state
  assert_eq permission "$(json 'd["reason"]' <<< "$out")" reason
}

test_timeout_exit_1_prints_current_state() {
  agent_pane new a
  set_state a working
  local out code start=$SECONDS
  out=$("$TM" wait a --until idle --interval 0.2 --timeout 1s); code=$?
  assert_eq 1 "$code" exit
  assert_eq working "$(json 'd["state"]' <<< "$out")" current-state
  [[ $((SECONDS - start)) -le 3 ]] || fail "timeout took $((SECONDS - start))s"
}

test_target_forms() {
  agent_pane new a
  agent_pane split a
  set_state a:0.1 idle
  local pane; pane=$(pane_id a:0.1)
  assert_eq a:0.1 "$("$TM" wait "$pane" --until idle --timeout 2s | json 'd["target"]')" pane-id
  assert_eq a:0.1 "$("$TM" wait a:0.1 --until idle --timeout 2s | json 'd["target"]')" address
  assert_eq a:0.1 "$("$TM" wait a:0 --until idle --timeout 2s | json 'd["target"]')" window
}

test_missing_target_exit_2() {
  new_session a
  local code
  "$TM" wait nope --until idle --timeout 2s >/dev/null 2>&1; code=$?
  assert_eq 2 "$code" session
  "$TM" wait a:0.9 --until idle --timeout 2s >/dev/null 2>&1; code=$?
  assert_eq 2 "$code" pane
}

test_no_server_exit_2() {
  local out code; out=$("$TM" wait a --until idle --timeout 1s 2>/dev/null); code=$?
  assert_eq 2 "$code" exit
  assert_eq "" "$out" stdout-empty
}

test_match_any_and_all() {
  agent_pane new a
  agent_pane split a
  set_state a:0.0 idle; set_state a:0.1 working
  local out
  out=$("$TM" wait a --until idle --match any --interval 0.2 --timeout 2s)
  assert_eq a:0.0 "$(json 'd["target"]' <<< "$out")" any
  local code; "$TM" wait a --until idle --match all --interval 0.2 --timeout 1s >/dev/null; code=$?
  assert_eq 1 "$code" all-times-out
  later 0.3 set_state a:0.1 blocked
  out=$("$TM" wait a --until done --match all --interval 0.2 --timeout 5s); code=$?
  wait
  assert_eq 0 "$code" all-done
  assert_eq 2 "$(printf '%s\n' "$out" | grep -c .)" two-lines
}

test_match_all_ignores_plain_panes() {
  agent_pane new a
  tmux split-window -d -t a "sleep 600"
  set_state a:0.0 idle
  local code; "$TM" wait a --until idle --match all --interval 0.2 --timeout 2s >/dev/null; code=$?
  assert_eq 0 "$code" exit
}

test_pane_without_agent_keeps_waiting() {
  tmux new-session -d -s a -c "$TEST_TMP" "sleep 600"
  local code; "$TM" wait a:0.0 --until idle --interval 0.2 --timeout 1s >/dev/null 2>&1; code=$?
  assert_eq 1 "$code" times-out-not-dead
}

test_unknown_is_not_done() {
  fake_agent codex
  tmux new-session -d -s a -c "$TEST_TMP" "$TEST_TMP/bin/codex"
  sleep 0.3
  local code; "$TM" wait a --until done --interval 0.2 --timeout 1s >/dev/null; code=$?
  assert_eq 1 "$code" heuristic-unknown
}

test_all_flag() {
  agent_pane new a; agent_pane new b
  set_state a working; set_state b working
  later 0.4 set_state b idle
  local out; out=$("$TM" wait --all --until idle --interval 0.2 --timeout 5s)
  wait
  assert_eq b:0.0 "$(json 'd["target"]' <<< "$out")" target
}

test_bad_args_exit_3() {
  new_session a
  local args code
  for args in "a" "a --until nope" "--until idle" "a --all --until idle" "a --until idle --timeout 30x" \
              "a --until idle --timeout 0" "a --until idle --interval 0" "a --until idle --interval x" \
              "a --until idle --match some" "a --until idle --bogus" "a b --until idle"; do
    # shellcheck disable=SC2086
    "$TM" wait $args >/dev/null 2>&1; code=$?
    assert_eq 3 "$code" "args <$args>"
  done
}

# ─── Task 2: dead agents and --after-change ───────────

test_after_change_ignores_previous_idle() {
  agent_pane new a
  set_state a idle
  local code; "$TM" wait a --until idle --after-change --interval 0.2 --timeout 1s >/dev/null; code=$?
  assert_eq 1 "$code" no-change-times-out
  # since has one-second resolution: let the new working/idle get a different since
  later 1.1 set_state a working
  later 2.2 set_state a idle
  local out; out=$("$TM" wait a --until idle --after-change --interval 0.2 --timeout 6s); code=$?
  wait
  assert_eq 0 "$code" changed
  assert_eq idle "$(json 'd["state"]' <<< "$out")" state
}

test_killed_agent_exits_2() {
  agent_pane new a
  set_state a working
  later 0.5 pkill -f "bash $TEST_TMP/bin/claude"
  local out code; out=$("$TM" wait a --until done --interval 0.2 --timeout 5s); code=$?
  wait
  assert_eq 2 "$code" exit
  assert_eq dead "$(json 'd["state"]' <<< "$out")" state
  assert_eq null "$(json 'd["pid"]' <<< "$out")" pid
}

test_closed_pane_exits_2() {
  agent_pane new a
  agent_pane split a
  set_state a:0.1 working
  local pid; pid=$(tmux display-message -p -t a:0.1 '#{pane_pid}')
  later 0.5 kill "$pid"
  local code; "$TM" wait a:0.1 --until idle --interval 0.2 --timeout 5s >/dev/null 2>&1; code=$?
  wait
  assert_eq 2 "$code" exit
}

test_until_dead_exit_0() {
  agent_pane new a
  set_state a idle
  later 0.5 pkill -f "bash $TEST_TMP/bin/claude"
  local out code; out=$("$TM" wait a --until dead --interval 0.2 --timeout 5s); code=$?
  wait
  assert_eq 0 "$code" exit
  assert_eq dead "$(json 'd["state"]' <<< "$out")" state
}

# ─── Final review fixes ───────────────────────────────

# rewrite_state <target> <state>: change the state but keep ts/since, as when
# a turn starts and ends within the same second
rewrite_state() {
  python3 - "$STATE_DIR/$(pane_id "$1" | tr -d %).json" "$2" <<'PY'
import json, sys
p, state = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d["state"] = state; json.dump(d, open(p, "w"))
PY
}

test_after_change_accepts_same_second_turn() {
  agent_pane new a
  set_state a working
  later 0.5 rewrite_state a idle
  local code; "$TM" wait a --until idle --after-change --interval 0.2 --timeout 3s >/dev/null; code=$?
  wait
  assert_eq 0 "$code" exit
}

# A state file written before the agent process started belongs to an earlier
# agent (killed without SessionEnd) and must not confirm the new one
test_state_older_than_agent_process_is_unconfirmed() {
  fake_agent claude
  # The agent starts 3s after the record: ts and ps etime are whole seconds and
  # the reader allows 1s of slack, so a shorter gap can still look current
  tmux new-session -d -s a -c "$TEST_TMP" "bash -c 'sleep 3; \"$TEST_TMP/bin/claude\"; true'"
  set_state a idle
  sleep 3.5
  local code; "$TM" wait a --until idle --interval 0.2 --timeout 1s >/dev/null; code=$?
  assert_eq 1 "$code" wait-not-done
  assert_eq unknown "$("$TM" ls --json | json 'd["sessions"][0]["agents"][0]["state"]')" ls-state
}

# ─── Task 3: inotify wake-up and SIGINT ───────────────

# fake_inotifywait [seconds]: stands in for inotify-tools; reports an event
# after the delay (default 0.2s)
fake_inotifywait() {
  printf '#!/bin/bash\nsleep %s\nexit 0\n' "${1:-0.2}" > "$TEST_TMP/bin/inotifywait"
  chmod +x "$TEST_TMP/bin/inotifywait"
}

test_inotify_wakes_before_interval() {
  fake_inotifywait
  agent_pane new a
  set_state a working
  later 0.5 set_state a idle
  local code start=$SECONDS
  PATH="$TEST_TMP/bin:$PATH" "$TM" wait a --until idle --interval 5 --timeout 20s >/dev/null; code=$?
  wait
  assert_eq 0 "$code" exit
  [[ $((SECONDS - start)) -le 3 ]] || fail "took $((SECONDS - start))s with --interval 5"
}

test_sigint_exits_130() {
  # A watcher that outlives the test proves SIGINT terminates it
  fake_inotifywait 30
  agent_pane new a
  set_state a working
  PATH="$TEST_TMP/bin:$PATH" "$TM" wait a --until idle --interval 5 >/dev/null 2>&1 &
  local pid=$!
  sleep 0.5
  kill -INT "$pid"
  local code; wait "$pid"; code=$?
  assert_eq 130 "$code" exit
  sleep 0.3
  assert_eq "" "$(pgrep -f "$TEST_TMP/bin/inotifywait")" no-leftover-watcher
}

run_tests
