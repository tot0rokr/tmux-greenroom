#!/usr/bin/env bash
# Integration tests. A harness server runs a real host client in a pane and
# types into it with send-keys. Every server uses its own -L socket, so the
# default server and the real greenroom socket are never touched.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ID="tgr-test-$$"
HARNESS=(tmux -L "$ID-harness" -f /dev/null)
HOST=(tmux -L "$ID-host")
AGENT=(tmux -L "$ID-agent")
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
  "${AGENT[@]}" kill-server 2>/dev/null
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
  local line
  stop_servers
  {
    printf '%s\n' \
      'set -g prefix C-a' \
      'unbind C-b' \
      'bind C-a send-prefix' \
      'set -g default-terminal tmux-256color' \
      'set -s extended-keys on' \
      "set -as terminal-features ',tmux*:extkeys'" \
      "set -g @greenroom-socket '$ID-agent'" \
      "set -g @greenroom-agents 'claude codex missing'" \
      "set -g @greenroom-claude-cmd '\"$WORK_DIR/stub-agent\" claude'" \
      "set -g @greenroom-codex-cmd '\"$WORK_DIR/stub-agent\" codex'" \
      "set -g @greenroom-missing-cmd 'no-such-agent-binary --flag'"
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

agent_client_session() {
  "${AGENT[@]}" list-clients -F '#{client_session}' 2>/dev/null
}

popup_on() {
  [[ $(agent_client_session) == "$1" ]]
}

popup_closed() {
  [[ -z $(agent_client_session) ]] && ! screen_has ' agents '
}

agent_windows() {
  "${AGENT[@]}" list-windows -t "=$1" -F '#{window_name}' 2>/dev/null | tr '\n' ' '
}

has_window() {
  "${AGENT[@]}" list-windows -t "=$1" -F '#{window_name}' 2>/dev/null | grep -qx "$2"
}

pane_field() {
  "${AGENT[@]}" display-message -p -t "=$1:$2" "$3" | unescape_output
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

agent_server_gone() {
  ! "${AGENT[@]}" list-sessions >/dev/null 2>&1
}

open_popup() {
  press C-a g
  wait_for popup_on "${1:-main}" || fail "popup did not open on ${1:-main}"
}

# --- tests -------------------------------------------------------------------

test_toggle_opens_workspace_with_default_agent() {
  start_host
  open_popup || return
  [[ $(agent_windows main) == 'claude ' ]] || fail "windows: $(agent_windows main)" || return
  [[ $(pane_field main claude '#{pane_current_path}') == "$ORIGIN" ]] ||
    fail "agent cwd: $(pane_field main claude '#{pane_current_path}')" || return
  [[ $("${AGENT[@]}" show-option -qv -t =main: @greenroom_origin | unescape_output) == "$ORIGIN" ]] ||
    fail "origin option not set" || return
  wait_for screen_has "STUB claude in $ORIGIN" || fail "stub output not visible in popup"
}

test_toggle_inside_popup_detaches_and_keeps_agent() {
  local pid
  start_host
  open_popup || return
  pid=$(pane_field main claude '#{pane_pid}')
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  has_window main claude || fail "agent window gone" || return
  kill -0 "$pid" 2>/dev/null || fail "agent process $pid died"
}

test_reopen_shows_the_same_agent() {
  local pane
  start_host
  open_popup || return
  pane=$(pane_field main claude '#{pane_id}')
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  open_popup || return
  [[ $(pane_field main claude '#{pane_id}') == "$pane" ]] || fail "agent pane changed"
}

test_agent_menu_adds_agent_in_origin() {
  start_host
  open_popup || return
  press C-a c
  wait_for screen_has 'new agent' || fail "agent menu not shown" || return
  press o
  wait_for has_window main codex || fail "codex window not created: $(agent_windows main)" || return
  [[ $(pane_field main codex '#{pane_current_path}') == "$ORIGIN" ]] ||
    fail "codex cwd: $(pane_field main codex '#{pane_current_path}')"
}

test_agent_command_keeps_shell_syntax() {
  start_host "set -g @greenroom-claude-cmd '\"$WORK_DIR/stub-agent\" \"v\$((1+2))\"'"
  open_popup || return
  wait_for screen_has "STUB v3 in" || fail "command was not run as written"
}

test_host_option_changes_apply_on_next_open() {
  start_host
  open_popup || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${HOST[@]}" set-option -g @greenroom-codex-cmd "\"$WORK_DIR/stub-agent\" codex-new"
  open_popup || return
  press C-a c
  wait_for screen_has 'new agent' || fail "agent menu not shown" || return
  press o
  wait_for screen_has "STUB codex-new in" || fail "old command still used"
}

test_missing_agent_reports_status_then_closes() {
  start_host
  open_popup || return
  press C-a c
  wait_for screen_has 'new agent' || fail "agent menu not shown" || return
  press m
  wait_for screen_has 'missing exited with status 127' || fail "no exit status shown" || return
  press x
  wait_for no_window main missing || fail "window not closed after a key press"
}

no_window() {
  ! has_window "$1" "$2"
}

test_last_agent_exit_closes_popup_and_server() {
  start_host
  open_popup || return
  "${AGENT[@]}" send-keys -t =main:claude quit Enter
  wait_for popup_closed || fail "popup still open" || return
  wait_for agent_server_gone || fail "agent server still running"
}

test_last_agent_exit_does_not_switch_workspace() {
  start_host
  open_popup || return
  "${AGENT[@]}" new-session -d -s other "sleep 600"
  "${AGENT[@]}" send-keys -t =main:claude quit Enter
  wait_for popup_closed || fail "popup did not close: client on $(agent_client_session)" || return
  "${AGENT[@]}" has-session -t =other || fail "other workspace is gone"
}

test_failed_agent_waits_for_a_key() {
  start_host
  open_popup || return
  "${AGENT[@]}" send-keys -t =main:claude fail Enter
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
  is_bound prefix y "${AGENT[@]}" || fail "agent server does not bind y" || return
  ! is_bound prefix g "${AGENT[@]}" || fail "agent server still binds g" || return
  press C-a y
  wait_for popup_closed || fail "new key did not close the popup"
}

menu_closed() {
  ! screen_has "$1"
}

test_menu_key_options_bind_on_host_and_in_popup() {
  start_host "set -g @greenroom-agents-key C" "set -g @greenroom-workspaces-key W"
  is_bound prefix W "${HOST[@]}" || fail "host does not bind W" || return
  ! is_bound prefix G "${HOST[@]}" || fail "host still binds the default G" || return
  open_popup || return
  is_bound prefix C "${AGENT[@]}" || fail "agent server does not bind C" || return
  is_bound prefix W "${AGENT[@]}" || fail "agent server does not bind W" || return
  ! is_bound prefix G "${AGENT[@]}" || fail "agent server binds the default G" || return
  press C-a C
  wait_for screen_has 'new agent' || fail "agent menu not shown with C" || return
  press q
  wait_for menu_closed 'new agent' || fail "agent menu did not close" || return
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
  wait_for popup_on code_review || fail "client not on code_review: $(agent_client_session)" || return
  [[ $(agent_windows code_review) == 'claude ' ]] || fail "windows: $(agent_windows code_review)" || return
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

test_shift_enter_reaches_the_agent() {
  start_host "set -g @greenroom-default keylog" \
    "set -g @greenroom-keylog-cmd '\"$WORK_DIR/key-logger\" \"$WORK_DIR/keys.log\"'"
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

test_plugin_is_inert_inside_agent_server() {
  local guard=(tmux -L "$ID-guard" -f "$REPO_DIR/conf/agent-server.conf")
  "${guard[@]}" new-session -d \; run-shell "$REPO_DIR/greenroom.tmux"
  ! is_bound prefix g "${guard[@]}" || fail "host keys were bound" || return
  # Control: the same load binds the keys once the marker is gone.
  "${guard[@]}" set-option -gu @greenroom_server \; run-shell "$REPO_DIR/greenroom.tmux"
  is_bound prefix g "${guard[@]}" || fail "plugin did not bind keys without the marker"
}

test_removed_host_option_is_removed_from_agent_server() {
  start_host "set -g @greenroom-missing-cmd '\"$WORK_DIR/stub-agent\" missing-set'"
  open_popup || return
  press C-a g
  wait_for popup_closed || fail "popup still open" || return
  "${HOST[@]}" set-option -gu @greenroom-missing-cmd
  open_popup || return
  press C-a c
  wait_for screen_has 'new agent' || fail "agent menu not shown" || return
  press m
  wait_for screen_has 'missing exited with status 127' || fail "removed command still used"
}

test_agent_server_reads_extra_config() {
  printf '%s\n' 'set -g @from-extra-config yes' > "$WORK_DIR/agent.conf"
  start_host "set -g @greenroom-config '$WORK_DIR/agent.conf'"
  open_popup || return
  [[ $("${AGENT[@]}" show-option -gqv @from-extra-config) == yes ]] || fail "extra config not read"
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
  wait_for screen_has 'new agent' || fail "agent menu not shown" || return
  press s
  wait_for has_window main shell || fail "shell window not created: $(agent_windows main)"
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
  wait_for popup_on v1_2_next || fail "client not on v1_2_next: $(agent_client_session)" || return
  [[ $("${AGENT[@]}" show-option -gqv @greenroom_last) == v1_2_next ]] || fail "last workspace not updated"
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
  wait_for agent_server_gone || fail "workspace still exists"
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
  "${AGENT[@]}" send-keys -t =main:claude bell Enter
  wait_for host_alert_is 'claude@main' || fail "host alert: [$(host_alert)]" || return
  wait_for screen_has 'greenroom: claude@main rang the bell' || fail "no message on the host" || return
  open_popup || return
  wait_for host_alert_is '' || fail "alert not cleared after opening: [$(host_alert)]"
}

test_bell_in_the_visible_agent_is_not_announced() {
  start_host
  open_popup || return
  "${AGENT[@]}" send-keys -t =main:claude bell Enter
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

agent_pane_has() {
  "${AGENT[@]}" capture-pane -p -t "=$1:" 2>/dev/null | grep -qF -- "$2"
}

host_buffers() {
  "${HOST[@]}" list-buffers -F '#{buffer_name}' 2>/dev/null
}

test_selection_is_sent_to_the_agent() {
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
  wait_for agent_pane_has main 'SEND-ME-123' || fail "text did not reach the agent" || return
  [[ -z $(host_buffers) ]] || fail "host buffers left: $(host_buffers)"
}

test_pane_screen_is_sent_to_a_new_workspace() {
  start_host
  type_text 'echo PANE-MARKER-9'
  press Enter
  wait_for screen_has 'PANE-MARKER-9' || fail "host pane output not shown" || return
  press C-a S
  wait_for popup_on main || fail "popup did not open" || return
  wait_for agent_pane_has main 'STUB claude in' || fail "agent did not start" || return
  wait_for agent_pane_has main 'PANE-MARKER-9' || fail "screen did not reach the agent" || return
  [[ -z $(host_buffers) ]] || fail "host buffers left: $(host_buffers)"
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
