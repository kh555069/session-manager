#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# start_dash [args]: run tm dash in its own session; sets DASH_SOCK
start_dash() {
  tmux new-session -d -s dash -x 120 -y 40 "$TM dash $*"
  local i
  DASH_SOCK=""
  for i in $(seq 50); do
    DASH_SOCK=$(ls "$HOME"/.tmux-manager/run/dash-*.sock 2>/dev/null | head -1)
    [[ -n "$DASH_SOCK" ]] && break
    sleep 0.1
  done
  [[ -n "$DASH_SOCK" ]] || fail "dash socket not found"
  sleep 0.5
}

# fzf_state <python-expr>: query the dash fzf over its socket
fzf_state() {
  curl -s --unix-socket "$DASH_SOCK" http://localhost | json "$1"
}

test_dash_reloads_on_state_change() {
  new_session a; new_session b
  start_dash
  assert_not_contains "$(fzf_state '[m["text"] for m in d["matches"]]')" "❓" before
  set_state a blocked
  sleep 3
  assert_contains "$(fzf_state '[m["text"] for m in d["matches"]]')" "❓" after
}

test_reload_keeps_cursor_session() {
  new_session a; new_session b; new_session c
  start_dash
  tmux send-keys -t dash Down
  sleep 0.3
  local before; before=$(fzf_state 'd["current"]["text"].split("\t")[1].strip()')
  # Another session turns blocked and jumps to the top of the list
  local other; for other in a b c; do [[ "$other" != "$before" ]] && break; done
  set_state "$other" blocked
  sleep 3
  assert_eq "$before" "$(fzf_state 'd["current"]["text"].split("\t")[1].strip()')" cursor
}

test_dash_exit_stops_watcher() {
  new_session a
  start_dash
  local sock="$DASH_SOCK"
  tmux send-keys -t dash Escape
  sleep 3
  assert_eq "" "$(pgrep -f "$sock")" no-watcher
  [[ ! -e "$sock" ]] || fail "socket left behind: $sock"
}

test_dash_sigterm_stops_watcher() {
  new_session a
  start_dash
  local sock="$DASH_SOCK" pane_pid; pane_pid=$(tmux display-message -p -t dash '#{pane_pid}')
  kill -TERM "$pane_pid"
  sleep 3
  assert_eq "" "$(pgrep -f "$sock")" no-watcher
}

test_dash_reload_action() {
  new_session a; new_session b
  local out; out=$("$TM" _dash-reload b)
  assert_contains "$out" "reload-sync(" reload
  [[ "$out" =~ \+pos\(([0-9]+)\)$ ]] || fail "no pos in <$out>"
  assert_eq b "$("$TM" _list | sed -n "$((BASH_REMATCH[1] + 1))p" | awk -F'\t' '{x=$2; sub(/ +$/, "", x); print x}')" pos-points-at-b
  assert_not_contains "$("$TM" _dash-reload nope)" "pos(" missing-session
}

run_tests
