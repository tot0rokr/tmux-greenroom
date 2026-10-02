#!/usr/bin/env bash
# Runs in the greenroom server after the "rename workspace" prompt.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

main() {
  local client=$1 pending=$2 name session
  name=$(take_pending_name "$pending")
  if [[ -z $name ]]; then
    return
  fi
  session=$(client_session "$client") || return
  tmux rename-session -t "$session" "$name"
}

main "$@"
