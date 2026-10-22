#!/usr/bin/env bash
# Shared helpers for tm.sh tests. Source this file, define test_* functions,
# then call run_tests at the end.
#
# Every test runs against a copy of tm.sh with its own HOME and its own tmux
# socket directory, so the user's real sessions and the repo's snapshots/ are
# never touched.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
CURRENT_TEST=""

setup_env() {
  TEST_TMP=$(mktemp -d)
  export HOME="$TEST_TMP/home"
  export TMUX_TMPDIR="$TEST_TMP/tmux"
  export COLUMNS=200
  unset TMUX TMUX_PANE TM_SORT TM_STALE_AFTER
  mkdir -p "$HOME" "$TMUX_TMPDIR" "$TEST_TMP/bin"
  cp "$REPO_ROOT/tm.sh" "$TEST_TMP/bin/tm.sh"
  chmod +x "$TEST_TMP/bin/tm.sh"
  TM="$TEST_TMP/bin/tm.sh"
  STATE_DIR="$HOME/.tmux-manager/state"
}

# Stop the isolated tmux server by ending its pane processes: once every pane
# exits, tmux closes the sessions and the server exits on its own. This only
# sees the server under $TMUX_TMPDIR, never the user's.
teardown_env() {
  local pid
  for pid in $(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null); do
    kill "$pid" 2>/dev/null || true
  done
}

# Create a detached test session whose pane runs a long sleep.
new_session() {
  local name="$1"
  tmux new-session -d -s "$name" -c "$TEST_TMP" "sleep 600"
}

# Print the pane id (e.g. %3) of a target such as "a" or "a:0.1".
pane_id() {
  tmux display-message -p -t "$1" '#{pane_id}'
}

fail() {
  echo "  FAIL [$CURRENT_TEST] $1" >&2
  FAILURES=$((FAILURES + 1))
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    fail "$label: expected <$expected>, got <$actual>"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "$label: <$needle> not found in:"$'\n'"$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "$label: <$needle> unexpectedly found in:"$'\n'"$haystack"
  fi
}

# json <python-expr>: evaluate an expression on the JSON read from stdin (bound to d).
# eval is safe here: expressions are literals written in the test files, never input.
json() {
  python3 -c 'import json, sys; d = json.load(sys.stdin); v = eval(sys.argv[1]); print(json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list, bool)) or v is None else v)' "$1"
}

# set_state <target> <state> [payload]: write a state file via the real hook.
# The default payload is a permission prompt so "blocked" is recorded.
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

# agent_pane new|split <session-or-target>: a pane running a fake claude,
# so hook states are confirmed by a live agent process
agent_pane() {
  [[ -x "$TEST_TMP/bin/claude" ]] || fake_agent claude
  if [[ "$1" == new ]]; then
    tmux new-session -d -s "$2" -c "$TEST_TMP" "$TEST_TMP/bin/claude"
  else
    tmux split-window -d -t "$2" "$TEST_TMP/bin/claude"
  fi
  sleep 0.3
}

run_tests() {
  local fn before
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    CURRENT_TEST="$fn"
    before=$FAILURES
    setup_env
    "$fn"
    teardown_env
    if [[ $FAILURES -eq $before ]]; then
      echo "  ok   $fn"
    fi
  done
  if [[ $FAILURES -gt 0 ]]; then
    echo "$(basename "$0"): $FAILURES failure(s)"
    exit 1
  fi
  echo "$(basename "$0"): all passed"
}
