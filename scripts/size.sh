#!/usr/bin/env bash
# Runs in the greenroom server. Stores the new popup size on the host server
# and has the host open the popup again at that size, on the host client that
# shows the given inner client.
#
#   size.sh large|grow|shrink|reset <client-pid> <workspace>

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

MIN_PERCENT=20
MAX_PERCENT=95

# Prints a -w or -h value moved by delta points, as a percent of the client
# size in cells, within MIN_PERCENT and MAX_PERCENT.
resize() {
  local size=$1 cells=$2 delta=$3 percent
  percent=${size%\%}
  if [[ -z $percent || $percent == *[!0-9]* ]]; then
    percent=80
  elif [[ $size != *% ]]; then
    percent=$(((10#$percent * 100 + cells / 2) / cells))
  fi
  percent=$((10#$percent + delta))
  ((percent < MIN_PERCENT)) && percent=$MIN_PERCENT
  ((percent > MAX_PERCENT)) && percent=$MAX_PERCENT
  printf '%d%%' "$percent"
}

# Appends a command that sets a state option, or unsets it if the value is
# empty, to HOST_COMMANDS.
set_state() {
  if [[ -n $2 ]]; then
    HOST_COMMANDS+=(set-option -g "$1" "$2" ';')
  else
    HOST_COMMANDS+=(set-option -gu "$1" ';')
  fi
}

main() {
  local action=$1 pid=$2 workspace=$3 values=() host client origin format line before step delta reopen
  local large state_width state_height width height client_width client_height
  IFS=$FIELD_SEPARATOR read -r -d '' -a values < <(read_raw_options -t "=$workspace:" \
    @greenroom_host "@greenroom_host_client_$pid" @greenroom_origin)
  host=${values[0]}
  client=${values[1]}
  origin=${values[2]:-$HOME}
  # A client without a record shows no popup: it was attached to this server
  # directly, or by an attach.sh older than the records.
  [[ -n $host && -n $client ]] || return 0

  # display-message -c expands client formats for the most recently active
  # client, not the given one, so the size comes from list-clients.
  format='#{client_name}|#{client_width}|#{client_height}|#{@greenroom_size_large}'
  format+='|#{@greenroom_size_width}|#{@greenroom_size_height}|#{@greenroom-width}'
  format+='|#{@greenroom-height}|#{@greenroom-resize-step}'
  while IFS= read -r line; do
    if [[ ${line%%"|"*} == "$client" ]]; then
      IFS='|' read -r client client_width client_height large state_width state_height \
        width height step <<<"$line"
      break
    fi
  done < <(tmux -S "$host" list-clients -F "$format")
  ((client_width > 0 && client_height > 0)) || return 0

  before="$large $state_width $state_height"
  case $action in
    large)
      if [[ -n $large ]]; then
        large=''
      else
        large=1
      fi
      ;;
    grow | shrink)
      step=${step:-10}
      [[ $step == *[!0-9]* ]] && step=10
      delta=$((10#$step))
      [[ $action == shrink ]] && delta=$((-delta))
      state_width=$(resize "${state_width:-${width:-80%}}" "$client_width" "$delta")
      state_height=$(resize "${state_height:-${height:-80%}}" "$client_height" "$delta")
      large=''
      ;;
    reset)
      large=''
      state_width=''
      state_height=''
      ;;
    *) return 1 ;;
  esac
  [[ "$large $state_width $state_height" != "$before" ]] || return 0

  HOST_COMMANDS=()
  set_state @greenroom_size_large "$large"
  set_state @greenroom_size_width "$state_width"
  set_state @greenroom_size_height "$state_height"
  # The new display-popup waits until its popup closes. Run by the host, it
  # leaves no job behind in this server.
  reopen="$(quote "$SCRIPTS_DIR/open.sh") $(quote "$client") $(quote "$origin") --reopen $(quote "$workspace")"
  tmux -S "$host" "${HOST_COMMANDS[@]}" run-shell -b "$(format_escape "$reopen")"
}

# Keys typed during a re-open reach the new client at once, so two size keys
# can run together; the lock makes each start from the size the last stored.
# A job's output or failure would cover the pane.
{
  tmux wait-for -L greenroom_size
  main "$@"
  tmux wait-for -U greenroom_size
} >/dev/null 2>&1
exit 0
