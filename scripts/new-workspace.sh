#!/usr/bin/env bash
# Runs in the agent server after the "new workspace" prompt.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

main() {
  local client=$1 name origin agent pane
  name=$(take_pending_name)
  if [[ -z $name ]]; then
    return
  fi

  if ! tmux has-session -t "=$name" 2>/dev/null; then
    pane=$(tmux display-message -c "$client" -p '#{pane_id}')
    origin=$(read_raw_options -t "$pane" @llm_agent_origin)
    origin=${origin%"$FIELD_SEPARATOR"}
    origin=${origin:-$HOME}
    agent=$(get_tmux_option @llm_agent_default claude)
    tmux new-session -d -s "$name" -c "$(tmux_arg "$(format_escape "$origin")")" \
      -n "$agent" "$(agent_command "$agent")" \; \
      set-option -t "=$name:" @llm_agent_origin "$(tmux_arg "$origin")"
  fi
  tmux switch-client -c "$client" -t "=$name"
}

main "$@"
