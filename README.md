# tmux-llm-agent

Keep AI coding agents one keystroke away from any tmux window. Toggle a popup that hosts Claude Code, Codex, Gemini CLI, OpenCode, or any other agent CLI, and close it without stopping them.

Status: in design. Nothing is usable yet.

## Goals

- One popup shared by every session and window on the tmux server.
- Closing the popup detaches from the agents instead of killing them, so the next toggle picks up where you left off.
- Several agents side by side in one popup, and several named popups for separate contexts.
- Any agent CLI: Claude Code, Codex, Gemini CLI, and OpenCode are built in, and others can be added.

## License

[MIT](LICENSE)
