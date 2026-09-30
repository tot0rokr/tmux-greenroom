#!/usr/bin/env bash
# Runs in the agent server (from a key binding or right after attach).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

MAX_NUMBERED=9

# The typed name goes through an option, never through a shell command line.
prompt_item() {
  local label=$1 key=$2 prompt=$3 initial=$4 script=$5 template
  template="set-option -g @llm_agent_pending \"%%%\" ; run-shell -b $(quote "$(quote "$SCRIPTS_DIR/$script") $(quote "$CLIENT")")"
  ITEMS+=("$label" "$key" "$(format_escape "command-prompt -I $(quote "$initial") -p $(quote "$prompt") $(quote "$template")")")
}

main() {
  local current id name windows label key i=0
  CLIENT=$1
  ITEMS=()
  # Session IDs start with '$', which tmux 3.4 escapes in command output.
  current=$(tmux display-message -c "$CLIENT" -p '#{session_id}')
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

  name=$(tmux display-message -c "$CLIENT" -p '#{session_name}')
  ITEMS+=('')
  prompt_item 'New workspace' n 'new workspace:' '' new-workspace.sh
  prompt_item 'Rename workspace' r 'rename workspace:' "$name" rename-workspace.sh
  ITEMS+=('Kill workspace' x "$(format_escape "confirm-before -p $(quote "kill workspace $name? (y/n)") $(quote "kill-session -t $(quote "$current")")")")

  tmux display-menu -c "$CLIENT" -T '#[align=centre] workspaces ' -x C -y C "${ITEMS[@]}"
}

main "$@"
