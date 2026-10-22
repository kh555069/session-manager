#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

set_state() {
  printf '%s' "${3:-{\}}" | TMUX_PANE="$(pane_id "$1")" "$TM" hook-state "$2"
}

test_preview_shows_blocked_agent() {
  new_session a
  set_state a blocked '{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
  local out; out=$("$TM" _preview a)
  assert_contains "$out" "── Agents" section
  assert_contains "$out" "❓" icon
  assert_contains "$out" "blocked (permission)" state
  assert_contains "$out" "Claude needs your permission to use Bash" message
}

test_preview_hides_section_without_state() {
  new_session a
  assert_not_contains "$("$TM" _preview a)" "── Agents" section
}

test_preview_message_single_line() {
  new_session a
  set_state a blocked '{"notification_type":"permission_prompt","message":"line1\nline2\tx"}'
  local out; out=$("$TM" _preview a)
  assert_contains "$out" "line1 line2 x" joined
}

test_preview_strips_control_chars() {
  new_session a
  set_state a blocked '{"notification_type":"permission_prompt","message":"\u001b]0;pwned\u0007\u001b[31mred\u001b[0m text"}'
  local out; out=$("$TM" _preview a)
  assert_contains "$out" "red" text-kept
  assert_not_contains "$out" "pwned"$'\a' bell
  assert_not_contains "$out" $'\e]0;' osc
  assert_not_contains "$out" $'\e[31m' sgr
}

test_save_removes_orphan_state() {
  new_session a
  set_state a idle
  local id; id=$(pane_id a)
  echo '{"v":1,"state":"idle"}' > "$STATE_DIR/99999.json"
  local out; out=$("$TM" save)
  [[ ! -e "$STATE_DIR/99999.json" ]] || fail "orphan not removed"
  [[ -e "$STATE_DIR/${id#%}.json" ]] || fail "live pane state removed"
  assert_contains "$out" "Removed 1 orphan state file" message
}

test_save_keeps_state_when_none_orphan() {
  new_session a
  set_state a idle
  assert_not_contains "$("$TM" save)" "Removed" message
}

test_preview_shows_blocked_screen() {
  tmux new-session -d -s a -c "$TEST_TMP" "printf 'line-%s\n' \$(seq 1 30); printf 'Allow Bash? \033[31m(y/n)\033[0m\n'; sleep 600"
  sleep 0.3
  set_state a blocked '{"notification_type":"permission_prompt"}'
  local out; out=$("$TM" _preview a | sed 's/\x1b\[[0-9;]*m//g')
  assert_contains "$out" "Allow Bash? (y/n)" last-line
  assert_contains "$out" "line-30" within-15
  assert_not_contains "$out" "line-10" older-lines-cut
}

test_preview_no_screen_for_idle() {
  tmux new-session -d -s a -c "$TEST_TMP" "echo SCREEN-MARKER; sleep 600"
  sleep 0.3
  set_state a idle
  assert_not_contains "$("$TM" _preview a)" "SCREEN-MARKER" idle
}

test_save_removes_stale_tmp_files() {
  new_session a
  set_state a idle '{}'
  local stale="$STATE_DIR/$(pane_id a | tr -d %).json.99999.tmp" fresh="$STATE_DIR/1.json.88888.tmp"
  echo '{' > "$stale"; echo '{' > "$fresh"
  touch -t 202001010000 "$stale"
  "$TM" save >/dev/null
  [[ ! -e "$stale" ]] || fail "stale tmp kept"
  [[ -e "$fresh" ]] || fail "fresh tmp removed (a hook may be writing it)"
}

# AI summaries and session paths are outside text: echo -e would turn a
# literal \t into a tab (tmux itself escapes backslashes in session names)
test_preview_prints_backslashes_literally() {
  mkdir -p "$TEST_TMP/dir\\tname"
  tmux new-session -d -s a -c "$TEST_TMP/dir\\tname" "sleep 600"
  mkdir -p "$HOME/.tmux-manager/summaries"
  printf '%s\n' '{"ts":1,"summary":"fix a\tb parsing"}' > "$HOME/.tmux-manager/summaries/a.jsonl"
  local out; out=$("$TM" _preview a)
  assert_contains "$out" 'fix a\tb parsing' literal-summary
  assert_contains "$out" 'dir\tname' literal-path
}

run_tests
