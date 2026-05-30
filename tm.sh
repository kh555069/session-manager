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
readonly CLAUDE_PROJECTS="${HOME}/.claude/projects"
readonly SCRIPT_DIR="${SELF%/*}"
readonly SNAPSHOT_DIR="${SCRIPT_DIR}/snapshots"
readonly SNAPSHOT_FILE="${SNAPSHOT_DIR}/sessions.json"
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
readonly IMPORTANT_PROCS="claude|python|node|npm|cargo|go|java|docker|kubectl"

# Performance cache for batch queries (populated by _build_list_cache)
_CACHED_SESSION_DATA=""
_CACHED_PROTECTED=""
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
  _CACHE_LOADED=1
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
    printf "     \t%-16s\t%s\t%s\t%s\n" "NAME" "W" "P" "IDLE"
  else
    printf "     \t%-20s\t%-30s\t%s\t%s\t%s\n" "NAME" "DIRECTORY" "W" "P" "IDLE"
  fi
  # Batch pre-cache to avoid per-session fork overhead
  _build_list_cache
  _CURRENT_SESSION=$(_current_session)
  _NOW=$(date +%s)
  # Sort by session_last_attached descending (most recent first)
  while IFS=';' read -r name attached windows path _last_attached activity; do
    _format_session_line "$name" "$attached" "$windows" "$path" "$activity"
  done < <(sort -t';' -k5,5 -rn <<< "$sessions_raw")
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
  tm save               Snapshot all sessions, windows, panes & layouts
  tm restore [--claude] Restore full session tree (--claude: relaunch Claude per pane)
  tm snapshots          Show latest snapshot contents (sessions → windows → panes)
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

# Check if a Claude Code conversation exists for a project path
_has_conversation() {
  local project_path="$1"
  # Convert path to Claude project dir format: /home/user/project/foo -> -home-user-project-foo
  local dir_name
  dir_name=$(echo "$project_path" | sed 's|^/||; s|/$||; s|/|-|g')
  local conv_dir="${CLAUDE_PROJECTS}/-${dir_name}"
  [[ -d "$conv_dir" ]] && compgen -G "${conv_dir}/*.jsonl" >/dev/null 2>&1
}

# Detect whether a specific pane is running Claude Code (by pane_pid)
_pane_has_claude() {
  local pane_pid="$1"
  local children c
  children=$(pgrep -P "$pane_pid" 2>/dev/null) || return 1
  [[ -z "$children" ]] && return 1
  c=$(ps -o command= -p $children 2>/dev/null | grep -c "claude" || true)
  [[ "$c" -gt 0 ]]
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

# Save snapshot of all tmux sessions, windows, panes & layouts
_cmd_save() {
  if ! _has_tmux_server; then
    echo -e "${C_RED}✗ No tmux server running${C_RESET}" >&2
    exit 1
  fi

  _check_cmd python3
  mkdir -p "$SNAPSHOT_DIR"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Rotate previous snapshot
  if [[ -f "$SNAPSHOT_FILE" ]]; then
    cp "$SNAPSHOT_FILE" "${SNAPSHOT_FILE}.bak"
  fi

  # Build TSV stream: one line per pane.
  # Fields: SESSION \t WIN_IDX \t WIN_NAME \t WIN_ACTIVE \t WIN_LAYOUT \t
  #         PANE_IDX \t PANE_ACTIVE \t PANE_PATH \t HAS_CLAUDE \t CLAUDE_MODE
  local tsv=""
  local session win_line win_idx win_name win_active win_layout
  local pane_line pane_idx pane_active pane_path pane_pid has_claude claude_mode

  while IFS= read -r session; do
    [[ -z "$session" ]] && continue
    while IFS=$'\t' read -r win_idx win_name win_active win_layout; do
      [[ -z "$win_idx" ]] && continue
      while IFS=$'\t' read -r pane_idx pane_active pane_path pane_pid; do
        [[ -z "$pane_idx" || -z "$pane_path" ]] && continue
        if _pane_has_claude "$pane_pid"; then
          has_claude=true
        else
          has_claude=false
        fi
        if _has_conversation "$pane_path"; then
          claude_mode="continue"
        else
          claude_mode="fresh"
        fi
        tsv+="${session}"$'\t'"${win_idx}"$'\t'"${win_name}"$'\t'"${win_active}"$'\t'"${win_layout}"$'\t'"${pane_idx}"$'\t'"${pane_active}"$'\t'"${pane_path}"$'\t'"${has_claude}"$'\t'"${claude_mode}"$'\n'
      done < <(tmux list-panes -t "${session}:${win_idx}" -F '#{pane_index}	#{?pane_active,1,0}	#{pane_current_path}	#{pane_pid}' 2>/dev/null)
    done < <(tmux list-windows -t "$session" -F '#{window_index}	#{window_name}	#{?window_active,1,0}	#{window_layout}' 2>/dev/null)
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

  # Group TSV into nested JSON via Python
  local py_save
  py_save=$(cat <<'PY'
import json, sys

timestamp = sys.argv[1]
out_path = sys.argv[2]

sessions = {}  # name -> {"name", "active_window", "windows": {idx: {...}}}
for line in sys.stdin.read().splitlines():
    if not line:
        continue
    parts = line.split('\t')
    if len(parts) != 10:
        continue
    sname, w_idx, w_name, w_active, w_layout, p_idx, p_active, p_path, has_cl, cl_mode = parts
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
with open(out_path, "w") as f:
    json.dump(data, f, indent=2)

n_sess = len(out_sessions)
n_win  = sum(len(s["windows"]) for s in out_sessions)
n_pane = sum(len(w["panes"]) for s in out_sessions for w in s["windows"])
print(f"{n_sess}\t{n_win}\t{n_pane}")
PY
)

  local summary n_sess n_win n_pane
  summary=$(printf '%s' "$tsv" | python3 -c "$py_save" "$timestamp" "$SNAPSHOT_FILE")
  IFS=$'\t' read -r n_sess n_win n_pane <<<"$summary"

  echo -e "${C_GREEN}✓${C_RESET} Saved ${C_BOLD}${n_sess:-0}${C_RESET} sessions · ${C_BOLD}${n_win:-0}${C_RESET} windows · ${C_BOLD}${n_pane:-0}${C_RESET} panes → ${C_DIM}${SNAPSHOT_FILE}${C_RESET}"
}

# Restore sessions from snapshot (full session/window/pane tree)
_cmd_restore() {
  local start_claude=false
  if [[ "${1:-}" == "--claude" ]]; then
    start_claude=true
  fi

  if [[ ! -f "$SNAPSHOT_FILE" ]]; then
    echo -e "${C_RED}✗ No snapshot found at ${SNAPSHOT_FILE}${C_RESET}" >&2
    echo -e "${C_DIM}  Run 'tm save' first${C_RESET}" >&2
    exit 1
  fi

  _check_cmd python3

  local existing=""
  if _has_tmux_server; then
    existing=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
  fi

  # Python handles the orchestration: validates version, drives tmux commands,
  # prints colored status lines to stdout, returns a summary on the last line.
  local py_restore
  py_restore=$(cat <<'PY'
import json, os, subprocess, sys

SNAPSHOT  = sys.argv[1]
START_CL  = sys.argv[2] == "true"
EXISTING  = set(filter(None, sys.argv[3].splitlines())) if len(sys.argv) > 3 else set()

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

n_sess = n_win = n_pane = 0
n_skip = 0
n_claude = 0

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

    pretty = base_path.replace(os.environ.get("HOME", ""), "~", 1) if os.environ.get("HOME") else base_path
    print(f"  {G}OK{X}    {sname} → {pretty}")
    n_sess += 1
    n_win += 1
    n_pane += 1

    # Stage 2a: window 0 — split remaining panes & apply layout
    for p in w0["panes"][1:]:
        tmux("split-window", "-t", f"{sname}:{w0['index']}", "-c", safe_path(p["path"]))
        n_pane += 1
    if w0.get("layout"):
        tmux("select-layout", "-t", f"{sname}:{w0['index']}", w0["layout"])
    tmux("select-pane", "-t", f"{sname}:{w0['index']}.{w0.get('active_pane', 0)}")

    # Stage 1b + 2b: remaining windows
    for w in windows[1:]:
        wp0 = w["panes"][0] if w.get("panes") else None
        if not wp0:
            continue
        wname = w.get("name", "")
        tmux("new-window", "-t", f"{sname}:{w['index']}", "-c", safe_path(wp0["path"]), "-n", wname)
        n_win += 1
        n_pane += 1
        for p in w["panes"][1:]:
            tmux("split-window", "-t", f"{sname}:{w['index']}", "-c", safe_path(p["path"]))
            n_pane += 1
        if w.get("layout"):
            tmux("select-layout", "-t", f"{sname}:{w['index']}", w["layout"])
        tmux("select-pane", "-t", f"{sname}:{w['index']}.{w.get('active_pane', 0)}")

    # Stage 3: launch Claude per-pane if requested
    if START_CL:
        for w in windows:
            for p in w.get("panes", []):
                if not p.get("has_claude"):
                    continue
                cmd = "claude --continue --dangerously-skip-permissions" if p.get("claude_mode") == "continue" \
                      else "claude --dangerously-skip-permissions"
                target = f"{sname}:{w['index']}.{p['index']}"
                tmux("send-keys", "-t", target, cmd, "Enter")
                n_claude += 1

    # Finally: set active window
    tmux("select-window", "-t", f"{sname}:{s.get('active_window', 0)}")

# Summary line (parsed by bash caller)
print(f"__SUMMARY__\t{n_sess}\t{n_win}\t{n_pane}\t{n_skip}\t{n_claude}")
PY
)

  local out summary n_sess n_win n_pane n_skip n_claude
  out=$(python3 -c "$py_restore" "$SNAPSHOT_FILE" "$start_claude" "$existing")
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "$out"
    exit $rc
  fi

  # Print everything except the summary line, then parse summary
  summary=$(printf '%s\n' "$out" | grep '^__SUMMARY__' | head -n1)
  printf '%s\n' "$out" | grep -v '^__SUMMARY__'

  IFS=$'\t' read -r _ n_sess n_win n_pane n_skip n_claude <<<"$summary"

  echo ""
  echo -e "${C_BOLD}Done:${C_RESET} ${n_sess:-0} sessions · ${n_win:-0} windows · ${n_pane:-0} panes restored, ${n_skip:-0} skipped"
  if [[ "${n_claude:-0}" -gt 0 ]]; then
    echo -e "${C_BOLD}Claude Code started in ${n_claude} panes${C_RESET}"
  fi
}

# List latest snapshot contents (sessions → windows → panes)
_cmd_snapshots() {
  if [[ ! -f "$SNAPSHOT_FILE" ]]; then
    echo -e "${C_DIM}No snapshot found. Run 'tm save' to create one.${C_RESET}"
    return
  fi

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
            claude = f"yes({p.get('claude_mode','fresh')})" if p.get("has_claude") else "no"
            print(f"  {w_cont}   {p_branch} pane {p['index']}  claude={claude:<14} {short(p.get('path',''))}")
PY
)
  python3 -c "$py_show" "$SNAPSHOT_FILE"
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

  # User-facing CLI commands (only need tmux, not fzf)
  new|create)      _check_cmd tmux; _cmd_quick_new "${@:2}" ;;
  attach)          _check_cmd tmux; _cmd_attach "${@:2}" ;;
  kill|rm|remove)  _check_cmd tmux; _cmd_quick_kill "${2:-}" ;;
  ls|list)         _check_cmd tmux; _cmd_simple_list ;;
  rename)          _check_cmd tmux; _cmd_rename "${2:-}" ;;
  last)            _check_cmd tmux; _cmd_last ;;
  templates|tpl)   _cmd_templates ;;
  protect|lock)    _check_cmd tmux; _toggle_protect "${2:-}" ;;
  summarize)       _check_cmd tmux; _cmd_summarize "${2:-}" ;;
  summarize-all)   _check_cmd tmux; _cmd_summarize_all ;;
  save)            _check_cmd tmux; _cmd_save ;;
  restore)         _check_cmd tmux; _cmd_restore "${2:-}" ;;
  snapshots|snaps) _cmd_snapshots ;;
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
