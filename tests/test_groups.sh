#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# Grouping is off by default in the other test files (lib.sh); it is the
# subject here, so every test turns it back on.
group_env() { export TM_GROUPS=on; }

# session_in <name> <dir>: a detached session whose path is $TEST_TMP/<dir>
session_in() {
  mkdir -p "$TEST_TMP/$2"
  tmux new-session -d -s "$1" -c "$TEST_TMP/$2" "sleep 600"
}

# rows: _list without its header, NAME column trimmed, "KIND NAME" per line
# (G = group row, whose NAME ends with ":"; S = session row)
rows() {
  "$TM" _list | awk -F'\t' 'NR > 1 {
    x = $2; sub(/^ +/, "", x); sub(/ +$/, "", x)
    print ((x ~ /:$/) ? "G " : "S ") x
  }'
}

# group_row <label>: the full _list line of the group labelled <label>
group_row() {
  "$TM" _list | awk -F'\t' -v l="$1:" '{x = $2; sub(/ +$/, "", x); if (x == l) print}'
}

# raw_col2 <label>: column 2 of a group row as fzf passes it with {2}
raw_col2() { group_row "$1" | cut -f2; }

test_shared_path_forms_a_group() {
  group_env
  session_in a x; session_in b x; session_in c y
  local out; out=$(rows)
  assert_contains "$out" "G $TEST_TMP/x:" group-row
  assert_not_contains "$out" "G $TEST_TMP/y:" singleton-has-no-group
  # Members follow their group row, indented in column 2
  assert_eq "S a S b" "$(grep -A2 "^G $TEST_TMP/x:" <<< "$out" | tail -2 | sort | tr '\n' ' ' | sed 's/ $//')" members
  assert_contains "$("$TM" _list | awk -F'\t' '$2 ~ /^  a/')" "a" indented
}

test_home_path_is_shortened_in_label() {
  group_env
  mkdir -p "$HOME/proj"
  tmux new-session -d -s a -c "$HOME/proj" "sleep 600"
  tmux new-session -d -s b -c "$HOME/proj" "sleep 600"
  assert_contains "$(rows)" "G ~/proj:" tilde
}

test_worktree_sessions_join_their_repo() {
  group_env
  session_in a repo; session_in b repo/.claude/worktrees/feat; session_in c repo/.worktrees/x
  assert_contains "$(rows)" "G $TEST_TMP/repo:" repo-group
  assert_eq 3 "$(rows | grep -c '^S ')" all-sessions
}

test_manual_group_overrides_path() {
  group_env
  session_in a x; session_in b x; session_in c y
  "$TM" group crawlers a c >/dev/null
  local out; out=$(rows)
  assert_contains "$out" "G crawlers:" manual-group
  # b is left alone in x, so x is no longer a group
  assert_not_contains "$out" "G $TEST_TMP/x:" path-group-gone
  assert_eq "S a S c" "$(grep -A2 '^G crawlers:' <<< "$out" | tail -2 | sort | tr '\n' ' ' | sed 's/ $//')" members
}

test_manual_group_of_one_session_is_shown() {
  group_env
  session_in a x; session_in b y
  "$TM" group solo a >/dev/null
  assert_contains "$(rows)" "G solo:" one-member-group
}

test_group_clear_returns_to_path() {
  group_env
  session_in a x; session_in b x
  "$TM" group crawlers a >/dev/null
  "$TM" group --clear a >/dev/null
  assert_not_contains "$(rows)" "G crawlers:" cleared
  assert_contains "$(rows)" "G $TEST_TMP/x:" back-to-path
}

test_group_name_is_sanitized() {
  group_env
  session_in a x
  "$TM" group "  web: api  " a >/dev/null
  assert_contains "$(rows)" "G web_ api:" colon-replaced
}

test_group_rejects_unknown_session() {
  group_env
  session_in a x
  "$TM" group crawlers nope >/dev/null 2>&1
  assert_eq 2 "$?" exit-code
  "$TM" group >/dev/null 2>&1
  assert_eq 3 "$?" usage
}

test_group_row_counts_states() {
  group_env
  session_in a x; session_in b x; session_in c x
  set_state a blocked
  set_state b working
  set_state c idle
  local row; row=$(group_row "$TEST_TMP/x")
  assert_contains "$row" "❓1" blocked
  assert_contains "$row" "⏳1" working
  assert_contains "$row" "💤1" idle
  assert_contains "$row" "(3)" total
}

test_group_with_blocked_member_goes_first() {
  group_env
  session_in a x; session_in b x; session_in c y
  set_state a blocked
  assert_eq "G $TEST_TMP/x:" "$(rows | head -1)" group-first
  # Inside the group the blocked member leads
  assert_eq "S a" "$(rows | sed -n 2p)" blocked-member-first
}

test_fold_hides_members_and_lists_their_names() {
  group_env
  session_in a x; session_in b x; session_in c y
  "$TM" _fold toggle "$(raw_col2 "$TEST_TMP/x")" >/dev/null
  local out; out=$(rows)
  assert_not_contains "$out" "S a" a-hidden
  assert_not_contains "$out" "S b" b-hidden
  assert_contains "$out" "S c" c-shown
  local row; row=$(group_row "$TEST_TMP/x")
  assert_contains "$row" "▸" folded-arrow
  # Member names stay on the row so a query still finds the group
  [[ "$row" == *"a, b"* || "$row" == *"b, a"* ]] || fail "member names missing in <$row>"
  "$TM" _fold toggle "$(raw_col2 "$TEST_TMP/x")" >/dev/null
  assert_contains "$(rows)" "S a" unfolded
  assert_contains "$(group_row "$TEST_TMP/x")" "▾" open-arrow
}

test_fold_survives_restart_of_list() {
  group_env
  session_in a x; session_in b x
  "$TM" _fold collapse "$(raw_col2 "$TEST_TMP/x")" >/dev/null
  assert_contains "$(cat "$HOME/.tmux-manager/folded.txt")" "$TEST_TMP/x" saved
}

test_collapse_from_member_row_folds_parent_and_points_at_it() {
  group_env
  session_in c y; session_in a x; session_in b x
  local out; out=$("$TM" _fold collapse a)
  assert_contains "$out" "reload-sync(" reload
  [[ "$out" =~ \+pos\(([0-9]+)\)$ ]] || fail "no pos in <$out>"
  assert_eq "G $TEST_TMP/x:" "$(rows | sed -n "${BASH_REMATCH[1]}p")" pos-is-group
  assert_not_contains "$(rows)" "S a" folded
}

test_arrows_with_query_move_the_cursor() {
  group_env
  session_in a x; session_in b x
  assert_eq "forward-char" "$(FZF_QUERY=q "$TM" _fold expand a)" right
  assert_eq "backward-char" "$(FZF_QUERY=q "$TM" _fold collapse a)" left
  assert_not_contains "$(rows)" "▸" nothing-folded
}

test_arrows_on_ungrouped_session_do_nothing() {
  group_env
  session_in a x; session_in b y
  assert_eq "" "$("$TM" _fold collapse a)" no-action
}

test_enter_toggles_group_and_accepts_session() {
  group_env
  session_in a x; session_in b x
  assert_eq "accept" "$("$TM" _enter a)" session
  assert_contains "$("$TM" _enter "$(raw_col2 "$TEST_TMP/x")")" "reload-sync(" group
  assert_contains "$(group_row "$TEST_TMP/x")" "▸" toggled
}

test_session_actions_ignore_group_rows() {
  group_env
  session_in a x; session_in b x
  local g; g=$(raw_col2 "$TEST_TMP/x")
  "$TM" _kill-selected "$g" </dev/null >/dev/null 2>&1
  "$TM" _toggle-protect "$g" >/dev/null 2>&1
  "$TM" _rename "$g" </dev/null >/dev/null 2>&1
  assert_eq 2 "$(tmux list-sessions | wc -l | tr -d ' ')" nothing-killed
  [[ ! -s "$HOME/.tmux-manager/protected.txt" ]] || fail "group row protected"
}

test_group_preview_lists_members() {
  group_env
  session_in a x; session_in b x
  set_state a blocked
  local out; out=$("$TM" _preview "$(raw_col2 "$TEST_TMP/x")")
  assert_contains "$out" "Group" title
  assert_contains "$out" "a" member-a
  assert_contains "$out" "b" member-b
  assert_contains "$out" "❓" state
  assert_not_contains "$out" "Session not found" not-a-session
}

test_rename_keeps_manual_group() {
  group_env
  session_in a x; session_in b y
  "$TM" group crawlers a >/dev/null
  printf 'renamed\n' | "$TM" _rename a >/dev/null 2>&1
  assert_contains "$(grep -A1 '^G crawlers:' <<< "$(rows)")" "S renamed" moved
}

test_dash_reload_keeps_cursor_on_group_row() {
  group_env
  session_in c y; session_in a x; session_in b x
  local g; g=$(raw_col2 "$TEST_TMP/x")
  local out; out=$("$TM" _dash-reload "$g")
  [[ "$out" =~ \+pos\(([0-9]+)\)$ ]] || fail "no pos in <$out>"
  assert_eq "G $TEST_TMP/x:" "$(rows | sed -n "${BASH_REMATCH[1]}p")" pos-is-group
}

test_groups_off_keeps_flat_list() {
  session_in a x; session_in b x
  TM_GROUPS=off "$TM" group crawlers a >/dev/null
  assert_not_contains "$(TM_GROUPS=off rows)" "G " flat
  assert_eq 2 "$(TM_GROUPS=off rows | grep -c '^S ')" both-sessions
}

# ─── Keys in a real fzf (tm dash) ─────────────────────

start_dash() {
  tmux new-session -d -s dash -c "$TEST_TMP/z" -x 160 -y 40 "TM_GROUPS=on $TM dash $*"
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

fzf_texts() { curl -s --unix-socket "$DASH_SOCK" http://localhost | json '"\n".join(m["text"] for m in d["matches"])'; }
current_name() { curl -s --unix-socket "$DASH_SOCK" http://localhost | json 'd["current"]["text"].split("\t")[1].strip()'; }

test_keys_fold_and_unfold_in_fzf() {
  group_env
  mkdir -p "$TEST_TMP/z"
  session_in a x; session_in b x
  start_dash
  # Rows: dash (ungrouped, most recent) then the x group; move onto a member
  local i
  for i in 1 2 3; do
    [[ "$(current_name)" == "a" || "$(current_name)" == "b" ]] && break
    tmux send-keys -t dash Down; sleep 0.3
  done
  tmux send-keys -t dash Left
  sleep 1.5
  assert_eq "$TEST_TMP/x:" "$(current_name)" cursor-on-group
  assert_not_contains "$(fzf_texts | cut -f2)" "  a" folded
  tmux send-keys -t dash Enter
  sleep 1.5
  assert_contains "$(fzf_texts | cut -f2)" "  a" unfolded-by-enter
  # Enter on a group row must not leave fzf
  [[ -S "$DASH_SOCK" ]] || fail "dash exited on Enter"
}

test_enter_on_session_row_still_accepts() {
  group_env
  mkdir -p "$TEST_TMP/z"
  session_in a x; session_in b x
  start_dash --popup
  local i
  for i in 1 2 3; do
    [[ "$(current_name)" == "a" || "$(current_name)" == "b" ]] && break
    tmux send-keys -t dash Down; sleep 0.3
  done
  tmux send-keys -t dash Enter
  sleep 1.5
  # --popup exits after Enter is accepted on a session row
  tmux has-session -t dash 2>/dev/null && fail "Enter on a session row did not leave fzf"
  return 0
}

run_tests
