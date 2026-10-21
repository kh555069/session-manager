#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

settings() { echo "$HOME/.claude/settings.json"; }

# count_cmd <event> <suffix>: number of hook commands under the event ending with suffix
count_cmd() {
  jq --arg s "$2" "[.hooks.$1[]?.hooks[]?.command | select(endswith(\$s))] | length" "$(settings)"
}

backups() {
  ls "$HOME/.claude/" | grep -c 'settings.json.tm-backup-' || true
}

assert_all_events() {
  local pair ev st
  for pair in SessionStart:idle UserPromptSubmit:working PreToolUse:working \
              PostToolUse:working Notification:blocked Stop:idle SessionEnd:dead; do
    ev=${pair%%:*}; st=${pair##*:}
    assert_eq 1 "$(count_cmd "$ev" "hook-state $st")" "$ev"
  done
  assert_eq 1 "$(count_cmd SessionStart _record-claude-session)" recorder
}

test_install_adds_all_events() {
  "$TM" install-claude-hook >/dev/null
  assert_all_events
  assert_contains "$(jq -r '.hooks.Stop[0].hooks[0].command' "$(settings)")" "$TM" absolute-path
}

test_install_idempotent() {
  mkdir -p "$HOME/.claude"
  echo '{}' > "$(settings)"
  "$TM" install-claude-hook >/dev/null
  local out; out=$("$TM" install-claude-hook)
  assert_all_events
  assert_contains "$out" "already installed" message
  assert_eq 1 "$(backups)" backups
}

test_install_preserves_user_hooks() {
  mkdir -p "$HOME/.claude"
  cat > "$(settings)" <<'JSON'
{"model": "opus", "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "my-guard.sh"}]}]}}
JSON
  "$TM" install-claude-hook >/dev/null
  assert_all_events
  assert_eq 1 "$(count_cmd PreToolUse my-guard.sh)" user-hook
  assert_eq Bash "$(jq -r '.hooks.PreToolUse[0].matcher' "$(settings)")" matcher
  assert_eq opus "$(jq -r .model "$(settings)")" model
}

test_install_upgrades_old_install() {
  mkdir -p "$HOME/.claude"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s _record-claude-session"}]}]}}\n' \
    "$TM" > "$(settings)"
  "$TM" install-claude-hook >/dev/null
  assert_all_events
}

test_install_rejects_malformed_event() {
  mkdir -p "$HOME/.claude"
  echo '{"hooks": {"Stop": "x"}}' > "$(settings)"
  local before err code
  before=$(cat "$(settings)")
  err=$("$TM" install-claude-hook 2>&1 >/dev/null); code=$?
  [[ $code -ne 0 ]] || fail "expected non-zero exit"
  assert_contains "$err" "hooks.Stop must be an array" stderr
  assert_eq "$before" "$(cat "$(settings)")" unchanged
  assert_eq 0 "$(backups)" backups
}

run_tests
