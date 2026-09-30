#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/scripts/helpers.sh"

POPUP=()
BOUND=''

bind_popup() {
  local table=$1 key=$2
  shift 2
  tmux bind-key -T "$table" "$(tmux_arg "$key")" "${POPUP[@]}" "$*"
  BOUND+=" $table:$key"
}

main() {
  local root_key attach binding
  # The agent server can be pointed at a config that loads this plugin again.
  if [[ -n $(get_tmux_option @llm_agent_server '') ]]; then
    return
  fi

  # Drop the keys a previous load bound, in case the options changed.
  for binding in $(get_tmux_option @llm_agent_bound ''); do
    tmux unbind-key -T "${binding%%:*}" "$(tmux_arg "${binding#*:}")"
  done

  attach=$(quote "$SCRIPTS_DIR/attach.sh")
  POPUP=(display-popup -E -d '#{pane_current_path}'
    -w "$(get_tmux_option @llm-agent-width 80%)"
    -h "$(get_tmux_option @llm-agent-height 80%)"
    -x "$(get_tmux_option @llm-agent-x C)"
    -y "$(get_tmux_option @llm-agent-y C)"
    -b "$(get_tmux_option @llm-agent-border-lines rounded)"
    -T ' agents ')

  bind_popup prefix "$(get_tmux_option @llm-agent-key g)" "$attach"
  root_key=$(get_tmux_option @llm-agent-root-key '')
  if [[ -n $root_key ]]; then
    bind_popup root "$root_key" "$attach"
  fi
  bind_popup prefix "$(get_tmux_option @llm-agent-menu-key G)" "$attach --menu"
  tmux set-option -g @llm_agent_bound "$BOUND"
}

main
