#!/usr/bin/env bash
# Runs in the greenroom server (from a key binding or right after attach).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

MAX_NUMBERED=9

# The typed name goes through an option, never through a shell command line.
# The option is per client, so two popups confirming at once keep their names.
prompt_item() {
  local label=$1 key=$2 prompt=$3 initial=$4 script=$5 template
  template="set-option -g $(quote "$PENDING") \"%%%\" ; run-shell -b $(quote "$(quote "$SCRIPTS_DIR/$script") $(quote "$CLIENT") $(quote "$PENDING")")"
  ITEMS+=("$label" "$key" "$(format_escape "command-prompt -I $(quote "$initial") -p $(quote "$prompt") $(quote "$template")")")
}

main() {
  local pid current current_name id name windows label key i=0
  CLIENT=$1
  ITEMS=()
  IFS=$FIELD_SEPARATOR read -r -d '' pid current current_name < <(client_values "$CLIENT" \
    '#{client_pid}' '#{session_id}' '#{session_name}')
  PENDING=@greenroom_pending_$pid
  # Session IDs start with '$', which tmux 3.4 escapes in command output.
  current=${current//\\/}

  while IFS=$'\t' read -r id name windows; do
    id=${id//\\/}
    i=$((i + 1))
    key=''
    ((i <= MAX_NUMBERED)) && key=$i
    label="$name ($windows)"
    [[ $id == "$current" ]] && label="$label *"
    ITEMS+=("$(format_escape "$label")" "$key" "$(format_escape "switch-client -t $(quote "$id")")")
  done < <(tmux list-sessions -F "#{session_id}$(printf '\t')#{session_name}$(printf '\t')#{session_windows}")

  ITEMS+=('')
  prompt_item 'New workspace' n 'new workspace:' '' new-workspace.sh
  prompt_item 'Rename workspace' r 'rename workspace:' "$current_name" rename-workspace.sh
  ITEMS+=('Kill workspace' x "$(format_escape "confirm-before -p $(quote "kill workspace $current_name? (y/n)") $(quote "kill-session -t $(quote "$current")")")")

  tmux display-menu -c "$CLIENT" -T '#[align=centre] workspaces ' -x C -y C "${ITEMS[@]}"
}

main "$@"
