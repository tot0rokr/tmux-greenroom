#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/scripts/helpers.sh"

BOUND=''

bind_key() {
  local table=$1 key=$2
  shift 2
  tmux bind-key -T "$table" "$(tmux_arg "$key")" "$@"
  BOUND+=" $table:$key"
}

main() {
  local root_key send_key attach send binding
  # The agent server can be pointed at a config that loads this plugin again.
  if [[ -n $(get_tmux_option @greenroom_server '') ]]; then
    return
  fi

  # Drop the keys a previous load bound, in case the options changed.
  for binding in $(get_tmux_option @greenroom_bound ''); do
    tmux unbind-key -T "${binding%%:*}" "$(tmux_arg "${binding#*:}")"
  done

  attach=$(quote "$SCRIPTS_DIR/attach.sh")
  popup_args '#{pane_current_path}'
  bind_key prefix "$(get_tmux_option @greenroom-key g)" "${POPUP[@]}" "$attach"
  root_key=$(get_tmux_option @greenroom-root-key '')
  if [[ -n $root_key ]]; then
    bind_key root "$root_key" "${POPUP[@]}" "$attach"
  fi
  bind_key prefix "$(get_tmux_option @greenroom-workspaces-key G)" "${POPUP[@]}" "$attach --menu"

  # Both commands are format-expanded when they run.
  send=$(format_escape "$(quote "$SCRIPTS_DIR/send.sh")")
  send_key=$(get_tmux_option @greenroom-send-key a)
  bind_key copy-mode "$send_key" send-keys -X pipe-and-cancel \
    "$send selection '#{client_name}' #{q:pane_current_path}"
  bind_key copy-mode-vi "$send_key" send-keys -X pipe-and-cancel \
    "$send selection '#{client_name}' #{q:pane_current_path}"
  bind_key prefix "$(get_tmux_option @greenroom-send-pane-key S)" run-shell -b \
    "$send pane '#{client_name}' #{q:pane_current_path} '#{pane_id}'"

  tmux set-option -g @greenroom_bound "$BOUND"
}

main
