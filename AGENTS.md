# AGENTS.md

Instructions for AI coding agents working in this repository. `CLAUDE.md` is a symlink to this file, so keep it tool-neutral.

## Project

A tmux plugin that toggles a popup attached to a dedicated tmux server hosting AI agent CLIs (Claude Code, Codex, Gemini CLI, OpenCode). Read [docs/design.md](docs/design.md) before changing behavior; it records the decisions and the evidence behind them.

## Hard rules

- Tests and experiments use their own `tmux -L <unique-name>` sockets. Never touch the default tmux server or a socket named `llm-agent`: the user's real agents live there.
- Host-side code (`llm-agent.tmux`, `scripts/attach.sh`) passes `-L "$socket"` on every agent server call. Inside a popup, `$TMUX` points at the host server, so a bare `tmux` goes to the wrong server. Scripts that run inside the agent server use a bare `tmux`.
- `@llm-agent-*` names are user options and are copied to the agent server on every open. Plugin state uses `@llm_agent_*`. Do not mix the two.
- Read option values that may hold shell text or paths with `read_raw_options`, not `show-option -v` or `display-message -p`: tmux 3.4 escapes `$` in command output.
- Pass user-controlled values through `tmux_arg` when they go on a tmux command line (an argument ending in `;` is a separator), and through `format_escape` when tmux expands them as a format (`new-session -c`, `display-menu` items).
- Scripts must run on bash 3.2 (the macOS default): no associative arrays, `mapfile`, or `${var,,}`.
- The minimum tmux version is 3.4, the oldest release the tests run on. Guard or document anything that needs a newer release.
- No runtime dependencies beyond bash and tmux.

## Checks

- Run `tests/run.sh` and `BASH_COMPAT=3.2 tests/run.sh` before committing. To test another tmux build, put a directory with a `tmux` symlink to it first in `PATH`.
- Run `shellcheck` on `llm-agent.tmux` and `scripts/*.sh` when it is installed.

## Docs

- `README.md` is the user-facing guide, in English.
- `docs/design.md` is the design record, in Korean.
- Update both when behavior, keys, or options change.
