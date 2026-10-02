#!/usr/bin/env bash
# Integration tests. A harness server runs a real host client in a pane and
# types into it with send-keys. Every server uses its own -L socket, so the
# default server and the real greenroom socket are never touched.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ID="tgr-test-$$"
HARNESS=(tmux -L "$ID-harness" -f /dev/null)
HOST=(tmux -L "$ID-host")
GREENROOM=(tmux -L "$ID-greenroom")
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tgr-test.XXXXXX")
# Characters that break shell quoting, tmux formats and tmux argv parsing.
ORIGIN="$WORK_DIR/it's #S \$x;"
TIMEOUT_SECONDS=5
POLL_SECONDS=0.1

PASSED=0
FAILED=0
FAILURES=()

stop_servers() {
  "${HARNESS[@]}" kill-server 2>/dev/null
  "${HOST[@]}" kill-server 2>/dev/null
  "${GREENROOM[@]}" kill-server 2>/dev/null
  tmux -L "$ID-guard" kill-server 2>/dev/null
}

cleanup() {
  stop_servers
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

wait_for() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  until "$@"; do
    ((SECONDS >= deadline)) && return 1
    sleep "$POLL_SECONDS"
  done
}

fail() {
  printf '    %s\n' "$*"
  return 1
}

sh_quote() {
  local q="'" escaped="'\\''"
  printf "'%s'" "${1//$q/$escaped}"
}

# tmux 3.4 prints '$' as '\$' in command output.
unescape_output() {
  sed 's/\\\$/$/g'
}

write_fixtures() {
  mkdir -p "$ORIGIN"
  cat > "$WORK_DIR/stub-agent" <<'EOF'
#!/usr/bin/env bash
printf 'STUB %s in %s\n' "$1" "$PWD"
while IFS= read -r line; do
  case $line in
    quit) exit 0 ;;
    fail) exit 3 ;;
    bell) printf '\a' ;;
  esac
done
EOF
  cat > "$WORK_DIR/key-logger" <<'EOF'
#!/usr/bin/env bash
# Asks for modifyOtherKeys mode 2, then logs every input byte.
: > "$1"
printf '\033[>4;2m'
stty raw -echo
while IFS= read -r -s -n1 -d '' c; do
  printf '%q ' "$c" >> "$1"
done
EOF
  chmod +x "$WORK_DIR/stub-agent" "$WORK_DIR/key-logger"
}

# start_host [extra host.conf lines...]
start_host() {
  stop_servers
  launch_host "$@"
}

# Starts the harness and the host server, and leaves the greenroom server alone.
launch_host() {
  local line
  {
    printf '%s\n' \
      'set -g prefix C-a' \
      'unbind C-b' \
      'bind C-a send-prefix' \
      'set -g default-terminal tmux-256color' \
      'set -s extended-keys on' \
      "set -as terminal-features ',tmux*:extkeys'" \
      "set -g @greenroom-socket '$ID-greenroom'" \
      "set -g @greenroom-profiles 'claude codex missing | shell'" \
      "set -g @greenroom-profile-claude-cmd '\"$WORK_DIR/stub-agent\" claude'" \
      "set -g @greenroom-profile-codex-cmd '\"$WORK_DIR/stub-agent\" codex'" \
      "set -g @greenroom-profile-missing-cmd 'no-such-agent-binary --flag'"
    for line in "$@"; do
      printf '%s\n' "$line"
    done
    printf '%s\n' "run-shell '$REPO_DIR/greenroom.tmux'"
  } > "$WORK_DIR/host.conf"

  # new-session -c expands formats, and a trailing ';' would end the argument.
  local hash='#' host_origin
  host_origin=${ORIGIN//$hash/##}
  host_origin="${host_origin%;}\\;"
  "${HARNESS[@]}" new-session -d -s h -x 160 -y 45 \; \
    set -g default-terminal tmux-256color \; \
    set -s extended-keys on \; \
    set -as terminal-features ',tmux*:extkeys' \; \
    respawn-pane -k -t h \
    "env -u TMUX SHELL=/bin/sh tmux -L '$ID-host' -f '$WORK_DIR/host.conf' new-session -s host -c $(sh_quote "$host_origin")"
  wait_for host_ready
}

host_ready() {
  "${HOST[@]}" list-clients -F x 2>/dev/null | grep -q x
}

press() {
  "${HARNESS[@]}" send-keys -t h "$@"
}

type_text() {
  "${HARNESS[@]}" send-keys -t h -l "$1"
}

screen() {
  "${HARNESS[@]}" capture-pane -p -t h
}

screen_has() {
  screen | grep -qF -- "$1"
}

greenroom_client_session() {
  "${GREENROOM[@]}" list-clients -F '#{client_session}' 2>/dev/null
}

popup_on() {
  [[ $(greenroom_client_session) == "$1" ]]
}

popup_closed() {
  [[ -z $(greenroom_client_session) ]] && ! screen_has ' greenroom '
}

workspace_windows() {
  "${GREENROOM[@]}" list-windows -t "=$1" -F '#{window_name}' 2>/dev/null | tr '\n' ' '
}

has_window() {
  "${GREENROOM[@]}" list-windows -t "=$1" -F '#{window_name}' 2>/dev/null | grep -qx "$2"
}

pane_field() {
  "${GREENROOM[@]}" display-message -p -t "=$1:$2" "$3" | unescape_output
}

# is_bound <table> <key> <tmux command...>
# tmux 3.7 prints nothing for "list-keys -T table key", so search the table.
is_bound() {
  local table=$1 key=$2
  shift 2
  "$@" list-keys -T "$table" 2>/dev/null | awk -v key="$key" '
    { for (i = 1; i < NF; i++) if ($i == "-T") { if ($(i + 2) == key) found = 1; break } }
    END { exit !found }'
}

greenroom_server_gone() {
  ! "${GREENROOM[@]}" list-sessions >/dev/null 2>&1
}

open_popup() {
  press C-a g
  wait_for popup_on "${1:-main}" || fail "popup did not open on ${1:-main}"
}

# --- tests -------------------------------------------------------------------

test_toggle_opens_workspace_with_default_profile() {
  start_host
  open_popup || return
  [[ $(workspace_windows main) == 'claude ' ]] || fail "windows: $(workspace_windows main)" || return
  [[ $(pane_field main claude '#{pane_current_path}') == "$ORIGIN" ]] ||
    fail "claude cwd: $(pane_field main claude '#{pane_current_path}')" || return
  [[ $("${GREENROOM[@]}" show-option -qv -t =main: @greenroom_origin | unescape_output) == "$ORIGIN" ]] ||
    fail "origin option not set" || return
  wait_for screen_has "STUB claude in $ORIGIN" || fail "stub output not visible in popup"
}

test_toggle_inside_popup_detaches_and_keeps_the_window() {
  local pid
  start_host
  open_popup || return
  pid=$(pane_field main claude '#{pane_pid}')
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  has_window main claude || fail "claude window gone" || return
  kill -0 "$pid" 2>/dev/null || fail "claude process $pid died"
}

test_reopen_shows_the_same_window() {
  local pane
  start_host
  open_popup || return
  pane=$(pane_field main claude '#{pane_id}')
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  open_popup || return
  [[ $(pane_field main claude '#{pane_id}') == "$pane" ]] || fail "claude pane changed"
}

test_profile_menu_adds_a_window_in_origin() {
  start_host
  open_popup || return
  press C-a c
  wait_for screen_has ' profiles ' || fail "profile menu not shown" || return
  press o
  wait_for has_window main codex || fail "codex window not created: $(workspace_windows main)" || return
  [[ $(pane_field main codex '#{pane_current_path}') == "$ORIGIN" ]] ||
    fail "codex cwd: $(pane_field main codex '#{pane_current_path}')"
}

test_profile_command_keeps_shell_syntax() {
  start_host "set -g @greenroom-profile-claude-cmd '\"$WORK_DIR/stub-agent\" \"v\$((1+2))\"'"
  open_popup || return
  wait_for screen_has "STUB v3 in" || fail "command was not run as written"
}

test_host_option_changes_apply_on_next_open() {
  start_host
  open_popup || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${HOST[@]}" set-option -g @greenroom-profile-codex-cmd "\"$WORK_DIR/stub-agent\" codex-new"
  open_popup || return
  press C-a c
  wait_for screen_has ' profiles ' || fail "profile menu not shown" || return
  press o
  wait_for screen_has "STUB codex-new in" || fail "old command still used"
}

test_missing_command_reports_status_then_closes() {
  start_host
  open_popup || return
  press C-a c
  wait_for screen_has ' profiles ' || fail "profile menu not shown" || return
  press m
  wait_for screen_has 'missing exited with status 127' || fail "no exit status shown" || return
  press x
  wait_for no_window main missing || fail "window not closed after a key press"
}

no_window() {
  ! has_window "$1" "$2"
}

test_last_window_exit_closes_popup_and_server() {
  start_host
  open_popup || return
  "${GREENROOM[@]}" send-keys -t =main:claude quit Enter
  wait_for popup_closed || fail "popup still open" || return
  wait_for greenroom_server_gone || fail "greenroom server still running"
}

test_last_window_exit_does_not_switch_workspace() {
  start_host
  open_popup || return
  "${GREENROOM[@]}" new-session -d -s other "sleep 600"
  "${GREENROOM[@]}" send-keys -t =main:claude quit Enter
  wait_for popup_closed || fail "popup did not close: client on $(greenroom_client_session)" || return
  "${GREENROOM[@]}" has-session -t =other || fail "other workspace is gone"
}

test_failed_command_waits_for_a_key() {
  start_host
  open_popup || return
  "${GREENROOM[@]}" send-keys -t =main:claude fail Enter
  wait_for screen_has 'claude exited with status 3' || fail "no exit status shown" || return
  popup_on main || fail "popup closed before a key press" || return
  press x
  wait_for popup_closed || fail "popup still open after a key press"
}

test_changed_key_replaces_the_old_binding() {
  start_host
  open_popup || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${HOST[@]}" set-option -g @greenroom-key y \; run-shell "$REPO_DIR/greenroom.tmux"
  is_bound prefix y "${HOST[@]}" || fail "host does not bind y" || return
  ! is_bound prefix g "${HOST[@]}" || fail "host still binds g" || return
  press C-a y
  wait_for popup_on main || fail "popup did not open with the new key" || return
  is_bound prefix y "${GREENROOM[@]}" || fail "greenroom server does not bind y" || return
  ! is_bound prefix g "${GREENROOM[@]}" || fail "greenroom server still binds g" || return
  press C-a y
  wait_for popup_closed || fail "new key did not close the popup"
}

menu_closed() {
  ! screen_has "$1"
}

test_menu_key_options_bind_on_host_and_in_popup() {
  start_host "set -g @greenroom-profiles-key C" "set -g @greenroom-workspaces-key W"
  is_bound prefix W "${HOST[@]}" || fail "host does not bind W" || return
  ! is_bound prefix G "${HOST[@]}" || fail "host still binds the default G" || return
  open_popup || return
  is_bound prefix C "${GREENROOM[@]}" || fail "greenroom server does not bind C" || return
  is_bound prefix W "${GREENROOM[@]}" || fail "greenroom server does not bind W" || return
  ! is_bound prefix G "${GREENROOM[@]}" || fail "greenroom server binds the default G" || return
  press C-a C
  wait_for screen_has ' profiles ' || fail "profile menu not shown with C" || return
  press q
  wait_for menu_closed ' profiles ' || fail "profile menu did not close" || return
  press C-a W
  wait_for screen_has 'New workspace' || fail "workspace menu not shown with W"
}

test_workspace_menu_creates_and_switches() {
  start_host
  open_popup || return
  press C-a G
  wait_for screen_has 'New workspace' || fail "workspace menu not shown" || return
  press n
  wait_for screen_has 'new workspace:' || fail "name prompt not shown" || return
  type_text 'code review'
  press Enter
  wait_for popup_on code_review || fail "client not on code_review: $(greenroom_client_session)" || return
  [[ $(workspace_windows code_review) == 'claude ' ]] || fail "windows: $(workspace_windows code_review)" || return
  [[ $(pane_field code_review claude '#{pane_current_path}') == "$ORIGIN" ]] ||
    fail "new workspace cwd: $(pane_field code_review claude '#{pane_current_path}')"
}

test_toggle_reopens_the_last_workspace() {
  test_workspace_menu_creates_and_switches || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  open_popup code_review
}

test_host_menu_key_opens_workspace_menu() {
  start_host
  press C-a G
  wait_for popup_on main || fail "popup did not open" || return
  wait_for screen_has 'New workspace' || fail "workspace menu not shown"
}

test_shift_enter_reaches_the_pane() {
  start_host "set -g @greenroom-default keylog" \
    "set -g @greenroom-profile-keylog-cmd '\"$WORK_DIR/key-logger\" \"$WORK_DIR/keys.log\"'"
  open_popup || return
  wait_for test -e "$WORK_DIR/keys.log" || fail "key logger did not start" || return
  sleep 0.3
  # Raw bytes, as a terminal sends them; harness key names differ by version.
  type_text $'\e[27;2;13~'
  wait_for got_shift_enter || fail "got: $(cat "$WORK_DIR/keys.log")"
}

# modifyOtherKeys (tmux 3.5+) or CSI u (tmux 3.4) encoding of Shift+Enter.
got_shift_enter() {
  grep -qF -e '\[ 2 7 \; 2 \; 1 3 \~' -e '\[ 1 3 \; 2 u' "$WORK_DIR/keys.log"
}

test_plugin_is_inert_inside_greenroom_server() {
  local guard=(tmux -L "$ID-guard" -f "$REPO_DIR/conf/greenroom-server.conf")
  "${guard[@]}" new-session -d \; run-shell "$REPO_DIR/greenroom.tmux"
  ! is_bound prefix g "${guard[@]}" || fail "host keys were bound" || return
  # Control: the same load binds the keys once the marker is gone.
  "${guard[@]}" set-option -gu @greenroom_server \; run-shell "$REPO_DIR/greenroom.tmux"
  is_bound prefix g "${guard[@]}" || fail "plugin did not bind keys without the marker"
}

test_removed_host_option_is_removed_from_greenroom_server() {
  start_host "set -g @greenroom-profile-missing-cmd '\"$WORK_DIR/stub-agent\" missing-set'"
  open_popup || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${HOST[@]}" set-option -gu @greenroom-profile-missing-cmd
  open_popup || return
  press C-a c
  wait_for screen_has ' profiles ' || fail "profile menu not shown" || return
  press m
  wait_for screen_has 'missing exited with status 127' || fail "removed command still used"
}

test_greenroom_server_reads_extra_config() {
  printf '%s\n' 'set -g @from-extra-config yes' > "$WORK_DIR/greenroom.conf"
  start_host "set -g @greenroom-config '$WORK_DIR/greenroom.conf'"
  open_popup || return
  [[ $("${GREENROOM[@]}" show-option -gqv @from-extra-config) == yes ]] || fail "extra config not read"
}

test_root_key_toggles_without_prefix() {
  start_host "set -g @greenroom-root-key M-g"
  press M-g
  wait_for popup_on main || fail "popup did not open" || return
  press M-g
  wait_for popup_closed || fail "popup did not close"
}

test_shell_entry_starts_a_login_shell() {
  start_host
  open_popup || return
  press C-a c
  wait_for screen_has ' profiles ' || fail "profile menu not shown" || return
  press s
  wait_for has_window main shell || fail "shell window not created: $(workspace_windows main)" || return
  # exec -l puts a '-' in front of $0.
  type_text 'echo LOGIN:$0'
  press Enter
  wait_for screen_has 'LOGIN:-' || fail "not a login shell"
}

test_workspace_menu_renames_with_a_clean_name() {
  start_host
  open_popup || return
  press C-a G
  wait_for screen_has 'Rename workspace' || fail "workspace menu not shown" || return
  press r
  wait_for screen_has 'rename workspace:' || fail "rename prompt not shown" || return
  press C-u
  type_text 'v1.2 next'
  press Enter
  wait_for popup_on v1_2_next || fail "client not on v1_2_next: $(greenroom_client_session)" || return
  [[ $("${GREENROOM[@]}" show-option -gqv @greenroom_last) == v1_2_next ]] || fail "last workspace not updated"
}

test_workspace_menu_kills_the_workspace() {
  start_host
  open_popup || return
  press C-a G
  wait_for screen_has 'Kill workspace' || fail "workspace menu not shown" || return
  press x
  wait_for screen_has 'kill workspace main?' || fail "confirmation not shown" || return
  press y
  wait_for popup_closed || fail "popup still open" || return
  wait_for greenroom_server_gone || fail "workspace still exists"
}

test_default_workspace_name_is_cleaned() {
  start_host "set -g @greenroom-workspace 'my.proj'"
  open_popup my_proj
}

host_alert() {
  "${HOST[@]}" show-option -gqv @greenroom_alert
}

host_alert_is() {
  [[ $(host_alert) == "$1" ]]
}

test_bell_in_a_closed_popup_alerts_the_host() {
  start_host
  open_popup || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${GREENROOM[@]}" send-keys -t =main:claude bell Enter
  wait_for host_alert_is 'claude@main' || fail "host alert: [$(host_alert)]" || return
  wait_for screen_has 'greenroom: claude@main rang the bell' || fail "no message on the host" || return
  open_popup || return
  wait_for host_alert_is '' || fail "alert not cleared after opening: [$(host_alert)]"
}

test_bell_in_the_visible_window_is_not_announced() {
  start_host
  open_popup || return
  "${GREENROOM[@]}" send-keys -t =main:claude bell Enter
  sleep 1
  host_alert_is '' || fail "host alert: [$(host_alert)]"
}

# The snippet README.md gives for status-right.
STATUS_SNIPPET='#{?@greenroom_alert,#[fg=black#,bg=yellow#,bold] #{@greenroom_alert} #[default],}'

test_status_snippet_shows_only_an_alert() {
  start_host
  [[ -z $("${HOST[@]}" display-message -p "$STATUS_SNIPPET") ]] || fail "renders without an alert" || return
  "${HOST[@]}" set-option -g @greenroom_alert 'claude@main'
  [[ $("${HOST[@]}" display-message -p "$STATUS_SNIPPET") == '#[fg=black,bg=yellow,bold] claude@main #[default]' ]] ||
    fail "rendered: $("${HOST[@]}" display-message -p "$STATUS_SNIPPET")"
}

active_pane_has() {
  "${GREENROOM[@]}" capture-pane -p -t "=$1:" 2>/dev/null | grep -qF -- "$2"
}

host_buffers() {
  "${HOST[@]}" list-buffers -F '#{buffer_name}' 2>/dev/null
}

test_selection_is_sent_to_the_active_pane() {
  start_host
  open_popup || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  type_text 'echo SEND-ME-123'
  press Enter
  wait_for screen_has 'SEND-ME-123' || fail "host pane output not shown" || return
  "${HOST[@]}" copy-mode -t host: \; \
    send-keys -t host: -X search-backward 'SEND-ME-123' \; \
    send-keys -t host: -X begin-selection \; \
    send-keys -t host: -X end-of-line
  press a
  wait_for popup_on main || fail "popup did not open" || return
  wait_for active_pane_has main 'SEND-ME-123' || fail "text did not reach the pane" || return
  [[ -z $(host_buffers) ]] || fail "host buffers left: $(host_buffers)"
}

test_pane_screen_is_sent_to_a_new_workspace() {
  start_host
  type_text 'echo PANE-MARKER-9'
  press Enter
  wait_for screen_has 'PANE-MARKER-9' || fail "host pane output not shown" || return
  press C-a S
  wait_for popup_on main || fail "popup did not open" || return
  wait_for active_pane_has main 'STUB claude in' || fail "claude did not start" || return
  wait_for active_pane_has main 'PANE-MARKER-9' || fail "screen did not reach the pane" || return
  [[ -z $(host_buffers) ]] || fail "host buffers left: $(host_buffers)"
}

open_profile_menu() {
  press C-a c
  wait_for screen_has ' profiles ' || fail "profile menu not shown"
}

# Prints the profile menu as drawn: "name(key)" per item, "|" per separator
# line, "<blank>" per empty row. Box characters depend on the locale, so rows
# are found by the columns of the top border.
menu_items() {
  local title=' profiles ' lines=() items=() line i top=-1
  local before after edge tail left width bar row inner
  local keyed='^ *(.*[^ ]) +\(([^()]+)\) *$' plain='^ *(.*[^ ]) *$'
  while IFS= read -r line; do
    lines+=("$line")
  done < <(screen)
  for i in "${!lines[@]}"; do
    if [[ ${lines[i]} == *"$title"* ]]; then
      top=$i
      break
    fi
  done
  ((top >= 0)) || return 1
  before=${lines[top]%%"$title"*}
  after=${lines[top]#*"$title"}
  edge=${before%"${before##* }"}
  tail=${after%% *}
  left=${#edge}
  width=$((${#before} - left + ${#title} + ${#tail}))
  bar=${lines[top + 1]:left:1}
  for ((i = top + 1; i < ${#lines[@]}; i++)); do
    row=${lines[i]:left:width}
    if [[ ${row:0:1} != "$bar" ]]; then
      # A separator has more of the menu below it; the bottom border does not.
      [[ ${lines[i + 1]:left:1} == [!\ ]* ]] || break
      items+=('|')
      continue
    fi
    inner=${row:1:width-2}
    if [[ $inner =~ $keyed ]]; then
      items+=("${BASH_REMATCH[1]}(${BASH_REMATCH[2]})")
    elif [[ $inner =~ $plain ]]; then
      items+=("${BASH_REMATCH[1]}")
    else
      items+=('<blank>')
    fi
  done
  printf '%s' "${items[*]}"
}

menu_is() {
  [[ $(menu_items) == "$1" ]]
}

# tmux draws a disabled item dim.
menu_item_dim() {
  "${HARNESS[@]}" capture-pane -p -e -t h | grep -qF -- $'\e[2m'"$1"
}

windows_are() {
  [[ $(workspace_windows "$1") == "$2" ]]
}

test_profile_menu_default_puts_shell_after_a_separator() {
  start_host 'set -gu @greenroom-profiles'
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(c) codex(o) gemini(e) opencode(p) | shell(s)' || fail "menu: [$(menu_items)]" || return
  press s
  wait_for has_window main shell || fail "shell window not created: $(workspace_windows main)"
}

test_profile_menu_follows_the_list_order() {
  start_host "set -g @greenroom-profiles 'shell codex | claude'"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'shell(s) codex(c) | claude(l)' || fail "menu: [$(menu_items)]" || return
  press l
  wait_for windows_are main 'claude claude ' || fail "windows: $(workspace_windows main)"
}

test_profile_menu_without_shell() {
  start_host "set -g @greenroom-profiles 'claude codex'"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(c) codex(o)' || fail "menu: [$(menu_items)]" || return
  # If s still started a shell, the menu would be gone before o.
  press s
  press o
  wait_for has_window main codex || fail "codex window not created after s: $(workspace_windows main)" || return
  windows_are main 'claude codex ' || fail "windows: $(workspace_windows main)"
}

test_profile_menu_drops_extra_separators() {
  start_host "set -g @greenroom-profiles '| |  claude | | codex  missing | |'"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(c) | codex(o) missing(m)' || fail "menu: [$(menu_items)]"
}

test_profile_menu_drops_separators_left_by_skipped_names() {
  start_host "set -g @greenroom-profiles 'claude | bad.name | codex | claude'"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(c) | codex(o)' || fail "menu: [$(menu_items)]"
}

test_profile_menu_custom_profile_runs_its_command() {
  start_host "set -g @greenroom-profiles 'claude my_cli-2 k9s'" \
    "set -g @greenroom-profile-my_cli-2-cmd '\"$WORK_DIR/stub-agent\" my-cli-run'"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(c) my_cli-2(m) k9s(9)' || fail "menu: [$(menu_items)]" || return
  press m
  wait_for has_window main my_cli-2 || fail "my_cli-2 window not created: $(workspace_windows main)" || return
  wait_for screen_has "STUB my-cli-run in $ORIGIN" || fail "custom command not run in the origin"
}

test_profile_menu_custom_profile_without_cmd_runs_its_name() {
  start_host "set -g @greenroom-profiles 'claude tgr-plain'"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(c) tgr-plain(t)' || fail "menu: [$(menu_items)]" || return
  press t
  wait_for screen_has 'tgr-plain exited with status 127' || fail "no exit status shown" || return
  screen | grep -q 'tgr-plain: .*not found' || fail "the name was not run as the command"
}

test_profile_menu_shell_cmd_replaces_the_login_shell() {
  start_host "set -g @greenroom-profiles 'shell claude'" \
    "set -g @greenroom-profile-shell-cmd '\"$WORK_DIR/stub-agent\" my-shell'"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'shell(s) claude(c)' || fail "menu: [$(menu_items)]" || return
  press s
  wait_for has_window main shell || fail "shell window not created: $(workspace_windows main)" || return
  wait_for screen_has "STUB my-shell in $ORIGIN" || fail "shell command not used"
}

test_profile_menu_explicit_keys_are_shown_and_work() {
  start_host "set -g @greenroom-profiles 'claude codex missing'" \
    'set -g @greenroom-profile-claude-key M-a' \
    'set -g @greenroom-profile-codex-key X' \
    'set -g @greenroom-profile-missing-key 1'
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(M-a) codex(X) missing(1)' || fail "menu: [$(menu_items)]" || return
  press X
  wait_for windows_are main 'claude codex ' || fail "X: windows: $(workspace_windows main)" || return
  open_profile_menu || return
  press M-a
  wait_for windows_are main 'claude codex claude ' || fail "M-a: windows: $(workspace_windows main)" || return
  open_profile_menu || return
  press 1
  wait_for has_window main missing || fail "1: windows: $(workspace_windows main)"
}

test_profile_menu_explicit_key_may_be_a_menu_key() {
  start_host "set -g @greenroom-profiles 'claude codex'" 'set -g @greenroom-profile-codex-key j'
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(c) codex(j)' || fail "menu: [$(menu_items)]" || return
  press j
  wait_for has_window main codex || fail "codex window not created: $(workspace_windows main)"
}

test_profile_menu_explicit_arrow_keys_fall_back() {
  start_host "set -g @greenroom-profiles 'claude codex missing shell gemini opencode'" \
    'set -g @greenroom-profile-claude-key Up' \
    'set -g @greenroom-profile-codex-key Down' \
    'set -g @greenroom-profile-missing-key Left' \
    'set -g @greenroom-profile-shell-key Right' \
    'set -g @greenroom-profile-gemini-key S-Up' \
    'set -g @greenroom-profile-opencode-key down'
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(c) codex(o) missing(m) shell(s) gemini(e) opencode(p)' || fail "menu: [$(menu_items)]" || return
  press o
  wait_for has_window main codex || fail "codex window not created: $(workspace_windows main)"
}

test_profile_menu_second_claim_on_a_key_falls_back() {
  start_host "set -g @greenroom-profiles 'claude codex'" \
    'set -g @greenroom-profile-claude-key x' \
    'set -g @greenroom-profile-codex-key x'
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(x) codex(c)' || fail "menu: [$(menu_items)]" || return
  press c
  wait_for windows_are main 'claude codex ' || fail "windows: $(workspace_windows main)"
}

test_profile_menu_automatic_key_skips_a_later_explicit_key() {
  start_host "set -g @greenroom-profiles 'claude codex'" 'set -g @greenroom-profile-codex-key c'
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(l) codex(c)' || fail "menu: [$(menu_items)]" || return
  press c
  wait_for windows_are main 'claude codex ' || fail "windows: $(workspace_windows main)"
}

test_profile_menu_explicit_key_may_end_in_a_semicolon() {
  start_host "set -g @greenroom-profiles 'claude codex missing'" \
    "set -g @greenroom-profile-codex-key ';'" \
    "set -g @greenroom-profile-missing-key 'M-;'"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(c) codex(;) missing(M-;)' || fail "menu: [$(menu_items)]" || return
  # A bare ';' argument would end send-keys.
  press '\;'
  wait_for has_window main codex || fail "codex window not created: $(workspace_windows main)"
}

host_bound() {
  "${HOST[@]}" show-option -gqv @greenroom_bound
}

# A profile may have the name of a plugin key option, such as root for
# @greenroom-root-key: its key option is @greenroom-profile-root-key, so
# neither key changes the other. grow has no profile key, so it takes an
# automatic shortcut rather than the + of @greenroom-grow-key.
test_profile_menu_names_of_plugin_keys_take_their_profile_keys() {
  start_host "set -g @greenroom-profiles 'root send send-pane profiles workspaces large grow shrink reset'" \
    'set -g @greenroom-profile-root-key 1' 'set -g @greenroom-profile-send-key 2' \
    'set -g @greenroom-profile-send-pane-key 3' 'set -g @greenroom-profile-profiles-key 4' \
    'set -g @greenroom-profile-workspaces-key 5' 'set -g @greenroom-profile-large-key 6' \
    'set -g @greenroom-profile-shrink-key 8' 'set -g @greenroom-profile-reset-key 9' \
    "set -g @greenroom-profile-root-cmd '\"$WORK_DIR/stub-agent\" root'" \
    'set -g @greenroom-root-key M-r' 'set -g @greenroom-grow-key +'
  [[ $(host_bound) == ' prefix:g root:M-r prefix:G copy-mode:a copy-mode-vi:a prefix:S' ]] ||
    fail "host keys: [$(host_bound)]" || return
  open_popup || return
  [[ $(greenroom_bound) == ' prefix:C-a prefix:g root:M-r prefix:G prefix:c prefix:z prefix:+' ]] ||
    fail "greenroom server keys: [$(greenroom_bound)]" || return
  open_profile_menu || return
  # g is reserved, so grow gets r.
  wait_for menu_is 'root(1) send(2) send-pane(3) profiles(4) workspaces(5) large(6) grow(r) shrink(8) reset(9)' ||
    fail "menu: [$(menu_items)]" || return
  press 1
  wait_for screen_has "STUB root in $ORIGIN" || fail "root profile not run" || return
  size_key + 90% 90% || return
  press M-r
  wait_for popup_closed || fail "root key did not close the popup" || return
  press M-r
  wait_for popup_on main || fail "root key did not open the popup"
}

test_profile_menu_skips_invalid_names() {
  # o.k would take o from codex if it were not skipped.
  start_host "set -g @greenroom-profiles 'claude o.k codex it#S'"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(c) codex(o)' || fail "menu: [$(menu_items)]"
}

test_profile_menu_name_may_start_with_a_dash() {
  # display-menu disables an item whose name starts with '-'.
  start_host "set -g @greenroom-profiles '-dash claude'" \
    "set -g @greenroom-profile--dash-cmd '\"$WORK_DIR/stub-agent\" dash'"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is '-dash(d) claude(c)' || fail "menu: [$(menu_items)]" || return
  press d
  wait_for windows_are main 'claude -dash ' || fail "windows: $(workspace_windows main)" || return
  wait_for screen_has "STUB dash in $ORIGIN" || fail "dash command not run"
}

test_profile_menu_shows_a_duplicate_once() {
  # A second claude would take l from cline.
  start_host "set -g @greenroom-profiles 'claude codex claude cline'"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(c) codex(o) cline(l)' || fail "menu: [$(menu_items)]"
}

test_profile_menu_empty_list_shows_a_disabled_item() {
  start_host "set -g @greenroom-profiles ''"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'no profiles configured' || fail "menu: [$(menu_items)]" || return
  menu_item_dim 'no profiles configured' || fail "item is not disabled" || return
  press q
  wait_for menu_closed ' profiles ' || fail "profile menu did not close"
}

test_profile_menu_separator_only_list_shows_a_disabled_item() {
  start_host "set -g @greenroom-profiles '| |'"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'no profiles configured' || fail "menu: [$(menu_items)]" || return
  menu_item_dim 'no profiles configured' || fail "item is not disabled"
}

test_profile_menu_list_changes_apply_on_next_open() {
  start_host "set -g @greenroom-profiles 'claude codex'"
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'claude(c) codex(o)' || fail "first menu: [$(menu_items)]" || return
  press q
  wait_for menu_closed ' profiles ' || fail "profile menu did not close" || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${HOST[@]}" set-option -g @greenroom-profiles 'codex | claude' \; set-option -g @greenroom-profile-codex-key x
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'codex(x) | claude(c)' || fail "changed menu: [$(menu_items)]" || return
  press q
  wait_for menu_closed ' profiles ' || fail "profile menu did not close" || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${HOST[@]}" set-option -gu @greenroom-profile-codex-key
  open_popup || return
  open_profile_menu || return
  wait_for menu_is 'codex(c) | claude(l)' || fail "menu after removing the key: [$(menu_items)]"
}

test_default_profile_outside_the_list_still_starts() {
  start_host "set -g @greenroom-profiles 'codex'" \
    'set -g @greenroom-default aider' \
    "set -g @greenroom-profile-aider-cmd '\"$WORK_DIR/stub-agent\" aider'"
  open_popup || return
  windows_are main 'aider ' || fail "windows: $(workspace_windows main)" || return
  wait_for screen_has "STUB aider in $ORIGIN" || fail "default profile did not run" || return
  open_profile_menu || return
  wait_for menu_is 'codex(c)' || fail "menu: [$(menu_items)]" || return
  press q
  wait_for menu_closed ' profiles ' || fail "profile menu did not close" || return
  press C-a G
  wait_for screen_has 'New workspace' || fail "workspace menu not shown" || return
  press n
  wait_for screen_has 'new workspace:' || fail "name prompt not shown" || return
  type_text 'two'
  press Enter
  wait_for popup_on two || fail "client not on two: $(greenroom_client_session)" || return
  windows_are two 'aider ' || fail "new workspace windows: $(workspace_windows two)"
}

# --- popup size --------------------------------------------------------------

host_state() {
  "${HOST[@]}" show-option -gqv "@greenroom_size_$1"
}

# The sizes of the inner clients, sorted, each followed by a space.
inner_sizes() {
  "${GREENROOM[@]}" list-clients -F '#{client_width}x#{client_height}' 2>/dev/null | LC_ALL=C sort | tr '\n' ' '
}

# inner_is <size>...: the greenroom server has exactly these inner clients.
inner_is() {
  [[ $(inner_sizes) == "$(printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' ' ')" ]]
}

inner_pids() {
  "${GREENROOM[@]}" list-clients -F '#{client_pid}' 2>/dev/null
}

process_gone() {
  ! kill -0 "$1" 2>/dev/null
}

# popup_inner <client width> <client height> <width> <height>
# The terminal size of a popup job. A percent is of the whole host client,
# and the border takes a cell on each side.
popup_inner() {
  local w=$3 h=$4
  [[ $w == *% ]] && w=$(($1 * ${w%\%} / 100))
  [[ $h == *% ]] && h=$(($2 * ${h%\%} / 100))
  printf '%dx%d' $((w - 2)) $((h - 2))
}

# The host client running in a harness session (default h).
host_client() {
  "${HARNESS[@]}" display-message -p -t "${1:-h}" '#{pane_tty}'
}

host_client_size() {
  "${HOST[@]}" list-clients -F '#{client_name} #{client_width} #{client_height}' |
    awk -v name="$1" '$1 == name { print $2, $3 }'
}

# inner_for <width> <height> [harness session]
inner_for() {
  local size
  size=$(host_client_size "$(host_client "${3:-h}")")
  popup_inner "${size% *}" "${size#* }" "$1" "$2"
}

workspace_panes() {
  "${GREENROOM[@]}" list-panes -s -t "=$1" -F '#{pane_id}' 2>/dev/null | tr '\n' ' '
}

workspace_origin() {
  "${GREENROOM[@]}" show-option -qv -t "=$1:" @greenroom_origin | unescape_output
}

greenroom_bound() {
  "${GREENROOM[@]}" show-option -gqv @greenroom_bound
}

# key_binding <table> <key> <tmux command...>: the list-keys line of the key.
key_binding() {
  local table=$1 key=$2
  shift 2
  "$@" list-keys -T "$table" 2>/dev/null | awk -v key="$key" '
    { for (i = 1; i < NF; i++) if ($i == "-T") { if ($(i + 2) == key) print; break } }'
}

# The plugin script that a key runs.
bound_script() {
  local line rest
  line=$(key_binding "$@")
  rest=${line#*"$REPO_DIR/scripts/"}
  [[ $rest != "$line" ]] || return 1
  printf '%s' "$REPO_DIR/scripts/${rest%%.sh*}.sh"
}

# keys_running <text> <tmux command...>: "table:key" of every binding whose
# command contains the text, sorted.
keys_running() {
  local text=$1
  shift
  "$@" list-keys 2>/dev/null | awk -v text="$text" '
    index($0, text) { for (i = 1; i < NF; i++) if ($i == "-T") { print $(i + 1) ":" $(i + 2); break } }' |
    LC_ALL=C sort | tr '\n' ' '
}

# Processes the greenroom server runs besides its panes: key and hook jobs.
greenroom_jobs() {
  local server panes pid ppid args
  server=$("${GREENROOM[@]}" display-message -p '#{pid}') || return 0
  panes=" $("${GREENROOM[@]}" list-panes -a -F '#{pane_pid}' | tr '\n' ' ') "
  while read -r pid ppid args; do
    [[ $ppid == "$server" && $panes != *" $pid "* ]] && printf '%s\n' "$args"
  done < <(ps -A -o pid= -o ppid= -o args=)
}

no_greenroom_jobs() {
  [[ -z $(greenroom_jobs) ]]
}

# A run-shell job that fails prints "'...' returned N" in a pane in view mode.
pane_modes() {
  "${HOST[@]}" list-panes -a -F 'host #{pane_id} #{pane_in_mode} #{pane_mode}' 2>/dev/null
  "${GREENROOM[@]}" list-panes -a -F 'greenroom #{pane_id} #{pane_in_mode} #{pane_mode}' 2>/dev/null
}

no_pane_in_mode() {
  ! pane_modes | awk '$3 == 1 { found = 1 } END { exit !found }'
}

# Fills a host pane with x and keeps it so: the host screen around a popup can
# be told from the popup, and keys that reach the pane show up in it.
fill_host_pane() {
  local width
  width=$("${HOST[@]}" display-message -p -t "$1" '#{pane_width}')
  "${HOST[@]}" send-keys -t "$1" -l \
    "i=0; while [ \$i -lt 60 ]; do printf '%0${width}d' 0; i=\$((i + 1)); done | tr 0 x; sleep 600" \; \
    send-keys -t "$1" Enter
  wait_for host_pane_filled "$1"
}

host_pane_filled() {
  ! "${HOST[@]}" capture-pane -p -t "$1" | grep -qvx 'xx*'
}

host_row() {
  [[ $1 == x* && $1 != *[!x]* ]]
}

# popup_framed <harness session> <inner client height>
# Succeeds if the popup has its border on every side and the host screen,
# filled by fill_host_pane, shows around it. The last row is the host status
# line.
popup_framed() {
  local lines=() line i top=-1 bottom last
  while IFS= read -r line; do
    lines+=("$line")
  done < <("${HARNESS[@]}" capture-pane -p -t "$1")
  for i in "${!lines[@]}"; do
    if [[ ${lines[i]} == *' greenroom '* ]]; then
      top=$i
      break
    fi
  done
  bottom=$((top + $2 + 1))
  last=$((${#lines[@]} - 1))
  ((top >= 1 && bottom < last)) || return 1
  host_row "${lines[top - 1]}" || return 1
  ((bottom + 1 == last)) || host_row "${lines[bottom + 1]}" || return 1
  for ((i = top; i <= bottom; i++)); do
    [[ ${lines[i]} == x*[!x]*x ]] || return 1
  done
}

# size_key <key> <width> <height>: presses a size key inside the popup, and
# waits for the popup to come back at that normal size.
size_key() {
  local expected
  expected=$(inner_for "$2" "$3")
  press C-a "$1"
  wait_for inner_is "$expected" ||
    fail "after $1: inner clients $(inner_sizes), expected $expected ($2 x $3)" || return
  [[ $(host_state width) == "$2" && $(host_state height) == "$3" ]] ||
    fail "after $1: size state [$(host_state width)] x [$(host_state height)], expected $2 x $3" || return
  [[ $(host_state large) != 1 ]] || fail "after $1: still large"
}

# size_key_is_a_no_op <key> <width> <height>: the size is at a limit already.
size_key_is_a_no_op() {
  local expected
  expected=$(inner_for "$2" "$3")
  press C-a "$1"
  # Time for the action to run; a re-open at the same size is allowed.
  sleep 0.5
  wait_for inner_is "$expected" || fail "after $1 at the limit: inner clients $(inner_sizes), expected $expected" || return
  [[ $(host_state width) == "$2" && $(host_state height) == "$3" ]] ||
    fail "after $1 at the limit: size state [$(host_state width)] x [$(host_state height)], expected $2 x $3"
}

host_client_records() {
  "${GREENROOM[@]}" show-options -g 2>/dev/null | awk '$1 ~ /^@greenroom_host_client_/' | LC_ALL=C sort
}

most_active_host_client() {
  "${HOST[@]}" list-clients -F '#{client_activity} #{client_name}' | sort -n | tail -n 1 | cut -d ' ' -f 2
}

host_pane_path_is() {
  [[ $("${HOST[@]}" display-message -p -t "$1" '#{pane_current_path}') == "$2" ]]
}

host_server_gone() {
  ! "${HOST[@]}" list-sessions >/dev/null 2>&1
}

host_clients_are() {
  [[ $("${HOST[@]}" list-clients -F x 2>/dev/null | grep -c x) == "$1" ]]
}

# A second host client, 120x41, in harness session h2 on host session host2.
start_second_client() {
  "${HARNESS[@]}" new-session -d -s h2 -x 120 -y 41 \; \
    respawn-pane -k -t h2 \
    "env -u TMUX SHELL=/bin/sh tmux -L '$ID-host' new-session -s host2 -c $(sh_quote "$1")"
  wait_for host_clients_are 2
}

screen_of_has() {
  "${HARNESS[@]}" capture-pane -p -t "$1" | grep -qF -- "$2"
}

test_size_large_key_toggles_a_large_popup() {
  local normal large panes pid size
  start_host
  fill_host_pane host: || fail "host pane not filled" || return
  normal=$(inner_for 80% 80%)
  large=$(inner_for 95% 95%)
  ! popup_framed h "${large#*x}" || fail "found a popup frame with no popup" || return
  open_popup || return
  "${GREENROOM[@]}" new-window -t =main: -n second 'sleep 600'
  wait_for inner_is "$normal" || fail "normal popup: inner clients $(inner_sizes), expected $normal" || return
  wait_for popup_framed h "${normal#*x}" || fail "normal popup frame not found" || return
  is_bound prefix z "${GREENROOM[@]}" || fail "greenroom server does not bind z" || return
  [[ " $(greenroom_bound) " == *' prefix:z '* ]] || fail "z not in @greenroom_bound: $(greenroom_bound)" || return
  panes=$(workspace_panes main)
  pid=$(inner_pids)

  press C-a z
  wait_for inner_is "$large" || fail "large popup: inner clients $(inner_sizes), expected $large" || return
  [[ $(host_state large) == 1 ]] || fail "@greenroom_size_large: [$(host_state large)]" || return
  popup_on main || fail "popup on [$(greenroom_client_session)]" || return
  [[ $(workspace_panes main) == "$panes" ]] || fail "panes: $(workspace_panes main), were $panes" || return
  [[ $(pane_field main '' '#{window_name}') == second ]] ||
    fail "current window: $(pane_field main '' '#{window_name}')" || return
  wait_for process_gone "$pid" || fail "old inner client $pid still runs" || return
  size=$(host_client_size "$(host_client)")
  ((${large%x*} + 2 < ${size% *} && ${large#*x} + 2 < ${size#* })) ||
    fail "large popup $large is not smaller than the host client $size" || return
  wait_for popup_framed h "${large#*x}" || fail "large popup has no border or no margin" || return
  wait_for no_greenroom_jobs || fail "jobs left in the greenroom server: $(greenroom_jobs)" || return
  type_text 'typed-in-large'
  wait_for active_pane_has main 'typed-in-large' || fail "keys did not reach the pane" || return
  host_pane_filled host: || fail "keys reached the host pane" || return

  press C-a z
  wait_for inner_is "$normal" || fail "after toggling back: inner clients $(inner_sizes), expected $normal" || return
  [[ $(host_state large) != 1 ]] || fail "still large" || return
  [[ $(workspace_panes main) == "$panes" ]] || fail "panes after toggling back: $(workspace_panes main), were $panes" || return
  # A late popup, a second inner client or a failed job shows up by now.
  sleep 0.5
  inner_is "$normal" || fail "inner clients a moment later: $(inner_sizes)" || return
  no_pane_in_mode || fail "a job reported an error: $(pane_modes | tr '\n' ',')"
}

host_size_is() {
  [[ $(host_client_size "$(host_client)") == "$1" ]]
}

# tmux's own centring put a 95% popup on the top edge at these heights, where
# the popup is 47 and 38 rows high.
test_size_large_popup_keeps_its_margin_at_other_heights() {
  local rows large
  start_host
  fill_host_pane host: || fail "host pane not filled" || return
  open_popup || return
  press C-a z
  wait_for inner_is "$(inner_for 95% 95%)" || fail "large popup: $(inner_sizes)" || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  for rows in 50 40; do
    "${HARNESS[@]}" resize-window -t h -y "$rows"
    wait_for host_size_is "160 $rows" || fail "host client is $(host_client_size "$(host_client)")" || return
    wait_for host_pane_filled host: || fail "host pane at $rows rows not filled" || return
    open_popup || return
    large=$(inner_for 95% 95%)
    wait_for inner_is "$large" || fail "at $rows rows: inner clients $(inner_sizes), expected $large" || return
    wait_for popup_framed h "${large#*x}" || fail "at $rows rows: the popup has no border or no margin" || return
    press C-a g
    wait_for popup_closed || fail "popup still open" || return
  done
}

test_size_large_uses_the_large_size_options() {
  local normal large
  start_host 'set -g @greenroom-large-width 90%' 'set -g @greenroom-large-height 85%'
  normal=$(inner_for 80% 80%)
  large=$(inner_for 90% 85%)
  open_popup || return
  wait_for inner_is "$normal" || fail "normal popup: $(inner_sizes)" || return
  press C-a z
  wait_for inner_is "$large" || fail "large popup: inner clients $(inner_sizes), expected $large" || return
  press C-a z
  wait_for inner_is "$normal" || fail "after toggling back: $(inner_sizes)"
}

test_size_grow_steps_and_clamps_each_dimension_at_95() {
  start_host 'set -g @greenroom-width 70%' 'set -g @greenroom-height 60%' \
    'set -g @greenroom-grow-key +' 'set -g @greenroom-shrink-key -'
  open_popup || return
  wait_for inner_is "$(inner_for 70% 60%)" || fail "first popup: $(inner_sizes)" || return
  size_key + 80% 70% || return
  size_key + 90% 80% || return
  size_key + 95% 90% || return
  size_key + 95% 95% || return
  size_key_is_a_no_op + 95% 95% || return
  # From the stored 95%, not from an unclamped 105%.
  size_key - 85% 85%
}

test_size_shrink_steps_and_clamps_each_dimension_at_20() {
  start_host 'set -g @greenroom-width 50%' 'set -g @greenroom-height 40%' \
    'set -g @greenroom-grow-key +' 'set -g @greenroom-shrink-key -'
  open_popup || return
  wait_for inner_is "$(inner_for 50% 40%)" || fail "first popup: $(inner_sizes)" || return
  size_key - 40% 30% || return
  size_key - 30% 20% || return
  size_key - 20% 20% || return
  size_key_is_a_no_op - 20% 20% || return
  # From the stored 20%, not from an unclamped 10%.
  size_key + 30% 30%
}

test_size_reset_returns_to_the_size_options() {
  local normal
  start_host 'set -g @greenroom-width 70%' 'set -g @greenroom-height 60%' \
    'set -g @greenroom-grow-key +' 'set -g @greenroom-reset-key ='
  normal=$(inner_for 70% 60%)
  open_popup || return
  wait_for inner_is "$normal" || fail "first popup: $(inner_sizes)" || return
  size_key + 80% 70% || return
  press C-a z
  wait_for inner_is "$(inner_for 95% 95%)" || fail "large popup: $(inner_sizes)" || return
  press C-a =
  wait_for inner_is "$normal" || fail "after reset: inner clients $(inner_sizes), expected $normal" || return
  [[ -z "$(host_state width)$(host_state height)$(host_state large)" ]] ||
    fail "state left after reset: [$(host_state width)] [$(host_state height)] [$(host_state large)]" || return
  # The grown size is gone: leaving large mode goes back to the options too.
  press C-a z
  wait_for inner_is "$(inner_for 95% 95%)" || fail "large popup after reset: $(inner_sizes)" || return
  press C-a z
  wait_for inner_is "$normal" || fail "large off after reset: inner clients $(inner_sizes), expected $normal"
}

test_size_step_option_sets_the_step() {
  start_host 'set -g @greenroom-resize-step 5' \
    'set -g @greenroom-grow-key +' 'set -g @greenroom-shrink-key -'
  open_popup || return
  wait_for inner_is "$(inner_for 80% 80%)" || fail "first popup: $(inner_sizes)" || return
  size_key + 85% 85% || return
  size_key - 80% 80% || return
  size_key - 75% 75%
}

test_size_cells_convert_to_percent() {
  start_host 'set -g @greenroom-width 120' 'set -g @greenroom-height 18' \
    'set -g @greenroom-grow-key +' 'set -g @greenroom-shrink-key -' 'set -g @greenroom-reset-key ='
  # 120 of 160 columns is 75%, and 18 of 45 rows is 40%.
  [[ $(host_client_size "$(host_client)") == '160 45' ]] ||
    fail "test setup: host client is $(host_client_size "$(host_client)")" || return
  open_popup || return
  wait_for inner_is 118x16 || fail "first popup: $(inner_sizes)" || return
  size_key + 85% 50% || return
  press C-a =
  wait_for inner_is 118x16 || fail "after reset: $(inner_sizes)" || return
  size_key - 65% 30%
}

test_size_cells_convert_with_the_popup_client_size() {
  local b_dir="$WORK_DIR/client-b" a expected
  mkdir -p "$b_dir"
  start_host 'set -g @greenroom-width 60' 'set -g @greenroom-height 20' 'set -g @greenroom-grow-key +'
  start_second_client "$b_dir" || fail "second host client did not start" || return
  a=$(host_client h)
  "${HARNESS[@]}" send-keys -t h2 C-a g
  wait_for inner_is 58x18 || fail "second client popup: $(inner_sizes)" || return
  # The first client becomes the most recently active one, the client whose
  # size a lookup that ignores the popup's client would take.
  sleep 1.1
  type_text 'echo FIRST-CLIENT-ACTIVE'
  press Enter
  wait_for screen_has 'FIRST-CLIENT-ACTIVE' || fail "first client did not take the keys" || return
  [[ $(most_active_host_client) == "$a" ]] ||
    fail "test setup: most active host client is $(most_active_host_client), not $a" || return
  # 60 of 120 columns is 50%, and 20 of 41 rows is 49%.
  expected=$(inner_for 60% 59% h2)
  "${HARNESS[@]}" send-keys -t h2 C-a +
  wait_for inner_is "$expected" ||
    fail "after grow on the second client: inner clients $(inner_sizes), expected $expected" || return
  [[ $(host_state width) == 60% && $(host_state height) == 59% ]] ||
    fail "size state [$(host_state width)] x [$(host_state height)], expected 60% x 59%"
}

test_size_grow_and_shrink_leave_large_mode() {
  local large
  start_host 'set -g @greenroom-grow-key +' 'set -g @greenroom-shrink-key -'
  large=$(inner_for 95% 95%)
  open_popup || return
  press C-a z
  wait_for inner_is "$large" || fail "large popup: $(inner_sizes)" || return
  size_key + 90% 90% || return
  press C-a z
  wait_for inner_is "$large" || fail "large popup again: $(inner_sizes)" || return
  [[ $(host_state large) == 1 ]] || fail "@greenroom_size_large: [$(host_state large)]" || return
  # Shrinks the normal size, 90%, and leaves large mode.
  size_key - 80% 80%
}

test_size_only_the_large_key_is_bound_by_default() {
  local script
  start_host
  open_popup || return
  script=$(bound_script prefix z "${GREENROOM[@]}") ||
    fail "z does not run a plugin script: [$(key_binding prefix z "${GREENROOM[@]}")]" || return
  [[ $(keys_running "$script" "${GREENROOM[@]}") == 'prefix:z ' ]] ||
    fail "keys that run $script: $(keys_running "$script" "${GREENROOM[@]}")"
}

test_size_empty_large_key_keeps_the_zoom_key() {
  local script
  start_host "set -g @greenroom-large-key ''" 'set -g @greenroom-grow-key +'
  open_popup || return
  script=$(bound_script prefix + "${GREENROOM[@]}") ||
    fail "+ does not run a plugin script: [$(key_binding prefix + "${GREENROOM[@]}")]" || return
  [[ $(keys_running "$script" "${GREENROOM[@]}") == 'prefix:+ ' ]] ||
    fail "keys that run $script: $(keys_running "$script" "${GREENROOM[@]}")" || return
  [[ $(key_binding prefix z "${GREENROOM[@]}") == *'resize-pane -Z'* ]] ||
    fail "prefix z: [$(key_binding prefix z "${GREENROOM[@]}")]"
}

test_size_key_options_bind_and_unbind_on_next_open() {
  local script key
  start_host 'set -g @greenroom-large-key Z' 'set -g @greenroom-grow-key +' \
    'set -g @greenroom-shrink-key -' 'set -g @greenroom-reset-key ='
  open_popup || return
  script=$(bound_script prefix Z "${GREENROOM[@]}") ||
    fail "Z does not run a plugin script: [$(key_binding prefix Z "${GREENROOM[@]}")]" || return
  [[ $(keys_running "$script" "${GREENROOM[@]}") == 'prefix:+ prefix:- prefix:= prefix:Z ' ]] ||
    fail "keys that run $script: $(keys_running "$script" "${GREENROOM[@]}")" || return
  for key in + - = Z; do
    [[ " $(greenroom_bound) " == *" prefix:$key "* ]] || fail "$key not in @greenroom_bound: $(greenroom_bound)" || return
  done
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${HOST[@]}" set-option -gu @greenroom-large-key \; set-option -gu @greenroom-grow-key \; \
    set-option -gu @greenroom-shrink-key \; set-option -gu @greenroom-reset-key
  open_popup || return
  [[ $(keys_running "$script" "${GREENROOM[@]}") == 'prefix:z ' ]] ||
    fail "keys that run $script after unsetting: $(keys_running "$script" "${GREENROOM[@]}")" || return
  ! is_bound prefix + "${GREENROOM[@]}" || fail "+ is still bound"
}

window_zoomed() {
  [[ $("${GREENROOM[@]}" display-message -p -t "=$1:" '#{window_zoomed_flag}') == 1 ]]
}

# On a running greenroom server, which keeps the bindings of the last open.
test_size_freed_keys_get_their_tmux_binding_back() {
  local script
  start_host 'set -g @greenroom-grow-key +' 'set -g @greenroom-shrink-key -' 'set -g @greenroom-reset-key ='
  open_popup || return
  script=$(bound_script prefix z "${GREENROOM[@]}") ||
    fail "z does not run a plugin script: [$(key_binding prefix z "${GREENROOM[@]}")]" || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${HOST[@]}" set-option -g @greenroom-large-key '' \; set-option -g @greenroom-profiles-key C \; \
    set-option -gu @greenroom-grow-key \; set-option -gu @greenroom-shrink-key \; set-option -gu @greenroom-reset-key
  open_popup || return
  [[ -z $(keys_running "$script" "${GREENROOM[@]}") ]] ||
    fail "keys that still run $script: $(keys_running "$script" "${GREENROOM[@]}")" || return
  [[ $(key_binding prefix z "${GREENROOM[@]}") == *'resize-pane -Z'* ]] || fail "prefix z: [$(key_binding prefix z "${GREENROOM[@]}")]" || return
  [[ $(key_binding prefix c "${GREENROOM[@]}") == *'new-window'* ]] || fail "prefix c: [$(key_binding prefix c "${GREENROOM[@]}")]" || return
  [[ $(key_binding prefix - "${GREENROOM[@]}") == *'delete-buffer'* ]] || fail "prefix -: [$(key_binding prefix - "${GREENROOM[@]}")]" || return
  [[ $(key_binding prefix = "${GREENROOM[@]}") == *'choose-buffer -Z'* ]] || fail "prefix =: [$(key_binding prefix = "${GREENROOM[@]}")]" || return
  ! is_bound prefix + "${GREENROOM[@]}" || fail "+ is still bound" || return
  [[ " $(greenroom_bound) " != *' prefix:z '* ]] || fail "z still in @greenroom_bound: $(greenroom_bound)" || return
  "${GREENROOM[@]}" split-window -d -t =main: 'sleep 600'
  press C-a z
  wait_for window_zoomed main || fail "prefix z did not zoom the pane" || return

  # Moving the large key to another key gives z back too.
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${HOST[@]}" set-option -gu @greenroom-large-key \; set-option -gu @greenroom-profiles-key
  open_popup || return
  [[ $(keys_running "$script" "${GREENROOM[@]}") == 'prefix:z ' ]] ||
    fail "keys that run $script with the default: $(keys_running "$script" "${GREENROOM[@]}")" || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${HOST[@]}" set-option -g @greenroom-large-key Z
  open_popup || return
  [[ $(keys_running "$script" "${GREENROOM[@]}") == 'prefix:Z ' ]] ||
    fail "keys that run $script with Z: $(keys_running "$script" "${GREENROOM[@]}")" || return
  [[ $(key_binding prefix z "${GREENROOM[@]}") == *'resize-pane -Z'* ]] ||
    fail "prefix z after moving the large key: [$(key_binding prefix z "${GREENROOM[@]}")]"
}

test_size_persists_across_close_and_reopen() {
  local grown large
  start_host 'set -g @greenroom-grow-key +' 'set -g @greenroom-root-key M-g'
  grown=$(inner_for 90% 90%)
  large=$(inner_for 95% 95%)
  open_popup || return
  size_key + 90% 90% || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  [[ $(host_state width) == 90% ]] || fail "size state after closing: [$(host_state width)]" || return
  open_popup || return
  wait_for inner_is "$grown" || fail "prefix+g opened at $(inner_sizes), expected $grown" || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  press C-a G
  wait_for screen_has 'New workspace' || fail "workspace menu not shown" || return
  inner_is "$grown" || fail "prefix+G opened at $(inner_sizes), expected $grown" || return
  press q
  wait_for menu_closed 'New workspace' || fail "workspace menu did not close" || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  press M-g
  wait_for inner_is "$grown" || fail "root key opened at $(inner_sizes), expected $grown" || return
  press M-g
  wait_for popup_closed || fail "popup still open" || return

  open_popup || return
  press C-a z
  wait_for inner_is "$large" || fail "large popup: $(inner_sizes)" || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  open_popup || return
  wait_for inner_is "$large" || fail "large mode lost on close: $(inner_sizes)" || return
  press C-a z
  wait_for inner_is "$grown" || fail "large off: inner clients $(inner_sizes), expected the grown $grown"
}

test_size_resets_when_the_host_server_restarts() {
  local pane
  start_host 'set -g @greenroom-grow-key +'
  open_popup || return
  pane=$(pane_field main claude '#{pane_id}')
  size_key + 90% 90% || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${HARNESS[@]}" kill-server
  "${HOST[@]}" kill-server 2>/dev/null
  wait_for host_server_gone || fail "host server still running" || return
  launch_host 'set -g @greenroom-grow-key +'
  open_popup || return
  [[ $(pane_field main claude '#{pane_id}') == "$pane" ]] || fail "claude pane changed across the host restart" || return
  wait_for inner_is "$(inner_for 80% 80%)" || fail "opened at $(inner_sizes) after a host restart"
}

test_size_send_opens_at_the_grown_size() {
  local grown
  start_host 'set -g @greenroom-grow-key +'
  grown=$(inner_for 90% 90%)
  open_popup || return
  size_key + 90% 90% || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  type_text 'echo SIZE-SEND-7'
  press Enter
  wait_for screen_has 'SIZE-SEND-7' || fail "host pane output not shown" || return
  press C-a S
  wait_for popup_on main || fail "popup did not open" || return
  wait_for inner_is "$grown" || fail "send opened at $(inner_sizes), expected $grown" || return
  wait_for active_pane_has main 'SIZE-SEND-7' || fail "screen did not reach the pane" || return
  [[ -z $(host_buffers) ]] || fail "host buffers left: $(host_buffers)"
}

test_size_reopen_keeps_the_workspace_and_its_origin() {
  local elsewhere="$WORK_DIR/elsewhere" two="$WORK_DIR/two #{pane_id} it's \$y;" panes client
  mkdir -p "$elsewhere" "$two"
  start_host
  open_popup || return
  # The host pane changes directory while the popup is open.
  "${HOST[@]}" send-keys -t host: -l "cd $(sh_quote "$elsewhere")" \; send-keys -t host: Enter
  wait_for host_pane_path_is host: "$elsewhere" || fail "host pane did not change directory" || return
  press C-a z
  wait_for inner_is "$(inner_for 95% 95%)" || fail "large popup: $(inner_sizes)" || return
  [[ $(workspace_origin main) == "$ORIGIN" ]] || fail "main origin after large: $(workspace_origin main)" || return

  # A workspace with an origin of its own, as if opened from another pane.
  "${GREENROOM[@]}" new-session -d -s two -n claude 'sleep 600' \; \
    set-option -t =two: @greenroom_origin "${two%;}\\;"
  [[ $(workspace_origin two) == "$two" ]] || fail "test setup: origin of two: $(workspace_origin two)" || return
  panes=$(workspace_panes two)
  client=$("${GREENROOM[@]}" list-clients -F '#{client_name}')
  "${GREENROOM[@]}" switch-client -c "$client" -t =two
  wait_for popup_on two || fail "client not on two: $(greenroom_client_session)" || return
  # As if another host client had opened main since.
  "${GREENROOM[@]}" set-option -g @greenroom_last main
  press C-a z
  wait_for inner_is "$(inner_for 80% 80%)" || fail "after large off: $(inner_sizes)" || return
  popup_on two || fail "re-opened on [$(greenroom_client_session)]" || return
  [[ $(workspace_panes two) == "$panes" ]] || fail "panes of two: $(workspace_panes two), were $panes" || return
  [[ $(workspace_origin two) == "$two" ]] || fail "origin of two: $(workspace_origin two)" || return
  [[ $(workspace_origin main) == "$ORIGIN" ]] || fail "origin of main: $(workspace_origin main)" || return
  open_profile_menu || return
  press o
  wait_for has_window two codex || fail "codex window not created: $(workspace_windows two)" || return
  [[ $(pane_field two codex '#{pane_current_path}') == "$two" ]] ||
    fail "codex cwd: $(pane_field two codex '#{pane_current_path}')"
}

test_size_inner_client_records_its_host_client() {
  local host pid
  start_host
  open_popup || return
  host=$(host_client)
  pid=$(inner_pids)
  [[ $(host_client_records) == "@greenroom_host_client_$pid $host" ]] ||
    fail "records: [$(host_client_records)], inner client $pid on $host" || return
  press C-a z
  wait_for inner_is "$(inner_for 95% 95%)" || fail "large popup: $(inner_sizes)" || return
  pid=$(inner_pids)
  host_client_records | grep -qxF "@greenroom_host_client_$pid $host" ||
    fail "no record for the new inner client $pid: [$(host_client_records)]" || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  open_popup || return
  pid=$(inner_pids)
  # Records of inner clients that have gone are dropped on the next open.
  [[ $(host_client_records) == "@greenroom_host_client_$pid $host" ]] ||
    fail "records after reopening: [$(host_client_records)], inner client $pid"
}

# The size keys are bound for every client of the greenroom server. One attached
# directly has no host client record, and the host client must not get a popup.
test_size_key_in_a_direct_client_does_nothing() {
  start_host
  open_popup || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${HARNESS[@]}" new-session -d -s h2 -x 100 -y 30 \; \
    respawn-pane -k -t h2 "env -u TMUX tmux -L '$ID-greenroom' attach-session -t =main"
  wait_for inner_is 100x30 || fail "direct client: inner clients $(inner_sizes)" || return
  "${HARNESS[@]}" send-keys -t h2 C-a z
  # Time for the action to run.
  sleep 0.5
  inner_is 100x30 || fail "inner clients after the size key: $(inner_sizes)" || return
  [[ -z $(host_state large) ]] || fail "@greenroom_size_large: [$(host_state large)]" || return
  ! screen_has ' greenroom ' || fail "a popup opened on the host client" || return
  no_pane_in_mode || fail "a job reported an error: $(pane_modes | tr '\n' ',')"
}

test_size_keys_typed_during_a_reopen_stay_in_the_popup() {
  local i=0
  start_host
  fill_host_pane host: || fail "host pane not filled" || return
  open_popup || return
  press C-a z
  # Keys spread over the re-open. Between two separate display-popup calls,
  # some reach the host pane.
  while ((i < 30)); do
    press Q
    sleep 0.01
    i=$((i + 1))
  done
  wait_for inner_is "$(inner_for 95% 95%)" || fail "large popup: $(inner_sizes)" || return
  wait_for active_pane_has main QQ || fail "keys did not reach the pane" || return
  host_pane_filled host: ||
    fail "keys reached the host pane: $("${HOST[@]}" capture-pane -p -t host: | grep -vx 'xx*' | head -3)"
}

test_size_action_reopens_on_the_client_showing_the_popup() {
  local b_dir="$WORK_DIR/client-b" a b a_normal a_large b_large b_pid
  mkdir -p "$b_dir"
  start_host
  start_second_client "$b_dir" || fail "second host client did not start" || return
  a=$(host_client h)
  b=$(host_client h2)
  a_normal=$(inner_for 80% 80% h)
  a_large=$(inner_for 95% 95% h)
  b_large=$(inner_for 95% 95% h2)
  [[ $a_large != "$b_large" ]] || fail "test setup: both host clients are $a_large" || return
  fill_host_pane host2: || fail "host pane of the second client not filled" || return

  "${HARNESS[@]}" send-keys -t h2 C-a g
  wait_for inner_is "$(inner_for 80% 80% h2)" || fail "second client popup: $(inner_sizes)" || return
  wait_for screen_of_has h2 ' greenroom ' || fail "no popup on the second client" || return
  ! screen_has ' greenroom ' || fail "popup on the first client too" || return
  # client_activity counts seconds. Afterwards the first client is the most
  # recently active, which a guess from activity would pick.
  sleep 1.1
  type_text 'echo FIRST-CLIENT-ACTIVE'
  press Enter
  wait_for screen_has 'FIRST-CLIENT-ACTIVE' || fail "first client did not take the keys" || return
  [[ $(most_active_host_client) == "$a" ]] ||
    fail "test setup: most active host client is $(most_active_host_client), not $a" || return

  "${HARNESS[@]}" send-keys -t h2 C-a z
  wait_for inner_is "$b_large" || fail "after large on the second client: inner clients $(inner_sizes), expected $b_large" || return
  wait_for popup_framed h2 "${b_large#*x}" || fail "second client popup has no border or no margin" || return
  ! screen_has ' greenroom ' || fail "a popup opened on the first client" || return
  [[ $(workspace_origin main) == "$b_dir" ]] || fail "origin: $(workspace_origin main)" || return

  # Both host clients show a popup; each action must find its own.
  b_pid=$(inner_pids)
  press C-a g
  wait_for inner_is "$a_large" "$b_large" || fail "with two popups: inner clients $(inner_sizes)" || return
  wait_for screen_has ' greenroom ' || fail "no popup on the first client" || return
  press C-a z
  wait_for inner_is "$a_normal" "$b_large" ||
    fail "after large off on the first client: inner clients $(inner_sizes), expected $a_normal $b_large" || return
  inner_pids | grep -qx "$b_pid" || fail "the second client's popup was re-opened" || return
  screen_of_has h2 ' greenroom ' || fail "the second client lost its popup"
}

# --- runner ------------------------------------------------------------------

run() {
  local name=$1
  if "$name"; then
    PASSED=$((PASSED + 1))
    printf 'ok      %s\n' "${name#test_}"
  else
    FAILED=$((FAILED + 1))
    FAILURES+=("$name")
    printf 'FAILED  %s\n' "${name#test_}"
    printf '    last screen:\n'
    screen 2>/dev/null | sed -e '/^[[:space:]]*$/d' -e 's/^/      | /' | head -30
  fi
}

main() {
  local name
  write_fixtures
  for name in $(declare -F | awk '{print $3}' | grep '^test_'); do
    if [[ -n ${1:-} && $name != *"$1"* ]]; then
      continue
    fi
    run "$name"
  done
  printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
  ((FAILED == 0))
}

main "$@"
