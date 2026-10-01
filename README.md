# tmux-llm-agent

Keep AI coding agents one keystroke away from any tmux window. Toggle a popup that hosts Claude Code, Codex, Gemini CLI, OpenCode, or any other agent CLI, and close it without stopping them.

The popup shows a dedicated tmux server. Its sessions are workspaces and its windows are agents.

```
 your tmux (host server)                 agent server (tmux -L llm-agent)
┌──────────────────────────────┐        ┌────────────────────────────┐
│ session "work"               │        │ workspace "main"           │
│  └ popup ────────────────────┼───────▶│  ├ agent 0: claude         │
│                              │        │  └ agent 1: codex          │
│ session "notes"              │        │                            │
│  └ popup ────────────────────┼───────▶│ workspace "review"         │
│                              │        │  └ agent 0: claude         │
└──────────────────────────────┘        └────────────────────────────┘
```

- Every session and window on the host opens the same popup, so you see the same agents wherever you are.
- Closing the popup only detaches. The agents keep running, and the next open shows them as you left them.
- A workspace is one popup context with its own set of agents. Keep one per project or task and switch between them from a menu.
- New agents start in the directory of the pane that last opened the popup on that workspace.

## Requirements

- tmux 3.4 or later (tested on 3.4 and 3.7)
- bash 3.2 or later
- Agent CLIs such as `claude`, `codex`, `gemini`, and `opencode` are optional. Starting one that is not installed shows its exit status in the window.

## Installation

### With TPM

Add the plugin to `~/.tmux.conf`:

```tmux
set -g @plugin 'tot0rokr/tmux-llm-agent'
```

Then press `prefix` + `I` to install it.

### Manual

```bash
git clone https://github.com/tot0rokr/tmux-llm-agent ~/.tmux/plugins/tmux-llm-agent
```

Add this line to `~/.tmux.conf` and reload the config:

```tmux
run-shell ~/.tmux/plugins/tmux-llm-agent/llm-agent.tmux
```

## Usage

On the host:

| Key                   | Action                                                   |
| --------------------- | -------------------------------------------------------- |
| `prefix` + `g`        | Open the popup on the last workspace                     |
| `prefix` + `G`        | Open the popup with the workspace menu on top            |
| `prefix` + `S`        | Send the visible screen of the pane to the agent         |
| `a` in copy mode      | Send the selection to the agent                          |
| `@llm-agent-root-key` | Same as `prefix` + `g`, without the prefix (only if set) |

The first open starts the agent server and a workspace named `main` with one `claude` agent. Later opens go to the workspace you used last.

Inside the popup, the agent server uses the same prefix as your host tmux:

| Key                          | Action                                    |
| ---------------------------- | ----------------------------------------- |
| `prefix` + `g`               | Close the popup (the agents keep running) |
| `prefix` + `d`               | Close the popup (tmux default)            |
| `prefix` + `c`               | Open the agent menu                       |
| `prefix` + `G`               | Open the workspace menu                   |
| `prefix` + `n`, `p`, `0`-`9` | Switch agent (tmux default)               |
| `prefix` + `&`               | Kill the current agent (tmux default)     |
| `prefix` + `s`, `w`          | Workspace and agent tree (tmux default)   |
| `prefix` + `$`               | Rename the workspace (tmux default)       |
| `prefix` + `prefix`          | Send the prefix key to the agent          |

If you set `@llm-agent-root-key`, the same key also closes the popup. It is not passed on to the agent.

### Agent menu

`prefix` + `c` lists the agents from `@llm-agent-agents`, then a `shell` entry that starts your login shell. The chosen agent opens in a new window, named after the agent. Its directory is the one recorded for the current workspace: the pane that last opened the popup on it.

The shortcut of each entry is the first letter of its name that no earlier entry took. The letters `q`, `j`, `k`, `g`, and `G` are skipped because `display-menu` uses them itself.

| Key        | Action                             |
| ---------- | ---------------------------------- |
| `Enter`    | Start the highlighted agent        |
| letter     | Start the agent with that shortcut |
| `Esc`, `q` | Close the menu                     |

### Workspace menu

`prefix` + `G` lists the workspaces with their agent count, and marks the current one with `*`. The chosen workspace replaces the one in the popup.

| Key     | Action                                           |
| ------- | ------------------------------------------------ |
| `1`-`9` | Switch to the workspace in that row              |
| `n`     | Create a workspace (prompts for a name)          |
| `r`     | Rename the current workspace                     |
| `x`     | Kill the current workspace, after a confirmation |

A new workspace starts one `@llm-agent-default` agent in the directory of the current workspace. Characters other than letters, digits, `_`, and `-` in a workspace name are replaced with `_`, for new and renamed workspaces and for `@llm-agent-workspace`. Renaming with tmux's own `prefix` + `$` skips this; a name with `.` or `:` then cannot be picked as the last workspace.

### Lifetime

- An agent that exits with status 0 closes its window.
- An agent that exits with any other status, including a command that is not found, prints the status and waits. The window closes on the next key press, so you can read the error first.
- When the last agent of a workspace exits, the workspace closes and the popup closes with it. It does not jump to another workspace.
- When the last workspace closes, the agent server exits.

### Sending text to an agent

Hand an error message or a log to the agent without copying and pasting by hand:

- In copy mode, select the text and press `a`.
- Or press `prefix` + `S` to send everything the pane shows.

The text goes into the prompt of the active agent in the last workspace, and the popup opens on it. It is pasted as one block and Enter is not pressed, so you can add your question before sending. If no workspace exists yet, one is started and the text is pasted once the new agent has drawn its prompt.

Sending does not touch your paste buffers or the clipboard.

### Bell alerts

An agent that rings the terminal bell while you cannot see it, because the popup is closed or shows another agent, raises an alert on the host:

- A `display-message` on every host client, such as `llm-agent: claude@main rang the bell`.
- The host option `@llm_agent_alert`, which lists the agents with an unseen bell as `agent@workspace`, separated by spaces. Opening the popup on an agent clears its entry.
- Inside the popup, the window list marks those agents with `!`.

The plugin adds nothing to make an agent ring the bell. Configure your agent CLI to do it, for example from a hook that runs when it finishes or needs input. The agent server always uses `bell-action any`, so a bell from the agent a closed popup was showing still counts.

To show the alert in the host status line, add this to `~/.tmux.conf` after the plugin is loaded. It renders nothing while there is no alert, or when the plugin is not installed, and the guard keeps a config reload from adding it twice:

```tmux
if-shell -F '#{m:*llm_agent_alert*,#{status-right}}' '' "set -ga status-right '#{?@llm_agent_alert,#[fg=black#,bg=yellow#,bold] #{@llm_agent_alert} #[default],}'"
```

### Shift+Enter

Shift+Enter reaches the agent inside the popup if your host tmux has `extended-keys on`. The agent server copies the host value when it starts.

## Options

| Option                     | Default                        | Description                                                           |
| -------------------------- | ------------------------------ | --------------------------------------------------------------------- |
| `@llm-agent-key`           | `g`                            | Key that opens and closes the popup                                   |
| `@llm-agent-root-key`      | empty                          | Key that opens and closes the popup without the prefix, such as `M-g` |
| `@llm-agent-menu-key`      | `G`                            | Key for the workspace menu                                            |
| `@llm-agent-new-key`       | `c`                            | Key for the agent menu inside the popup                               |
| `@llm-agent-send-key`      | `a`                            | Copy-mode key that sends the selection to the agent                   |
| `@llm-agent-send-pane-key` | `S`                            | Key that sends the visible screen of the pane to the agent            |
| `@llm-agent-agents`        | `claude codex gemini opencode` | Agents in the menu, in order                                          |
| `@llm-agent-<name>-cmd`    | `<name>`                       | Command that starts the agent called `<name>`                         |
| `@llm-agent-default`       | `claude`                       | First agent of a new workspace                                        |
| `@llm-agent-workspace`     | `main`                         | Workspace to open when there is no last workspace                     |
| `@llm-agent-width`         | `80%`                          | Popup width                                                           |
| `@llm-agent-height`        | `80%`                          | Popup height                                                          |
| `@llm-agent-x`             | `C`                            | Popup horizontal position                                             |
| `@llm-agent-y`             | `C`                            | Popup vertical position                                               |
| `@llm-agent-border-lines`  | `rounded`                      | Popup border, a `popup-border-lines` value                            |
| `@llm-agent-socket`        | `llm-agent`                    | Socket name of the agent server (`tmux -L`)                           |
| `@llm-agent-config`        | empty                          | Extra config file for the agent server                                |

An agent name may contain letters, digits, `_`, and `-`. The command runs through `$SHELL -lc`, so it can carry arguments and environment assignments, and the `PATH` from your login profile applies. `shell` is always in the menu; set `@llm-agent-shell-cmd` to run something other than your login shell.

```tmux
set -g @llm-agent-key 'a'
set -g @llm-agent-root-key 'M-a'
set -g @llm-agent-width '90%'
set -g @llm-agent-claude-cmd 'claude --model opus'
set -g @llm-agent-agents 'claude codex aider'
set -g @llm-agent-aider-cmd 'aider --no-auto-commits'
```

The host keys (`@llm-agent-key`, `@llm-agent-root-key`, `@llm-agent-menu-key`, `@llm-agent-send-key`, `@llm-agent-send-pane-key`) and the popup options (`@llm-agent-width`, `@llm-agent-height`, `@llm-agent-x`, `@llm-agent-y`, `@llm-agent-border-lines`) are read when the plugin loads, so reload your config after changing them. The old keys are unbound on reload. The other options are read on every open.

## Customizing the agent server

The agent server does not read your `tmux.conf`. Reading it would run TPM again inside the agent server, and plugins such as tmux-continuum could overwrite your saved host state. It reads `conf/agent-server.conf` from the plugin, then the file named by `@llm-agent-config`, once when it starts.

Use that file for the status line, colors, and plugins you want inside the popup. For example, to load tmux-cuecard in the popup:

```tmux
set -g @llm-agent-config '~/.tmux/llm-agent.conf'
```

```tmux
# ~/.tmux/llm-agent.conf
run-shell ~/.tmux/plugins/tmux-cuecard/cuecard.tmux
```

What the agent server takes from the host:

- On every open: `prefix`, `prefix2`, and every `@llm-agent-*` option. Removing an option on the host removes it from the agent server too.
- Once, when the agent server starts: `default-terminal`, `history-limit`, `mouse`, `mode-keys`, `status-keys`, `base-index`, `pane-base-index`, `escape-time`, `extended-keys`, and `set-clipboard`.

To apply a change to the second group, restart the agent server:

```bash
tmux -L llm-agent kill-server
```

This also stops every agent. If you changed `@llm-agent-socket`, use that name instead.

## State

The plugin writes no files. Workspaces, agents, and the last-used workspace live in the memory of the agent server.

- Closing the popup keeps everything.
- Restarting or killing the host tmux server keeps everything. The next host server that loads the plugin opens the same agents.
- Stopping the agent server, or rebooting, ends every agent. Use the resume feature of the agent CLI, such as `claude --continue`, to pick up a conversation.
- Each agent server socket is separate. A host that sets a different `@llm-agent-socket` sees different workspaces.

## Known limitations

- Two clients showing the same workspace at different popup sizes resize the window back and forth, following whichever client was used last (`window-size latest`).
- The agent server has one global `prefix` and one origin directory per workspace. When two host servers with different settings share it, the host that opened the popup last wins.
- Paste buffers are per server. On tmux 3.7 and later with `set-clipboard on`, a copy inside the popup still reaches the system clipboard through OSC 52, and the host stores it as a paste buffer too, so `prefix` + `]` on the host pastes it. On tmux 3.4 to 3.6 it stays inside the agent server.
- Bell alerts go to the host server that opened the popup last.
- An upgrade of the plugin takes full effect after the agent server restarts, because `conf/agent-server.conf` is read only at start.

## Development

`tests/run.sh` runs the integration tests. Each run starts its own tmux servers on unique sockets and never touches your running servers. Pass part of a test name to run only matching tests.

```bash
tests/run.sh
tests/run.sh workspace
BASH_COMPAT=3.2 tests/run.sh
```

## License

[MIT](LICENSE)
