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

test_installer_updates_moved_tm_path() {
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'JSON'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/old/place/tm.sh hook-state idle"}]}]}}
JSON
  local out; out=$("$TM" install-claude-hook)
  assert_contains "$out" "Updated" reported
  python3 - "$HOME/.claude/settings.json" "$TM" <<'PY' || fail "Stop hook not updated"
import json, shlex, sys
d = json.load(open(sys.argv[1]))
cmds = [h["command"] for g in d["hooks"]["Stop"] for h in g["hooks"]]
assert cmds == [shlex.quote(sys.argv[2]) + " hook-state idle"], cmds
PY
}

test_installer_leaves_foreign_hooks() {
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'JSON'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/my/wrapper.sh hook-state idle"}]}]}}
JSON
  "$TM" install-claude-hook >/dev/null
  python3 - "$HOME/.claude/settings.json" "$TM" <<'PY' || fail "foreign hook changed or tm hook missing"
import json, shlex, sys
d = json.load(open(sys.argv[1]))
cmds = [h["command"] for g in d["hooks"]["Stop"] for h in g["hooks"]]
assert "/my/wrapper.sh hook-state idle" in cmds, cmds
assert shlex.quote(sys.argv[2]) + " hook-state idle" in cmds, cmds
PY
}

test_installer_skips_unparsable_command() {
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'JSON'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "'unclosed tm.sh hook-state idle"}, {"type": "command", "command": 7}]}]}}
JSON
  local code; "$TM" install-claude-hook >/dev/null 2>&1; code=$?
  assert_eq 0 "$code" exit
}


# A tm hook behind an env assignment or "bash" is the user's wrapper around
# tm: it must not be repointed, and no duplicate tm hook may be added
test_installer_no_duplicate_beside_prefixed_tm_hook() {
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'JSON'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "TM_NOTIFY_ON=blocked,idle /x/tm.sh hook-state idle"}]}],
           "Notification": [{"hooks": [{"type": "command", "command": "bash /x/tm.sh hook-state blocked"}]}]}}
JSON
  "$TM" install-claude-hook >/dev/null
  assert_eq 1 "$(count_cmd Stop 'hook-state idle')" stop-once
  assert_eq 1 "$(count_cmd Notification 'hook-state blocked')" notification-once
  assert_contains "$(cat "$HOME/.claude/settings.json")" "TM_NOTIFY_ON=blocked,idle /x/tm.sh hook-state idle" wrapper-kept
}

run_tests
