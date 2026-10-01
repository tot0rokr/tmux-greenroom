#!/usr/bin/env bash
# Runs in the agent server right after attach. Pastes the text sent from the
# host into the agent pane. A just-started agent gets time to draw its prompt
# first, since tmux cannot tell when it starts reading input.
#
#   paste.sh <pane> now|wait

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

SETTLE_POLL_SECONDS=0.3
SETTLE_TIMEOUT_SECONDS=10

# Returns once the pane shows something and has stopped changing.
wait_until_settled() {
  local pane=$1 previous='' current deadline=$((SECONDS + SETTLE_TIMEOUT_SECONDS))
  while ((SECONDS < deadline)); do
    sleep "$SETTLE_POLL_SECONDS"
    current=$(tmux capture-pane -p -t "$pane") || return 0
    if [[ -n ${current//[[:space:]]/} && $current == "$previous" ]]; then
      return 0
    fi
    previous=$current
  done
}

main() {
  local pane=$1 mode=$2
  if [[ $mode == wait ]]; then
    wait_until_settled "$pane"
  fi
  tmux paste-buffer -p -d -b "$SEND_BUFFER" -t "$pane"
}

main "$@" >/dev/null 2>&1
exit 0
