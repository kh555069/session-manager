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
