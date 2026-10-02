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

# client_values [-S socket] client format...
# Prints the client's values of the formats, each followed by FIELD_SEPARATOR,
# or fails if there is no such client. display-message -c gives the values of
# the most recently active session and its client, not of the given client.
client_values() {
  local server=() client format='#{client_name}' name line rest placeholder=$'\001'
  if [[ $1 == -S ]]; then
    server=(-S "$2")
    shift 2
  fi
  client=$1
  shift
  for name in "$@"; do
    format+="$FIELD_SEPARATOR$name"
  done
  while IFS= read -r line; do
    # tmux 3.4 prints the separator as \037 and a backslash as \\, so a \037
    # that is text in a value prints as \\037. The \\ pairs are put back by
    # concatenation: bash 5.2 turns \\ in a replacement string into \.
    if [[ $line != *"$FIELD_SEPARATOR"* ]]; then
      rest=${line//\\\\/$placeholder}
      rest=${rest//\\037/$FIELD_SEPARATOR}
      line=
      while [[ $rest == *"$placeholder"* ]]; do
        line+=${rest%%"$placeholder"*}'\\'
        rest=${rest#*"$placeholder"}
      done
      line+=$rest
    fi
    if [[ ${line%%"$FIELD_SEPARATOR"*} == "$client" ]]; then
      printf '%s%s' "${line#*"$FIELD_SEPARATOR"}" "$FIELD_SEPARATOR"
      return 0
    fi
  done < <(tmux "${server[@]}" list-clients -F "$format")
  return 1
}

# Prints the ID of the client's session. A pane target would not do: tmux
# resolves it to the most recently active session that has the window, and a
# window can be in several sessions (session groups, link-window).
client_session() {
  local id
  id=$(client_values "$1" '#{session_id}') || return
  # Session IDs start with '$', which tmux 3.4 escapes in command output.
  id=${id//\\/}
  printf '%s' "${id%"$FIELD_SEPARATOR"}"
}

# Single-quotes a string for both sh and the tmux command parser.
quote() {
  local q="'" escaped="'\\''"
  printf "'%s'" "${1//$q/$escaped}"
}

# Joins the arguments into one tmux command line.
command_line() {
  local arg line=''
  for arg in "$@"; do
    line+=" $(quote "$arg")"
  done
  printf '%s' "${line# }"
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

# take_pending_name option
# Reads and clears the name typed into a workspace prompt (see
# workspace-menu.sh).
take_pending_name() {
  local name
  name=$(read_raw_options "$1")
  tmux set-option -gu "$1"
  sanitize_name "${name%"$FIELD_SEPARATOR"}"
}

# The shell command a window runs to start a profile.
profile_command() {
  printf '%s %s' "$(quote "$SCRIPTS_DIR/run-profile.sh")" "$(quote "$1")"
}
