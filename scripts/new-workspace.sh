#!/usr/bin/env bash
# Runs in the greenroom server after the "new workspace" prompt.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

main() {
  local client=$1 pending=$2 name origin profile session
  name=$(take_pending_name "$pending")
  if [[ -z $name ]]; then
    return
  fi

  if ! tmux has-session -t "=$name" 2>/dev/null; then
    session=$(client_session "$client") || return
    origin=$(read_raw_options -t "$session" @greenroom_origin)
    origin=${origin%"$FIELD_SEPARATOR"}
    origin=${origin:-$HOME}
    profile=$(get_tmux_option @greenroom_default claude)
    tmux new-session -d -s "$name" -c "$(tmux_arg "$(format_escape "$origin")")" \
      -n "$profile" "$(profile_command "$profile")" \; \
      set-option -t "=$name:" @greenroom_origin "$(tmux_arg "$origin")"
  fi
  tmux switch-client -c "$client" -t "=$name"
}

main "$@"
