#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

test_tm_version() {
  assert_contains "$("$TM" --version)" "tm v1.0.0" version
}

test_tmux_is_isolated() {
  new_session iso
  assert_eq "iso" "$(tmux ls -F '#{session_name}')" sessions
}

run_tests
