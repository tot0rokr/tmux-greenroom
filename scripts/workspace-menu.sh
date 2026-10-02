#!/usr/bin/env bash
# Runs in the greenroom server (from a key binding, the command menu or right
# after attach).
#
#   workspace-menu.sh <client> [new | rename | kill]    an action skips the menu

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

MAX_NUMBERED=9

# Sets ACTION to the tmux command of a workspace action. The typed name goes
# through an option, never through a shell command line. The option is per
# client, so two popups confirming at once keep their names. With -b the job
# of an action does not wait for the answer: a "no" would fail it, and it would
# hang, keeping the server alive, if the popup went away first.
set_action() {
  local initial='' template
  if [[ $1 == kill ]]; then
    ACTION=(confirm-before -b -t "$CLIENT" -p "kill workspace $CURRENT_NAME? (y/n)" "kill-session -t $(quote "$CURRENT")")
    return
  fi
  [[ $1 == rename ]] && initial=$CURRENT_NAME
  template="set-option -g $(quote "$PENDING") \"%%%\" ; run-shell -b $(quote "$(quote "$SCRIPTS_DIR/$1-workspace.sh") $(quote "$CLIENT") $(quote "$PENDING")")"
  ACTION=(command-prompt -b -t "$CLIENT" -I "$initial" -p "$1 workspace:" "$template")
}

action_item() {
  set_action "$3"
  ITEMS+=("$1" "$2" "$(format_escape "$(command_line "${ACTION[@]}")")")
}

main() {
  local action=${2:-} pid id name windows label key arg args=() i=0
  CLIENT=$1
  ITEMS=()
  IFS=$FIELD_SEPARATOR read -r -d '' pid CURRENT CURRENT_NAME < <(client_values "$CLIENT" \
    '#{client_pid}' '#{session_id}' '#{session_name}')
  PENDING=@greenroom_pending_$pid
  # Session IDs start with '$', which tmux 3.4 escapes in command output.
  CURRENT=${CURRENT//\\/}

  if [[ -n $action ]]; then
    set_action "$action"
    for arg in "${ACTION[@]}"; do
      args+=("$(tmux_arg "$arg")")
    done
    tmux "${args[@]}"
    return
  fi

  while IFS=$'\t' read -r id name windows; do
    id=${id//\\/}
    i=$((i + 1))
    key=''
    ((i <= MAX_NUMBERED)) && key=$i
    label="$name ($windows)"
    [[ $id == "$CURRENT" ]] && label="$label *"
    ITEMS+=("$(format_escape "$label")" "$key" "$(format_escape "switch-client -t $(quote "$id")")")
  done < <(tmux list-sessions -F "#{session_id}$(printf '\t')#{session_name}$(printf '\t')#{session_windows}")

  ITEMS+=('')
  action_item 'New workspace' n new
  action_item 'Rename workspace' r rename
  action_item 'Kill workspace' x kill

  tmux display-menu -c "$CLIENT" -T '#[align=centre] workspaces ' -x C -y C "${ITEMS[@]}"
}

main "$@"
