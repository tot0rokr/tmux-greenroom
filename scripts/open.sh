#!/usr/bin/env bash
# Host side: the one place that opens the popup. display-popup waits until the
# popup closes, so callers run this in the background (run-shell -b).
#
#   open.sh <client> <origin> [--menu | --paste]
#   open.sh <client> <origin> --reopen <workspace>    closes the popup first

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

# Fills POPUP with the display-popup arguments at the current size; $1 is the
# start directory, which tmux expands as a format. Sizes and positions hold no
# '$', so one display-message reads them all.
popup_args() {
  local large state_width state_height width height large_width large_height x y lines
  {
    IFS= read -r large
    IFS= read -r state_width
    IFS= read -r state_height
    IFS= read -r width
    IFS= read -r height
    IFS= read -r large_width
    IFS= read -r large_height
    IFS= read -r x
    IFS= read -r y
    IFS= read -r lines
  } < <(tmux display-message -p '#{@greenroom_size_large}
#{@greenroom_size_width}
#{@greenroom_size_height}
#{@greenroom-width}
#{@greenroom-height}
#{@greenroom-large-width}
#{@greenroom-large-height}
#{@greenroom-x}
#{@greenroom-y}
#{@greenroom-border-lines}')
  if [[ -n $large ]]; then
    width=${large_width:-95%}
    height=${large_height:-95%}
  else
    width=${state_width:-${width:-80%}}
    height=${state_height:-${height:-80%}}
  fi
  # tmux's C puts a popup of odd height a row high, so at many heights a 95%
  # popup touches the top edge. -y, the row under the popup, is format-expanded:
  # this centres the popup on the whole client, an odd spare row going below.
  if [[ -z $y || $y == C ]]; then
    y='#{e|+:#{popup_height},#{e|/:#{e|-:#{client_height},#{popup_height}},2}}'
  fi
  POPUP=(-E -d "$1" -w "$width" -h "$height" -x "${x:-C}" -y "$y"
    -b "${lines:-rounded}" -T ' agents ')
}

main() {
  local client=$1 origin=$2 attach clear=() error
  shift 2
  attach="$(quote "$SCRIPTS_DIR/attach.sh") --client $(quote "$client")"
  case ${1:-} in
    --menu | --paste) attach+=" $1" ;;
    --reopen)
      # A client that shows a popup drops another display-popup. Two separate
      # calls would let the host pane show through between them.
      clear=(display-popup -C -c "$client" ';')
      attach+=" --reopen $(quote "$2")"
      ;;
  esac
  popup_args "$(tmux_arg "$(format_escape "$origin")")"
  # display-popup exits with the popup job's status, 129 once a re-open clears
  # the popup, so only an error message means it failed. Under run-shell -b a
  # non-zero status would show in the pane and the message would be lost.
  error=$(tmux "${clear[@]}" display-popup -c "$client" "${POPUP[@]}" "$attach" 2>&1 >/dev/null)
  if [[ -n $error ]]; then
    tmux display-message -c "$client" "$(format_escape "greenroom: $error")"
  fi
  return 0
}

main "$@"
