#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# Claude Code sends no hook when the user interrupts a turn (Esc / Ctrl-C);
# the transcript ends the turn with "[Request interrupted by user...]"
# instead. Entry shapes follow a real Claude Code 2.1.309 transcript
# (2026-10-23).

# iso <seconds offset>: transcript timestamp, e.g. 2026-10-23T08:43:27.384Z
iso() {
  python3 -c 'import sys, time; t = time.time() + float(sys.argv[1]); print(time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".384Z")' "$1"
}

transcript() { echo "$TEST_TMP/transcript.jsonl"; }

prompt_entry() {
  printf '{"type":"user","message":{"role":"user","content":"do the task"},"timestamp":"%s"}\n' "$(iso "${1:-0}")" >> "$(transcript)"
}

tool_use_entry() {
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]},"timestamp":"%s"}\n' "$(iso 0)" >> "$(transcript)"
}

tool_result_entry() {
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"x"}]},"timestamp":"%s"}\n' "$(iso 0)" >> "$(transcript)"
}

# interrupt_entry [suffix] [offset]: suffix "" or " for tool use"
interrupt_entry() {
  printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user%s]"}]},"timestamp":"%s"}\n' "${1:-}" "$(iso "${2:-0}")" >> "$(transcript)"
}

meta_entries() {
  printf '%s\n' \
    "{\"type\":\"system\",\"subtype\":\"turn_duration\",\"timestamp\":\"$(iso 0)\"}" \
    '{"type":"last-prompt"}' '{"type":"ai-title"}' '{"type":"mode"}' '{"type":"permission-mode"}' >> "$(transcript)"
}

hook_working() {
  set_state a working "{\"hook_event_name\":\"UserPromptSubmit\",\"transcript_path\":\"$(transcript)\"}"
}

agent_field() {
  "$TM" ls --json | json "d[\"sessions\"][0][\"agents\"][0][\"$1\"]"
}

test_records_transcript_path() {
  agent_pane new a
  hook_working
  assert_eq "$(transcript)" "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["transcript_path"])' "$STATE_DIR/$(pane_id a | tr -d %).json")" transcript_path
}

test_interrupt_turns_working_idle() {
  agent_pane new a
  prompt_entry
  hook_working
  assert_eq working "$(agent_field state)" before
  interrupt_entry "" 1
  assert_eq idle "$(agent_field state)" after
  assert_eq hook "$(agent_field source)" source
  assert_eq null "$(agent_field reason)" reason
}

test_interrupt_since_is_interrupt_time() {
  agent_pane new a
  prompt_entry
  hook_working
  # One timestamp for both the entry and the expectation: computing iso twice
  # can straddle a second boundary
  local ts; ts=$(iso 2)
  printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"%s"}\n' "$ts" >> "$(transcript)"
  local since; since=$(agent_field since)
  assert_eq "${ts:0:19}Z" "$since" since
}

test_denied_permission_turns_blocked_idle() {
  agent_pane new a
  prompt_entry
  tool_use_entry
  set_state a blocked "{\"notification_type\":\"permission_prompt\",\"message\":\"m\",\"transcript_path\":\"$(transcript)\"}"
  assert_eq blocked "$(agent_field state)" before
  tool_result_entry
  interrupt_entry " for tool use" 1
  assert_eq idle "$(agent_field state)" after
  assert_eq null "$(agent_field message)" message
}

test_metadata_after_interrupt_is_skipped() {
  agent_pane new a
  prompt_entry
  hook_working
  interrupt_entry " for tool use" 1
  meta_entries
  assert_eq idle "$(agent_field state)" state
}

test_new_prompt_after_old_interrupt_stays_working() {
  agent_pane new a
  prompt_entry -20
  interrupt_entry "" -10
  prompt_entry
  hook_working
  assert_eq working "$(agent_field state)" state
}

test_interrupt_older_than_record_is_ignored() {
  agent_pane new a
  prompt_entry -20
  interrupt_entry "" -10
  hook_working
  assert_eq working "$(agent_field state)" state
}

test_running_tool_stays_working() {
  agent_pane new a
  prompt_entry
  hook_working
  tool_use_entry
  tool_result_entry
  assert_eq working "$(agent_field state)" state
}

test_missing_or_garbled_transcript_keeps_state() {
  agent_pane new a
  set_state a working '{"hook_event_name":"UserPromptSubmit","transcript_path":"/nonexistent/t.jsonl"}'
  assert_eq working "$(agent_field state)" missing
  printf 'not json\n{"type":"user","message":"oops"}\n' > "$(transcript)"
  hook_working
  assert_eq working "$(agent_field state)" garbled
  set_state a working '{"hook_event_name":"UserPromptSubmit","transcript_path":["x"]}'
  assert_eq working "$(agent_field state)" non-string-path
}

test_idle_and_dead_never_read_the_transcript() {
  agent_pane new a
  prompt_entry
  set_state a idle "{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$(transcript)\"}"
  local since; since=$(agent_field since)
  interrupt_entry "" 5
  assert_eq idle "$(agent_field state)" state
  assert_eq "$since" "$(agent_field since)" since-unchanged
}

test_wait_after_change_sees_interrupt() {
  agent_pane new a
  prompt_entry
  hook_working
  ( sleep 1.5; interrupt_entry "" 0 ) &
  local out code; out=$("$TM" wait a --until done --after-change --interval 0.2 --timeout 8s); code=$?
  wait
  assert_eq 0 "$code" exit
  assert_eq idle "$(json 'd["state"]' <<< "$out")" state
}

test_state_count_counts_interrupted_as_idle() {
  agent_pane new a
  prompt_entry
  hook_working
  assert_eq "⏳1" "$("$TM" state-count --format plain)" before
  interrupt_entry "" 1
  assert_eq "💤1" "$("$TM" state-count --format plain)" after
}

run_tests
