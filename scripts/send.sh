#!/usr/bin/env bash
# Host side of "send to agent". Leaves the text in a host buffer and opens the
# popup; attach.sh --paste moves it into the agent server.
#
#   send.sh selection <client> <origin>         text on stdin
#   send.sh pane <client> <origin> <pane>       the pane's visible screen

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

main() {
  local source=$1 client=$2 origin=$3 text
  if [[ $source == pane ]]; then
    tmux capture-pane -J -b "$SEND_BUFFER" -t "$4"
    text=$(tmux save-buffer -b "$SEND_BUFFER" - | sed 's/[[:space:]]*$//')
  else
    text=$(cat)
  fi
  if [[ -z ${text//[[:space:]]/} ]]; then
    tmux delete-buffer -b "$SEND_BUFFER" 2>/dev/null
    return 0
  fi
  printf '%s' "$text" | tmux load-buffer -b "$SEND_BUFFER" -

  popup_args "$(tmux_arg "$(format_escape "$origin")")"
  tmux display-popup -c "$client" "${POPUP[@]:1}" "$(quote "$SCRIPTS_DIR/attach.sh") --paste"
}

main "$@"
