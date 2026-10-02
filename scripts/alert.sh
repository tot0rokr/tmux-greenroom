#!/usr/bin/env bash
# Runs in the greenroom server from hooks. Copies the list of windows with a
# bell nobody has seen yet to the host's @greenroom_alert, and announces new
# bells on the host clients.
#
#   alert.sh refresh
#   alert.sh bell <window-id>

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

main() {
  local mode=$1 window=${2:-} host alerts='' name client
  host=$(read_raw_options @greenroom_host)
  host=${host%"$FIELD_SEPARATOR"}
  [[ -n $host ]] || return 0

  # tmux sets the bell flag only on windows no client is looking at, and
  # clears it once one is.
  while IFS= read -r name; do
    [[ -n $name ]] && alerts+="${alerts:+ }$name"
  done < <(tmux list-windows -a -F '#{?window_bell_flag,#{window_name}@#{session_name},}')
  if [[ -n $alerts ]]; then
    tmux -S "$host" set-option -g @greenroom_alert "$(tmux_arg "$alerts")"
  else
    tmux -S "$host" set-option -gu @greenroom_alert
  fi

  [[ $mode == bell && $(tmux display-message -p -t "$window" '#{window_bell_flag}') == 1 ]] || return 0
  name=$(tmux display-message -p -t "$window" '#{window_name}@#{session_name}')
  for client in $(tmux -S "$host" list-clients -F '#{client_name}'); do
    tmux -S "$host" display-message -c "$client" "$(format_escape "greenroom: $name rang the bell")"
  done
}

# A hook job's output or failure would show up in the popup.
main "$@" >/dev/null 2>&1
exit 0
