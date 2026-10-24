#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# The preview summarizes each Claude agent's transcript: the last prompt, the
# tools of the current turn and the last reply. Entry shapes follow a real
# Claude Code 2.1.309 transcript (2026-10-24).

transcript() { echo "$TEST_TMP/transcript.jsonl"; }

ts() { python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%S.100Z", time.gmtime()))'; }

# entry <json without timestamp>: append a transcript line stamped now
entry() { printf '%s,"timestamp":"%s"}\n' "${1%\}}" "$(ts)" >> "$(transcript)"; }

prompt() { entry "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":$(json_str "$1")}}"; }
reply() { entry "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":$(json_str "$1")}]}}"; }
# tool_use <id> <name> <input json>
tool_use() { entry "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"$2\",\"input\":$3}]}}"; }
tool_result() { entry "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":\"ok\"}]}}"; }

json_str() { python3 -c 'import json, sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"; }

# agent <state>: session a with a live fake claude whose state file points at the transcript
agent() {
  agent_pane new a
  : >> "$(transcript)"
  set_state a "$1" "{\"notification_type\":\"permission_prompt\",\"message\":\"m\",\"transcript_path\":\"$(transcript)\"}"
}

preview() { "$TM" _preview a | sed 's/\x1b\[[0-9;]*m//g'; }

test_idle_agent_shows_prompt_tools_and_reply() {
  prompt "merge the branch"
  tool_use t1 Bash '{"command":"git merge --ff-only feat","description":"Merge"}'
  tool_result t1
  reply "Merged and pushed."
  agent idle
  local out; out=$(preview)
  assert_contains "$out" "You: merge the branch" prompt
  assert_contains "$out" "Bash git merge --ff-only feat" tool
  assert_contains "$out" "Claude: Merged and pushed." reply
}

test_running_tool_is_marked() {
  prompt "fix the timeout"
  tool_use t1 Read '{"file_path":"/repo/src/crawler.py"}'
  tool_result t1
  tool_use t2 Edit '{"file_path":"/repo/src/crawler.py","old_string":"a","new_string":"b"}'
  agent working
  local out; out=$(preview)
  assert_contains "$out" "Read crawler.py" done-tool
  assert_contains "$out" "Edit crawler.py …" running-tool
  assert_contains "$out" "2 tools" count
}

test_only_last_three_tools_are_listed() {
  prompt "go"
  local i
  for i in 1 2 3 4 5; do
    tool_use "t$i" Bash "{\"command\":\"step$i\"}"
    tool_result "t$i"
  done
  agent working
  local out; out=$(preview)
  assert_contains "$out" "5 tools" count
  assert_not_contains "$out" "step2" old-tool
  assert_contains "$out" "step3" recent-tool
  assert_contains "$out" "step5" last-tool
}

test_new_prompt_starts_a_new_turn() {
  prompt "old task"
  tool_use t1 Bash '{"command":"old-cmd"}'
  tool_result t1
  reply "old answer"
  prompt "new task"
  agent working
  local out; out=$(preview)
  assert_contains "$out" "You: new task" prompt
  assert_not_contains "$out" "old-cmd" old-tool
  assert_not_contains "$out" "old answer" old-reply
}

test_slash_command_prompt_is_shown_as_command() {
  prompt $'<command-message>vault-sync</command-message>\n<command-name>/vault-sync</command-name>\n<command-args>--all</command-args>'
  agent idle
  assert_contains "$(preview)" "You: /vault-sync --all" command
}

test_meta_sidechain_and_wrapper_entries_are_skipped() {
  prompt "real task"
  entry '{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"skill body"}]}}'
  entry '{"type":"user","message":{"role":"user","content":"<system-reminder>note</system-reminder>"}}'
  entry '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent says"}]}}'
  entry '{"type":"system","subtype":"turn_duration"}'
  agent idle
  local out; out=$(preview)
  assert_contains "$out" "You: real task" prompt
  assert_not_contains "$out" "skill body" meta
  assert_not_contains "$out" "system-reminder" wrapper
  assert_not_contains "$out" "subagent says" sidechain
}

test_interrupted_turn_is_marked() {
  prompt "long task"
  tool_use t1 Bash '{"command":"sleep 100"}'
  entry '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}'
  agent working
  local out; out=$(preview)
  assert_contains "$out" "You: long task" prompt
  assert_contains "$out" "(interrupted)" marker
  assert_not_contains "$out" "You: [Request" not-a-prompt
}

test_long_text_is_cut_and_controls_dropped() {
  prompt "$(printf 'p%.0s' $(seq 300))"
  reply $'line one\nline two\x1b[31m red'
  agent idle
  local out; out=$(preview)
  local you; you=$(grep "You:" <<< "$out")
  [[ ${#you} -lt 200 ]] || fail "prompt not cut: ${#you} chars"
  assert_contains "$you" "…" ellipsis
  assert_contains "$out" "Claude: line one line two" joined
  assert_not_contains "$("$TM" _preview a)" $'\x1b[31m' no-escape
}

test_missing_transcript_shows_state_only() {
  agent_pane new a
  set_state a idle '{"transcript_path":"/nonexistent/t.jsonl"}'
  local out; out=$(preview)
  assert_contains "$out" "idle" state
  assert_not_contains "$out" "You:" no-summary
}

test_blocked_agent_shows_summary() {
  prompt "deploy"
  tool_use t1 Bash '{"command":"touch x"}'
  agent blocked
  local out; out=$(preview)
  assert_contains "$out" "You: deploy" prompt
  assert_contains "$out" "Bash touch x …" waiting-tool
  assert_contains "$out" "blocked" state
}

test_long_reply_keeps_its_start_and_its_question() {
  prompt "design it"
  reply "## Design
**Plan** first: $(printf 'x%.0s' $(seq 400))
Shall I merge it into \`main\`?"
  agent idle
  local line; line=$(preview | grep "Claude:")
  assert_contains "$line" "Claude: Design Plan first:" start-without-markdown
  assert_contains "$line" "Shall I merge it into main?" ending-question
  assert_contains "$line" " … " gap
  [[ ${#line} -lt 260 ]] || fail "reply not cut: ${#line} chars"
}

test_tool_name_cannot_inject_escapes_or_columns() {
  prompt "go"
  tool_use t1 'Ba\u001b[31msh\tX' '{"command":"ls"}'
  tool_result t1
  reply "done"
  agent idle
  local raw; raw=$("$TM" _preview a)
  assert_not_contains "$raw" $'\x1b[31m' no-escape
  # A tab in the name must not shift the reply into another column
  assert_contains "$(preview)" "Claude: done" reply-intact
}

run_tests
