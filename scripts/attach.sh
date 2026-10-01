#!/usr/bin/env bash
# Runs as the popup job: the cwd is the origin pane path and $TMUX points at
# the host server. Prepares the workspace, then becomes an agent server client.
#
#   attach.sh [--client <host client>] [--menu | --paste] [workspace]
#   attach.sh --client <host client> --reopen <workspace>    from open.sh

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

# Host options copied once, when the agent server starts.
MIRRORED_OPTIONS=(default-terminal history-limit mouse mode-keys status-keys
  base-index pane-base-index escape-time extended-keys set-clipboard)
# display-menu uses these keys itself.
RESERVED_MENU_KEYS=' q j k g G '
# display-menu never runs an item shortcut on an arrow key on tmux 3.7, or on
# an arrow with a modifier (S-Up) on any version. Named keys ignore case.
ARROW_KEY='^([CcMmSs]-|\^)*([Uu][Pp]|[Dd][Oo][Ww][Nn]|[Ll][Ee][Ff][Tt]|[Rr][Ii][Gg][Hh][Tt])$'
# For these agent names, @greenroom-<name>-key is one of the plugin's own key
# options, not a menu shortcut.
PLUGIN_KEY_NAMES=' root send send-pane agents workspaces large grow shrink reset '
# Hook array slots this plugin owns; conf/agent-server.conf uses 100.
ALERT_HOOK_INDEX=101

SOCKET=$(get_tmux_option @greenroom-socket greenroom)
KEY=$(get_tmux_option @greenroom-key g)
ROOT_KEY=$(get_tmux_option @greenroom-root-key '')
AGENTS_KEY=$(get_tmux_option @greenroom-agents-key c)
WORKSPACES_KEY=$(get_tmux_option @greenroom-workspaces-key G)
# An empty value binds no key, so prefix + z stays tmux's zoom.
LARGE_KEY=$(tmux show-option -gv @greenroom-large-key 2>/dev/null) || LARGE_KEY=z
GROW_KEY=$(get_tmux_option @greenroom-grow-key '')
SHRINK_KEY=$(get_tmux_option @greenroom-shrink-key '')
RESET_KEY=$(get_tmux_option @greenroom-reset-key '')
# An empty list is kept: it means no agents, not the default.
AGENTS=$(tmux show-option -gv @greenroom-agents 2>/dev/null) ||
  AGENTS='claude codex gemini opencode | shell'
DEFAULT_AGENT=$(get_tmux_option @greenroom-default claude)
DEFAULT_WORKSPACE=$(sanitize_name "$(get_tmux_option @greenroom-workspace main)")
USER_CONFIG=$(get_tmux_option @greenroom-config '')

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
  local table=$1 key=$2 args=() arg
  shift 2
  # bind-key parses its command arguments a second time, so an argument that
  # ends in ';' (a menu shortcut) is escaped once more.
  for arg in "$@"; do
    args+=("$(tmux_arg "$arg")")
  done
  chain bind-key -T "$table" "$key" "${args[@]}"
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
  for candidate in "$(agent_tmux show-option -gqv @greenroom_last 2>/dev/null)" "$DEFAULT_WORKSPACE"; do
    if [[ -n $candidate ]] && has_workspace "$candidate"; then
      printf '%s' "$candidate"
      return
    fi
  done
  first=$(agent_tmux list-sessions -F '#{session_name}' 2>/dev/null | head -n 1)
  printf '%s' "${first:-$DEFAULT_WORKSPACE}"
}

# First letter of the name that is not in the space-separated used keys.
menu_shortcut() {
  local name=$1 used=$2 i c
  for ((i = 0; i < ${#name}; i++)); do
    c=${name:i:1}
    case $c in
      [!a-z0-9]) continue ;;
    esac
    case $used in
      *" $c "*) continue ;;
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
  for name in $(agent_tmux show-options -g 2>/dev/null | awk '$1 ~ /^@greenroom-/ { print $1 }'); do
    chain set-option -gu "$name"
  done
  while read -r name _; do
    [[ $name == @greenroom-* ]] && names+=("$name")
  done < <(tmux show-options -g)
  ((${#names[@]})) || return
  IFS=$FIELD_SEPARATOR read -r -d '' -a values < <(read_raw_options "${names[@]}")
  for i in "${!names[@]}"; do
    chain set-option -g "${names[i]}" "${values[i]}"
  done
}

push_state() {
  chain set-option -g @greenroom_key "$KEY"
  chain set-option -g @greenroom_agents_key "$AGENTS_KEY"
  chain set-option -g @greenroom_workspaces_key "$WORKSPACES_KEY"
  chain set-option -g @greenroom_default "$DEFAULT_AGENT"
}

agent_menu() {
  local tokens=() names=() gaps=() options=() keys=() claimed=' ' used
  local token gap='' key label spawn i
  # read, unlike an unquoted expansion, does not glob a token such as '*'.
  read -r -d '' -a tokens <<<"$AGENTS"
  for token in "${tokens[@]}"; do
    if [[ $token == '|' ]]; then
      ((${#names[@]})) && gap=1
      continue
    fi
    is_valid_name "$token" || continue
    case " ${names[*]} " in
      *" $token "*) continue ;;
    esac
    names+=("$token")
    gaps+=("$gap")
    options+=("@greenroom-$token-key")
    gap=''
  done

  AGENT_MENU=(display-menu -T '#[align=centre] new agent ' -x C -y C --)
  if ((${#names[@]} == 0)); then
    AGENT_MENU+=('-no agents configured' '' '')
    return
  fi

  # Explicit keys go first, so an automatic shortcut never takes one.
  IFS=$FIELD_SEPARATOR read -r -d '' -a keys < <(read_raw_options "${options[@]}")
  for i in "${!names[@]}"; do
    key=${keys[i]}
    case $PLUGIN_KEY_NAMES in
      *" ${names[i]} "*) key='' ;;
    esac
    [[ $key =~ $ARROW_KEY ]] && key=''
    case $claimed in
      *" $key "*) key='' ;;
    esac
    keys[i]=$key
    [[ -n $key ]] && claimed+="$key "
  done
  used=$RESERVED_MENU_KEYS$claimed
  for i in "${!names[@]}"; do
    if [[ -z ${keys[i]} ]]; then
      keys[i]=$(menu_shortcut "${names[i]}" "$used")
      used+="${keys[i]} "
    fi
    [[ -n ${gaps[i]} ]] && AGENT_MENU+=('')
    label=${names[i]}
    # display-menu draws a name that starts with '-' as a disabled item.
    [[ $label == -* ]] && label="#[default]$label"
    # Escaped, so new-window -c expands the origin itself when the item runs.
    spawn="new-window -c '#{@greenroom_origin}' -n $(quote "${names[i]}") $(quote "$(agent_command "${names[i]}")")"
    AGENT_MENU+=("$label" "${keys[i]}" "$(format_escape "$spawn")")
  done
}

push_bindings() {
  local prefix prefix2 binding
  for binding in $(agent_tmux show-option -gqv @greenroom_bound 2>/dev/null); do
    release_key "$binding"
  done

  prefix=$(tmux show-option -gqv prefix)
  prefix2=$(tmux show-option -gqv prefix2)
  chain set-option -g prefix "$prefix"
  chain set-option -g prefix2 "$prefix2"
  [[ $prefix != None ]] && chain_bind prefix "$prefix" send-prefix
  chain_bind prefix "$KEY" detach-client
  [[ -n $ROOT_KEY ]] && chain_bind root "$ROOT_KEY" detach-client
  chain_bind prefix "$WORKSPACES_KEY" run-shell -b \
    "$(quote "$SCRIPTS_DIR/workspace-menu.sh") '#{client_name}'"
  agent_menu
  chain_bind prefix "$AGENTS_KEY" "${AGENT_MENU[@]}"
  bind_size_key "$LARGE_KEY" large
  bind_size_key "$GROW_KEY" grow
  bind_size_key "$SHRINK_KEY" shrink
  bind_size_key "$RESET_KEY" reset
  chain set-option -g @greenroom_bound "$BOUND"
}

# Drops a binding of the last open; a new one for the key comes later in CHAIN.
# tmux has no command that restores one default binding, and on a new agent
# server the binding a key had before the plugin took it cannot be read. So the
# tmux keys the plugin takes by default (c, z) or the README suggests (-, =)
# get their tmux binding back, and other keys stay unbound until a restart.
release_key() {
  case $1 in
    prefix:c) chain bind-key -T prefix c new-window ;;
    prefix:z) chain bind-key -T prefix z resize-pane -Z ;;
    prefix:-) chain bind-key -T prefix - delete-buffer ;;
    prefix:=) chain bind-key -T prefix = choose-buffer -Z ;;
    *) chain unbind-key -T "${1%%:*}" "${1#*:}" ;;
  esac
}

# Popup size keys; see docs/design.md (D11). An empty key is not bound.
bind_size_key() {
  [[ -n $1 ]] || return 0
  chain_bind prefix "$1" run-shell -b \
    "$(format_escape "$(quote "$SCRIPTS_DIR/size.sh")") $2 '#{client_pid}' #{q:session_name}"
}

# size.sh finds the host client of a popup by the pid of its inner client,
# which this process becomes with the exec at the end. Entries of clients that
# have gone are dropped.
record_host_client() {
  local client=$1 pids name
  pids=" $(agent_tmux list-clients -F '#{client_pid}' 2>/dev/null | tr '\n' ' ')"
  for name in $(agent_tmux show-options -g 2>/dev/null | awk '$1 ~ /^@greenroom_host_client_/ { print $1 }'); do
    case $pids in
      *" ${name#@greenroom_host_client_} "*) ;;
      *) chain set-option -gu "$name" ;;
    esac
  done
  [[ -n $client ]] && chain set-option -g "@greenroom_host_client_$$" "$client"
}

# Bells reach the host through alert.sh; see docs/design.md (D9).
push_alert_hooks() {
  local alert hook
  alert=$(quote "$SCRIPTS_DIR/alert.sh")
  # With the default "other", a bell in the current window of a closed popup
  # would not run the hook.
  chain set-option -g bell-action any
  chain set-option -g @greenroom_host "${TMUX%%,*}"
  chain set-hook -g "alert-bell[$ALERT_HOOK_INDEX]" "run-shell -b $(quote "$alert bell '#{window_id}'")"
  for hook in client-attached client-session-changed session-window-changed window-unlinked session-closed; do
    chain set-hook -g "$hook[$ALERT_HOOK_INDEX]" "run-shell -b $(quote "$alert refresh")"
  done
}

# Moves the text from send.sh into the agent server and pastes it after
# attach, into the active pane of the workspace.
paste_after_attach() {
  local workspace=$1 created=$2 pane mode=now
  tmux show-buffer -b "$SEND_BUFFER" >/dev/null 2>&1 || return 0
  [[ -n $created ]] && mode=wait
  pane=$(agent_tmux display-message -p -t "=$workspace:" '#{pane_id}')
  tmux save-buffer -b "$SEND_BUFFER" - | agent_tmux load-buffer -b "$SEND_BUFFER" -
  tmux delete-buffer -b "$SEND_BUFFER"
  ATTACH+=(';' run-shell -b "$(quote "$SCRIPTS_DIR/paste.sh") $(quote "$pane") $mode")
}

main() {
  local open_menu='' paste='' reopen='' fresh='' created='' host_client='' workspace origin=$PWD
  while [[ ${1:-} == --* ]]; do
    case $1 in
      --client)
        host_client=$2
        shift
        ;;
      --menu) open_menu=1 ;;
      --paste) paste=1 ;;
      --reopen) reopen=1 ;;
    esac
    shift
  done

  # size.sh re-opens the popup on a workspace that is ready. Preparing it
  # again would leave the new popup empty for about half a second. Entries of
  # gone clients stay until the next open, since a size key that the old
  # client sent last still looks up its own.
  if [[ -n $reopen ]]; then
    chain set-option -g "@greenroom_host_client_$$" "$host_client"
    chain attach-session -t "=$1"
    exec env -u TMUX -u TMUX_PANE tmux -L "$SOCKET" "${CHAIN[@]}"
  fi

  agent_tmux list-sessions >/dev/null 2>&1 || fresh=1
  workspace=$(pick_workspace "${1:-}")
  # A host alert left over from an agent server that has since exited.
  [[ -n $fresh ]] && tmux set-option -gu @greenroom_alert

  chain start-server
  [[ -n $fresh ]] && mirror_host_options
  mirror_user_options
  push_state
  push_bindings
  push_alert_hooks
  record_host_client "$host_client"
  if [[ -n $fresh ]] || ! has_workspace "$workspace"; then
    created=1
    chain new-session -d -s "$workspace" -c "$(format_escape "$origin")" -n "$DEFAULT_AGENT" \
      "$(agent_command "$DEFAULT_AGENT")"
  fi
  chain set-option -t "=$workspace:" @greenroom_origin "$origin"

  # Another client may have created the workspace first; that is fine.
  if ! agent_tmux "${CHAIN[@]}" && ! has_workspace "$workspace"; then
    printf 'tmux-greenroom: could not prepare workspace %s. Press any key.' "$workspace"
    read -rsn1
    exit 1
  fi

  ATTACH=(attach-session -t "=$workspace")
  if [[ -n $open_menu ]]; then
    ATTACH+=(';' run-shell -b "$(quote "$SCRIPTS_DIR/workspace-menu.sh") '#{client_name}'")
  fi
  [[ -n $paste ]] && paste_after_attach "$workspace" "$created"
  exec env -u TMUX -u TMUX_PANE tmux -L "$SOCKET" "${ATTACH[@]}"
}

main "$@"
