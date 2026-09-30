#!/usr/bin/env bash
# Runs as the popup job: the cwd is the origin pane path and $TMUX points at
# the host server. Prepares the workspace, then becomes an agent server client.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

# Host options copied once, when the agent server starts.
MIRRORED_OPTIONS=(default-terminal history-limit mouse mode-keys status-keys
  base-index pane-base-index escape-time extended-keys set-clipboard)
# display-menu uses these keys itself.
RESERVED_MENU_KEYS=qjkgG

SOCKET=$(get_tmux_option @llm-agent-socket llm-agent)
KEY=$(get_tmux_option @llm-agent-key g)
ROOT_KEY=$(get_tmux_option @llm-agent-root-key '')
NEW_KEY=$(get_tmux_option @llm-agent-new-key c)
MENU_KEY=$(get_tmux_option @llm-agent-menu-key G)
AGENTS=$(get_tmux_option @llm-agent-agents 'claude codex gemini opencode')
DEFAULT_AGENT=$(get_tmux_option @llm-agent-default claude)
DEFAULT_WORKSPACE=$(sanitize_name "$(get_tmux_option @llm-agent-workspace main)")
USER_CONFIG=$(get_tmux_option @llm-agent-config '')

CHAIN=()
BOUND=''

agent_tmux() {
  local config=(-f "$PLUGIN_DIR/conf/agent-server.conf")
  [[ -n $USER_CONFIG ]] && config+=(-f "${USER_CONFIG/#\~/$HOME}")
  env -u TMUX -u TMUX_PANE tmux -L "$SOCKET" "${config[@]}" "$@"
}

# Appends one command to CHAIN, which runs as a single tmux invocation.
chain() {
  local arg
  if ((${#CHAIN[@]})); then
    CHAIN+=(';')
  fi
  for arg in "$@"; do
    CHAIN+=("$(tmux_arg "$arg")")
  done
}

# Binds a key and remembers it, so the next open can drop stale bindings.
chain_bind() {
  local table=$1 key=$2
  shift 2
  chain bind-key -T "$table" "$key" "$@"
  BOUND+=" $table:$key"
}

has_workspace() {
  agent_tmux has-session -t "=$1" 2>/dev/null
}

pick_workspace() {
  local candidate first
  if [[ -n $1 ]]; then
    sanitize_name "$1"
    return
  fi
  for candidate in "$(agent_tmux show-option -gqv @llm_agent_last 2>/dev/null)" "$DEFAULT_WORKSPACE"; do
    if [[ -n $candidate ]] && has_workspace "$candidate"; then
      printf '%s' "$candidate"
      return
    fi
  done
  first=$(agent_tmux list-sessions -F '#{session_name}' 2>/dev/null | head -n 1)
  printf '%s' "${first:-$DEFAULT_WORKSPACE}"
}

# First letter of the name that no earlier item took.
menu_shortcut() {
  local name=$1 used=$2 i c
  for ((i = 0; i < ${#name}; i++)); do
    c=${name:i:1}
    case $c in
      [!a-z0-9]) continue ;;
    esac
    case $used in
      *"$c"*) continue ;;
    esac
    printf '%s' "$c"
    return
  done
}

mirror_host_options() {
  local option value
  for option in "${MIRRORED_OPTIONS[@]}"; do
    value=$(tmux show-option -gqv "$option")
    [[ -n $value ]] && chain set-option -g "$option" "$value"
  done
}

# Replaces the agent server's copy of every user option, so edits and
# removals on the host take effect on the next open.
mirror_user_options() {
  local names=() values=() name i
  for name in $(agent_tmux show-options -g 2>/dev/null | awk '$1 ~ /^@llm-agent-/ { print $1 }'); do
    chain set-option -gu "$name"
  done
  while read -r name _; do
    [[ $name == @llm-agent-* ]] && names+=("$name")
  done < <(tmux show-options -g)
  ((${#names[@]})) || return
  IFS=$FIELD_SEPARATOR read -r -d '' -a values < <(read_raw_options "${names[@]}")
  for i in "${!names[@]}"; do
    chain set-option -g "${names[i]}" "${values[i]}"
  done
}

push_state() {
  chain set-option -g @llm_agent_key "$KEY"
  chain set-option -g @llm_agent_new_key "$NEW_KEY"
  chain set-option -g @llm_agent_menu_key "$MENU_KEY"
  chain set-option -g @llm_agent_default "$DEFAULT_AGENT"
}

agent_menu() {
  local used=$RESERVED_MENU_KEYS name key spawn
  AGENT_MENU=(display-menu -T '#[align=centre] new agent ' -x C -y C)
  for name in $AGENTS shell; do
    is_valid_name "$name" || continue
    [[ $name == shell ]] && AGENT_MENU+=('')
    key=$(menu_shortcut "$name" "$used")
    used+=$key
    # Escaped, so new-window -c expands the origin itself when the item runs.
    spawn="new-window -c '#{@llm_agent_origin}' -n $(quote "$name") $(quote "$(agent_command "$name")")"
    AGENT_MENU+=("$name" "$key" "$(format_escape "$spawn")")
  done
}

push_bindings() {
  local prefix prefix2 binding
  for binding in $(agent_tmux show-option -gqv @llm_agent_bound 2>/dev/null); do
    chain unbind-key -T "${binding%%:*}" "${binding#*:}"
  done

  prefix=$(tmux show-option -gqv prefix)
  prefix2=$(tmux show-option -gqv prefix2)
  chain set-option -g prefix "$prefix"
  chain set-option -g prefix2 "$prefix2"
  [[ $prefix != None ]] && chain_bind prefix "$prefix" send-prefix
  chain_bind prefix "$KEY" detach-client
  [[ -n $ROOT_KEY ]] && chain_bind root "$ROOT_KEY" detach-client
  chain_bind prefix "$MENU_KEY" run-shell -b \
    "$(quote "$SCRIPTS_DIR/workspace-menu.sh") '#{client_name}'"
  agent_menu
  chain_bind prefix "$NEW_KEY" "${AGENT_MENU[@]}"
  chain set-option -g @llm_agent_bound "$BOUND"
}

main() {
  local open_menu='' fresh='' workspace origin=$PWD attach
  if [[ ${1:-} == --menu ]]; then
    open_menu=1
    shift
  fi

  agent_tmux list-sessions >/dev/null 2>&1 || fresh=1
  workspace=$(pick_workspace "${1:-}")

  chain start-server
  [[ -n $fresh ]] && mirror_host_options
  mirror_user_options
  push_state
  push_bindings
  if [[ -n $fresh ]] || ! has_workspace "$workspace"; then
    chain new-session -d -s "$workspace" -c "$(format_escape "$origin")" -n "$DEFAULT_AGENT" \
      "$(agent_command "$DEFAULT_AGENT")"
  fi
  chain set-option -t "=$workspace:" @llm_agent_origin "$origin"

  # Another client may have created the workspace first; that is fine.
  if ! agent_tmux "${CHAIN[@]}" && ! has_workspace "$workspace"; then
    printf 'tmux-llm-agent: could not prepare workspace %s. Press any key.' "$workspace"
    read -rsn1
    exit 1
  fi

  attach=(attach-session -t "=$workspace")
  if [[ -n $open_menu ]]; then
    attach+=(';' run-shell -b "$(quote "$SCRIPTS_DIR/workspace-menu.sh") '#{client_name}'")
  fi
  exec env -u TMUX -u TMUX_PANE tmux -L "$SOCKET" "${attach[@]}"
}

main "$@"
