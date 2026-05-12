#compdef tm
#
# Zsh completion for tm (tmux session manager)
#
# Installation:
#   Option 1 - Source directly (add to ~/.zshrc):
#     source /path/to/session-manager/completions/tm.zsh
#
#   Option 2 - Copy to fpath:
#     cp completions/tm.zsh ~/.zsh/completions/_tm
#     # Ensure ~/.zsh/completions is in fpath (before compinit):
#     #   fpath=(~/.zsh/completions $fpath)

_tm_sessions() {
  local -a sessions
  sessions=( ${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null)"} )
  (( ${#sessions} )) && compadd -X "sessions" "$@" -- "${sessions[@]}"
}

_tm_templates() {
  local -a templates
  templates=( ${(f)"$(ls ~/.tmux-manager/templates/ 2>/dev/null)"} )
  (( ${#templates} )) && compadd -X "templates" "$@" -- "${templates[@]}"
}

_tm() {
  local curcontext="$curcontext" ret=1

  local -a subcommands=(
    'new:Create a new session'
    'kill:Kill a session'
    'attach:Attach to a session'
    'rename:Rename a session'
    'ls:List all sessions'
    'last:Switch to last session'
    'templates:List available templates'
    'protect:Toggle session protection'
    'summarize:Generate AI summary for a session'
    'summarize-all:Generate AI summaries for all sessions'
    'save:Snapshot all sessions for restore after reboot'
    'restore:Restore sessions from snapshot'
    'snapshots:Show latest snapshot contents'
    'help:Show usage information'
  )

  if (( CURRENT == 2 )); then
    # First argument: subcommands + existing session names
    _describe -t commands 'tm command' subcommands && ret=0
    _tm_sessions && ret=0
    return ret
  fi

  # Second argument onwards: dispatch by subcommand
  local subcmd="${words[2]}"
  case "$subcmd" in
    kill|rm|remove)
      _tm_sessions && ret=0
      ;;
    rename)
      _tm_sessions && ret=0
      ;;
    protect|lock)
      _tm_sessions && ret=0
      ;;
    summarize)
      _tm_sessions && ret=0
      ;;
    attach)
      _arguments -s \
        '-d[Detach other clients]' \
        '1:session:_tm_sessions' && ret=0
      ;;
    new|create)
      _arguments -s \
        '(-t --template)'{-t,--template}'[Use template]:template:_tm_templates' \
        '1:name:' \
        '2:directory:_directories' && ret=0
      ;;
    restore)
      _arguments -s \
        '--claude[Auto-launch Claude Code after restore]' && ret=0
      ;;
    ls|list|last|templates|tpl|summarize-all|save|snapshots|snaps|help)
      # No further arguments
      ;;
  esac

  return ret
}

# When loaded via fpath, #compdef handles registration.
# When sourced directly, register explicitly.
# Also register for alias target (e.g., alias tm=/path/to/tm.sh),
# since zsh expands aliases before completion lookup by default.
if (( $+functions[compdef] )); then
  compdef _tm tm
  if (( $+aliases[tm] )); then
    compdef _tm "${aliases[tm]}"
  fi
fi
