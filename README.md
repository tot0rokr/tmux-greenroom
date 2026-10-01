# tmux-greenroom

Keep AI coding agents one keystroke away from any tmux window. Toggle a popup that hosts Claude Code, Codex, Gemini CLI, OpenCode, or any other agent CLI, and close it without stopping them.

The name comes from the green room of a theater or TV studio, where performers wait off stage until they are called. Your agents wait there, still running, until you bring them up.

The popup shows a dedicated tmux server. Its sessions are workspaces and its windows are agents.

```
 your tmux (host server)                 agent server (tmux -L greenroom)
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
set -g @plugin 'tot0rokr/tmux-greenroom'
```

Then press `prefix` + `I` to install it.

### Manual

```bash
git clone https://github.com/tot0rokr/tmux-greenroom ~/.tmux/plugins/tmux-greenroom
```

Add this line to `~/.tmux.conf` and reload the config:

```tmux
run-shell ~/.tmux/plugins/tmux-greenroom/greenroom.tmux
```

## Usage

On the host:

| Key                   | Action                                                   |
| --------------------- | -------------------------------------------------------- |
| `prefix` + `g`        | Open the popup on the last workspace                     |
| `prefix` + `G`        | Open the popup with the workspace menu on top            |
| `prefix` + `S`        | Send the visible screen of the pane to the agent         |
| `a` in copy mode      | Send the selection to the agent                          |
| `@greenroom-root-key` | Same as `prefix` + `g`, without the prefix (only if set) |

The first open starts the agent server and a workspace named `main` with one `claude` agent. Later opens go to the workspace you used last.

Inside the popup, the agent server uses the same prefix as your host tmux:

| Key                          | Action                                    |
| ---------------------------- | ----------------------------------------- |
| `prefix` + `g`               | Close the popup (the agents keep running) |
| `prefix` + `d`               | Close the popup (tmux default)            |
| `prefix` + `c`               | Open the agent menu                       |
| `prefix` + `G`               | Open the workspace menu                   |
| `prefix` + `z`               | Toggle large mode                         |
| `prefix` + `n`, `p`, `0`-`9` | Switch agent (tmux default)               |
| `prefix` + `&`               | Kill the current agent (tmux default)     |
| `prefix` + `s`, `w`          | Workspace and agent tree (tmux default)   |
| `prefix` + `$`               | Rename the workspace (tmux default)       |
| `prefix` + `prefix`          | Send the prefix key to the agent          |

If you set `@greenroom-root-key`, the same key also closes the popup. It is not passed on to the agent.

### Agent menu

`prefix` + `c` lists the agents named in `@greenroom-agents`, in that order. The chosen agent opens in a new window, named after the agent. Its directory is the one recorded for the current workspace: the pane that last opened the popup on it.

With the default list, `claude codex gemini opencode | shell`, the menu looks like this:

```
┌── new agent ─┐
│ claude   (c) │
│ codex    (o) │
│ gemini   (e) │
│ opencode (p) │
├──────────────┤
│ shell    (s) │
└──────────────┘
```

- Each word of the list is an agent name, made of letters, digits, `_`, and `-`. Other words are skipped. A name listed twice appears once, at its first place.
- `|` draws a separator line. A `|` at the start or end of the list, or next to another `|`, is dropped.
- `shell` starts your login shell, or `@greenroom-shell-cmd` if you set it. It is an ordinary entry and is not added for you: leave it out to drop it, or move it.
- Any other name runs `@greenroom-<name>-cmd`, or the name itself as a command when that option is not set.
- An empty list shows a disabled `no agents configured` entry.

`@greenroom-<name>-key` sets the shortcut of an entry to a tmux key name, such as `x`, `X`, `1`, or `M-a`. An entry without one gets the first lowercase letter or digit of its name that no other entry took. That automatic choice skips `q`, `j`, `k`, `g`, and `G`, because `display-menu` uses them itself; an explicit key may take one of them and replaces its built-in action in the menu. An explicit key that an earlier entry already set falls back to the automatic shortcut. So does an arrow key, such as `Up` or `S-Up`, because `display-menu` does not run a shortcut on one.

The agents `root`, `send`, `send-pane`, `agents`, `workspaces`, `large`, `grow`, `shrink`, and `reset` always get the automatic shortcut. Their `@greenroom-<name>-key` is one of the plugin's own key options, such as `@greenroom-root-key`, and setting it changes that key instead.

For example, to put the shell first and add Aider:

```tmux
set -g @greenroom-agents 'shell | claude codex aider'
set -g @greenroom-aider-cmd 'aider --no-auto-commits'
set -g @greenroom-aider-key 'a'
set -g @greenroom-codex-key 'x'
```

```
┌─ new agent ─┐
│ shell   (s) │
├─────────────┤
│ claude  (c) │
│ codex   (x) │
│ aider   (a) │
└─────────────┘
```

| Key        | Action                             |
| ---------- | ---------------------------------- |
| `Enter`    | Start the highlighted agent        |
| shortcut   | Start the agent with that shortcut |
| `Esc`, `q` | Close the menu                     |

### Workspace menu

`prefix` + `G` lists the workspaces with their agent count, and marks the current one with `*`. The chosen workspace replaces the one in the popup.

| Key     | Action                                           |
| ------- | ------------------------------------------------ |
| `1`-`9` | Switch to the workspace in that row              |
| `n`     | Create a workspace (prompts for a name)          |
| `r`     | Rename the current workspace                     |
| `x`     | Kill the current workspace, after a confirmation |

A new workspace starts one `@greenroom-default` agent in the directory of the current workspace. Characters other than letters, digits, `_`, and `-` in a workspace name are replaced with `_`, for new and renamed workspaces and for `@greenroom-workspace`. Renaming with tmux's own `prefix` + `$` skips this; a name with `.` or `:` then cannot be picked as the last workspace.

### Popup size

`prefix` + `z` inside the popup toggles large mode. The popup then takes `@greenroom-large-width` by `@greenroom-large-height` of the terminal, 95% by 95% by default: almost the whole screen, but its border and a margin of the host stay visible, so it still reads as a popup. On a terminal of 20 rows or fewer, 95% leaves a single spare row, so the top border reaches the first row. Press `prefix` + `z` again to go back.

To grow and shrink the popup in steps, give the other size actions a key. They have none by default:

```tmux
set -g @greenroom-grow-key '+'
set -g @greenroom-shrink-key '-'
set -g @greenroom-reset-key '='
```

| Key                                | Action                                                |
| ---------------------------------- | ----------------------------------------------------- |
| `prefix` + `z`                     | Toggle large mode (`@greenroom-large-key`)            |
| `prefix` + `@greenroom-grow-key`   | Grow the popup by one step and leave large mode       |
| `prefix` + `@greenroom-shrink-key` | Shrink the popup by one step and leave large mode     |
| `prefix` + `@greenroom-reset-key`  | Go back to `@greenroom-width` and `@greenroom-height` |

- A step changes the width and the height by `@greenroom-resize-step` percentage points, 10 by default, and stops at 20% and 95%. A size in cells, such as `@greenroom-width 120`, is turned into a percentage of the terminal first.
- Percentages count the whole terminal, status line included.
- The popup closes and opens again at the new size on the same workspace. The agents keep running and see only a resize.
- The size stays until you reset it or the host tmux server restarts. Closing the popup, reloading the config, and sending text to an agent keep it. It is one setting for the host server: a popup on another client takes it the next time it opens.
- `prefix` + `z` replaces tmux's own zoom key inside the popup. Set `@greenroom-large-key` to another key, or to `''` to leave large mode without a key; `prefix` + `z` zooms again from the next open.
- The size keys do nothing in a client attached to the agent server directly, such as `tmux -L greenroom attach`, because it shows no popup.

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

- A `display-message` on every host client, such as `greenroom: claude@main rang the bell`.
- The host option `@greenroom_alert`, which lists the agents with an unseen bell as `agent@workspace`, separated by spaces. Opening the popup on an agent clears its entry.
- Inside the popup, the window list marks those agents with `!`.

The plugin adds nothing to make an agent ring the bell. Configure your agent CLI to do it, for example from a hook that runs when it finishes or needs input. The agent server always uses `bell-action any`, so a bell from the agent a closed popup was showing still counts.

To show the alert in the host status line, add this to `~/.tmux.conf` after the plugin is loaded. It renders nothing while there is no alert, or when the plugin is not installed, and the guard keeps a config reload from adding it twice:

```tmux
if-shell -F '#{m:*greenroom_alert*,#{status-right}}' '' "set -ga status-right '#{?@greenroom_alert,#[fg=black#,bg=yellow#,bold] #{@greenroom_alert} #[default],}'"
```

### Shift+Enter

Shift+Enter reaches the agent inside the popup if your host tmux has `extended-keys on`. The agent server copies the host value when it starts.

## Options

| Option                      | Default                                 | Description                                                           |
| --------------------------- | --------------------------------------- | --------------------------------------------------------------------- |
| `@greenroom-key`            | `g`                                     | Key that opens and closes the popup                                   |
| `@greenroom-root-key`       | empty                                   | Key that opens and closes the popup without the prefix, such as `M-g` |
| `@greenroom-workspaces-key` | `G`                                     | Key for the workspace menu, on the host and inside the popup          |
| `@greenroom-agents-key`     | `c`                                     | Key for the agent menu inside the popup                               |
| `@greenroom-send-key`       | `a`                                     | Copy-mode key that sends the selection to the agent                   |
| `@greenroom-send-pane-key`  | `S`                                     | Key that sends the visible screen of the pane to the agent            |
| `@greenroom-large-key`      | `z`                                     | Key inside the popup that toggles large mode; `''` for none           |
| `@greenroom-grow-key`       | empty                                   | Key inside the popup that grows it by one step                        |
| `@greenroom-shrink-key`     | empty                                   | Key inside the popup that shrinks it by one step                      |
| `@greenroom-reset-key`      | empty                                   | Key inside the popup that goes back to the size options               |
| `@greenroom-agents`         | `claude codex gemini opencode \| shell` | Agent menu entries, in order                                          |
| `@greenroom-<name>-cmd`     | `<name>`                                | Command that starts the agent called `<name>`                         |
| `@greenroom-<name>-key`     | automatic                               | Shortcut of the agent called `<name>` in the agent menu               |
| `@greenroom-default`        | `claude`                                | First agent of a new workspace                                        |
| `@greenroom-workspace`      | `main`                                  | Workspace to open when there is no last workspace                     |
| `@greenroom-width`          | `80%`                                   | Popup width                                                           |
| `@greenroom-height`         | `80%`                                   | Popup height                                                          |
| `@greenroom-large-width`    | `95%`                                   | Popup width in large mode                                             |
| `@greenroom-large-height`   | `95%`                                   | Popup height in large mode                                            |
| `@greenroom-resize-step`    | `10`                                    | Percentage points that grow and shrink change the size by             |
| `@greenroom-x`              | `C`                                     | Popup horizontal position                                             |
| `@greenroom-y`              | `C`                                     | Popup vertical position                                               |
| `@greenroom-border-lines`   | `rounded`                               | Popup border, a `popup-border-lines` value                            |
| `@greenroom-socket`         | `greenroom`                             | Socket name of the agent server (`tmux -L`)                           |
| `@greenroom-config`         | empty                                   | Extra config file for the agent server                                |

An agent name may contain letters, digits, `_`, and `-`. The command runs through `$SHELL -lc`, so it can carry arguments and environment assignments, and the `PATH` from your login profile applies. `@greenroom-default` may name any agent, listed in `@greenroom-agents` or not. See [Agent menu](#agent-menu) for the list syntax and `shell`.

```tmux
set -g @greenroom-key 'a'
set -g @greenroom-root-key 'M-a'
set -g @greenroom-width '90%'
set -g @greenroom-claude-cmd 'claude --model opus'
set -g @greenroom-agents 'claude codex aider | shell'
set -g @greenroom-aider-cmd 'aider --no-auto-commits'
```

The host keys (`@greenroom-key`, `@greenroom-root-key`, `@greenroom-workspaces-key`, `@greenroom-send-key`, `@greenroom-send-pane-key`) are read when the plugin loads, so reload your config after changing them. The old keys are unbound on reload. The other options, the popup size and position included, are read on every open. A key that the plugin stops using inside the popup is unbound; `c`, `z`, `-`, and `=` get tmux's own binding back, and other keys get theirs back when the agent server restarts.

## Customizing the agent server

The agent server does not read your `tmux.conf`. Reading it would run TPM again inside the agent server, and plugins such as tmux-continuum could overwrite your saved host state. It reads `conf/agent-server.conf` from the plugin, then the file named by `@greenroom-config`, once when it starts.

Use that file for the status line, colors, and plugins you want inside the popup. For example, to load tmux-cuecard in the popup:

```tmux
set -g @greenroom-config '~/.tmux/greenroom.conf'
```

```tmux
# ~/.tmux/greenroom.conf
run-shell ~/.tmux/plugins/tmux-cuecard/cuecard.tmux
```

What the agent server takes from the host:

- On every open: `prefix`, `prefix2`, and every `@greenroom-*` option. Removing an option on the host removes it from the agent server too.
- Once, when the agent server starts: `default-terminal`, `history-limit`, `mouse`, `mode-keys`, `status-keys`, `base-index`, `pane-base-index`, `escape-time`, `extended-keys`, and `set-clipboard`.

To apply a change to the second group, restart the agent server:

```bash
tmux -L greenroom kill-server
```

This also stops every agent. If you changed `@greenroom-socket`, use that name instead.

## State

The plugin writes no files. Workspaces, agents, and the last-used workspace live in the memory of the agent server. The popup size lives in the memory of the host server.

- Closing the popup keeps everything.
- Restarting or killing the host tmux server keeps everything but the popup size. The next host server that loads the plugin opens the same agents.
- Stopping the agent server, or rebooting, ends every agent. Use the resume feature of the agent CLI, such as `claude --continue`, to pick up a conversation.
- Each agent server socket is separate. A host that sets a different `@greenroom-socket` sees different workspaces.

## Known limitations

- Two clients showing the same workspace at different popup sizes resize the window back and forth, following whichever client was used last (`window-size latest`).
- The agent server has one global `prefix` and one origin directory per workspace. When two host servers with different settings share it, the host that opened the popup last wins.
- Paste buffers are per server. On tmux 3.7 and later with `set-clipboard on`, a copy inside the popup still reaches the system clipboard through OSC 52, and the host stores it as a paste buffer too, so `prefix` + `]` on the host pastes it. On tmux 3.4 to 3.6 it stays inside the agent server.
- Bell alerts go to the host server that opened the popup last. So do the size keys: in a popup of another host server they do nothing.
- A size key closes and opens the popup, which takes about a quarter of a second. Keys typed meanwhile reach the agent, but size keys pressed faster than that can lose a step.
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
