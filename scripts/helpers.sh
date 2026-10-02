#!/usr/bin/env bash
# Option names: @greenroom-* are user options, @greenroom_* are plugin state.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPTS_DIR")"
FIELD_SEPARATOR=$'\037'
# Carries text sent to the popup: a host buffer first, then a greenroom server
# one.
SEND_BUFFER=greenroom_send

get_tmux_option() {
  local value
  value=$(tmux show-option -gqv "$1")
  printf '%s' "${value:-$2}"
}

# read_raw_options [-t target-pane] name...
# Prints the values of the named options, each followed by FIELD_SEPARATOR.
# tmux 3.4 prints '$' as '\$' in show-option and display-message output, and
# a paste buffer is the one path that returns values as stored.
read_raw_options() {
  local buffer="greenroom-read-$$" target=() format=x name
  if [[ $1 == -t ]]; then
    target=(-t "$2")
    shift 2
  fi
  # The leading x keeps tmux from tilde-expanding the first value.
  for name in "$@"; do
    format+="#{q:$name}\\037"
  done
  tmux run-shell -C "${target[@]}" "set-buffer -b $buffer \"$format\"" &&
    tmux save-buffer -b "$buffer" - | tail -c +2 &&
    tmux delete-buffer -b "$buffer"
}

# Single-quotes a string for both sh and the tmux command parser.
quote() {
  local q="'" escaped="'\\''"
  printf "'%s'" "${1//$q/$escaped}"
}

# Escapes '#' so a string survives format expansion (display-menu items,
# start directories).
format_escape() {
  local hash='#'
  printf '%s' "${1//$hash/##}"
}

# tmux takes a command-line argument that ends in ';' as a command separator.
tmux_arg() {
  if [[ $1 == *';' ]]; then
    printf '%s\\;' "${1%;}"
    return
  fi
  printf '%s' "$1"
}

is_valid_name() {
  case $1 in
    '' | *[!A-Za-z0-9_-]*) return 1 ;;
  esac
}

sanitize_name() {
  local name=$1
  name=${name//[!A-Za-z0-9_-]/_}
  printf '%s' "$name"
}

# Reads the name typed into a workspace prompt (see workspace-menu.sh).
take_pending_name() {
  local name
  name=$(read_raw_options @greenroom_pending)
  tmux set-option -gu @greenroom_pending
  sanitize_name "${name%"$FIELD_SEPARATOR"}"
}

# The shell command a window runs to start a profile.
profile_command() {
  printf '%s %s' "$(quote "$SCRIPTS_DIR/run-profile.sh")" "$(quote "$1")"
}
