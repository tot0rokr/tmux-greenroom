#!/usr/bin/env bash
# Runs as the popup job: the cwd is the origin pane path and $TMUX points at
# the host server. Prepares the workspace, then becomes a client of the
# greenroom server.
#
#   attach.sh [--client <host client>] [--menu | --paste] [workspace]
#   attach.sh --client <host client> --reopen <workspace>    from open.sh

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

# Host options copied once, when the greenroom server starts.
MIRRORED_OPTIONS=(default-terminal history-limit mouse mode-keys status-keys
  base-index pane-base-index escape-time extended-keys set-clipboard)
# display-menu uses these keys itself.
RESERVED_MENU_KEYS=' q j k g G '
# display-menu never runs an item shortcut on an arrow key on tmux 3.7, or on
# an arrow with a modifier (S-Up) on any version. Named keys ignore case.
ARROW_KEY='^([CcMmSs]-|\^)*([Uu][Pp]|[Dd][Oo][Ww][Nn]|[Ll][Ee][Ff][Tt]|[Rr][Ii][Gg][Hh][Tt])$'
# Hook array slots this plugin owns, set again on every open: a set-hook without
# an index (in @greenroom-config, say) replaces all slots of a hook.
LAST_HOOK_INDEX=100
ALERT_HOOK_INDEX=101

SOCKET=$(get_tmux_option @greenroom-socket greenroom)
KEY=$(get_tmux_option @greenroom-key g)
ROOT_KEY=$(get_tmux_option @greenroom-root-key '')
PROFILES_KEY=$(get_tmux_option @greenroom-profiles-key c)
WORKSPACES_KEY=$(get_tmux_option @greenroom-workspaces-key G)
# An empty value binds no key, so prefix + M or z keeps its tmux binding.
COMMANDS_KEY=$(tmux show-option -gv @greenroom-commands-key 2>/dev/null) || COMMANDS_KEY=M
LARGE_KEY=$(tmux show-option -gv @greenroom-large-key 2>/dev/null) || LARGE_KEY=z
GROW_KEY=$(get_tmux_option @greenroom-grow-key '')
SHRINK_KEY=$(get_tmux_option @greenroom-shrink-key '')
RESET_KEY=$(get_tmux_option @greenroom-reset-key '')
# An empty list is kept: it means an empty menu, not the default.
PROFILES=$(tmux show-option -gv @greenroom-profiles 2>/dev/null) ||
  PROFILES='claude codex gemini opencode | shell'
COMMANDS=$(tmux show-option -gv @greenroom-commands 2>/dev/null) ||
  COMMANDS='profiles workspaces | large grow shrink reset | hide'
DEFAULT_PROFILE=$(get_tmux_option @greenroom-default claude)
DEFAULT_WORKSPACE=$(sanitize_name "$(get_tmux_option @greenroom-workspace main)")
USER_CONFIG=$(get_tmux_option @greenroom-config '')

CHAIN=()
BOUND=''

greenroom_tmux() {
  local config=(-f "$PLUGIN_DIR/conf/greenroom-server.conf")
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
  greenroom_tmux has-session -t "=$1" 2>/dev/null
}

pick_workspace() {
  local candidate first
  if [[ -n $1 ]]; then
    sanitize_name "$1"
    return
  fi
  for candidate in "$(greenroom_tmux show-option -gqv @greenroom_last 2>/dev/null)" "$DEFAULT_WORKSPACE"; do
    if [[ -n $candidate ]] && has_workspace "$candidate"; then
      printf '%s' "$candidate"
      return
    fi
  done
  first=$(greenroom_tmux list-sessions -F '#{session_name}' 2>/dev/null | head -n 1)
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

# Replaces the greenroom server's copy of every user option, so edits and
# removals on the host take effect on the next open.
mirror_user_options() {
  local names=() values=() name i
  for name in $(greenroom_tmux show-options -g 2>/dev/null | awk '$1 ~ /^@greenroom-/ { print $1 }'); do
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
  chain set-option -g @greenroom_profiles_key "$PROFILES_KEY"
  chain set-option -g @greenroom_workspaces_key "$WORKSPACES_KEY"
  chain set-option -g @greenroom_commands_key "$COMMANDS_KEY"
  chain set-option -g @greenroom_default "$DEFAULT_PROFILE"
}

# Sets MENU_NAMES and MENU_GAPS (1 for a separator above the item) from a menu
# list. Invalid names and repeats are skipped. So is a '|' at either end or
# next to another one: tmux merges repeated separators but draws a trailing one.
menu_entries() {
  local tokens=() token gap=''
  MENU_NAMES=()
  MENU_GAPS=()
  # read, unlike an unquoted expansion, does not glob a token such as '*'.
  read -r -d '' -a tokens <<<"$1"
  for token in "${tokens[@]}"; do
    if [[ $token == '|' ]]; then
      ((${#MENU_NAMES[@]})) && gap=1
      continue
    fi
    is_valid_name "$token" || continue
    case " ${MENU_NAMES[*]} " in
      *" $token "*) continue ;;
    esac
    MENU_NAMES+=("$token")
    MENU_GAPS+=("$gap")
    gap=''
  done
}

# menu_keys key...
# Sets MENU_KEYS to the shortcuts of MENU_NAMES, given their explicit keys. A
# name of '' gets none.
menu_keys() {
  local claimed=' ' used key i
  MENU_KEYS=("$@")
  # Explicit keys go first, so an automatic shortcut never takes one.
  for i in "${!MENU_NAMES[@]}"; do
    key=${MENU_KEYS[i]}
    [[ $key =~ $ARROW_KEY ]] && key=''
    case $claimed in
      *" $key "*) key='' ;;
    esac
    MENU_KEYS[i]=$key
    [[ -n $key ]] && claimed+="$key "
  done
  used=$RESERVED_MENU_KEYS$claimed
  for i in "${!MENU_NAMES[@]}"; do
    if [[ -z ${MENU_KEYS[i]} ]]; then
      MENU_KEYS[i]=$(menu_shortcut "${MENU_NAMES[i]}" "$used")
      used+="${MENU_KEYS[i]} "
    fi
  done
}

menu_label() {
  local label
  label=$(format_escape "$1")
  # display-menu draws a name that starts with '-' as a disabled item.
  [[ $label == -* ]] && label="#[default]$label"
  printf '%s' "$label"
}

profile_menu() {
  local options=() keys=() name spawn i
  menu_entries "$PROFILES"
  PROFILE_MENU=(display-menu -T '#[align=centre] profiles ' -x C -y C --)
  if ((${#MENU_NAMES[@]} == 0)); then
    PROFILE_MENU+=('-no profiles configured' '' '')
    return
  fi

  for name in "${MENU_NAMES[@]}"; do
    options+=("@greenroom-profile-$name-key")
  done
  IFS=$FIELD_SEPARATOR read -r -d '' -a keys < <(read_raw_options "${options[@]}")
  menu_keys "${keys[@]}"
  for i in "${!MENU_NAMES[@]}"; do
    [[ -n ${MENU_GAPS[i]} ]] && PROFILE_MENU+=('')
    name=${MENU_NAMES[i]}
    # Escaped, so new-window -c expands the origin itself when the item runs.
    spawn="new-window -c '#{@greenroom_origin}' -n $(quote "$name") $(quote "$(profile_command "$name")")"
    PROFILE_MENU+=("$(menu_label "$name")" "${MENU_KEYS[i]}" "$(format_escape "$spawn")")
  done
}

# Shell commands for run-shell, which expands their formats when it runs them.
workspace_menu_command() {
  printf "%s '#{client_name}'%s" "$(format_escape "$(quote "$SCRIPTS_DIR/workspace-menu.sh")")" "${1:+ $1}"
}

size_command() {
  printf "%s %s '#{client_pid}' #{q:session_name}%s" "$(format_escape "$(quote "$SCRIPTS_DIR/size.sh")")" "$1" "${2:+ $2}"
}

# Sets ITEM_LABEL, ITEM_KEY and ITEM_ACTION to the label, shortcut and tmux
# command of a built-in command, or fails if the id is not one. The command
# runs with the client that opened the menu and its session as the context.
builtin_command() {
  local shell=''
  case $1 in
    profiles) ITEM_LABEL=Profiles ITEM_KEY=c ITEM_ACTION=$(command_line "${PROFILE_MENU[@]}") ;;
    workspaces) ITEM_LABEL=Workspaces ITEM_KEY=w shell=$(workspace_menu_command) ;;
    large) ITEM_LABEL='Large popup' ITEM_KEY=z shell=$(size_command large) ;;
    grow) ITEM_LABEL=Grow ITEM_KEY=+ shell=$(size_command grow) ;;
    shrink) ITEM_LABEL=Shrink ITEM_KEY=- shell=$(size_command shrink "$MENU_ROWS") ;;
    reset) ITEM_LABEL='Reset size' ITEM_KEY='=' shell=$(size_command reset) ;;
    hide) ITEM_LABEL='Hide popup' ITEM_KEY=h ITEM_ACTION=detach-client ;;
    new-workspace) ITEM_LABEL='New workspace' ITEM_KEY=n shell=$(workspace_menu_command new) ;;
    rename-workspace) ITEM_LABEL='Rename workspace' ITEM_KEY=r shell=$(workspace_menu_command rename) ;;
    kill-workspace) ITEM_LABEL='Kill workspace' ITEM_KEY=x shell=$(workspace_menu_command kill) ;;
    kill-window)
      ITEM_LABEL='Kill window' ITEM_KEY=X
      ITEM_ACTION=$(command_line confirm-before -p 'kill window #W? (y/n)' kill-window)
      ;;
    *) return 1 ;;
  esac
  [[ -n $shell ]] && ITEM_ACTION=$(command_line run-shell -b "$shell")
  return 0
}

# Uses PROFILE_MENU, so it comes after profile_menu.
command_menu() {
  local ids=() options=() values=() labels=() keys=() actions=() id label key run action i
  local separators style='#[' escaped_style='##[' ITEM_LABEL ITEM_KEY ITEM_ACTION MENU_ROWS
  menu_entries "$COMMANDS"
  COMMAND_MENU=(display-menu -T '#[align=centre] commands ' -x C -y C --)
  if ((${#MENU_NAMES[@]} == 0)); then
    COMMAND_MENU+=('-no commands configured' '' '')
    return
  fi

  # Items, separators and the border: the rows tmux needs to draw the menu,
  # where its Shrink item stops (size.sh).
  separators=$(printf '%s' "${MENU_GAPS[@]}")
  MENU_ROWS=$((${#MENU_NAMES[@]} + ${#separators} + 2))
  ids=("${MENU_NAMES[@]}")
  for id in "${ids[@]}"; do
    options+=("@greenroom-command-$id-label" "@greenroom-command-$id-key" "@greenroom-command-$id-run")
  done
  IFS=$FIELD_SEPARATOR read -r -d '' -a values < <(read_raw_options "${options[@]}")
  for i in "${!ids[@]}"; do
    id=${ids[i]}
    label=${values[i * 3]}
    key=${values[i * 3 + 1]}
    run=${values[i * 3 + 2]}
    if builtin_command "$id"; then
      labels+=("$(menu_label "${label:-$ITEM_LABEL}")")
      keys+=("${key:-$ITEM_KEY}")
      action=$(format_escape "$ITEM_ACTION")
      # Expansion keeps a '##[' as it is, so the '#[' styles of the profile
      # menu stay unescaped; a lone '#[' passes through.
      actions+=("${action//"$escaped_style"/$style}")
    elif [[ -n $run ]]; then
      labels+=("$(menu_label "${label:-$id}")")
      keys+=("$key")
      # As the user wrote it; display-menu expands its formats.
      actions+=("$run")
    else
      labels+=("-$id (not defined)")
      keys+=('')
      actions+=('')
      MENU_NAMES[i]=''
    fi
  done
  menu_keys "${keys[@]}"
  for i in "${!ids[@]}"; do
    [[ -n ${MENU_GAPS[i]} ]] && COMMAND_MENU+=('')
    COMMAND_MENU+=("${labels[i]}" "${MENU_KEYS[i]}" "${actions[i]}")
  done
}

push_bindings() {
  local prefix prefix2 binding
  for binding in $(greenroom_tmux show-option -gqv @greenroom_bound 2>/dev/null); do
    release_key "$binding"
  done

  prefix=$(tmux show-option -gqv prefix)
  prefix2=$(tmux show-option -gqv prefix2)
  chain set-option -g prefix "$prefix"
  chain set-option -g prefix2 "$prefix2"
  [[ $prefix != None ]] && chain_bind prefix "$prefix" send-prefix
  chain_bind prefix "$KEY" detach-client
  [[ -n $ROOT_KEY ]] && chain_bind root "$ROOT_KEY" detach-client
  chain_bind prefix "$WORKSPACES_KEY" run-shell -b "$(workspace_menu_command)"
  profile_menu
  chain_bind prefix "$PROFILES_KEY" "${PROFILE_MENU[@]}"
  if [[ -n $COMMANDS_KEY ]]; then
    command_menu
    chain_bind prefix "$COMMANDS_KEY" "${COMMAND_MENU[@]}"
  fi
  bind_size_key "$LARGE_KEY" large
  bind_size_key "$GROW_KEY" grow
  bind_size_key "$SHRINK_KEY" shrink
  bind_size_key "$RESET_KEY" reset
  chain set-option -g @greenroom_bound "$BOUND"
}

# Drops a binding of the last open; a new one for the key comes later in CHAIN.
# tmux has no command that restores one default binding, and on a new greenroom
# server the binding a key had before the plugin took it cannot be read. So the
# tmux keys the plugin takes by default (c, M, z) or the README suggests (-, =)
# get their tmux binding back, and other keys stay unbound until a restart.
release_key() {
  case $1 in
    prefix:c) chain bind-key -T prefix c new-window ;;
    prefix:M) chain bind-key -T prefix M select-pane -M ;;
    prefix:z) chain bind-key -T prefix z resize-pane -Z ;;
    prefix:-) chain bind-key -T prefix - delete-buffer ;;
    prefix:=) chain bind-key -T prefix = choose-buffer -Z ;;
    *) chain unbind-key -T "${1%%:*}" "${1#*:}" ;;
  esac
}

# Popup size keys; see docs/design.md (D11). An empty key is not bound.
bind_size_key() {
  [[ -n $1 ]] || return 0
  chain_bind prefix "$1" run-shell -b "$(size_command "$2")"
}

# size.sh finds the host client of a popup by the pid of its inner client,
# which this process becomes with the exec at the end. Entries of clients that
# have gone are dropped.
record_host_client() {
  local client=$1 pids name
  pids=" $(greenroom_tmux list-clients -F '#{client_pid}' 2>/dev/null | tr '\n' ' ')"
  for name in $(greenroom_tmux show-options -g 2>/dev/null | awk '$1 ~ /^@greenroom_host_client_/ { print $1 }'); do
    case $pids in
      *" ${name#@greenroom_host_client_} "*) ;;
      *) chain set-option -gu "$name" ;;
    esac
  done
  [[ -n $client ]] && chain set-option -g "@greenroom_host_client_$$" "$client"
}

# @greenroom_last is the workspace a toggle opens.
push_last_hooks() {
  local hook
  for hook in client-attached client-session-changed session-renamed; do
    chain set-hook -g "$hook[$LAST_HOOK_INDEX]" "set-option -gF @greenroom_last '#{session_name}'"
  done
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

# Moves the text from send.sh into the greenroom server and pastes it after
# attach, into the active pane of the workspace.
paste_after_attach() {
  local workspace=$1 created=$2 pane mode=now
  tmux show-buffer -b "$SEND_BUFFER" >/dev/null 2>&1 || return 0
  [[ -n $created ]] && mode=wait
  pane=$(greenroom_tmux display-message -p -t "=$workspace:" '#{pane_id}')
  tmux save-buffer -b "$SEND_BUFFER" - | greenroom_tmux load-buffer -b "$SEND_BUFFER" -
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

  greenroom_tmux list-sessions >/dev/null 2>&1 || fresh=1
  workspace=$(pick_workspace "${1:-}")
  # A host alert left over from a greenroom server that has since exited.
  [[ -n $fresh ]] && tmux set-option -gu @greenroom_alert

  chain start-server
  [[ -n $fresh ]] && mirror_host_options
  mirror_user_options
  push_state
  push_bindings
  push_last_hooks
  push_alert_hooks
  record_host_client "$host_client"
  if [[ -n $fresh ]] || ! has_workspace "$workspace"; then
    created=1
    chain new-session -d -s "$workspace" -c "$(format_escape "$origin")" -n "$DEFAULT_PROFILE" \
      "$(profile_command "$DEFAULT_PROFILE")"
  fi
  chain set-option -t "=$workspace:" @greenroom_origin "$origin"

  # Another client may have created the workspace first; that is fine.
  if ! greenroom_tmux "${CHAIN[@]}" && ! has_workspace "$workspace"; then
    printf 'tmux-greenroom: could not prepare workspace %s. Press any key.' "$workspace"
    read -rsn1
    exit 1
  fi

  ATTACH=(attach-session -t "=$workspace")
  if [[ -n $open_menu ]]; then
    ATTACH+=(';' run-shell -b "$(workspace_menu_command)")
  fi
  [[ -n $paste ]] && paste_after_attach "$workspace" "$created"
  exec env -u TMUX -u TMUX_PANE tmux -L "$SOCKET" "${ATTACH[@]}"
}

main "$@"
