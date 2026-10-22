#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# start_dash [args]: run tm dash in its own session; sets DASH_SOCK.
# DASH_PATH, when set, is prepended to PATH inside the dash pane.
start_dash() {
  tmux new-session -d -s dash -x 120 -y 40 "PATH='${DASH_PATH:+$DASH_PATH:}$PATH' $TM dash $*"
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

# ─── Final review fixes ───────────────────────────────

# current_name: session name under the fzf cursor
current_name() { fzf_state 'd["current"]["text"].split("\t")[1].strip()'; }

# inotifywait exits 2 when its timeout passes without an event (Linux)
test_dash_survives_inotify_timeout() {
  mkdir -p "$TEST_TMP/watchbin"
  printf '#!/bin/bash\nsleep 1\nexit 2\n' > "$TEST_TMP/watchbin/inotifywait"
  chmod +x "$TEST_TMP/watchbin/inotifywait"
  new_session a
  set_state a idle  # the watcher only uses inotifywait once the state dir exists
  DASH_PATH="$TEST_TMP/watchbin" start_dash
  sleep 3
  [[ -n "$(pgrep -f "_dash-watch $DASH_SOCK")" ]] || fail "watcher died after an inotify timeout"
  set_state a blocked
  sleep 3
  assert_contains "$(fzf_state '[m["text"] for m in d["matches"]]')" "❓" still-reloading
}

test_reload_keeps_cursor_with_query() {
  new_session yy1; new_session xx1; new_session yy2; new_session xx2; new_session xx3
  start_dash
  tmux send-keys -t dash -l xx
  sleep 0.5
  tmux send-keys -t dash Down
  sleep 0.5
  local before; before=$(current_name)
  set_state yy1 blocked
  sleep 3
  assert_eq "$before" "$(current_name)" cursor-with-query
}

test_reload_keeps_multi_selection() {
  new_session a; new_session b; new_session c
  start_dash
  tmux send-keys -t dash Tab
  sleep 0.5
  assert_eq 1 "$(fzf_state 'len(d["selected"])')" selected-before
  set_state c blocked
  sleep 3
  assert_eq 1 "$(fzf_state 'len(d["selected"])')" selected-after
}

test_ctrl_c_in_prompt_keeps_dash() {
  new_session a
  start_dash
  tmux send-keys -t dash C-e
  sleep 0.8
  tmux send-keys -t dash C-c
  sleep 1.5
  [[ -n "$(curl -s --max-time 2 --unix-socket "$DASH_SOCK" http://localhost)" ]] || fail "dash quit on Ctrl-C in a prompt"
}

run_tests
