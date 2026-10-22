#!/usr/bin/env bash
# ╭──────────────────────────────────────────────────────╮
# │  tm -- tmux Session Manager                          │
# │  Self-routing single-file script                     │
# │  Dependencies: bash 4+, tmux, fzf                    │
# ╰──────────────────────────────────────────────────────╯
# Auto-detect tmux binary; define wrapper only when not in PATH
if ! command -v tmux &>/dev/null; then
  for _p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
    if [[ -x "$_p" ]]; then eval "tmux() { \"$_p\" \"\$@\"; }"; break; fi
  done
  unset _p
fi
set -euo pipefail

# Force a UTF-8 locale. Under cron the locale is unset; tmux then treats the TAB
# separators in our -F format strings (e.g. `tm save`) as control chars and
# rewrites them to '_', breaking `IFS=$'\t' read` splitting and yielding an
# empty snapshot. Manual runs work only because the login shell sets LANG.
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-$LANG}"

# ─── 1. Constants ──────────────────────────────────────

readonly VERSION="1.0.0"
# Resolve paths without forking (realpath/dirname → pure bash)
_self="${BASH_SOURCE[0]}"
if [[ -L "$_self" ]]; then
  _self="$(realpath "$_self")"  # fork only for symlinks
else
  [[ "$_self" != /* ]] && _self="${PWD}/${_self}"
fi
readonly SELF="$_self"
readonly CONFIG_DIR="${HOME}/.tmux-manager"
readonly PROTECTED_FILE="${CONFIG_DIR}/protected.txt"
readonly CLAUDE_SESSION_MAP="${CONFIG_DIR}/claude_sessions.jsonl"
readonly STATE_DIR="${CONFIG_DIR}/state"
# Seconds without a hook write before a working agent is shown as "working?"
if [[ "${TM_STALE_AFTER:-}" =~ ^[1-9][0-9]*$ ]]; then
  readonly STALE_AFTER="$TM_STALE_AFTER"
else
  readonly STALE_AFTER=1800
fi
readonly CLAUDE_PROJECTS="${HOME}/.claude/projects"
readonly CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
readonly SCRIPT_DIR="${SELF%/*}"
readonly SNAPSHOT_DIR="${SCRIPT_DIR}/snapshots"
readonly SNAPSHOT_FILE="${SNAPSHOT_DIR}/sessions.json"
readonly SNAPSHOT_HISTORY_DIR="${SNAPSHOT_DIR}/history"
readonly SNAPSHOT_KEEP="${TM_SNAPSHOT_KEEP:-48}"
readonly PROJECT_BASE="${TM_PROJECT_BASE:-${SCRIPT_DIR%/*}}"
readonly FZF="${SCRIPT_DIR}/fzf"
unset _self

# Semantic ANSI colors (only those actually used)
readonly C_RESET=$'\033[0m'
readonly C_BOLD=$'\033[1m'
readonly C_DIM=$'\033[2m'
readonly C_RED=$'\033[0;31m'
readonly C_GREEN=$'\033[0;32m'
readonly C_YELLOW=$'\033[0;33m'
readonly C_CYAN=$'\033[0;36m'
readonly C_WHITE=$'\033[1;37m'
readonly C_BG_RED=$'\033[41m'
readonly C_BG_YELLOW=$'\033[43m'

# Processes that trigger a warning before kill
readonly IMPORTANT_PROCS="claude|codex|python|node|npm|cargo|go|java|docker|kubectl"

# Performance cache for batch queries (populated by _build_list_cache)
_CACHED_SESSION_DATA=""
_CACHED_PROTECTED=""
_CACHED_AGENT_STATE=""
_CACHE_LOADED=0

# ─── 2. Init & Dependency Check ───────────────────────

_init() {
  # Skip filesystem ops if already initialized (saves 4 forks)
  if [[ -d "${CONFIG_DIR}/summaries" && -f "$PROTECTED_FILE" ]]; then
    return
  fi
  mkdir -p "$CONFIG_DIR"
  mkdir -p "${CONFIG_DIR}/templates"
  mkdir -p "${CONFIG_DIR}/summaries"
  touch "$PROTECTED_FILE"

  # Seed default dev template if none exists
  if [[ ! -f "${CONFIG_DIR}/templates/dev" ]]; then
    cat > "${CONFIG_DIR}/templates/dev" <<'TMPL'
# dev — typical development layout
# Format: window_name [shell_command]
editor
server
logs
TMPL
  fi
}

_check_cmd() {
  # Check if a command exists; print install hint on failure
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${C_RED}✗ Missing required tool: ${cmd}${C_RESET}" >&2
    echo -e "${C_DIM}Install via:${C_RESET}" >&2
    echo "  macOS:  brew install ${cmd}" >&2
    echo "  Ubuntu: sudo apt install ${cmd}" >&2
    exit 1
  fi
}

_check_deps() {
  _check_cmd tmux
  if [[ ! -x "$FZF" ]]; then
    echo -e "${C_RED}✗ fzf not found: ${FZF}${C_RESET}" >&2
    exit 1
  fi
}

# ─── 3. Protection Lock ───────────────────────────────

_is_protected() {
  local name="$1"
  if [[ $_CACHE_LOADED -eq 1 ]]; then
    [[ $'\n'"${_CACHED_PROTECTED}"$'\n' == *$'\n'"$name"$'\n'* ]]
    return
  fi
  grep -qxF "$name" "$PROTECTED_FILE" 2>/dev/null
}

_toggle_protect() {
  local name="$1"
  if _is_protected "$name"; then
    # Remove from protected list
    local tmp; tmp=$(mktemp)
    grep -vxF "$name" "$PROTECTED_FILE" > "$tmp" || true
    mv "$tmp" "$PROTECTED_FILE"
    echo -e "${C_YELLOW}🔓 Unprotected: ${name}${C_RESET}"
  else
    echo "$name" >> "$PROTECTED_FILE"
    echo -e "${C_GREEN}🔒 Protected: ${name}${C_RESET}"
  fi
}

# ─── 4. tmux Queries ──────────────────────────────────

_has_tmux_server() {
  tmux list-sessions &>/dev/null
}

_is_inside_tmux() {
  [[ -n "${TMUX:-}" ]]
}

_current_session() {
  if _is_inside_tmux; then
    tmux display-message -p '#{session_name}' 2>/dev/null
  fi
}

# List unique pane commands for a session
_session_procs() {
  local name="$1"
  if [[ $_CACHE_LOADED -eq 1 ]]; then
    local s cnt procs_str
    while IFS=$'\t' read -r s cnt procs_str; do
      if [[ "$s" == "$name" ]]; then
        echo "${procs_str//|/$'\n'}"
        return
      fi
    done <<< "$_CACHED_SESSION_DATA"
    return
  fi
  tmux list-panes -t "$name" -F '#{pane_current_command}' 2>/dev/null | sort -u
}

_session_pane_count() {
  local name="$1"
  if [[ $_CACHE_LOADED -eq 1 ]]; then
    local s cnt rest
    while IFS=$'\t' read -r s cnt rest; do
      if [[ "$s" == "$name" ]]; then
        echo "$cnt"
        return
      fi
    done <<< "$_CACHED_SESSION_DATA"
    echo "0"
    return
  fi
  tmux list-panes -t "$name" 2>/dev/null | wc -l | tr -d ' '
}

# Batch pre-cache session data (single tmux+awk call replaces N per-session forks)
# Output format per line: SESSION_NAME\tPANE_COUNT\tPROC1|PROC2|...
_build_list_cache() {
  _CACHED_SESSION_DATA=$(tmux list-panes -a -F $'#{session_name}\t#{pane_current_command}' 2>/dev/null \
    | awk -F'\t' '{
        count[$1]++
        if (!seen[$1,$2]++) procs[$1] = (procs[$1] ? procs[$1] "|" : "") $2
      }
      END {
        for (s in count) print s "\t" count[s] "\t" procs[s]
      }')
  _CACHED_PROTECTED=""
  [[ -f "$PROTECTED_FILE" ]] && _CACHED_PROTECTED=$(<"$PROTECTED_FILE")
  _CACHED_AGENT_STATE=$(tmux list-panes -a \
    -F $'#{session_name}\t#{pane_id}\t#{session_created}\t#{window_index}.#{pane_index}' 2>/dev/null \
    | _agent_states session) || _CACHED_AGENT_STATE=""
  _CACHE_LOADED=1
}

# Python helpers shared by every reader of agent state files, so the fzf list
# and `tm ls --json` apply the same validity rules. Must not contain single quotes.
readonly _PY_STATE_LIB='
import calendar, json, os, re, sys, time

# Terminal escape sequences (OSC, CSI) and other control characters in file
# fields must never reach the terminal
_escapes = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b\[[0-?]*[ -/]*[@-~]|\x1b.?")
_controls = re.compile(r"[\x00-\x1f\x7f-\x9f]")

def epoch(value):
    try:
        return calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None

def clean(value):
    text = _controls.sub(" ", _escapes.sub("", str(value))) if value else ""
    return " ".join(text.split()) or "-"

def load_state(state_dir, pane, created, now, stale_after):
    """Validated state of one pane, or None when its state file is unusable.

    Ignored: unreadable or non-object files, unknown states, missing ts, and
    files older than the session (pane ids restart with the tmux server).
    dead is reported as unknown; working older than stale_after is stale.
    """
    try:
        with open(os.path.join(state_dir, pane.lstrip("%") + ".json")) as f:
            record = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(record, dict):
        return None
    state = record.get("state")
    ts = epoch(record.get("ts"))
    if state not in ("working", "blocked", "idle", "dead") or ts is None:
        return None
    if str(created).isdigit() and ts < int(created):
        return None
    if state == "dead":
        state = "unknown"
    stale = state == "working" and now - ts > stale_after
    return {"state": state, "stale": stale, "ts": ts,
            "since": epoch(record.get("since")) or ts, "record": record}
'

# Read agent state files for the panes given on stdin.
# Input lines:  SESSION \t PANE_ID \t SESSION_CREATED \t WIN.PANE
# Mode session: SESSION \t AGG_STATE  (blocked > working? > working > idle > unknown)
# Mode pane:    WIN.PANE \t PANE_ID \t STATE \t SINCE_EPOCH \t REASON \t MESSAGE
#               (only panes with a valid state file; empty REASON/MESSAGE → "-")
# Validity rules live in load_state (_PY_STATE_LIB).
_agent_states() {
  local mode="$1"
  command -v python3 &>/dev/null || return 0
  python3 -I -S -c "${_PY_STATE_LIB}"'
mode, state_dir, stale_after = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = time.time()
rank = {"unknown": 0, "idle": 1, "working": 2, "working?": 3, "blocked": 4}

order, agg = [], {}
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 4:
        continue
    session, pane, created, target = parts
    if session not in agg:
        order.append(session)
        agg[session] = "unknown"
    loaded = load_state(state_dir, pane, created, now, stale_after)
    if loaded is None:
        continue
    state = "working?" if loaded["stale"] else loaded["state"]
    if rank[state] > rank[agg[session]]:
        agg[session] = state
    if mode == "pane" and state != "unknown":
        record = loaded["record"]
        print("\t".join([target, pane, state, str(loaded["since"]),
                         clean(record.get("reason")), clean(record.get("message"))]))

if mode == "session":
    for session in order:
        print(f"{session}\t{agg[session]}")
' "$mode" "$STATE_DIR" "$STALE_AFTER"
}

# Aggregated agent state of a session from the list cache → $_AGENT_STATE
# (default: unknown). Sets a global instead of echoing to avoid a subshell fork.
_session_agent_state() {
  local name="$1" s st
  _AGENT_STATE="unknown"
  while IFS=$'\t' read -r s st; do
    if [[ "$s" == "$name" ]]; then
      _AGENT_STATE="$st"
      return
    fi
  done <<< "$_CACHED_AGENT_STATE"
}

# Icon for an agent state → $_STATE_ICON
_state_icon() {
  case "$1" in
    blocked)   _STATE_ICON="❓" ;;
    working)   _STATE_ICON="⏳" ;;
    working\?) _STATE_ICON="⏳?" ;;
    idle)      _STATE_ICON="💤" ;;
    *)         _STATE_ICON="·" ;;
  esac
}

_clear_list_cache() {
  _CACHE_LOADED=0
}

# Convert epoch timestamp to human-readable relative time
_relative_time() {
  local timestamp="$1"
  [[ -z "$timestamp" || "$timestamp" == "0" ]] && echo "N/A" && return
  local now diff
  now="${_NOW:-$(date +%s)}"
  diff=$((now - timestamp))
  if [[ $diff -lt 60 ]]; then
    echo "now"
  elif [[ $diff -lt 3600 ]]; then
    echo "$((diff / 60))m"
  elif [[ $diff -lt 86400 ]]; then
    echo "$((diff / 3600))h"
  elif [[ $diff -lt 604800 ]]; then
    echo "$((diff / 86400))d"
  else
    echo "$((diff / 604800))w"
  fi
}

# Convert RSS (KB) to human-readable format
_format_rss() {
  local kb="${1:-0}"
  kb="${kb#"${kb%%[! ]*}"}"  # trim leading spaces
  [[ -z "$kb" || "$kb" == "0" ]] && echo "0K" && return
  if [[ $kb -ge 1048576 ]]; then
    local gi=$((kb / 1048576))
    local gf=$(( (kb % 1048576) * 10 / 1048576 ))
    echo "${gi}.${gf}G"
  elif [[ $kb -ge 1024 ]]; then
    local mi=$((kb / 1024))
    local mf=$(( (kb % 1024) * 10 / 1024 ))
    echo "${mi}.${mf}M"
  else
    echo "${kb}K"
  fi
}

# Map directory to a consistent color based on top-level folder
_dir_group_color() {
  local path="$1"
  # $HOME itself gets dim
  if [[ "$path" == "$HOME" ]]; then
    echo "$C_DIM"
    return
  fi
  local rel="${path/#$HOME\//}"
  local group="${rel%%/*}"
  # Deterministic color from first char + length (no subprocess)
  local len=${#group}
  local first_char="${group:0:1}"
  local ord
  printf -v ord '%d' "'$first_char"
  local idx=$(( (ord + len) % 6 ))
  local -a palette=("\033[0;36m" "\033[0;32m" "\033[0;33m" "\033[0;35m" "\033[0;34m" "\033[1;36m")
  echo -e "${palette[$idx]}"
}

# Strip lock icon and trim whitespace from session name (zero forks)
_parse_name() {
  _PARSED="${1// 🔒/}"
  _PARSED="${_PARSED#"${_PARSED%%[![:space:]]*}"}"
  _PARSED="${_PARSED%"${_PARSED##*[![:space:]]}"}"
}

# Detect narrow terminal (< 80 columns) — cached after first call
_NARROW=""
_is_narrow() {
  if [[ -z "$_NARROW" ]]; then
    local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 120)}"
    [[ $cols -lt 80 ]] && _NARROW=1 || _NARROW=0
  fi
  [[ "$_NARROW" == "1" ]]
}

# ─── 5. Formatted Output for fzf ─────────────────────

_format_session_line() {
  # Output (wide):   STATUS\tNAME[+lock]\tPATH\tWINDOWS\tPANES\tIDLE\tPROCS
  # Output (narrow): STATUS\tNAME[+lock]\tWINDOWS\tPANES\tIDLE\tPROCS
  local name="$1" attached="$2" windows="$3" path="$4" activity="${5:-0}"
  local panes current status lock="" procs_display="" has_important=0

  panes=$(_session_pane_count "$name")
  current="${_CURRENT_SESSION:-}"

  # Status indicator (bracket style, colored by directory group)
  local grp_color
  grp_color=$(_dir_group_color "$path")
  if [[ "$name" == "$current" ]]; then
    status="${grp_color}[▸]${C_RESET}"
  elif [[ "$attached" == "1" ]]; then
    status="${grp_color}[●]${C_RESET}"
  else
    status="${grp_color}[○]${C_RESET}"
  fi
  _session_agent_state "$name"
  _state_icon "$_AGENT_STATE"
  status+=" ${_STATE_ICON}"

  # Protection lock icon
  if _is_protected "$name"; then
    lock=" 🔒"
  fi

  # Detect important processes
  local procs_raw
  procs_raw=$(_session_procs "$name")
  while IFS= read -r proc; do
    [[ -z "$proc" ]] && continue
    if [[ "$proc" =~ $IMPORTANT_PROCS ]]; then
      has_important=1
      procs_display+="${proc},"
    fi
  done <<< "$procs_raw"
  procs_display="${procs_display%,}"

  # Shorten path (replace $HOME with ~, truncate if >30 chars)
  local short_path="${path/#$HOME/~}"
  if [[ ${#short_path} -gt 30 ]]; then
    short_path="…${short_path: -29}"
  fi

  local idle
  idle=$(_relative_time "$activity")

  if _is_narrow; then
    # Narrow: drop DIRECTORY column, shorten NAME
    printf "%s\t%-16s\t%s\t%s\t%s\t%s\n" \
      "$status" "${name}${lock}" "$windows" "$panes" "$idle" "${procs_display:--}"
  else
    printf "%s\t%-20s\t%-30s\t%s\t%s\t%s\t%s\n" \
      "$status" \
      "${name}${lock}" \
      "$short_path" \
      "$windows" \
      "$panes" \
      "$idle" \
      "${procs_display:--}"
  fi
}

# ─── 6. Sub-commands ──────────────────────────────────

# List all sessions (consumed by fzf)
_cmd_list() {
  # Fetch sessions once (also serves as server-alive check, avoids extra _has_tmux_server fork)
  local fmt='#{session_name};#{session_attached};#{session_windows};#{session_path};#{session_last_attached};#{session_activity}'
  local sessions_raw
  sessions_raw=$(tmux list-sessions -F "$fmt" 2>/dev/null) || true
  if [[ -z "$sessions_raw" ]]; then
    echo "(No tmux sessions)"
    return
  fi
  # Column header (frozen by --header-lines=1 in fzf)
  if _is_narrow; then
    printf "ST   \t%-16s\t%s\t%s\t%s\n" "NAME" "W" "P" "IDLE"
  else
    printf "ST   \t%-20s\t%-30s\t%s\t%s\t%s\n" "NAME" "DIRECTORY" "W" "P" "IDLE"
  fi
  # Batch pre-cache to avoid per-session fork overhead
  _build_list_cache
  _CURRENT_SESSION=$(_current_session)
  _NOW=$(date +%s)
  # Sort by session_last_attached descending (most recent first).
  # Unless TM_SORT=recent, sessions with a blocked agent go first (two passes
  # keep the recency order inside each group).
  local sorted pass blocked
  sorted=$(sort -t';' -k5,5 -rn <<< "$sessions_raw")
  for pass in blocked rest; do
    if [[ "${TM_SORT:-}" == "recent" ]]; then
      [[ "$pass" == "blocked" ]] && continue
    fi
    while IFS=';' read -r name attached windows path _last_attached activity; do
      if [[ "${TM_SORT:-}" != "recent" ]]; then
        blocked=0
        _session_agent_state "$name"
        [[ "$_AGENT_STATE" == "blocked" ]] && blocked=1
        [[ "$pass" == "blocked" && $blocked -eq 0 ]] && continue
        [[ "$pass" == "rest" && $blocked -eq 1 ]] && continue
      fi
      _format_session_line "$name" "$attached" "$windows" "$path" "$activity"
    done <<< "$sorted"
  done
}

# Preview panel (fzf bottom panel)
_cmd_preview() {
  local raw_name="$1"
  _parse_name "$raw_name"
  local name="$_PARSED"

  # Single tmux call for all session metadata (replaces has-session + 5× display-message)
  local session_info
  session_info=$(tmux display-message -t "$name" -p \
    '#{session_path};#{session_windows};#{session_created};#{session_attached};#{session_activity}' 2>/dev/null) || true
  local path windows created clients activity
  IFS=';' read -r path windows created clients activity <<< "$session_info"
  if [[ -z "$path" ]]; then
    echo "Session not found: $name"
    return
  fi

  # Pane count from list-panes (will be called anyway for process info)
  local proc_lines
  proc_lines=$(tmux list-panes -t "$name" -F '#{pane_pid} #{pane_current_command}' 2>/dev/null)
  local panes=0
  if [[ -n "$proc_lines" ]]; then
    while IFS= read -r _; do ((panes++)); done <<< "$proc_lines"
  fi

  # Format creation time (macOS-first, fallback to GNU)
  local created_fmt
  if [[ "$OSTYPE" == darwin* ]]; then
    created_fmt=$(date -r "$created" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$created")
  else
    created_fmt=$(date -d "@$created" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$created")
  fi

  local protected_status="No"
  if _is_protected "$name"; then
    protected_status="Yes"
  fi

  # Git branch (if session directory is a git repo)
  local git_branch=""
  if [[ -n "$path" ]]; then
    git_branch=$(git -C "$path" branch --show-current 2>/dev/null || true)
  fi

  # Idle time
  _NOW=$(date +%s)
  local idle_str
  idle_str=$(_relative_time "$activity")

  echo -e "${C_BOLD}── Session Details ──────────────────${C_RESET}"
  echo -e "🏷️  ${C_CYAN}${name}${C_RESET}"
  echo -e "📂 ${path/#$HOME/~}"
  if [[ -n "$git_branch" ]]; then
    echo -e "🌿 ${C_GREEN}${git_branch}${C_RESET}"
  fi
  echo -e "🪟 ${windows} win · ${panes} pane · ${clients} client"
  echo -e "🕒 ${created_fmt} · idle ${idle_str}"
  echo -e "🔒 ${protected_status}"

  # Latest AI summary (pure bash — no tail/sed forks)
  local summary_file="${CONFIG_DIR}/summaries/${name}.jsonl"
  if [[ -f "$summary_file" ]]; then
    local last_line=""
    while IFS= read -r _l; do last_line="$_l"; done < "$summary_file"
    if [[ -n "$last_line" ]]; then
      local _tmp="${last_line#*\"summary\":\"}"
      local last_summary="${_tmp%%\"*}"
      _tmp="${last_line#*\"ts\":}"
      local last_ts="${_tmp%%[,\}]*}"
      if [[ -n "$last_summary" && "$last_summary" != "$last_line" ]]; then
        local summary_age
        summary_age=$(_relative_time "$last_ts")
        echo -e "💡 ${last_summary} ${C_DIM}(${summary_age})${C_RESET}"
      fi
    fi
  fi

  # Agent states (section hidden when no pane has a valid state file)
  local agent_lines
  agent_lines=$(tmux list-panes -t "$name" -s \
    -F $'#{session_name}\t#{pane_id}\t#{session_created}\t#{window_index}.#{pane_index}' 2>/dev/null \
    | _agent_states pane) || agent_lines=""
  if [[ -n "$agent_lines" ]]; then
    echo ""
    echo -e "${C_BOLD}── Agents ───────────────────────────${C_RESET}"
    local a_target a_pane a_state a_since a_reason a_message a_label
    while IFS=$'\t' read -r a_target a_pane a_state a_since a_reason a_message; do
      _state_icon "$a_state"
      a_label="$a_state"
      [[ "$a_reason" != "-" ]] && a_label+=" (${a_reason})"
      if [[ "$a_state" == "blocked" ]]; then
        echo -e "  ${_STATE_ICON} ${a_target}  ${C_RED}${a_label}${C_RESET} · $(_relative_time "$a_since")"
      else
        echo -e "  ${_STATE_ICON} ${a_target}  ${a_label} · $(_relative_time "$a_since")"
      fi
      if [[ "$a_state" == "blocked" && "$a_message" != "-" ]]; then
        # printf, not echo -e: the message is agent text and may contain backslashes
        printf '     %s%s%s\n' "$C_DIM" "$a_message" "$C_RESET"
      fi
    done <<< "$agent_lines"
  fi

  echo ""
  echo -e "${C_BOLD}── Running Processes ────────────────${C_RESET}"

  # proc_lines already fetched above for pane count
  if [[ -z "$proc_lines" ]]; then
    echo -e "  ${C_DIM}(None)${C_RESET}"
  else
    # Cache process tree once for child lookups
    local ps_tree all_pids=()
    ps_tree=$(ps -axo pid=,ppid=,comm= 2>/dev/null)

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local pid="${line%% *}"
      local fg_cmd="${line#* }"

      # Get shell's real command name + resource usage in single ps call
      local shell_cmd shell_cpu shell_rss shell_mem
      read -r shell_cmd shell_cpu shell_rss <<< "$(ps -p "$pid" -o comm=,%cpu=,rss= 2>/dev/null)"
      shell_cmd="${shell_cmd##*/}"
      shell_cmd="${shell_cmd#-}"
      [[ -z "$shell_cmd" ]] && shell_cmd="$fg_cmd"
      shell_mem=$(_format_rss "${shell_rss:-0}")
      all_pids+=("$pid")

      # Show shell process with resource usage
      echo -e "  ${C_DIM}▸ ${shell_cmd}  (${pid})  CPU ${shell_cpu:-0.0}% · RAM ${shell_mem}${C_RESET}"

      # Show child if foreground process differs from shell
      if [[ "$fg_cmd" != "$shell_cmd" && "$fg_cmd" != "-${shell_cmd}" ]]; then
        local child_pid child_cmd display_cmd
        child_pid=$(echo "$ps_tree" | awk -v p="$pid" '{gsub(/ /,"",$1); gsub(/ /,"",$2)} $2==p {print $1; exit}')
        if [[ -n "$child_pid" ]]; then
          # Single ps call for child name + resource usage
          local child_cpu child_rss child_mem
          read -r child_cmd child_cpu child_rss <<< "$(ps -p "$child_pid" -o comm=,%cpu=,rss= 2>/dev/null)"
          child_cmd="${child_cmd##*/}"
          child_mem=$(_format_rss "${child_rss:-0}")
          # Combine real name + version if fg_cmd is version-like
          if [[ "$fg_cmd" =~ ^[0-9]+\.[0-9] && -n "$child_cmd" && ! "$child_cmd" =~ ^[0-9.]+$ ]]; then
            display_cmd="${child_cmd} ${fg_cmd}"
          else
            display_cmd="${child_cmd:-$fg_cmd}"
          fi
          all_pids+=("$child_pid")

          if [[ "$display_cmd" =~ $IMPORTANT_PROCS ]]; then
            echo -e "    ${C_YELLOW}└─ ${display_cmd}  ${C_DIM}(${child_pid})  CPU ${child_cpu:-0.0}% · RAM ${child_mem}${C_RESET}"
          else
            echo -e "    ${C_DIM}└─ ${display_cmd}  (${child_pid})  CPU ${child_cpu:-0.0}% · RAM ${child_mem}${C_RESET}"
          fi
        fi
      fi
    done <<< "$proc_lines"

    # Session resource usage total
    if [[ ${#all_pids[@]} -gt 0 ]]; then
      local pid_list="" total_cpu total_rss total_mem
      local _p; for _p in "${all_pids[@]}"; do pid_list="${pid_list:+$pid_list,}$_p"; done
      read -r total_cpu total_rss <<< "$(ps -p "$pid_list" -o %cpu=,rss= 2>/dev/null \
        | awk '{cpu+=$1; rss+=$2} END {printf "%.1f %d", cpu, rss}')"
      total_mem=$(_format_rss "${total_rss:-0}")
      echo ""
      echo -e "  ${C_BOLD}Total: CPU ${total_cpu:-0.0}% · RAM ${total_mem}${C_RESET}"
    fi
  fi

  echo ""
  echo -e "${C_BOLD}── Window List ─────────────────────${C_RESET}"

  while IFS= read -r line; do
    echo -e "  ${line}"
  done < <(tmux list-windows -t "$name" \
    -F '#{window_index}: #{window_name} #{?window_active,(active),}' 2>/dev/null)
}

# Kill session with 3-tier safeguard
_cmd_kill() {
  local raw_name="$1"
  _parse_name "$raw_name"
  local name="$_PARSED"

  # Guard 1: protection lock
  if _is_protected "$name"; then
    echo -e "${C_BG_RED}${C_WHITE} ✗ Blocked ${C_RESET} Session '${name}' is protected 🔒"
    echo -e "${C_DIM}  Use Ctrl-P to unprotect before deleting.${C_RESET}"
    echo ""
    read -rsp "Press any key to return..." -n1
    return 1
  fi

  # Guard 2: current session check
  local current
  current=$(_current_session)
  if [[ "$name" == "$current" ]]; then
    echo -e "${C_BG_RED}${C_WHITE} ✗ Blocked ${C_RESET} Cannot close the current session"
    echo -e "${C_DIM}  You are inside '${name}'. Switch to another session first.${C_RESET}"
    echo ""
    read -rsp "Press any key to return..." -n1
    return 1
  fi

  echo -e "${C_RED}${C_BOLD}══════════════════════════════════════${C_RESET}"
  echo -e "${C_RED}${C_BOLD}  ⚠  About to close session: ${name}${C_RESET}"
  echo -e "${C_RED}${C_BOLD}══════════════════════════════════════${C_RESET}"
  echo ""

  # Guard 3: important process warning
  local procs has_important=0
  procs=$(_session_procs "$name")
  if [[ -n "$procs" ]]; then
    while IFS= read -r proc; do
      [[ -z "$proc" ]] && continue
      if [[ "$proc" =~ $IMPORTANT_PROCS ]]; then
        has_important=1
      fi
    done <<< "$procs"
  fi

  if [[ $has_important -eq 1 ]]; then
    echo -e "${C_BG_YELLOW}${C_BOLD} ⚠️  Warning: Important processes detected! ${C_RESET}"
    echo ""
    while IFS= read -r proc; do
      [[ -z "$proc" ]] && continue
      if [[ "$proc" =~ $IMPORTANT_PROCS ]]; then
        echo -e "  ${C_YELLOW}⚡ ${proc}${C_RESET}"
      else
        echo -e "  ${C_DIM}  ${proc}${C_RESET}"
      fi
    done <<< "$procs"
    echo ""
  fi

  # Confirmation: must type full session name
  echo -e "Type ${C_BOLD}${name}${C_RESET} to confirm deletion (or press Enter to cancel):"
  echo -n "> "
  read -r confirm

  if [[ "$confirm" != "$name" ]]; then
    echo -e "${C_GREEN}✓ Cancelled${C_RESET}"
    sleep 0.5
    return 0
  fi

  tmux kill-session -t "$name" 2>/dev/null
  echo -e "${C_RED}✗ Session '${name}' closed${C_RESET}"
  sleep 0.8
}

# Interactive session creation
_cmd_create() {
  echo -e "${C_BOLD}╭─ New tmux Session ─────────────────╮${C_RESET}"
  echo -e "${C_BOLD}╰────────────────────────────────────╯${C_RESET}"
  echo ""

  # Pick project directory via fzf (macOS compatible: ls instead of find -printf)
  local sess_dir=""
  if [[ -d "$PROJECT_BASE" ]]; then
    echo -e "${C_CYAN}Select project directory (ESC to skip):${C_RESET}"
    local selected
    selected=$(
      ls -1 "$PROJECT_BASE" 2>/dev/null \
        | while read -r d; do
            [[ -d "${PROJECT_BASE}/${d}" && "${d:0:1}" != "." ]] && echo "$d"
          done \
        | sort \
        | "$FZF" --height=10 \
              --border="rounded" \
              --prompt="Dir > " \
              --header="Select project directory" \
              --no-multi \
        || true
    )
    if [[ -n "$selected" ]]; then
      sess_dir="${PROJECT_BASE}/${selected}"
    fi
  fi

  # If no directory selected from fzf, prompt for manual input
  if [[ -z "$sess_dir" ]]; then
    echo ""
    echo -e "${C_CYAN}Enter directory path (Tab to autocomplete, Enter for ~):${C_RESET}"
    echo -n "> "
    read -er manual_dir
    if [[ -n "$manual_dir" ]]; then
      # Expand ~ to $HOME
      manual_dir="${manual_dir/#\~/$HOME}"
      if [[ -d "$manual_dir" ]]; then
        sess_dir=$(cd "$manual_dir" && pwd)
      else
        echo -e "${C_RED}✗ Directory not found: ${manual_dir}${C_RESET}"
        sleep 0.8
        return 1
      fi
    fi
  fi
  sess_dir="${sess_dir:-$HOME}"

  # Session name (default = directory basename; press Enter to accept)
  local default_name="${sess_dir##*/}"
  echo ""
  echo -e "${C_CYAN}Session name [${default_name}]:${C_RESET}"
  echo -n "> "
  read -r sess_name
  sess_name="${sess_name:-$default_name}"

  if [[ -z "$sess_name" ]]; then
    echo -e "${C_RED}✗ Name cannot be empty${C_RESET}"
    sleep 0.8
    return 1
  fi

  # Validate name (no spaces, dots, colons)
  if [[ "$sess_name" =~ [\ \.\:] ]]; then
    echo -e "${C_RED}✗ Name cannot contain spaces, dots, or colons${C_RESET}"
    sleep 0.8
    return 1
  fi

  # Check for duplicates
  if tmux has-session -t "$sess_name" 2>/dev/null; then
    echo -e "${C_RED}✗ Session '${sess_name}' already exists${C_RESET}"
    sleep 0.8
    return 1
  fi

  # Create session
  tmux new-session -d -s "$sess_name" -c "$sess_dir"
  echo -e "${C_GREEN}✓ Session created: ${sess_name}${C_RESET}"
  echo -e "${C_DIM}  Dir: ${sess_dir}${C_RESET}"
  sleep 0.5
}

# Rename session
_cmd_rename() {
  local raw_name="$1"
  _parse_name "$raw_name"
  local name="$_PARSED"

  # Prompt for new name
  echo -e "${C_CYAN}Rename session: ${name}${C_RESET}"
  echo -n "New name > "
  read -r new_name

  if [[ -z "$new_name" ]]; then
    echo -e "${C_DIM}Cancelled${C_RESET}"
    sleep 0.5
    return 0
  fi

  # Validate new name
  if [[ "$new_name" =~ [\ \.\:] ]]; then
    echo -e "${C_RED}✗ Name cannot contain spaces, dots, or colons${C_RESET}"
    sleep 0.8
    return 1
  fi

  if tmux has-session -t "$new_name" 2>/dev/null; then
    echo -e "${C_RED}✗ Session '${new_name}' already exists${C_RESET}"
    sleep 0.8
    return 1
  fi

  tmux rename-session -t "$name" "$new_name"

  # Sync protection lock list
  if _is_protected "$name"; then
    local tmp; tmp=$(mktemp)
    grep -vxF "$name" "$PROTECTED_FILE" > "$tmp" || true
    mv "$tmp" "$PROTECTED_FILE"
    echo "$new_name" >> "$PROTECTED_FILE"
  fi

  echo -e "${C_GREEN}✓ Renamed: ${name} → ${new_name}${C_RESET}"
  sleep 0.5
}

# Toggle protection (fzf keybind wrapper)
_cmd_toggle_protect() {
  local raw_name="$1"
  _parse_name "$raw_name"
  local name="$_PARSED"
  _toggle_protect "$name"
  sleep 0.3
}

# Kill multiple sessions (fzf multi-select via Ctrl-K)
_cmd_kill_selected() {
  shift  # skip sub-command name passed by self-routing
  if [[ $# -eq 0 ]]; then
    echo -e "${C_RED}✗ No session selected${C_RESET}"
    sleep 0.5
    return 1
  fi

  for raw_name in "$@"; do
    _parse_name "$raw_name"
    local name="$_PARSED"
    [[ -z "$name" ]] && continue
    _cmd_kill "$name"
  done
}

# Detach all other clients from a session (fzf keybind wrapper)
_cmd_detach_others() {
  local raw_name="$1"
  _parse_name "$raw_name"
  local name="$_PARSED"

  local count=0
  local my_client=""
  if _is_inside_tmux; then
    my_client=$(tmux display-message -p '#{client_tty}' 2>/dev/null)
  fi

  while IFS= read -r client_tty; do
    [[ -z "$client_tty" ]] && continue
    [[ "$client_tty" == "$my_client" ]] && continue
    tmux detach-client -t "$client_tty" 2>/dev/null && ((count++)) || true
  done < <(tmux list-clients -t "$name" -F '#{client_tty}' 2>/dev/null)

  if [[ $count -eq 0 ]]; then
    echo -e "${C_DIM}No other connections${C_RESET}"
  else
    echo -e "${C_GREEN}✓ Disconnected ${count} client(s)${C_RESET}"
  fi
  sleep 0.5
}

# ─── 7. Session Attach Helper ─────────────────────────

_attach_session() {
  local name="$1"
  # Record current session before switching (for "tm last")
  local current
  current=$(_current_session)
  if [[ -n "$current" && "$current" != "$name" ]]; then
    echo "$current" > "${CONFIG_DIR}/last_session"
  fi
  if _is_inside_tmux; then
    tmux switch-client -t "$name"
  else
    tmux attach-session -t "$name"
  fi
}

# ─── 8. Main Interface (fzf) ─────────────────────────

_cmd_main() {
  _check_deps

  if ! _has_tmux_server; then
    echo -e "${C_YELLOW}No tmux sessions found.${C_RESET}"
    echo ""
    echo -e "Create one? (Y/n)"
    echo -n "> "
    read -r answer
    if [[ "$answer" != "n" && "$answer" != "N" ]]; then
      _cmd_create
    fi
    # Fall through to fzf loop if session was created; exit otherwise
    if ! _has_tmux_server; then
      return
    fi
  fi

  # Loop: attach → detach → back to fzf menu
  # Exit loop on Esc or Ctrl-Q
  while true; do
    # Refresh: server may have been shut down while we were attached
    if ! _has_tmux_server; then
      echo -e "${C_YELLOW}No tmux sessions remaining.${C_RESET}"
      break
    fi

    # Adapt fzf header and column display for narrow terminals
    local fzf_header fzf_with_nth
    if _is_narrow; then
      fzf_header="↵Go Tab^Sel ^NNew ^KKill ^ERen ^DDtch ^PLock ^RRef Esc"
      fzf_with_nth="1,2,3,4,5"
    else
      fzf_header="Keys: ↵Enter │ Tab Multi-sel │ ^N New │ ^K Kill │ ^E Rename │ ^D Detach │ ^P Protect │ ^R Refresh │ ^Q Quit"
      fzf_with_nth="1,2,3,4,5,6"
    fi

    local selected
    selected=$(
      "$SELF" _list \
        | "$FZF" \
            --ansi --multi --reverse --exact \
            --border=rounded \
            --border-label=" tmux session manager v${VERSION} " \
            --header="$fzf_header" \
            --header-first \
            --header-lines=1 \
            --delimiter=$'\t' \
            --with-nth="$fzf_with_nth" \
            --preview="$SELF _preview {2}" \
            --preview-window="down:50%:wrap" \
            --bind="tab:toggle+down" \
            --bind="ctrl-n:execute($SELF _create </dev/tty >/dev/tty)+reload($SELF _list)" \
            --bind="ctrl-k:execute($SELF _kill-selected {+2} </dev/tty >/dev/tty)+reload($SELF _list)" \
            --bind="ctrl-e:execute($SELF _rename {2} </dev/tty >/dev/tty)+reload($SELF _list)" \
            --bind="ctrl-d:execute($SELF _detach-others {2} </dev/tty >/dev/tty)+reload($SELF _list)" \
            --bind="ctrl-p:execute-silent($SELF _toggle-protect {2})+reload($SELF _list)" \
            --bind="ctrl-r:reload($SELF _list)" \
            --bind="ctrl-q:abort" \
            --color="bg+:#283457,fg:#c0caf5,fg+:#c0caf5,hl:#ff9e64,hl+:#ff9e64" \
            --color="header:#565f89,info:#7aa2f7,pointer:#7dcfff,marker:#9ece6a" \
            --color="prompt:#7aa2f7,spinner:#9ece6a,border:#3b4261,label:#7aa2f7" \
        || true
    )

    # Esc / Ctrl-Q → empty selection → exit tm.sh
    if [[ -z "$selected" ]]; then
      break
    fi

    # Extract session name from first selected line; attach on Enter
    local first_line="${selected%%$'\n'*}"
    local session_name _skip
    IFS=$'\t' read -r _skip session_name _skip <<< "$first_line"
    _parse_name "$session_name"
    session_name="$_PARSED"
    if [[ -n "$session_name" ]]; then
      _attach_session "$session_name"
    fi
  done
}

# Switch to last session
_cmd_last() {
  local last
  last=$(cat "${CONFIG_DIR}/last_session" 2>/dev/null || true)
  if [[ -z "$last" ]] || ! tmux has-session -t "$last" 2>/dev/null; then
    echo -e "${C_RED}✗ No previous session record${C_RESET}" >&2
    return 1
  fi
  _attach_session "$last"
}

# ─── 9. CLI Commands ─────────────────────────────────

_cmd_help() {
  cat <<EOF
${C_BOLD}tm v${VERSION}${C_RESET} — tmux Session Manager

${C_BOLD}Usage:${C_RESET}
  tm                    Interactive menu (fzf)
  tm <session-name>     Attach to a session directly
  tm new <name> [dir] [-t tpl]  Create a new session
  tm kill <name>        Close a session (with safeguards)
  tm attach <name> [-d] Attach to session (-d: detach others)
  tm rename <name>      Rename a session
  tm last               Switch to previous session
  tm ls                 List all sessions (plain text)
  tm templates          List available templates
  tm protect <name>     Toggle protection status
  tm summarize <name>   Generate AI summary for a session
  tm summarize-all      Generate AI summaries for all sessions
  tm save               Snapshot all sessions, windows, panes, layouts & screens
  tm restore [--claude] [--codex] [--from <snapshot>]
                        Restore full session tree and optionally relaunch agents
  tm install-claude-hook  Install Claude session ID and agent state hooks
  tm snapshots [<snapshot>]  Show snapshot contents (latest by default)
  tm snapshots --list   List timestamped snapshot history
  tm screens [<session>] [--pane <window>.<pane>] [--from <snapshot>]
                        Show pane screens captured at save time (latest by default)
  tm help               Show this help

${C_BOLD}Interactive menu shortcuts:${C_RESET}
  Enter     Attach to selected session
  Ctrl-N    Create new session
  Ctrl-K    Close session (3-stage confirmation)
  Ctrl-E    Rename session
  Ctrl-D    Detach other connections
  Ctrl-P    Toggle protection lock
  Tab       Multi-select (batch delete with Ctrl-K)
  Ctrl-R    Refresh list
  Esc       Exit

${C_BOLD}Environment variables:${C_RESET}
  TM_PROJECT_BASE    Root directory for project picker on new session
                     Default: two levels above tm.sh
  TM_SNAPSHOT_KEEP   Number of timestamped snapshots kept by 'tm save'
                     Default: 48
  TM_SORT            Set to 'recent' to stop floating blocked agents to the top
  TM_STALE_AFTER     Seconds without a hook update before working shows as ⏳?
                     Default: 1800
EOF
}

# CLI quick create: tm new <name> [dir] [-t template]
_cmd_quick_new() {
  local name="" dir="" template=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--template)
        if [[ -n "${2:-}" ]]; then
          template="$2"; shift
        else
          echo -e "${C_RED}✗ --template requires a template name${C_RESET}" >&2
          return 1
        fi
        ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"
        elif [[ -z "$dir" ]]; then
          dir="$1"
        fi
        ;;
    esac
    shift
  done

  dir="${dir:-$HOME}"

  if [[ -z "$name" ]]; then
    echo -e "${C_RED}✗ Usage: tm new <name> [dir] [-t template]${C_RESET}" >&2
    return 1
  fi

  if [[ "$name" =~ [\ \.\:] ]]; then
    echo -e "${C_RED}✗ Name cannot contain spaces, dots, or colons${C_RESET}" >&2
    return 1
  fi

  if tmux has-session -t "$name" 2>/dev/null; then
    echo -e "${C_RED}✗ Session '${name}' already exists${C_RESET}" >&2
    return 1
  fi

  # Resolve dir to absolute path
  if [[ -d "$dir" ]]; then
    dir=$(cd "$dir" && pwd)
  else
    echo -e "${C_RED}✗ Directory not found: ${dir}${C_RESET}" >&2
    return 1
  fi

  if [[ -n "$template" ]]; then
    _apply_template "$name" "$dir" "$template"
  else
    tmux new-session -d -s "$name" -c "$dir"
  fi
  echo -e "${C_GREEN}✓ Session created: ${name}${C_RESET}"
  echo -e "${C_DIM}  Dir: ${dir}${C_RESET}"
  [[ -n "$template" ]] && echo -e "${C_DIM}  Template: ${template}${C_RESET}"
}

# CLI quick kill: tm kill <name>
_cmd_quick_kill() {
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    echo -e "${C_RED}✗ Usage: tm kill <name>${C_RESET}" >&2
    return 1
  fi

  if ! tmux has-session -t "$name" 2>/dev/null; then
    echo -e "${C_RED}✗ Session '${name}' not found${C_RESET}" >&2
    return 1
  fi

  # Same 3-tier safeguard as interactive kill
  _cmd_kill "$name"
}

# CLI attach with optional --detach-others: tm attach <name> [-d]
_cmd_attach() {
  local name="" detach_others=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--detach-others) detach_others=1 ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"
        fi
        ;;
    esac
    shift
  done

  if [[ -z "$name" ]]; then
    echo -e "${C_RED}✗ Usage: tm attach <name> [-d]${C_RESET}" >&2
    return 1
  fi

  if ! tmux has-session -t "$name" 2>/dev/null; then
    echo -e "${C_RED}✗ Session '${name}' not found${C_RESET}" >&2
    return 1
  fi

  # Kick all other clients from the target session
  if [[ $detach_others -eq 1 ]]; then
    local my_client=""
    if _is_inside_tmux; then
      my_client=$(tmux display-message -p '#{client_tty}' 2>/dev/null)
    fi
    while IFS= read -r client_tty; do
      [[ -z "$client_tty" ]] && continue
      [[ "$client_tty" == "$my_client" ]] && continue
      tmux detach-client -t "$client_tty" 2>/dev/null || true
    done < <(tmux list-clients -t "$name" -F '#{client_tty}' 2>/dev/null)
  fi

  _attach_session "$name"
}

# Apply a template to create a multi-window session
_apply_template() {
  local name="$1" dir="$2" template_name="$3"
  local template_file="${CONFIG_DIR}/templates/${template_name}"

  if [[ ! -f "$template_file" ]]; then
    echo -e "${C_RED}✗ Template not found: ${template_name}${C_RESET}" >&2
    local available
    available=$(ls "${CONFIG_DIR}/templates/" 2>/dev/null | tr '\n' ' ')
    if [[ -n "$available" ]]; then
      echo -e "${C_DIM}  Available templates: ${available}${C_RESET}" >&2
    fi
    echo -e "${C_DIM}  Create template: echo 'editor' > ${CONFIG_DIR}/templates/<name>${C_RESET}" >&2
    return 1
  fi

  local first=1
  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    local win_name win_cmd
    win_name=$(echo "$line" | awk '{print $1}')
    win_cmd=$(echo "$line" | cut -d' ' -f2- -s)

    if [[ $first -eq 1 ]]; then
      # Create session with first window
      tmux new-session -d -s "$name" -c "$dir" -n "$win_name"
      [[ -n "$win_cmd" ]] && tmux send-keys -t "${name}:${win_name}" "$win_cmd" Enter
      first=0
    else
      tmux new-window -t "$name" -n "$win_name" -c "$dir"
      [[ -n "$win_cmd" ]] && tmux send-keys -t "${name}:${win_name}" "$win_cmd" Enter
    fi
  done < "$template_file"

  # If template was empty or all comments, just create a basic session
  if [[ $first -eq 1 ]]; then
    tmux new-session -d -s "$name" -c "$dir"
  fi
}

# List available templates: tm templates
_cmd_templates() {
  local template_dir="${CONFIG_DIR}/templates"

  if [[ ! -d "$template_dir" ]] || [[ -z "$(ls -A "$template_dir" 2>/dev/null)" ]]; then
    echo -e "${C_DIM}(No templates available)${C_RESET}"
    echo -e "${C_DIM}Create template: echo 'editor' > ${template_dir}/<name>${C_RESET}"
    return
  fi

  echo -e "${C_BOLD}Available templates:${C_RESET}"
  echo ""
  for f in "${template_dir}"/*; do
    [[ ! -f "$f" ]] && continue
    local tname win_count
    tname=$(basename "$f")
    win_count=$(grep -cv '^\s*#\|^\s*$' "$f" 2>/dev/null || echo "0")
    echo -e "  ${C_CYAN}${tname}${C_RESET}  (${win_count} windows)"
    # Show window names
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      local wn
      wn=$(echo "$line" | awk '{print $1}')
      echo -e "    ${C_DIM}└ ${wn}${C_RESET}"
    done < "$f"
  done
  echo ""
  echo -e "${C_DIM}Usage: tm new <name> [dir] -t <template>${C_RESET}"
}

# Plain text session list (non-fzf)
_cmd_simple_list() {
  local fmt='#{session_name};#{session_attached};#{session_windows};#{session_path};#{session_last_attached};#{session_activity}'
  local sessions_raw
  sessions_raw=$(tmux list-sessions -F "$fmt" 2>/dev/null) || true
  if [[ -z "$sessions_raw" ]]; then
    echo -e "${C_DIM}(No tmux sessions)${C_RESET}"
    return
  fi

  printf "${C_BOLD}%-20s %-6s %-4s %-4s %-6s %s${C_RESET}\n" "NAME" "STATUS" "WIN" "PANE" "IDLE" "PATH"
  echo "───────────────────────────────────────────────────────────────────"

  _build_list_cache
  _CURRENT_SESSION=$(_current_session)
  _NOW=$(date +%s)

  while IFS=';' read -r name attached windows path _last_attached activity; do
    local panes status lock="" idle
    panes=$(_session_pane_count "$name")
    idle=$(_relative_time "$activity")
    local current
    current="${_CURRENT_SESSION:-}"

    if [[ "$name" == "$current" ]]; then
      status="${C_GREEN}▸ Active${C_RESET}"
    elif [[ "$attached" == "1" ]]; then
      status="${C_CYAN}● Attached${C_RESET}"
    else
      status="${C_DIM}○ Idle${C_RESET}"
    fi

    if _is_protected "$name"; then
      lock=" 🔒"
    fi

    local short_path="${path/#$HOME/~}"

    printf "%-20s %-16s %-4s %-4s %-6s %s\n" \
      "${name}${lock}" "$status" "$windows" "$panes" "$idle" "$short_path"
  done < <(sort -t';' -k5,5 -rn <<< "$sessions_raw")
}

# tm ls [--json ...]: plain text without arguments, JSON otherwise
_cmd_ls() {
  if [[ $# -eq 0 ]]; then
    _cmd_simple_list
    return
  fi
  local json=0 states="" agent="" session="" no_summary=0 filtered=0
  local opt value s
  while [[ $# -gt 0 ]]; do
    opt="$1"; value=""
    case "$opt" in
      --state=*|--agent=*|--session=*) value="${opt#*=}"; opt="${opt%%=*}" ;;
      --state|--agent|--session)
        if [[ $# -lt 2 ]]; then
          _ls_usage_error "${opt} needs a value"
        fi
        value="$2"; shift ;;
    esac
    case "$opt" in
      --json)       json=1 ;;
      --no-summary) no_summary=1; filtered=1 ;;
      --state)      states="$value"; filtered=1 ;;
      --agent)      agent="$value"; filtered=1 ;;
      --session)    session="$value"; filtered=1 ;;
      *)            _ls_usage_error "Unknown option: ${opt}" ;;
    esac
    case "$opt" in
      --state|--agent|--session)
        [[ -n "$value" ]] || _ls_usage_error "${opt} needs a value" ;;
    esac
    shift
  done
  if [[ $filtered -eq 1 && $json -eq 0 ]]; then
    _ls_usage_error "Filters require --json"
  fi
  local IFS=','
  for s in $states; do
    case "$s" in
      blocked|working|idle|unknown) ;;
      *) _ls_usage_error "Invalid state: ${s} (blocked, working, idle, unknown)" ;;
    esac
  done
  unset IFS
  _ls_json "$states" "$agent" "$session" "$no_summary"
}

# Print a tm ls argument error to stderr and exit 3
_ls_usage_error() {
  echo -e "${C_RED}✗ $1${C_RESET}" >&2
  echo "Usage: tm ls [--json [--state <s>[,<s>]] [--agent <name>] [--session <name>] [--no-summary]]" >&2
  exit 3
}

# Print every session and its agent panes as one JSON object (schema v1).
# Args: STATES_CSV AGENT SESSION NO_SUMMARY(0|1); empty strings mean no filter.
# Exit: 0 ok (also when empty), 2 session not found, 4 no tmux server.
_ls_json() {
  if ! command -v python3 &>/dev/null; then
    echo -e "${C_RED}✗ python3 is required for --json${C_RESET}" >&2
    exit 1
  fi
  python3 -I -S -c "${_PY_STATE_LIB}"'
import socket, subprocess

states_csv, agent_filter, session_filter, no_summary, config_dir, state_dir, stale_after = sys.argv[1:8]
stale_after = int(stale_after)
now = time.time()

def iso(value):
    if value is None:
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(value)))

def git_branch(path):
    # Walk up to the nearest .git (a directory, or a worktree "gitdir:" file)
    current = path
    while current:
        dot_git = os.path.join(current, ".git")
        head = None
        if os.path.isdir(dot_git):
            head = os.path.join(dot_git, "HEAD")
        elif os.path.isfile(dot_git):
            try:
                with open(dot_git) as f:
                    line = f.readline().strip()
            except OSError:
                return None
            if not line.startswith("gitdir:"):
                return None
            gitdir = line[len("gitdir:"):].strip()
            head = os.path.join(os.path.join(current, gitdir) if not os.path.isabs(gitdir) else gitdir, "HEAD")
        if head:
            try:
                with open(head) as f:
                    ref = f.readline().strip()
            except OSError:
                return None
            prefix = "ref: refs/heads/"
            return ref[len(prefix):] if ref.startswith(prefix) else None
        parent = os.path.dirname(current)
        if parent == current:
            return None
        current = parent
    return None

def last_summary(name):
    try:
        with open(os.path.join(config_dir, "summaries", name + ".jsonl")) as f:
            lines = [line for line in f if line.strip()]
        record = json.loads(lines[-1]) if lines else None
    except (OSError, ValueError):
        return None
    if isinstance(record, dict) and isinstance(record.get("summary"), str):
        return record["summary"]
    return None

fields = ["session_name", "session_created", "session_path", "session_windows",
          "session_attached", "session_activity", "window_index", "pane_index",
          "pane_id", "pane_pid"]
fmt = "\t".join("#{" + f + "}" for f in fields)
listing = subprocess.run(["tmux", "list-panes", "-a", "-F", fmt],
                         capture_output=True, text=True)
if listing.returncode != 0:
    sys.stderr.write("✗ tmux server is not running\n")
    sys.exit(4)

try:
    with open(os.path.join(config_dir, "protected.txt")) as f:
        protected = set(line.rstrip("\n") for line in f)
except OSError:
    protected = set()

sessions, panes = {}, []
for line in listing.stdout.splitlines():
    parts = line.split("\t")
    if len(parts) != len(fields):
        continue
    row = dict(zip(fields, parts))
    name = row["session_name"]
    if name not in sessions:
        sessions[name] = {
            "name": name,
            "dir": row["session_path"] or None,
            "git_branch": git_branch(row["session_path"]) if row["session_path"] else None,
            "windows": int(row["session_windows"] or 0),
            "panes": 0,
            "clients": int(row["session_attached"] or 0),
            "last_activity": iso(row["session_activity"]) if row["session_activity"].isdigit() else None,
            "protected": name in protected,
            "summary": None if no_summary == "1" else last_summary(name),
            "state": "unknown",
            "agents": [],
        }
    sessions[name]["panes"] += 1
    panes.append(row)

# One ps call for the whole process tree
children, args = {}, {}
ps = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "args="],
                    capture_output=True, text=True)
for line in ps.stdout.splitlines():
    parts = line.split(None, 2)
    if len(parts) < 2 or not parts[0].isdigit() or not parts[1].isdigit():
        continue
    pid, ppid = int(parts[0]), int(parts[1])
    children.setdefault(ppid, []).append(pid)
    args[pid] = parts[2] if len(parts) == 3 else ""

def detect_agent(root):
    # BFS from the pane shell; an agent is a process whose first or second
    # argv token is named claude/codex (direct run, or node/bash running it)
    queue, seen = [root], set()
    while queue:
        pid = queue.pop(0)
        if pid in seen:
            continue
        seen.add(pid)
        for token in args.get(pid, "").split()[:2]:
            name = os.path.basename(token)
            if name in ("claude", "codex"):
                return name, pid
        queue.extend(children.get(pid, []))
    return None, None

for row in panes:
    session = sessions[row["session_name"]]
    root = int(row["pane_pid"]) if row["pane_pid"].isdigit() else None
    found, pid = detect_agent(root) if root is not None else (None, None)
    loaded = load_state(state_dir, row["pane_id"], row["session_created"], now, stale_after)
    if loaded is not None and loaded["state"] == "unknown" and found is None:
        loaded = None  # dead agent, nothing running
    if loaded is None and found is None:
        continue
    record = loaded["record"] if loaded else {}
    recorded_agent = record.get("agent")
    session["agents"].append({
        "pane": row["pane_id"],
        "target": row["session_name"] + ":" + row["window_index"] + "." + row["pane_index"],
        "agent": recorded_agent if isinstance(recorded_agent, str) and recorded_agent else found,
        "pid": pid,
        "session_id": record.get("session_id") if loaded else None,
        "state": loaded["state"] if loaded else "unknown",
        "stale": loaded["stale"] if loaded else False,
        "since": iso(loaded["since"]) if loaded else None,
        "reason": record.get("reason") if loaded else None,
        "message": record.get("message") if loaded else None,
        "source": "hook" if loaded else "heuristic",
        "_order": (int(row["window_index"] or 0), int(row["pane_index"] or 0)),
    })

if session_filter and session_filter not in sessions:
    sys.stderr.write("✗ Session " + json.dumps(session_filter, ensure_ascii=False) + " not found\n")
    sys.exit(2)

wanted_states = set(s for s in states_csv.split(",") if s)
rank = {"unknown": 0, "idle": 1, "working": 2, "blocked": 3}
selected = []
for name in sorted(sessions):
    session = sessions[name]
    if session_filter and name != session_filter:
        continue
    session["agents"].sort(key=lambda agent: agent["_order"])
    for agent in session["agents"]:
        del agent["_order"]
    # --agent drops other agents and recomputes the session state from the rest
    if agent_filter:
        session["agents"] = [a for a in session["agents"] if a["agent"] == agent_filter]
        if not session["agents"]:
            continue
    for agent in session["agents"]:
        if rank[agent["state"]] > rank[session["state"]]:
            session["state"] = agent["state"]
    # --state keeps the whole session when any agent matches
    if wanted_states and not any(a["state"] in wanted_states for a in session["agents"]):
        continue
    selected.append(session)

result = {
    "v": 1,
    "host": socket.gethostname().split(".")[0] or None,
    "generated_at": iso(now),
    "sessions": selected,
}
json.dump(result, sys.stdout, ensure_ascii=False)
sys.stdout.write("\n")
' "$1" "$2" "$3" "$4" "$CONFIG_DIR" "$STATE_DIR" "$STALE_AFTER"
}

# ─── 10. AI Summary ──────────────────────────────────

# Build prompt context from session metadata (no pane content capture)
_build_session_context() {
  local name="$1"
  local path windows procs git_branch windows_list

  path=$(tmux display-message -t "$name" -p '#{session_path}' 2>/dev/null)
  windows=$(tmux display-message -t "$name" -p '#{session_windows}' 2>/dev/null)
  procs=$(_session_procs "$name" | tr '\n' ', ')
  git_branch=$(git -C "$path" branch --show-current 2>/dev/null || true)
  windows_list=$(tmux list-windows -t "$name" \
    -F '#{window_name}' 2>/dev/null | tr '\n' ', ')

  cat <<EOF
Session: ${name}
Directory: ${path}
Git branch: ${git_branch:-N/A}
Windows (${windows}): ${windows_list%,}
Running processes: ${procs%,}
EOF
}

# Generate AI summary for a single session
_cmd_summarize() {
  local name="$1"
  if [[ -z "$name" ]]; then
    echo -e "${C_RED}✗ Usage: tm summarize <session-name>${C_RESET}" >&2
    return 1
  fi

  if ! tmux has-session -t "$name" 2>/dev/null; then
    echo -e "${C_RED}✗ Session '${name}' not found${C_RESET}" >&2
    return 1
  fi

  local context
  context=$(_build_session_context "$name")

  local prompt="Based on this tmux session metadata, write a one-line summary in English describing what this session is likely used for. Be concise (under 60 chars). Only output the summary, nothing else.

${context}"

  local summary
  summary=$(claude -p --model haiku "$prompt" 2>/dev/null)

  if [[ -z "$summary" ]]; then
    echo -e "${C_RED}✗ Summary generation failed (claude CLI error)${C_RESET}" >&2
    return 1
  fi

  # Escape double quotes for safe JSON storage
  summary="${summary//\\/\\\\}"
  summary="${summary//\"/\\\"}"

  # Append to JSONL history
  local ts
  ts=$(date +%s)
  local summary_file="${CONFIG_DIR}/summaries/${name}.jsonl"
  printf '{"ts":%s,"summary":"%s"}\n' "$ts" "$summary" >> "$summary_file"

  echo -e "${C_GREEN}✓${C_RESET} ${C_CYAN}${name}${C_RESET}: ${summary}"
}

# Generate AI summaries for all active sessions
_cmd_summarize_all() {
  if ! _has_tmux_server; then
    echo -e "${C_DIM}(No tmux sessions)${C_RESET}"
    return
  fi

  echo -e "${C_BOLD}Generating session summaries...${C_RESET}"
  while IFS= read -r name; do
    _cmd_summarize "$name"
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
  echo -e "${C_BOLD}Done${C_RESET}"
}

# ─── 11. Backup & Restore ─────────────────────────────

# Receive Claude SessionStart hook input and record pane-to-session metadata.
_cmd_record_claude_session() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  command -v python3 &>/dev/null || return 0

  local record
  record=$(python3 -c '
import json, os, sys, time, uuid

try:
    payload = json.load(sys.stdin)
    session_id = payload.get("session_id", "")
    if str(uuid.UUID(session_id)) != session_id.lower():
        raise ValueError("invalid session ID")
    print(json.dumps({
        "pane_id": os.environ["TMUX_PANE"],
        "session_id": session_id,
        "cwd": payload.get("cwd", ""),
        "updated_at": int(time.time()),
    }, separators=(",", ":")))
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    pass
' 2>/dev/null) || return 0

  if [[ -n "$record" ]]; then
    if [[ ! -f "$CLAUDE_SESSION_MAP" ]]; then
      (umask 077; touch "$CLAUDE_SESSION_MAP")
    fi
    printf '%s\n' "$record" >> "$CLAUDE_SESSION_MAP"
  fi
}

# Record an agent's state for the current pane (called by Claude Code hooks).
# Never fails the hook: runtime errors are swallowed and exit 0, because a
# non-zero hook exit can block the agent. Only a bad state argument exits 3.
_cmd_hook_state() {
  local state="${1:-}"
  case "$state" in
    working|blocked|idle|dead) ;;
    *)
      echo "Usage: tm hook-state <working|blocked|idle|dead>" >&2
      exit 3
      ;;
  esac
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  command -v python3 &>/dev/null || return 0

  # -I -S and no tempfile import keep interpreter startup inside the hook's
  # 50 ms budget (PreToolUse fires on every tool call)
  python3 -I -S -c '
import json, os, sys, time

state, pane, state_dir = sys.argv[1:]
try:
    payload = json.loads(sys.stdin.read() or "null")
except ValueError:
    payload = None
if not isinstance(payload, dict):
    payload = {}

reason = message = None
if state == "blocked":
    message = payload.get("message")
    ntype = payload.get("notification_type")
    if ntype == "permission_prompt":
        reason = "permission"
    elif ntype == "elicitation_dialog":
        reason = "input"
    elif ntype:
        # e.g. idle_prompt (sent ~60 s after every Stop, the turn is already
        # idle) or auth_success: not a request for human input
        sys.exit(0)
    elif "permission" in str(message or "").lower():
        reason = "permission"
    else:
        # Payload without notification_type: only a permission request is
        # recognisable; "waiting for your input" is the idle reminder
        sys.exit(0)

os.makedirs(state_dir, mode=0o700, exist_ok=True)
path = os.path.join(state_dir, pane.lstrip("%") + ".json")
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

since = now
try:
    with open(path) as f:
        old = json.load(f)
    if isinstance(old, dict) and old.get("state") == state and old.get("since"):
        since = old["since"]
except (OSError, ValueError):
    pass

record = {
    "v": 1,
    "pane": pane,
    "agent": "claude",
    "session_id": payload.get("session_id"),
    "state": state,
    "reason": reason,
    "message": message,
    "event": payload.get("hook_event_name"),
    "cwd": payload.get("cwd"),
    "ts": now,
    "since": since,
}
# Readers glob *.json, so the temp name must not end in .json
tmp = f"{path}.{os.getpid()}.tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(record, f)
os.replace(tmp, path)
' "$state" "$TMUX_PANE" "$STATE_DIR" 2>/dev/null || true
  return 0
}

# Safely merge tm's session recorder and agent state hooks into the user's
# Claude settings. Only missing entries are added; user hooks are kept.
_cmd_install_claude_hook() {
  _check_cmd python3
  mkdir -p "${CLAUDE_SETTINGS%/*}"

  python3 -c '
import datetime, json, os, shlex, shutil, sys, uuid

settings_path, script_path = sys.argv[1:]
existed = os.path.isfile(settings_path)

if existed:
    try:
        with open(settings_path) as settings_file:
            data = json.load(settings_file)
    except (OSError, ValueError) as error:
        print(f"Failed to read Claude settings: {error}", file=sys.stderr)
        sys.exit(1)
else:
    data = {}

if not isinstance(data, dict):
    print("Failed to update Claude settings: root value must be an object", file=sys.stderr)
    sys.exit(1)

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print("Failed to update Claude settings: hooks must be an object", file=sys.stderr)
    sys.exit(1)

quoted = shlex.quote(script_path)
wanted = [
    ("SessionStart", "_record-claude-session"),
    ("SessionStart", "hook-state idle"),
    ("UserPromptSubmit", "hook-state working"),
    ("PreToolUse", "hook-state working"),
    # PreToolUse fires before the permission prompt, so only PostToolUse
    # clears blocked once the user has approved
    ("PostToolUse", "hook-state working"),
    ("Notification", "hook-state blocked"),
    ("Stop", "hook-state idle"),
    ("SessionEnd", "hook-state dead"),
]

# Validate every event first so a malformed file is never partially changed
for event in dict.fromkeys(e for e, _ in wanted):
    if not isinstance(hooks.get(event, []), list):
        print(f"Failed to update Claude settings: hooks.{event} must be an array", file=sys.stderr)
        sys.exit(1)

def installed(groups, suffix):
    for group in groups:
        if not isinstance(group, dict):
            continue
        for hook in group.get("hooks", []):
            if isinstance(hook, dict) and str(hook.get("command", "")).endswith(suffix):
                return True
    return False

added = []
for event, suffix in wanted:
    groups = hooks.setdefault(event, [])
    if installed(groups, suffix):
        continue
    groups.append({"hooks": [{"type": "command", "command": f"{quoted} {suffix}"}]})
    added.append(f"{event} ({suffix})")

if not added:
    print("Claude hooks are already installed")
    sys.exit(0)

backup_path = ""
if existed:
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup_path = f"{settings_path}.tm-backup-{stamp}"
    shutil.copy2(settings_path, backup_path)

temp_path = f"{settings_path}.tm-new-{uuid.uuid4()}"
with open(temp_path, "x") as settings_file:
    json.dump(data, settings_file, indent=2)
    settings_file.write("\n")
os.chmod(temp_path, os.stat(settings_path).st_mode & 0o777 if existed else 0o600)
os.replace(temp_path, settings_path)

print(f"Installed Claude hooks in {settings_path}:")
for item in added:
    print(f"  {item}")
if backup_path:
    print(f"Backup: {backup_path}")
' "$CLAUDE_SETTINGS" "$SELF"
}

# Check if a Claude Code conversation exists for a project path
_has_conversation() {
  local project_path="$1"
  # Convert path to Claude project dir format: /home/user/project/foo -> -home-user-project-foo
  local dir_name
  dir_name=$(echo "$project_path" | sed 's|^/||; s|/$||; s|/|-|g')
  local conv_dir="${CLAUDE_PROJECTS}/-${dir_name}"
  [[ -d "$conv_dir" ]] && compgen -G "${conv_dir}/*.jsonl" >/dev/null 2>&1
}

_is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# List a tmux pane's shell PID and every descendant process.
_pane_process_pids() {
  local root_pid="$1"
  local current child index=0
  local -a queue=("$root_pid")

  while (( index < ${#queue[@]} )); do
    current="${queue[$index]}"
    ((index += 1))
    echo "$current"
    while IFS= read -r child; do
      [[ -z "$child" ]] && continue
      queue+=("$child")
    done < <(pgrep -P "$current" 2>/dev/null || true)
  done
}

# Detect whether a specific pane is running Claude Code (by pane_pid)
_pane_has_claude() {
  local pane_pid="$1"
  local children c
  children=$(_pane_process_pids "$pane_pid")
  [[ -z "$children" ]] && return 1
  children="${children//$'\n'/,}"
  c=$(ps -o command= -p "$children" 2>/dev/null | grep -c "claude" || true)
  [[ "$c" -gt 0 ]]
}

# Detect whether a specific pane is running Codex CLI (by pane_pid)
_pane_has_codex() {
  local pane_pid="$1"
  local children c
  children=$(_pane_process_pids "$pane_pid")
  [[ -z "$children" ]] && return 1
  children="${children//$'\n'/,}"
  c=$(ps -o command= -p "$children" 2>/dev/null | grep -cE '(^|[ /])codex( |$)' || true)
  [[ "$c" -gt 0 ]]
}

# Read the exact Codex session UUID from a pane descendant's open rollout file.
_pane_codex_session_id() {
  local pane_pid="$1"
  local pid fd path filename candidate files
  local lsof_path=""
  lsof_path=$(command -v lsof || true)

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    files=""
    if [[ -d "/proc/${pid}/fd" ]]; then
      for fd in "/proc/${pid}/fd/"*; do
        path=$(readlink "$fd" 2>/dev/null || true)
        [[ -n "$path" ]] && files+="${path}"$'\n'
      done
    elif [[ -n "$lsof_path" ]]; then
      files=$("$lsof_path" -a -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' || true)
    fi

    while IFS= read -r path; do
      [[ "$path" == */sessions/*/rollout-*.jsonl ]] || continue
      filename="${path##*/}"
      candidate="${filename%.jsonl}"
      candidate="${candidate: -36}"
      if _is_uuid "$candidate"; then
        echo "$candidate"
        return 0
      fi
    done <<< "$files"
  done < <(_pane_process_pids "$pane_pid")

  return 1
}

# Look up the latest Claude hook record for a tmux pane and working directory.
_pane_claude_session_id() {
  local pane_id="$1"
  local pane_path="$2"
  [[ -f "$CLAUDE_SESSION_MAP" ]] || return 1

  python3 -c '
import json, sys

path, pane_id, pane_path = sys.argv[1:]
session_id = ""
with open(path) as records:
    for line in records:
        try:
            record = json.loads(line)
        except (TypeError, ValueError):
            continue
        if record.get("pane_id") == pane_id and record.get("cwd") == pane_path:
            session_id = record.get("session_id", "")
if session_id:
    print(session_id)
' "$CLAUDE_SESSION_MAP" "$pane_id" "$pane_path"
}

# Detect whether any pane in a session is running Claude Code
_session_has_claude() {
  local session="$1"
  local pane_pid
  for pane_pid in $(tmux list-panes -t "$session" -s -F '#{pane_pid}' 2>/dev/null); do
    if _pane_has_claude "$pane_pid"; then
      return 0
    fi
  done
  return 1
}

# Map a session name to its screens subdirectory ('/' is not filename-safe).
# Must match screen_dir_name() in _cmd_screens.
_screen_dir_name() {
  printf '%s\n' "${1//\//_}"
}

# Save one pane's visible screen (with ANSI colors) as <win>.<pane>.ans.
# Headers are not stored: _cmd_screens builds them from the snapshot JSON,
# so pane boundaries never depend on what the screen happens to show.
_capture_pane_screen() {
  local pane_id="$1" out_file="$2"
  # -e keeps colors; without -S only the visible screen is captured
  tmux capture-pane -p -e -t "$pane_id" >"$out_file" 2>/dev/null \
    || echo "(capture failed)" >"$out_file"
}

# Save snapshot of all tmux sessions, windows, panes & layouts
_cmd_save() {
  if ! _has_tmux_server; then
    echo -e "${C_RED}✗ No tmux server running${C_RESET}" >&2
    exit 1
  fi

  _check_cmd python3
  if [[ ! "$SNAPSHOT_KEEP" =~ ^[1-9][0-9]*$ ]]; then
    echo -e "${C_RED}✗ TM_SNAPSHOT_KEEP must be a positive integer (got: ${SNAPSHOT_KEEP})${C_RESET}" >&2
    exit 1
  fi
  mkdir -p "$SNAPSHOT_HISTORY_DIR"

  # One clock read for both forms so the screens dir matches the JSON stamp
  local stamp timestamp
  stamp=$(date -u +"%Y%m%dT%H%M%SZ")
  timestamp="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}Z"

  # Pane screens can hold secrets, so keep them owner-only
  local screens_dir="${SNAPSHOT_HISTORY_DIR}/screens-${stamp}"
  mkdir -p "$screens_dir"
  chmod 700 "$screens_dir"

  # Build TSV stream: one line per pane.
  # Fields: SESSION \t WIN_IDX \t WIN_NAME \t WIN_ACTIVE \t WIN_LAYOUT \t
  #         PANE_IDX \t PANE_ACTIVE \t PANE_PATH \t HAS_CLAUDE \t CLAUDE_MODE \t
  #         CLAUDE_SESSION_ID \t HAS_CODEX \t CODEX_SESSION_ID
  local tsv=""
  local session win_line win_idx win_name win_active win_layout
  local pane_line pane_idx pane_active pane_path pane_pid pane_id
  local has_claude claude_mode claude_session_id has_codex codex_session_id
  local session_screens

  while IFS= read -r session; do
    [[ -z "$session" ]] && continue
    while IFS=$'\t' read -r win_idx win_name win_active win_layout; do
      [[ -z "$win_idx" ]] && continue
      while IFS=$'\t' read -r pane_idx pane_active pane_path pane_pid pane_id; do
        [[ -z "$pane_idx" || -z "$pane_path" ]] && continue
        if _pane_has_claude "$pane_pid"; then
          has_claude=true
          claude_session_id=$(_pane_claude_session_id "$pane_id" "$pane_path" || true)
          if [[ -n "$claude_session_id" ]] && ! _is_uuid "$claude_session_id"; then
            claude_session_id=""
          fi
        else
          has_claude=false
          claude_session_id=""
        fi
        if _has_conversation "$pane_path"; then
          claude_mode="continue"
        else
          claude_mode="fresh"
        fi
        if _pane_has_codex "$pane_pid"; then
          has_codex=true
          codex_session_id=$(_pane_codex_session_id "$pane_pid" || true)
        else
          has_codex=false
          codex_session_id=""
        fi
        tsv+="${session}"$'\t'"${win_idx}"$'\t'"${win_name}"$'\t'"${win_active}"$'\t'"${win_layout}"$'\t'"${pane_idx}"$'\t'"${pane_active}"$'\t'"${pane_path}"$'\t'"${has_claude}"$'\t'"${claude_mode}"$'\t'"${claude_session_id}"$'\t'"${has_codex}"$'\t'"${codex_session_id}"$'\n'
        session_screens="${screens_dir}/$(_screen_dir_name "$session")"
        mkdir -p "$session_screens"
        _capture_pane_screen "$pane_id" "${session_screens}/${win_idx}.${pane_idx}.ans"
      done < <(tmux list-panes -t "${session}:${win_idx}" -F '#{pane_index}	#{?pane_active,1,0}	#{pane_current_path}	#{pane_pid}	#{pane_id}' 2>/dev/null)
    done < <(tmux list-windows -t "$session" -F '#{window_index}	#{window_name}	#{?window_active,1,0}	#{window_layout}' 2>/dev/null)
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

  # Group TSV into nested JSON via Python
  local py_save
  py_save=$(cat <<'PY'
import glob, json, os, shutil, sys

timestamp = sys.argv[1]
out_path = sys.argv[2]
history_dir = sys.argv[3]
keep = int(sys.argv[4])

sessions = {}  # name -> {"name", "active_window", "windows": {idx: {...}}}
for line in sys.stdin.read().splitlines():
    if not line:
        continue
    parts = line.split('\t')
    if len(parts) != 13:
        continue
    sname, w_idx, w_name, w_active, w_layout, p_idx, p_active, p_path, has_cl, cl_mode, cl_session, has_codex, codex_session = parts
    w_idx_i = int(w_idx)
    p_idx_i = int(p_idx)
    s = sessions.setdefault(sname, {"name": sname, "active_window": 0, "windows": {}})
    if w_active == "1":
        s["active_window"] = w_idx_i
    w = s["windows"].setdefault(w_idx_i, {
        "index": w_idx_i, "name": w_name, "layout": w_layout,
        "active_pane": 0, "panes": {},
    })
    if p_active == "1":
        w["active_pane"] = p_idx_i
    w["panes"][p_idx_i] = {
        "index": p_idx_i,
        "path": p_path,
        "has_claude": has_cl == "true",
        "claude_mode": cl_mode,
        "claude_session_id": cl_session or None,
        "has_codex": has_codex == "true",
        "codex_session_id": codex_session or None,
    }

out_sessions = []
for sname in sorted(sessions):
    s = sessions[sname]
    windows = []
    for w_idx in sorted(s["windows"]):
        w = s["windows"][w_idx]
        w["panes"] = [w["panes"][k] for k in sorted(w["panes"])]
        windows.append(w)
    out_sessions.append({
        "name": s["name"],
        "active_window": s["active_window"],
        "windows": windows,
    })

data = {"version": 2, "timestamp": timestamp, "sessions": out_sessions}

def write_atomic(path):
    # Write via temp file so a crash never leaves a truncated snapshot
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)

# Compact UTC stamp keeps lexical order equal to chronological order
stamp = timestamp.replace("-", "").replace(":", "")
history_path = os.path.join(history_dir, f"sessions-{stamp}.json")
write_atomic(history_path)
write_atomic(out_path)

# Prune oldest history snapshots beyond the retention count
history = sorted(glob.glob(os.path.join(history_dir, "sessions-*.json")))
for old in history[:-keep]:
    os.remove(old)

# Screens follow their JSON. Only dirs older than the oldest kept snapshot
# are removed, so a concurrent save still writing its screens is left alone;
# dirs from an interrupted save age out the same way.
oldest_kept = os.path.basename(history[-keep:][0])[len("sessions-"):-len(".json")]
for screens in glob.glob(os.path.join(history_dir, "screens-*")):
    if os.path.basename(screens)[len("screens-"):] < oldest_kept:
        shutil.rmtree(screens, ignore_errors=True)

n_sess = len(out_sessions)
n_win  = sum(len(s["windows"]) for s in out_sessions)
n_pane = sum(len(w["panes"]) for s in out_sessions for w in s["windows"])
print(f"{n_sess}\t{n_win}\t{n_pane}")
PY
)

  local summary n_sess n_win n_pane
  summary=$(printf '%s' "$tsv" | python3 -c "$py_save" "$timestamp" "$SNAPSHOT_FILE" "$SNAPSHOT_HISTORY_DIR" "$SNAPSHOT_KEEP")
  IFS=$'\t' read -r n_sess n_win n_pane <<<"$summary"

  echo -e "${C_GREEN}✓${C_RESET} Saved ${C_BOLD}${n_sess:-0}${C_RESET} sessions · ${C_BOLD}${n_win:-0}${C_RESET} windows · ${C_BOLD}${n_pane:-0}${C_RESET} panes → ${C_DIM}${SNAPSHOT_FILE}${C_RESET}"

  _clean_orphan_states
}

# Remove agent state files whose pane no longer exists. Runs from 'tm save'
# (often under cron), so a failure only warns and never fails the save.
_clean_orphan_states() {
  [[ -d "$STATE_DIR" ]] || return 0
  local removed
  removed=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | python3 -I -S -c '
import glob, os, sys

live = {line.strip().lstrip("%") for line in sys.stdin if line.strip()}
removed = 0
if not live:
    # tmux returned nothing (server gone mid-save): never treat that as
    # "every pane is dead"
    print(removed)
    sys.exit(0)
for path in glob.glob(os.path.join(sys.argv[1], "*.json")):
    if os.path.basename(path)[:-len(".json")] not in live:
        os.remove(path)
        removed += 1
print(removed)
' "$STATE_DIR") || {
    echo -e "${C_YELLOW}⚠ Could not clean orphan agent state files${C_RESET}" >&2
    return 0
  }
  if [[ "${removed:-0}" -gt 0 ]]; then
    echo -e "${C_DIM}Removed ${removed} orphan state file(s) from ${STATE_DIR}${C_RESET}"
  fi
}

# Resolve a snapshot reference to a file path.
# Accepts an empty value (latest), a path, a history file name,
# or a bare stamp such as 20261012T033000Z.
_resolve_snapshot() {
  local ref="${1:-}"
  local candidate
  if [[ -z "$ref" ]]; then
    candidate="$SNAPSHOT_FILE"
  elif [[ -f "$ref" ]]; then
    candidate="$ref"
  elif [[ -f "${SNAPSHOT_HISTORY_DIR}/${ref}" ]]; then
    candidate="${SNAPSHOT_HISTORY_DIR}/${ref}"
  elif [[ -f "${SNAPSHOT_HISTORY_DIR}/sessions-${ref}.json" ]]; then
    candidate="${SNAPSHOT_HISTORY_DIR}/sessions-${ref}.json"
  else
    echo -e "${C_RED}✗ Snapshot not found: ${ref:-$SNAPSHOT_FILE}${C_RESET}" >&2
    echo -e "${C_DIM}  Run 'tm snapshots --list' to see available snapshots${C_RESET}" >&2
    return 1
  fi
  if [[ ! -f "$candidate" ]]; then
    echo -e "${C_RED}✗ No snapshot found at ${candidate}${C_RESET}" >&2
    echo -e "${C_DIM}  Run 'tm save' first${C_RESET}" >&2
    return 1
  fi
  printf '%s\n' "$candidate"
}

# Restore sessions from snapshot (full session/window/pane tree)
_cmd_restore() {
  local start_claude=false
  local start_codex=false
  local from=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --claude) start_claude=true ;;
      --codex)  start_codex=true ;;
      --from)
        if [[ -z "${2:-}" ]]; then
          echo -e "${C_RED}✗ --from requires a snapshot name${C_RESET}" >&2
          return 1
        fi
        from="$2"
        shift
        ;;
      --from=*) from="${1#--from=}" ;;
      *)
        echo -e "${C_RED}✗ Unknown restore option: ${1}${C_RESET}" >&2
        echo -e "${C_DIM}  Usage: tm restore [--claude] [--codex] [--from <snapshot>]${C_RESET}" >&2
        return 1
        ;;
    esac
    shift
  done

  local snapshot
  snapshot=$(_resolve_snapshot "$from") || exit 1

  _check_cmd python3

  local existing=""
  if _has_tmux_server; then
    existing=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
  fi

  # Python handles the orchestration: validates version, drives tmux commands,
  # prints colored status lines to stdout, returns a summary on the last line.
  local py_restore
  py_restore=$(cat <<'PY'
import json, os, shlex, subprocess, sys, uuid

SNAPSHOT  = sys.argv[1]
START_CL  = sys.argv[2] == "true"
START_CX  = sys.argv[3] == "true"
EXISTING  = set(filter(None, sys.argv[4].splitlines())) if len(sys.argv) > 4 else set()

# ANSI color codes (must match bash C_* constants)
G  = "\033[32m"; R  = "\033[31m"; Y = "\033[33m"
B  = "\033[1m";  D  = "\033[2m"; X = "\033[0m"

try:
    data = json.load(open(SNAPSHOT))
except Exception as e:
    print(f"{R}✗ Failed to read snapshot: {e}{X}", file=sys.stderr)
    sys.exit(1)

version = data.get("version", 1)
if version < 2:
    print(f"{R}✗ Old snapshot format (version {version}) detected.{X}", file=sys.stderr)
    print(f"{D}  This version of tm requires snapshot v2. Run 'tm save' again to upgrade.{X}", file=sys.stderr)
    sys.exit(1)

print(f"{B}Restoring from snapshot:{X} {data.get('timestamp','?')}")

def tmux(*args, check=True):
    r = subprocess.run(["tmux", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        return None, r.stderr.strip()
    return r.stdout.strip(), None

def safe_path(p):
    return p if (p and os.path.isdir(p)) else os.environ.get("HOME", "/")

def valid_session_id(value):
    try:
        return str(uuid.UUID(value)) == value.lower()
    except (AttributeError, TypeError, ValueError):
        return False

def restore_window(sname, window):
    target = f"{sname}:{window['index']}"
    panes = window.get("panes", [])
    created = 1
    for pane in panes[1:]:
        _, err = tmux("split-window", "-t", target, "-c", safe_path(pane["path"]))
        if err is not None:
            return created, f"pane {pane['index']} split: {err}"
        created += 1

        # Rebalance after every split so the active pane never becomes too
        # small to split again. The saved layout is applied after all panes
        # exist, preserving its exact tree and proportions.
        _, err = tmux("select-layout", "-t", target, "tiled")
        if err is not None:
            return created, f"temporary tiled layout: {err}"

    if window.get("layout"):
        _, err = tmux("select-layout", "-t", target, window["layout"])
        if err is not None:
            return created, f"saved layout: {err}"

    _, err = tmux("select-pane", "-t", f"{target}.{window.get('active_pane', 0)}")
    if err is not None:
        return created, f"active pane: {err}"
    return created, None

n_sess = n_win = n_pane = 0
n_skip = 0
n_claude = 0
n_codex = 0

for s in data.get("sessions", []):
    sname = s["name"]
    if sname in EXISTING:
        print(f"  {D}SKIP{X}  {sname} (already exists)")
        n_skip += 1
        continue

    windows = s.get("windows", [])
    if not windows or not windows[0].get("panes"):
        print(f"  {Y}SKIP{X}  {sname} (no panes in snapshot)")
        n_skip += 1
        continue

    # Determine base path (first window's first pane) and warn if missing
    w0 = windows[0]
    p0 = w0["panes"][0]
    base_path = p0["path"]
    if not os.path.isdir(base_path):
        print(f"  {Y}WARN{X}  {sname} pane 0 path missing ({base_path}), falling back to $HOME")
        base_path = os.environ.get("HOME", "/")

    # Stage 1: create session with first window
    _, err = tmux("new-session", "-d", "-s", sname, "-c", base_path, "-n", w0.get("name", ""))
    if err is not None:
        print(f"  {R}FAIL{X}  {sname} (new-session: {err})")
        n_skip += 1
        continue

    # Stage 2a: window 0 — split remaining panes & apply layout
    session_windows = 1
    session_panes, restore_error = restore_window(sname, w0)

    # Stage 1b + 2b: remaining windows
    if restore_error is None:
        for w in windows[1:]:
            wp0 = w["panes"][0] if w.get("panes") else None
            if not wp0:
                continue
            wname = w.get("name", "")
            _, restore_error = tmux(
                "new-window", "-t", f"{sname}:{w['index']}",
                "-c", safe_path(wp0["path"]), "-n", wname,
            )
            if restore_error is not None:
                restore_error = f"window {w['index']} creation: {restore_error}"
                break
            restored_panes, restore_error = restore_window(sname, w)
            if restore_error is not None:
                restore_error = f"window {w['index']} {restore_error}"
                break
            session_windows += 1
            session_panes += restored_panes

    if restore_error is not None:
        tmux("kill-session", "-t", sname, check=False)
        print(f"  {R}FAIL{X}  {sname} ({restore_error})")
        n_skip += 1
        continue

    pretty = base_path.replace(os.environ.get("HOME", ""), "~", 1) if os.environ.get("HOME") else base_path
    print(f"  {G}OK{X}    {sname} → {pretty}")
    n_sess += 1
    n_win += session_windows
    n_pane += session_panes

    # Stage 3: launch Claude per-pane if requested
    if START_CL:
        for w in windows:
            for p in w.get("panes", []):
                if not p.get("has_claude"):
                    continue
                session_id = p.get("claude_session_id")
                if valid_session_id(session_id):
                    cmd = f"claude --resume {shlex.quote(session_id)} --dangerously-skip-permissions"
                elif p.get("claude_mode") == "continue":
                    cmd = "claude --continue --dangerously-skip-permissions"
                else:
                    cmd = "claude --dangerously-skip-permissions"
                target = f"{sname}:{w['index']}.{p['index']}"
                tmux("send-keys", "-t", target, cmd, "Enter")
                n_claude += 1

    # Stage 4: resume Codex per-pane if requested
    if START_CX:
        for w in windows:
            for p in w.get("panes", []):
                if not p.get("has_codex"):
                    continue
                target = f"{sname}:{w['index']}.{p['index']}"
                session_id = p.get("codex_session_id")
                cmd = f"codex resume {shlex.quote(session_id)}" if valid_session_id(session_id) \
                      else "codex resume --last"
                tmux("send-keys", "-t", target, cmd, "Enter")
                n_codex += 1

    # Finally: set active window
    tmux("select-window", "-t", f"{sname}:{s.get('active_window', 0)}")

# Summary line (parsed by bash caller)
print(f"__SUMMARY__\t{n_sess}\t{n_win}\t{n_pane}\t{n_skip}\t{n_claude}\t{n_codex}")
PY
)

  local out summary n_sess n_win n_pane n_skip n_claude n_codex
  out=$(python3 -c "$py_restore" "$snapshot" "$start_claude" "$start_codex" "$existing")
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "$out"
    exit $rc
  fi

  # Print everything except the summary line, then parse summary
  summary=$(printf '%s\n' "$out" | grep '^__SUMMARY__' | head -n1)
  printf '%s\n' "$out" | grep -v '^__SUMMARY__'

  IFS=$'\t' read -r _ n_sess n_win n_pane n_skip n_claude n_codex <<<"$summary"

  echo ""
  echo -e "${C_BOLD}Done:${C_RESET} ${n_sess:-0} sessions · ${n_win:-0} windows · ${n_pane:-0} panes restored, ${n_skip:-0} skipped"
  if [[ "${n_claude:-0}" -gt 0 ]]; then
    echo -e "${C_BOLD}Claude Code started in ${n_claude} panes${C_RESET}"
  fi
  if [[ "${n_codex:-0}" -gt 0 ]]; then
    echo -e "${C_BOLD}Codex resumed in ${n_codex} panes${C_RESET}"
  fi
}

# List snapshot history, newest first
_list_snapshot_history() {
  _check_cmd python3
  local py_list
  py_list=$(cat <<'PY'
import glob, json, os, sys

history_dir = sys.argv[1]
keep = sys.argv[2]
files = sorted(glob.glob(os.path.join(history_dir, "sessions-*.json")), reverse=True)
if not files:
    print("No snapshot history. Run 'tm save' to create one.")
    sys.exit(0)

print(f"Snapshot history ({len(files)} kept, limit {keep}) in {history_dir}")
for path in files:
    name = os.path.basename(path)
    try:
        d = json.load(open(path))
        sessions = d.get("sessions", [])
        n_win = sum(len(s.get("windows", [])) for s in sessions)
        n_pane = sum(len(w.get("panes", [])) for s in sessions for w in s.get("windows", []))
        detail = f"{d.get('timestamp', '?')}  {len(sessions)} sessions · {n_win} windows · {n_pane} panes"
    except Exception as e:
        detail = f"unreadable ({e})"
    print(f"  {name:<34} {detail}")
PY
)
  python3 -c "$py_list" "$SNAPSHOT_HISTORY_DIR" "$SNAPSHOT_KEEP"
}

# Show snapshot contents (sessions → windows → panes); latest by default
_cmd_snapshots() {
  case "${1:-}" in
    -l|--list)
      _list_snapshot_history
      return
      ;;
  esac

  if [[ -z "${1:-}" && ! -f "$SNAPSHOT_FILE" ]]; then
    echo -e "${C_DIM}No snapshot found. Run 'tm save' to create one.${C_RESET}"
    return
  fi

  local snapshot
  snapshot=$(_resolve_snapshot "${1:-}") || exit 1

  _check_cmd python3

  local py_show
  py_show=$(cat <<'PY'
import json, os, sys

path = sys.argv[1]
d = json.load(open(path))
version = d.get("version", 1)
if version < 2:
    print(f"Snapshot is in legacy format (version {version}).")
    print("Run 'tm save' again to upgrade to v2 (full window/pane tree).")
    sys.exit(0)

sessions = d.get("sessions", [])
n_sess = len(sessions)
n_win  = sum(len(s.get("windows", [])) for s in sessions)
n_pane = sum(len(w.get("panes", [])) for s in sessions for w in s.get("windows", []))

print(f"Snapshot: {d.get('timestamp', '?')}")
print(f"Sessions: {n_sess} · Windows: {n_win} · Panes: {n_pane}")

home = os.environ.get("HOME", "")
def short(p):
    return p.replace(home, "~", 1) if home and p.startswith(home) else p

for s in sessions:
    print()
    print(f"▸ {s['name']}  (active window: {s.get('active_window', 0)})")
    windows = s.get("windows", [])
    for wi, w in enumerate(windows):
        is_last_w = (wi == len(windows) - 1)
        w_branch = "└" if is_last_w else "├"
        w_cont   = " " if is_last_w else "│"
        wname = w.get("name") or "(unnamed)"
        panes = w.get("panes", [])
        layout = w.get("layout", "") or "-"
        if len(layout) > 24:
            layout = layout[:21] + "..."
        print(f"  {w_branch} [{w['index']}] {wname:<14} layout={layout} ({len(panes)} panes, active={w.get('active_pane',0)})")
        for pi, p in enumerate(panes):
            is_last_p = (pi == len(panes) - 1)
            p_branch = "└" if is_last_p else "├"
            claude_id = p.get("claude_session_id")
            codex_id = p.get("codex_session_id")
            claude = f"yes({claude_id[:8]})" if claude_id else \
                     (f"yes({p.get('claude_mode','fresh')})" if p.get("has_claude") else "no")
            codex = f"yes({codex_id[:8]})" if codex_id else \
                    ("yes(last)" if p.get("has_codex") else "no")
            print(f"  {w_cont}   {p_branch} pane {p['index']}  claude={claude:<14} codex={codex:<11} {short(p.get('path',''))}")
PY
)
  python3 -c "$py_show" "$snapshot"
}

# Show pane screens captured with a snapshot: list sessions, or print one
_cmd_screens() {
  local session="" from="" pane=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from|--pane)
        if [[ -z "${2:-}" ]]; then
          echo -e "${C_RED}✗ ${1} requires a value${C_RESET}" >&2
          return 1
        fi
        if [[ "$1" == "--from" ]]; then from="$2"; else pane="$2"; fi
        shift
        ;;
      --from=*) from="${1#--from=}" ;;
      --pane=*) pane="${1#--pane=}" ;;
      -*)
        echo -e "${C_RED}✗ Unknown screens option: ${1}${C_RESET}" >&2
        echo -e "${C_DIM}  Usage: tm screens [<session>] [--pane <window>.<pane>] [--from <snapshot>]${C_RESET}" >&2
        return 1
        ;;
      *) session="$1" ;;
    esac
    shift
  done

  if [[ -n "$pane" && ! "$pane" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo -e "${C_RED}✗ --pane must look like <window>.<pane>, e.g. 0.1 (got: ${pane})${C_RESET}" >&2
    return 1
  fi
  if [[ -n "$pane" && -z "$session" ]]; then
    echo -e "${C_RED}✗ --pane requires a session name${C_RESET}" >&2
    return 1
  fi

  _check_cmd python3
  local snapshot
  snapshot=$(_resolve_snapshot "$from") || exit 1

  # Pane list, counts and headers all come from the snapshot JSON; screen
  # files hold raw captures only, so their contents never affect boundaries.
  local py_screens
  py_screens=$(cat <<'PY'
import json, os, sys

snapshot, history_dir, session, pane = sys.argv[1:5]
B, C, D, R, X = "\033[1m", "\033[0;36m", "\033[2m", "\033[0;31m", "\033[0m"

def fail(msg):
    print(f"{R}✗ {msg}{X}", file=sys.stderr)
    sys.exit(1)

def screen_dir_name(name):
    # Must match _screen_dir_name in tm.sh
    return name.replace("/", "_")

data = json.load(open(snapshot))
stamp = data.get("timestamp", "").replace("-", "").replace(":", "")
screens_dir = os.path.join(history_dir, f"screens-{stamp}")
if not stamp or not os.path.isdir(screens_dir):
    fail(f"No screens captured for snapshot {stamp or '?'}")

sessions = data.get("sessions", [])
home = os.environ.get("HOME", "")
out = sys.stdout.buffer

def emit(text):
    out.write(text.encode())

if not session:
    emit(f"{B}Screens for snapshot {stamp}{X}  {D}(tm screens <session> to view){X}\n")
    for s in sessions:
        panes = [f"{w['index']}.{p['index']}" for w in s.get("windows", []) for p in w.get("panes", [])]
        sdir = os.path.join(screens_dir, screen_dir_name(s["name"]))
        has = os.path.isdir(sdir) or os.path.isfile(sdir + ".ans")
        note = "" if has else f"  {D}(no screens){X}"
        emit(f"  {s['name']:<36} {len(panes)} panes: {' '.join(panes)}{note}\n")
    sys.exit(0)

match = next((s for s in sessions if s["name"] == session), None)
if match is None:
    fail(f"Session '{session}' not in snapshot {stamp}")

sdir = os.path.join(screens_dir, screen_dir_name(session))
legacy = sdir + ".ans"
if not os.path.isdir(sdir):
    # Early captures stored one file per session with inline headers
    if os.path.isfile(legacy):
        if pane:
            fail(f"Snapshot {stamp} uses the old one-file format; --pane needs a newer save")
        out.write(open(legacy, "rb").read())
        sys.exit(0)
    fail(f"No screens for session '{session}' in snapshot {stamp}")

shown = 0
for w in match.get("windows", []):
    for p in w.get("panes", []):
        key = f"{w['index']}.{p['index']}"
        if pane and key != pane:
            continue
        path = p.get("path", "")
        if home and path.startswith(home):
            path = "~" + path[len(home):]
        active = " (active)" if w.get("active_pane") == p["index"] else ""
        if shown:
            emit("\n")
        emit(f"{B}{C}═══ {session} · window {w['index']} [{w.get('name', '')}] · pane {key}{active} · {path} ═══{X}\n")
        f = os.path.join(sdir, f"{key}.ans")
        if os.path.isfile(f):
            out.write(open(f, "rb").read())
        else:
            emit(f"{D}(no screen captured){X}\n")
        # Reset so a pane's trailing color never bleeds into the next header
        emit(X)
        shown += 1

if not shown:
    fail(f"Pane {pane} not in session '{session}' (run 'tm screens' to list panes)")
emit("\n")
PY
)
  python3 -c "$py_screens" "$snapshot" "$SNAPSHOT_HISTORY_DIR" "$session" "$pane"
}

# ─── 12. Self-routing ─────────────────────────────────

_init

case "${1:-}" in
  # Internal sub-commands (called by fzf binds)
  _list)           _cmd_list ;;
  _preview)        _cmd_preview "${2:-}" ;;
  _kill)           _cmd_kill "${2:-}" ;;
  _toggle-protect) _cmd_toggle_protect "${2:-}" ;;
  _rename)         _cmd_rename "${2:-}" ;;
  _kill-selected)  _cmd_kill_selected "$@" ;;
  _detach-others)  _cmd_detach_others "${2:-}" ;;
  _create)         _cmd_create ;;
  _summarize)      _cmd_summarize "${2:-}" ;;
  _record-claude-session) _cmd_record_claude_session ;;
  hook-state)      _cmd_hook_state "${2:-}" ;;

  # User-facing CLI commands (only need tmux, not fzf)
  new|create)      _check_cmd tmux; _cmd_quick_new "${@:2}" ;;
  attach)          _check_cmd tmux; _cmd_attach "${@:2}" ;;
  kill|rm|remove)  _check_cmd tmux; _cmd_quick_kill "${2:-}" ;;
  ls|list)         _check_cmd tmux; _cmd_ls "${@:2}" ;;
  rename)          _check_cmd tmux; _cmd_rename "${2:-}" ;;
  last)            _check_cmd tmux; _cmd_last ;;
  templates|tpl)   _cmd_templates ;;
  protect|lock)    _check_cmd tmux; _toggle_protect "${2:-}" ;;
  summarize)       _check_cmd tmux; _cmd_summarize "${2:-}" ;;
  summarize-all)   _check_cmd tmux; _cmd_summarize_all ;;
  save)            _check_cmd tmux; _cmd_save ;;
  restore)         _check_cmd tmux; _cmd_restore "${@:2}" ;;
  install-claude-hook) _cmd_install_claude_hook ;;
  snapshots|snaps) _cmd_snapshots "${2:-}" ;;
  screens)         _cmd_screens "${@:2}" ;;
  help|--help|-h)  _cmd_help ;;
  --version|-v)    echo "tm v${VERSION}" ;;

  # No args: interactive main menu (needs both tmux + fzf)
  "")              _cmd_main ;;

  # Try as session name, else error
  *)
    _check_cmd tmux
    if tmux has-session -t "$1" 2>/dev/null; then
      _attach_session "$1"
    else
      echo -e "${C_RED}✗ Unknown command or session: ${1}${C_RESET}" >&2
      echo -e "${C_DIM}  Run 'tm help' for usage information${C_RESET}" >&2
      exit 1
    fi
    ;;
esac
