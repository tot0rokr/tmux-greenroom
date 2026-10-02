#!/usr/bin/env bash
# Runs a profile in a greenroom server window. attach.sh copies the user
# options into the greenroom server, so the lookup never reaches the host
# server.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

name=$1
cmd=$(read_raw_options "@greenroom-profile-$name-cmd")
cmd=${cmd%"$FIELD_SEPARATOR"}

if [[ -z $cmd && $name == shell ]]; then
  exec -l "${SHELL:-/bin/sh}"
fi

# Stay alive through Ctrl-C so a failure can still be reported. A handler,
# unlike an ignored signal, is not inherited by the command.
trap : INT

# A login shell, so PATH set in the user's shell startup files (~/.profile
# and the like) applies.
"${SHELL:-/bin/sh}" -lc "${cmd:-$name}"
status=$?
if ((status != 0)); then
  printf '\n[%s exited with status %d. Press any key to close.]' "$name" "$status"
  read -rsn1
fi
