#!/usr/bin/env bash
# Runs in the greenroom server after the "rename workspace" prompt.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

main() {
  local client=$1 name
  name=$(take_pending_name)
  if [[ -z $name ]]; then
    return
  fi
  tmux rename-session -t "$(tmux display-message -c "$client" -p '#{pane_id}')" "$name"
}

main "$@"
