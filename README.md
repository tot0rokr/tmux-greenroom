# tmux-greenroom

Keep AI coding agents one keystroke away from any tmux window. Toggle a popup that hosts Claude Code, Codex, Gemini CLI, OpenCode, or any other agent CLI, and close it without stopping them.

The name comes from the green room of a theater or TV studio, where performers wait off stage until they are called. Your agents wait there, still running, until you bring them up.

The popup shows a dedicated tmux server, the greenroom server. Its sessions are workspaces, and each of its windows runs a profile: a named command such as `claude`, `codex`, or your shell.

```
 your tmux (host server)                 greenroom server (tmux -L greenroom)
┌──────────────────────────────┐        ┌───────────────────────────────────┐
│ session "work"               │        │ workspace "main"                  │
│  └ popup ────────────────────┼───────▶│  ├ window 0: claude               │
│                              │        │  └ window 1: codex                │
│ session "notes"              │        │                                   │
│  └ popup ────────────────────┼───────▶│ workspace "review"                │
│                              │        │  └ window 0: claude               │
└──────────────────────────────┘        └───────────────────────────────────┘
```

- Every session and window on the host opens the same popup, so you see the same workspaces wherever you are.
- Closing the popup only detaches. Everything in it keeps running, and the next open shows it as you left it.
- A workspace is one popup context with its own set of windows. Keep one per project or task and switch between them from a menu.
- New windows start in the directory of the pane that last opened the popup on that workspace.

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
| `prefix` + `S`        | Send the visible screen of the pane to the popup         |
| `a` in copy mode      | Send the selection to the popup                          |
| `@greenroom-root-key` | Same as `prefix` + `g`, without the prefix (only if set) |

The first open starts the greenroom server and a workspace named `main` with one `claude` window. Later opens go to the workspace you used last.

Inside the popup, the greenroom server uses the same prefix as your host tmux:

| Key                          | Action                                     |
| ---------------------------- | ------------------------------------------ |
| `prefix` + `g`               | Close the popup (its windows keep running) |
| `prefix` + `d`               | Close the popup (tmux default)             |
| `prefix` + `c`               | Open the profile menu                      |
| `prefix` + `G`               | Open the workspace menu                    |
| `prefix` + `M`               | Open the command menu                      |
| `prefix` + `z`               | Toggle large mode                          |
| `prefix` + `n`, `p`, `0`-`9` | Switch window (tmux default)               |
| `prefix` + `&`               | Kill the current window (tmux default)     |
| `prefix` + `s`, `w`          | Workspace and window tree (tmux default)   |
| `prefix` + `$`               | Rename the workspace (tmux default)        |
| `prefix` + `prefix`          | Send the prefix key to the pane            |

If you set `@greenroom-root-key`, the same key also closes the popup. It is not passed on to the pane.

### Profile menu

`prefix` + `c` lists the profiles named in `@greenroom-profiles`, in that order. A profile is a named command, such as an agent CLI, a shell, or `lazygit`. The chosen profile opens in a new window, named after the profile. Its directory is the one recorded for the current workspace: the pane that last opened the popup on it.

With the default list, `claude codex gemini opencode | shell`, the menu looks like this:

```
┌── profiles ──┐
│ claude   (c) │
│ codex    (o) │
│ gemini   (e) │
│ opencode (p) │
├──────────────┤
│ shell    (s) │
└──────────────┘
```

- Each word of the list is a profile name, made of letters, digits, `_`, and `-`. Other words are skipped. A name listed twice appears once, at its first place.
- `|` draws a separator line. A `|` at the start or end of the list, or next to another `|`, is dropped.
- `shell` starts your login shell, or `@greenroom-profile-shell-cmd` if you set it. It is an ordinary entry and is not added for you: leave it out to drop it, or move it.
- Any other name runs `@greenroom-profile-<name>-cmd`, or the name itself as a command when that option is not set.
- An empty list shows a disabled `no profiles configured` entry.

`@greenroom-profile-<name>-key` sets the shortcut of an entry to a tmux key name, such as `x`, `X`, `1`, or `M-a`. An entry without one gets the first lowercase letter or digit of its name that no other entry took. That automatic choice skips `q`, `j`, `k`, `g`, and `G`, because `display-menu` uses them itself; an explicit key may take one of them and replaces its built-in action in the menu. An explicit key that an earlier entry already set falls back to the automatic shortcut. So does an arrow key, such as `Up` or `S-Up`, because `display-menu` does not run a shortcut on one.

Profile options have their own `@greenroom-profile-` prefix, so a profile may take any valid name, `root` and `send` included: `@greenroom-profile-root-key` is the shortcut of a `root` profile and leaves the plugin's `@greenroom-root-key` alone.

For example, to put the shell first and add Aider:

```tmux
set -g @greenroom-profiles 'shell | claude codex aider'
set -g @greenroom-profile-aider-cmd 'aider --no-auto-commits'
set -g @greenroom-profile-aider-key 'a'
set -g @greenroom-profile-codex-key 'x'
```

```
┌─ profiles ─┐
│ shell  (s) │
├────────────┤
│ claude (c) │
│ codex  (x) │
│ aider  (a) │
└────────────┘
```

| Key        | Action                               |
| ---------- | ------------------------------------ |
| `Enter`    | Start the highlighted profile        |
| shortcut   | Start the profile with that shortcut |
| `Esc`, `q` | Close the menu                       |

### Workspace menu

`prefix` + `G` lists the workspaces with their window count, and marks the current one with `*`. The chosen workspace replaces the one in the popup.

| Key     | Action                                           |
| ------- | ------------------------------------------------ |
| `1`-`9` | Switch to the workspace in that row              |
| `n`     | Create a workspace (prompts for a name)          |
| `r`     | Rename the current workspace                     |
| `x`     | Kill the current workspace, after a confirmation |

A new workspace starts one window of the `@greenroom-default` profile in the directory of the current workspace. Characters other than letters, digits, `_`, and `-` in a workspace name are replaced with `_`, for new and renamed workspaces and for `@greenroom-workspace`. Renaming with tmux's own `prefix` + `$` skips this; a name with `.` or `:` then cannot be picked as the last workspace.

### Popup size

`prefix` + `z` inside the popup toggles large mode. The popup then takes `@greenroom-large-width` by `@greenroom-large-height` of the terminal, 95% by 95% by default: almost the whole screen, but its border and a margin of the host stay visible, so it still reads as a popup. On a terminal of 20 rows or fewer, 95% leaves a single spare row, so the top border reaches the first row. Press `prefix` + `z` again to go back.

To grow and shrink the popup in steps, use the [command menu](#command-menu), or give the other size actions a key. They have none by default:

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
- The popup closes and opens again at the new size on the same workspace. Its windows keep running and see only a resize.
- The size stays until you reset it or the host tmux server restarts. Closing the popup, reloading the config, and sending text to the popup keep it. It is one setting for the host server: a popup on another client takes it the next time it opens.
- `prefix` + `z` replaces tmux's own zoom key inside the popup. Set `@greenroom-large-key` to another key, or to `''` to leave large mode without a key; `prefix` + `z` zooms again from the next open.
- The size keys do nothing in a client attached to the greenroom server directly, such as `tmux -L greenroom attach`, because it shows no popup.

### Command menu

`prefix` + `M` inside the popup opens the command menu, which puts the popup actions in one list. `@greenroom-commands` names its entries, in order. With the default list, `profiles workspaces | large grow shrink reset | hide`, it looks like this:

```
┌─── commands ────┐
│ Profiles    (c) │
│ Workspaces  (w) │
├─────────────────┤
│ Large popup (z) │
│ Grow        (+) │
│ Shrink      (-) │
│ Reset size  (=) │
├─────────────────┤
│ Hide popup  (h) │
└─────────────────┘
```

The built-in commands:

| Id                 | Label            | Key | Action                                                |
| ------------------ | ---------------- | --- | ----------------------------------------------------- |
| `profiles`         | Profiles         | `c` | Open the profile menu                                 |
| `workspaces`       | Workspaces       | `w` | Open the workspace menu                               |
| `large`            | Large popup      | `z` | Toggle large mode                                     |
| `grow`             | Grow             | `+` | Grow the popup by one step                            |
| `shrink`           | Shrink           | `-` | Shrink the popup by one step                          |
| `reset`            | Reset size       | `=` | Go back to `@greenroom-width` and `@greenroom-height` |
| `hide`             | Hide popup       | `h` | Close the popup (its windows keep running)            |
| `new-workspace`    | New workspace    | `n` | Create a workspace (prompts for a name)               |
| `rename-workspace` | Rename workspace | `r` | Rename the current workspace                          |
| `kill-workspace`   | Kill workspace   | `x` | Kill the current workspace, after a confirmation      |
| `kill-window`      | Kill window      | `X` | Kill the current window, after a confirmation         |

Each command acts on the popup that opened the menu: its workspace, its window, and its size. The workspace commands use the prompts of the workspace menu.

Shrink stops before the popup gets too short to show the command menu, because tmux does not draw a menu taller than the popup. If the popup is too short for the menu anyway, for example after the terminal got smaller, `prefix` + `z` makes it large and the menu opens again.

- The list follows the rules of `@greenroom-profiles`: an id is made of letters, digits, `_`, and `-`, other words are skipped, an id listed twice appears once, and `|` draws a separator line, dropped at either end of the list or next to another `|`.
- An empty list, or one of separators only, shows a disabled `no commands configured` entry.
- Any other id runs `@greenroom-command-<id>-run`, a tmux command, in the greenroom server. It runs as a key binding in the popup would, on the client and the current pane of the popup. Without that option the entry shows as a disabled `<id> (not defined)`. A built-in id ignores the option.
- tmux expands formats in the command when it draws the menu, as in any `display-menu` entry: `#{pane_current_path}` is the path of the current pane, and a literal `#` must be written `##`.
- `@greenroom-command-<id>-label` sets the label of an entry. An id that is not built in is its own label by default.
- `@greenroom-command-<id>-key` sets the shortcut of an entry. The keys in the table count as explicit keys too. Shortcuts follow the rules of the profile menu: the first entry to claim a key gets it, and an entry without a key, or whose key an earlier entry took or is an arrow key, gets the first lowercase letter or digit of its id that is free and not `q`, `j`, `k`, `g`, or `G`.

For example, to put the workspace menu first, drop grow, shrink, and reset, and add a command that splits the current window:

```tmux
set -g @greenroom-commands 'workspaces profiles | split kill-window | large hide'
set -g @greenroom-command-split-run 'split-window -h'
set -g @greenroom-command-split-label 'Split pane'
set -g @greenroom-command-large-label 'Toggle large'
```

```
┌──── commands ────┐
│ Workspaces   (w) │
│ Profiles     (c) │
├──────────────────┤
│ Split pane   (s) │
│ Kill window  (X) │
├──────────────────┤
│ Toggle large (z) │
│ Hide popup   (h) │
└──────────────────┘
```

Every command option ends in `-label`, `-key`, or `-run`, so the options of two ids never share a name, even when an id contains `-`.

`prefix` + `M` replaces tmux's own key that clears the marked pane (`select-pane -M`) inside the popup. Set `@greenroom-commands-key` to another key, or to `''` for no key; `prefix` + `M` gets its tmux binding back from the next open.

### Lifetime

- A window closes when its command exits with status 0.
- When the command exits with any other status, including a command that is not found, the window prints the status and waits. It closes on the next key press, so you can read the error first.
- When the last window of a workspace closes, the workspace closes and the popup closes with it. It does not jump to another workspace.
- When the last workspace closes, the greenroom server exits.

### Sending text to the popup

Hand an error message or a log to an agent without copying and pasting by hand:

- In copy mode, select the text and press `a`.
- Or press `prefix` + `S` to send everything the pane shows.

The text goes into the active pane of the last workspace, such as the prompt of an agent, and the popup opens on it. It is pasted as one block and Enter is not pressed, so you can add your question before sending. If no workspace exists yet, one is started and the text is pasted once its first window has drawn its prompt.

Sending does not touch your paste buffers or the clipboard.

### Bell alerts

A window that rings the terminal bell while you cannot see it, because the popup is closed or shows another window, raises an alert on the host:

- A `display-message` on every host client, such as `greenroom: claude@main rang the bell`.
- The host option `@greenroom_alert`, which lists the windows with an unseen bell as `window@workspace`, separated by spaces. Opening the popup on a window clears its entry.
- Inside the popup, the window list marks those windows with `!`.

The plugin adds nothing to make an agent ring the bell. Configure your agent CLI to do it, for example from a hook that runs when it finishes or needs input. The greenroom server always uses `bell-action any`, so a bell from the window a closed popup was showing still counts.

To show the alert in the host status line, add this to `~/.tmux.conf` after the plugin is loaded. It renders nothing while there is no alert, or when the plugin is not installed, and the guard keeps a config reload from adding it twice:

```tmux
if-shell -F '#{m:*greenroom_alert*,#{status-right}}' '' "set -ga status-right '#{?@greenroom_alert,#[fg=black#,bg=yellow#,bold] #{@greenroom_alert} #[default],}'"
```

### Shift+Enter

Shift+Enter reaches the program in the popup if your host tmux has `extended-keys on`. The greenroom server copies the host value when it starts.

## Options

| Option                          | Default                                                  | Description                                                           |
| ------------------------------- | -------------------------------------------------------- | --------------------------------------------------------------------- |
| `@greenroom-key`                | `g`                                                      | Key that opens and closes the popup                                   |
| `@greenroom-root-key`           | empty                                                    | Key that opens and closes the popup without the prefix, such as `M-g` |
| `@greenroom-workspaces-key`     | `G`                                                      | Key for the workspace menu, on the host and inside the popup          |
| `@greenroom-profiles-key`       | `c`                                                      | Key for the profile menu inside the popup                             |
| `@greenroom-commands-key`       | `M`                                                      | Key for the command menu inside the popup; `''` for none              |
| `@greenroom-send-key`           | `a`                                                      | Copy-mode key that sends the selection to the popup                   |
| `@greenroom-send-pane-key`      | `S`                                                      | Key that sends the visible screen of the pane to the popup            |
| `@greenroom-large-key`          | `z`                                                      | Key inside the popup that toggles large mode; `''` for none           |
| `@greenroom-grow-key`           | empty                                                    | Key inside the popup that grows it by one step                        |
| `@greenroom-shrink-key`         | empty                                                    | Key inside the popup that shrinks it by one step                      |
| `@greenroom-reset-key`          | empty                                                    | Key inside the popup that goes back to the size options               |
| `@greenroom-profiles`           | `claude codex gemini opencode \| shell`                  | Profile menu entries, in order                                        |
| `@greenroom-profile-<name>-cmd` | `<name>`                                                 | Command that starts the profile called `<name>`                       |
| `@greenroom-profile-<name>-key` | automatic                                                | Shortcut of the profile called `<name>` in the profile menu           |
| `@greenroom-commands`           | `profiles workspaces \| large grow shrink reset \| hide` | Command menu entries, in order                                        |
| `@greenroom-command-<id>-label` | built-in label, or `<id>`                                | Label of the command `<id>` in the command menu                       |
| `@greenroom-command-<id>-key`   | built-in key, or automatic                               | Shortcut of the command `<id>` in the command menu                    |
| `@greenroom-command-<id>-run`   | empty                                                    | tmux command of the command `<id>`, if it is not built in             |
| `@greenroom-default`            | `claude`                                                 | Profile of the first window of a new workspace                        |
| `@greenroom-workspace`          | `main`                                                   | Workspace to open when there is no last workspace                     |
| `@greenroom-width`              | `80%`                                                    | Popup width                                                           |
| `@greenroom-height`             | `80%`                                                    | Popup height                                                          |
| `@greenroom-large-width`        | `95%`                                                    | Popup width in large mode                                             |
| `@greenroom-large-height`       | `95%`                                                    | Popup height in large mode                                            |
| `@greenroom-resize-step`        | `10`                                                     | Percentage points that grow and shrink change the size by             |
| `@greenroom-x`                  | `C`                                                      | Popup horizontal position                                             |
| `@greenroom-y`                  | `C`                                                      | Popup vertical position                                               |
| `@greenroom-border-lines`       | `rounded`                                                | Popup border, a `popup-border-lines` value                            |
| `@greenroom-socket`             | `greenroom`                                              | Socket name of the greenroom server (`tmux -L`)                       |
| `@greenroom-config`             | empty                                                    | Extra config file for the greenroom server                            |

A profile name may contain letters, digits, `_`, and `-`. The command runs through `$SHELL -lc`, so it can carry arguments and environment assignments, and the `PATH` that your login shell sets up applies. `@greenroom-default` may name any profile, listed in `@greenroom-profiles` or not. See [Profile menu](#profile-menu) for the list syntax and `shell`.

```tmux
set -g @greenroom-key 'a'
set -g @greenroom-root-key 'M-a'
set -g @greenroom-width '90%'
set -g @greenroom-profile-claude-cmd 'claude --model opus'
set -g @greenroom-profiles 'claude codex aider | shell'
set -g @greenroom-profile-aider-cmd 'aider --no-auto-commits'
```

The host keys (`@greenroom-key`, `@greenroom-root-key`, `@greenroom-workspaces-key`, `@greenroom-send-key`, `@greenroom-send-pane-key`) are read when the plugin loads, so reload your config after changing them. The old keys are unbound on reload. The other options, the popup size and position included, are read on every open. A key that the plugin stops using inside the popup is unbound; `c`, `M`, `z`, `-`, and `=` get tmux's own binding back, and other keys get theirs back when the greenroom server restarts.

## Customizing the greenroom server

The greenroom server does not read your `tmux.conf`. Reading it would run TPM again inside the greenroom server, and plugins such as tmux-continuum could overwrite your saved host state. It reads `conf/greenroom-server.conf` from the plugin, then the file named by `@greenroom-config`, once when it starts.

Use that file for the status line, colors, and plugins you want inside the popup. For example, to load tmux-cuecard in the popup:

```tmux
set -g @greenroom-config '~/.tmux/greenroom.conf'
```

```tmux
# ~/.tmux/greenroom.conf
run-shell ~/.tmux/plugins/tmux-cuecard/cuecard.tmux
```

What the greenroom server takes from the host:

- On every open: `prefix`, `prefix2`, and every `@greenroom-*` option. Removing an option on the host removes it from the greenroom server too.
- Once, when the greenroom server starts: `default-terminal`, `history-limit`, `mouse`, `mode-keys`, `status-keys`, `base-index`, `pane-base-index`, `escape-time`, `extended-keys`, and `set-clipboard`.

To apply a change to the second group, restart the greenroom server:

```bash
tmux -L greenroom kill-server
```

This also ends every window in it. If you changed `@greenroom-socket`, use that name instead.

## State

The plugin writes no files. Workspaces, their windows, and the last-used workspace live in the memory of the greenroom server. The popup size lives in the memory of the host server.

- Closing the popup keeps everything.
- Restarting or killing the host tmux server keeps everything but the popup size. The next host server that loads the plugin opens the same workspaces.
- Stopping the greenroom server, or rebooting, ends every window. Use the resume feature of your agent CLI, such as `claude --continue`, to pick up a conversation.
- Each greenroom server socket is separate. A host that sets a different `@greenroom-socket` sees different workspaces.

## Known limitations

- Two clients showing the same workspace at different popup sizes resize the window back and forth, following whichever client was used last (`window-size latest`).
- The greenroom server has one global `prefix` and one origin directory per workspace. When two host servers with different settings share it, the host that opened the popup last wins.
- Paste buffers are per server. On tmux 3.7 and later with `set-clipboard on`, a copy inside the popup still reaches the system clipboard through OSC 52, and the host stores it as a paste buffer too, so `prefix` + `]` on the host pastes it. On tmux 3.4 to 3.6 it stays inside the greenroom server.
- Bell alerts go to the host server that opened the popup last. So do the size keys: in a popup of another host server they do nothing.
- A size key closes and opens the popup, which takes about a quarter of a second. Keys typed meanwhile reach the popup, but size keys pressed faster than that can lose a step.
- An upgrade of the plugin takes full effect after the greenroom server restarts, because `conf/greenroom-server.conf` is read only at start.

## Development

`tests/run.sh` runs the integration tests. Each run starts its own tmux servers on unique sockets and never touches your running servers. Pass part of a test name to run only matching tests.

```bash
tests/run.sh
tests/run.sh workspace
BASH_COMPAT=3.2 tests/run.sh
```

## License

[MIT](LICENSE)
