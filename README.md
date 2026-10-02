# tmux-greenroom

A green room is where performers wait off stage, ready and still in costume, until they are called. tmux-greenroom gives your AI coding agents one: a dedicated tmux server where Claude Code, Codex, Gemini CLI, OpenCode, a shell or any other command keeps running, and a popup that brings them on stage from any tmux session or window with `prefix` + `g`. Closing the popup only detaches; nobody in the green room notices that you left.

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

- Every session and window of your tmux opens the same popup, so the same agents are one key away wherever you are.
- The greenroom server holds workspaces (its sessions), and each workspace holds windows that run profiles: named commands such as `claude`, `codex` or `shell`.
- Menus start profiles, manage workspaces and collect every popup action in one list. The profile and command menus are ordered lists in your `tmux.conf`.
- The popup can go large, grow, shrink and reset without stopping what runs in it.
- A copy-mode selection or a whole pane screen can be sent to the agent in the popup.
- An agent that rings the terminal bell while you are not looking raises an alert on the host.

## Requirements

- tmux 3.4 or later. The plugin is tested on tmux 3.4 and 3.7b.
- bash 3.2 or later. The scripts avoid bash 4 features, and the tests also run with `BASH_COMPAT=3.2`.
- Nothing else at runtime. The agent CLIs are optional: a profile whose command is not installed reports exit status 127 in its window.

## Installation

### TPM installation

Add the plugin to `~/.tmux.conf`:

```tmux
set -g @plugin 'tot0rokr/tmux-greenroom'
```

Press `prefix` + `I` to install it. Put any `@greenroom-*` options above the line that runs TPM: the host keys are bound when the plugin loads, and every other option is read again each time the popup opens.

### Manual installation

```bash
git clone https://github.com/tot0rokr/tmux-greenroom ~/.tmux/plugins/tmux-greenroom
```

Add this line to `~/.tmux.conf`, below your `@greenroom-*` options:

```tmux
run-shell ~/.tmux/plugins/tmux-greenroom/greenroom.tmux
```

Reload the config with `tmux source-file ~/.tmux.conf`.

## Quick start

These keys cover the first day. `prefix` is your own prefix key; the greenroom server copies it from your tmux.

| Key            | Where          | What it does                                                                                         |
| -------------- | -------------- | ---------------------------------------------------------------------------------------------------- |
| `prefix` + `g` | host           | Open the popup. The first open starts the greenroom server, a workspace `main` and a `claude` window |
| `prefix` + `g` | popup          | Close the popup. Everything in it keeps running                                                      |
| `prefix` + `c` | popup          | Profile menu: start another agent or a shell in a new window                                         |
| `prefix` + `G` | host and popup | Workspace menu: switch, create, rename or kill workspaces                                            |
| `prefix` + `M` | popup          | Command menu: every popup action in one list                                                         |
| `prefix` + `z` | popup          | Toggle a large popup                                                                                 |

If Claude Code is not your lead, cast another profile before the first open:

```tmux
set -g @greenroom-default 'codex'
```

To hand an agent something from the host, select text in copy mode and press `a`, or press `prefix` + `S` to send what the current pane shows.

## Concepts

### Terms

| Term             | Meaning                                                                                           |
| ---------------- | ------------------------------------------------------------------------------------------------- |
| host server      | The tmux server you normally use, the one that loads the plugin                                   |
| greenroom server | A tmux server of its own, `tmux -L greenroom`, that runs the agents                               |
| popup            | A `display-popup` on a host client whose only process is a client of the greenroom server         |
| workspace        | A session of the greenroom server. A popup shows one workspace at a time                          |
| profile          | A named command, such as `claude`, `lazygit` or `shell`, listed in the profile menu               |
| window           | A window of a workspace. Each runs one profile and is named after it                              |
| origin           | The directory of the host pane that last opened the popup on a workspace. New windows start there |

Keep one workspace per project or task. New windows start in the origin of their workspace, so `prefix` + `c` in a workspace opened from `~/src/api` starts its new windows in `~/src/api`. Opening the popup from a pane in another directory moves the origin of the workspace it opens on; switching to a workspace from the workspace menu leaves its origin as it was.

### Lifetime

Closing the popup is an exit, not the end of the show. What each event keeps:

| Event                           | Workspaces and windows | Popup size |
| ------------------------------- | ---------------------- | ---------- |
| Closing the popup               | Kept                   | Kept       |
| Reloading the host config       | Kept                   | Kept       |
| Restarting the host tmux server | Kept                   | Reset      |
| The greenroom server stopping   | Ended                  | Kept       |
| Rebooting                       | Ended                  | Reset      |

- A window closes when its command exits with status 0.
- When the command exits with any other status, including 127 for a command that is not found, the window prints `[<profile> exited with status <N>. Press any key to close.]` and closes on the next key, so you can read the error first.
- When the last window of a workspace closes, the workspace closes and the popup closes with it. It does not jump to another workspace.
- When the last workspace closes, the greenroom server exits.
- The plugin writes no files. Workspaces, windows and the last-used workspace live in the memory of the greenroom server; the popup size lives in the memory of the host server.
- Running agents do not survive the greenroom server. To pick a conversation up again, use the resume feature of the CLI, for example `claude --continue`, which continues the most recent conversation in the current directory.
- A host that sets a different `@greenroom-socket` talks to a different greenroom server, with workspaces of its own.

## Keys

### Host keys

| Key                   | Action                                                     |
| --------------------- | ---------------------------------------------------------- |
| `prefix` + `g`        | Open the popup on the last workspace                       |
| `prefix` + `G`        | Open the popup with the workspace menu on top              |
| `prefix` + `S`        | Send the visible screen of the current pane to the popup   |
| `a` in copy mode      | Send the selection to the popup and leave copy mode        |
| `@greenroom-root-key` | Same as `prefix` + `g`, without the prefix (only when set) |

`a` works in both the emacs and the vi copy-mode tables. Stock tmux binds none of these keys. They are bound when the plugin loads, so reload the config after changing their options; the old keys are unbound on reload.

### Popup keys

While a popup is open, the host passes every key to it without looking at its own key tables. The greenroom server therefore uses your prefix as it is, and no key needs to be pressed twice.

| Key                          | Action                                                                    |
| ---------------------------- | ------------------------------------------------------------------------- |
| `prefix` + `g`               | Close the popup; its windows keep running                                 |
| `@greenroom-root-key`        | Close the popup (only when set); the key does not reach the pane          |
| `prefix` + `c`               | Profile menu                                                              |
| `prefix` + `G`               | Workspace menu                                                            |
| `prefix` + `M`               | Command menu                                                              |
| `prefix` + `z`               | Toggle large mode                                                         |
| `prefix` + `prefix`          | Send the prefix key to the pane                                           |
| `prefix` + `d`               | Close the popup (tmux default)                                            |
| `prefix` + `n`, `p`, `0`-`9` | Switch windows (tmux default)                                             |
| `prefix` + `&`               | Kill the current window, after a confirmation (tmux default)              |
| `prefix` + `s`, `w`          | Tree of the workspaces and their windows (tmux default)                   |
| `prefix` + `$`               | Rename the workspace, without the name cleanup of the menu (tmux default) |
| `prefix` + `[`               | Copy mode; copies go to the greenroom server's buffers (tmux default)     |

The grow, shrink and reset size keys are bound too once you give them a key; see [Popup size](#popup-size). Inside the popup, `c`, `M` and `z` replace tmux's `new-window`, `select-pane -M` and `resize-pane -Z`; each can be moved to another key, and `M` and `z` can be turned off. Bound as size keys, `-` and `=` replace `delete-buffer` and `choose-buffer`. When the plugin stops using one of these five keys, the key gets its tmux binding back from the next open; any other key the plugin stops using stays unbound until the greenroom server restarts.

The status line of the popup shows the workspace, its windows and two reminders. This is a workspace named `code_review` whose `codex` window rang the bell, with the prefix `C-b`:

```text
 code_review   0:claude   1:codex!                     C-b g hide  C-b M menu
```

### Menu keys

The three menus are tmux's own `display-menu`:

| Key                    | Action                        |
| ---------------------- | ----------------------------- |
| `Up`, `Down`, `k`, `j` | Move the highlight            |
| `g`, `G`               | Go to the first or last entry |
| `Enter`                | Run the highlighted entry     |
| shortcut               | Run the entry with that key   |
| `Esc`, `q`             | Close the menu                |

## Profiles

The profile list is the cast list. `prefix` + `c` inside the popup lists the profiles named in `@greenroom-profiles`, in that order, and starts the chosen one in a new window of the current workspace. With the default list, `claude codex gemini opencode | shell`, the menu looks like this:

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

### List syntax

- The list is a space-separated list of names. A name is made of letters, digits, `_` and `-`; other words are skipped.
- `|` draws a separator line. It must stand alone between spaces: `claude|codex` is one invalid word and is skipped as a whole.
- A `|` at either end of the list, or next to another `|`, is dropped. The same holds once skipped names are taken out: `claude | bad.name | codex` shows one separator.
- A name listed twice appears once, at its first place.
- An empty list, or one of separators only, shows a single disabled entry, `no profiles configured`. Unsetting the option brings back the default list.
- `shell` is an ordinary entry. It is not added for you: leave it out to drop it, or move it anywhere in the list.

### Profile commands

- A profile runs `@greenroom-profile-<name>-cmd`, or, without that option, the name itself as a command. `lazygit` in the list runs `lazygit` with no further setup.
- The command runs through `$SHELL -lc`, a login shell. It may carry arguments, environment assignments, pipes and `$variables`, and the `PATH` that your shell startup files set up applies.
- `shell` without a command option starts your login shell itself. It then closes on exit with any status, since no wrapper waits to report it.
- The window is named after the profile and starts in the workspace's origin.
- `@greenroom-default`, the profile of the first window of a new workspace, may name any profile, listed in the menu or not.
- Profile options have their own `@greenroom-profile-` prefix, so a profile may take any valid name, `root` and `send` included: `@greenroom-profile-root-key` is the shortcut of a `root` profile and leaves the plugin's `@greenroom-root-key` alone.

### Shortcuts

The profile menu and the command menu pick their shortcuts by the same rules:

- `@greenroom-profile-<name>-key` (`@greenroom-command-<id>-key` in the command menu) sets the shortcut of an entry to a tmux key name, such as `x`, `X`, `1`, `M-a` or `;`.
- Explicit keys are assigned first, in list order. A key that an earlier entry already took is ignored for the later entry, which falls back to an automatic shortcut.
- Arrow keys, such as `Up`, `left` or `S-Up`, are ignored as shortcuts, because `display-menu` does not run them as shortcuts on every tmux version.
- An entry without a usable explicit key gets the first lowercase letter or digit of its name (its id, in the command menu) that no other entry claims. That choice skips `q`, `j`, `k`, `g` and `G`, which `display-menu` uses itself, and never takes a key that a later entry claims explicitly.
- An explicit key may be one of those menu keys; it then replaces the menu's own action for that key.
- An entry whose name has no free character gets no shortcut. `Enter` still runs it.

### Examples

To add a profile that resumes the last Claude Code conversation in the workspace's directory, and to add `lazygit` next to the shell:

```tmux
set -g @greenroom-profiles 'claude claude-resume codex | lazygit shell'
set -g @greenroom-profile-claude-resume-cmd 'claude --continue'
set -g @greenroom-profile-claude-resume-key 'r'
```

```
┌──── profiles ─────┐
│ claude        (c) │
│ claude-resume (r) │
│ codex         (o) │
├───────────────────┤
│ lazygit       (l) │
│ shell         (s) │
└───────────────────┘
```

Without the explicit `r`, `claude-resume` would get `l`, the first letter of its name that `claude` had not taken, and `lazygit` would fall back to `a`.

A command is shell text, so a profile can be a small script. Add `notes` to `@greenroom-profiles` to see this one in the menu:

```tmux
set -g @greenroom-profile-notes-cmd '${EDITOR:-vi} ~/notes/todo.md'
```

## Workspaces

`prefix` + `G`, on the host or inside the popup, opens the workspace menu. It lists the workspaces with their window counts, marks the one the popup shows with `*`, and gives the first nine the shortcuts `1` to `9`. Choosing one switches the popup to it.

```
┌───── workspaces ──────┐
│ code_review (1) * (1) │
│ main (1)          (2) │
├───────────────────────┤
│ New workspace     (n) │
│ Rename workspace  (r) │
│ Kill workspace    (x) │
└───────────────────────┘
```

| Key     | Action                                                                                                   |
| ------- | -------------------------------------------------------------------------------------------------------- |
| `1`-`9` | Switch to the workspace in that row                                                                      |
| `n`     | Prompt `new workspace:`, then create the workspace and switch to it, or just switch if it already exists |
| `r`     | Prompt `rename workspace:` with the current name filled in                                               |
| `x`     | Ask `kill workspace <name>? (y/n)`, then kill the workspace the popup shows                              |

- A new workspace starts one window of `@greenroom-default` in the origin of the workspace the popup was showing.
- Killing the workspace the popup shows closes the popup. The other workspaces keep running.
- Every action works on the popup that opened the menu, even when several host clients show popups at once.
- In workspace names, characters other than letters, digits, `_` and `-` become `_`: `code review` becomes `code_review`. This applies to new and renamed workspaces and to `@greenroom-workspace`.
- tmux's own `prefix` + `$` skips that cleanup. tmux 3.4 replaces `.` and `:` in session names by itself, but tmux 3.7b keeps them, and a workspace with such a name cannot be found by name. The popup then skips it when it picks the last workspace. Switch to it from the workspace menu and rename it there.
- If no other workspace can be picked first, because it is the only one, or `@greenroom-workspace` does not exist and it comes first in `list-sessions`, `prefix` + `g` and `prefix` + `G` fail with `could not prepare workspace <name>`. Rename it by its session ID from a shell instead:

```bash
tmux -L greenroom list-sessions -F '#{session_id} #{session_name}'
tmux -L greenroom rename-session -t '$0' new_name
```

When the popup opens, it picks the workspace in this order:

1. The workspace that any popup showed last, if it still exists.
2. `@greenroom-workspace` (default `main`), if it exists.
3. Any other workspace.
4. A new workspace named `@greenroom-workspace`, with one window of `@greenroom-default`.

## Command menu

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

The list follows the syntax of `@greenroom-profiles`: ids made of letters, digits, `_` and `-`, `|` for a separator, repeats and invalid words skipped. An empty list, or one of separators only, shows a disabled `no commands configured` entry.

### Built-in commands

| Id                 | Label            | Key | Action                                                     |
| ------------------ | ---------------- | --- | ---------------------------------------------------------- |
| `profiles`         | Profiles         | `c` | Open the profile menu                                      |
| `workspaces`       | Workspaces       | `w` | Open the workspace menu                                    |
| `large`            | Large popup      | `z` | Toggle large mode                                          |
| `grow`             | Grow             | `+` | Grow the popup by one step                                 |
| `shrink`           | Shrink           | `-` | Shrink the popup by one step, while the menu still fits    |
| `reset`            | Reset size       | `=` | Leave large mode and go back to the size options           |
| `hide`             | Hide popup       | `h` | Close the popup; its windows keep running                  |
| `new-workspace`    | New workspace    | `n` | Prompt for a name and create a workspace                   |
| `rename-workspace` | Rename workspace | `r` | Rename the current workspace                               |
| `kill-workspace`   | Kill workspace   | `x` | Kill the current workspace, after a confirmation           |
| `kill-window`      | Kill window      | `X` | Kill the current window, after `kill window <name>? (y/n)` |

- Each command acts on the popup that opened the menu: its workspace, its current window and its size.
- The workspace commands use the prompts of the workspace menu.
- The default keys in the table count as explicit keys under the [shortcut rules](#shortcuts): the first entry in the list that claims a key gets it.
- Shrink stops before the popup gets too short to draw the command menu, because tmux draws no menu taller than the popup. If the popup is too short for the menu anyway, for example after the terminal got smaller, `prefix` + `z` makes it large and the menu opens again.

### Custom commands

Any id that is not built in is a custom command:

- `@greenroom-command-<id>-run` is a tmux command, not a shell command; wrap a shell command in `run-shell`. It runs in the greenroom server as a key binding in the popup would, with the popup's client and current pane as the target. Without this option the entry shows as a disabled `<id> (not defined)` and takes no shortcut. A built-in id ignores the option.
- tmux expands formats in the `-run` value when it draws the menu, as in any `display-menu` entry. `#{pane_current_path}` becomes the path of the current pane, and a literal `#` must be written `##`.
- `@greenroom-command-<id>-label` sets the label of any entry, built-in or not. A custom id is its own label by default. Labels are shown as written, `#` included.
- `@greenroom-command-<id>-key` sets the shortcut of any entry. Without it, a custom entry gets an automatic shortcut from its id.
- Every command option ends in `-label`, `-key` or `-run`, so the options of two ids never share a name, even when an id contains `-`.
- The menu is built when the popup opens. Changes to these options apply from the next open.

### Example

To add the New workspace and Kill window commands, drop grow and shrink, and add a split with lazygit and a canned request for the agent:

```tmux
set -g @greenroom-commands 'profiles workspaces | new-workspace kill-window | large reset | lazygit tests hide'
set -g @greenroom-command-large-label 'Toggle large'
set -g @greenroom-command-lazygit-label 'lazygit in a split'
set -g @greenroom-command-lazygit-run 'split-window -h -c "#{pane_current_path}" lazygit'
set -g @greenroom-command-tests-label 'Ask for tests'
set -g @greenroom-command-tests-run 'send-keys -l "Write tests for issue ##42."'
```

```
┌─────── commands ───────┐
│ Profiles           (c) │
│ Workspaces         (w) │
├────────────────────────┤
│ New workspace      (n) │
│ Kill window        (X) │
├────────────────────────┤
│ Toggle large       (z) │
│ Reset size         (=) │
├────────────────────────┤
│ lazygit in a split (l) │
│ Ask for tests      (t) │
│ Hide popup         (h) │
└────────────────────────┘
```

`Ask for tests` types `Write tests for issue #42.` into the current pane, such as the agent's prompt, without pressing Enter. For prompts you want to keep and send later, the sibling plugin [tmux-cuecard](https://github.com/tot0rokr/tmux-cuecard) keeps them on cue cards.

To free `prefix` + `M`, set `@greenroom-commands-key` to another key, or to `''` for no key; see [Popup keys](#popup-keys) for what a freed key does.

## Popup size

`prefix` + `z` inside the popup toggles large mode. The popup then takes `@greenroom-large-width` by `@greenroom-large-height` of the terminal, 95% by 95% by default: almost the whole screen, with its border and a margin of the host still visible. Press `prefix` + `z` again to go back.

To grow and shrink the popup in steps, use the command menu, or give the size actions keys. They have none by default:

```tmux
set -g @greenroom-grow-key '+'
set -g @greenroom-shrink-key '-'
set -g @greenroom-reset-key '='
```

| Key                                | Action                                                  |
| ---------------------------------- | ------------------------------------------------------- |
| `prefix` + `z`                     | Toggle large mode (`@greenroom-large-key`)              |
| `prefix` + `@greenroom-grow-key`   | Grow the normal size by one step and leave large mode   |
| `prefix` + `@greenroom-shrink-key` | Shrink the normal size by one step and leave large mode |
| `prefix` + `@greenroom-reset-key`  | Leave large mode and go back to the size options        |

- A step changes the width and the height by `@greenroom-resize-step` percentage points, 10 by default. Each dimension stops at 20% and at 95%.
- Grow and shrink always step the normal size, even from large mode. From an 80% popup in large mode, grow gives 90%, which is smaller than large.
- A size in cells, such as `@greenroom-width 120`, is turned into a percentage of the terminal that shows the popup before the first step.
- Percentages count the whole terminal, the host status line included.
- When `@greenroom-y` is `C`, the default, the plugin centers the popup on the whole terminal itself, with an odd spare row going below, so a 95% popup keeps a margin at the top. On a terminal of 20 rows or fewer, 95% leaves a single spare row, and the top border reaches the first row.
- A size change closes the popup and opens it again at the new size on the same workspace, in a single host command, so the host pane does not show through. The windows keep running and see only a resize. Keys typed meanwhile reach the new popup.
- A size action that would change nothing, such as grow at 95%, does not reopen the popup.
- The size is stored on the host server, as `@greenroom_size_large`, `@greenroom_size_width` and `@greenroom_size_height`. It is one setting for the host server: a popup on another client takes it the next time it opens.
- The stored size stays until you reset it or the host server restarts. Closing the popup, reloading the config, the workspace menu key and sending text all keep it. While a grown or shrunk size is stored, it wins over `@greenroom-width` and `@greenroom-height`.
- To free `prefix` + `z`, set `@greenroom-large-key` to another key, or to `''` for no key; see [Popup keys](#popup-keys) for what a freed key does.

## Sending text to the popup

To give an agent its cue without retyping it, select text in copy mode and press `a`, or press `prefix` + `S` for the visible screen of the current pane. The popup opens on the last workspace, at the current size, and the text goes into its active pane, such as the prompt of an agent.

- The text is pasted as one block, as a bracketed paste when the program asked for one. Enter is not pressed, so you can add your question first.
- `prefix` + `S` sends the visible screen, with wrapped lines joined and trailing spaces removed.
- Text that is empty or all whitespace sends nothing, and the popup does not open.
- If the workspace has to be created first, the plugin waits until its first window has drawn something and stopped changing (checked every 0.3 seconds, for up to 10 seconds), then pastes.
- Sending does not copy: your paste buffers are left as they were. The text travels through a temporary buffer, `greenroom_send`, which is deleted on the way.

## Bell alerts

An agent in the green room cannot call you; it can only ring the terminal bell, and the plugin carries the news to the host. A window that rings the bell while nobody is looking at it, because the popup is closed or shows another window, raises an alert on the host server that opened a popup last:

- A message on each of its clients, such as `greenroom: claude@main rang the bell`.
- The host option `@greenroom_alert`, which lists the windows with an unseen bell as `window@workspace`, separated by spaces. Looking at a window in the popup removes its entry; the option is unset when the list is empty.
- Inside the popup, the window list marks those windows with `!`.

A bell in the window you are looking at is not an alert. The plugin does not make an agent ring the bell; the agent CLI must ring the terminal bell when it finishes or needs input. The greenroom server always uses `bell-action any`, so a bell from the window that a closed popup was showing still counts.

To check the plugin side before you set up an agent CLI, open a `shell` window in the `main` workspace from the profile menu, run `sleep 5; printf '\a'` in it, and close the popup with `prefix` + `g` at once. About five seconds later the host shows `greenroom: shell@main rang the bell`, and `tmux show-option -gv @greenroom_alert` prints `shell@main`.

To show the alert in the host status line, add this to `~/.tmux.conf` below the line that runs TPM, so that a theme setting `status-right` does not replace it. It renders nothing while there is no alert, or when the plugin is not installed, and the guard keeps a config reload from adding it twice:

```tmux
if-shell -F '#{m:*greenroom_alert*,#{status-right}}' '' "set -ga status-right '#{?@greenroom_alert,#[fg=black#,bg=yellow#,bold] #{@greenroom_alert} #[default],}'"
```

With an alert, it renders as ` claude@main ` in bold black on yellow.

## Customizing the greenroom server

The greenroom server does not read your `tmux.conf`. Reading it would run TPM again inside the greenroom server, and plugins such as tmux-continuum could overwrite your saved host state with the greenroom server's. When it starts, it reads `conf/greenroom-server.conf` from the plugin, then the file named by `@greenroom-config`. A `~` at the start of that path is expanded, and an error in the file does not stop the popup from opening. Mind the kind of error, though: a command that fails when it runs (an unknown option, say) skips only its own line, while one tmux cannot parse (an unknown command) skips the whole file.

Use that file for the status line, colors, bindings of other keys and plugins you want inside the popup. Plugins load with `run-shell`, for example tmux-cuecard:

```tmux
set -g @greenroom-config '~/.tmux/greenroom.conf'
```

```tmux
# ~/.tmux/greenroom.conf
set -g status-style 'bg=colour236'
run-shell ~/.tmux/plugins/tmux-cuecard/cuecard.tmux
```

`conf/greenroom-server.conf` sets the status line, `detach-on-destroy on`, which closes the popup with the last window of its workspace, and `terminal-features` for colors, Shift+Enter and OSC 52. If you replace `window-status-format`, keep `#{?window_bell_flag,!,}` for the bell marker. The default `status-right` shows the close key and the command menu key with `#{@greenroom_key}` and `#{@greenroom_commands_key}`. A status line of your own can use those two and also `#{@greenroom_profiles_key}` and `#{@greenroom_workspaces_key}`; the plugin sets all four on every open, so they always hold the current keys.

What the greenroom server takes from the host:

- On every open: `prefix` and `prefix2`, and every `@greenroom-*` option. The copy is replaced as a whole, so an option removed on the host disappears from the greenroom server too.
- Once, when the greenroom server starts: `default-terminal`, `history-limit`, `mouse`, `mode-keys`, `status-keys`, `base-index`, `pane-base-index`, `escape-time`, `extended-keys` and `set-clipboard`.

The host's values win over the same options in `@greenroom-config`, because they are applied after the file is read. Set those options on the host, or change them in the running greenroom server, for example `tmux -L greenroom set -g mouse on`.

The plugin also sets, on every open, the bindings of its own keys, `bell-action any` and its hooks: the ones that keep `@greenroom_last`, the last workspace, up to date at hook array slot 100, and the alert hooks at slot 101. A `set-hook` without an index replaces every slot of that hook, the plugin's included; the plugin puts its own back on the next open, but your hook then shares the array with them only if it has an index of its own. Give your hooks an index below 100, such as `set-hook -g client-attached[0] 'display-message hello'`. `set-hook -ga` also leaves the plugin's slots alone, but adds the hook once more each time the file is sourced.

To apply an edited `@greenroom-config` to the running server, source it there:

```bash
tmux -L greenroom source-file ~/.tmux/greenroom.conf
```

To start from scratch, for example after changing one of the host options copied once at start, restart the greenroom server. This **ends every window** in it:

```bash
tmux -L greenroom kill-server
```

If you changed `@greenroom-socket`, use that name instead of `greenroom`.

## Options reference

Options whose names start with `@greenroom-` are yours. The plugin keeps its state in options that start with `@greenroom_`, such as `@greenroom_alert` and `@greenroom_size_width`; leave those alone. The host keys are read when the plugin loads, `@greenroom-config` when the greenroom server starts, and everything else on every open (`@greenroom-resize-step` when a size key runs).

### Key options

| Option                      | Default | Bound in | Key for                                                  |
| --------------------------- | ------- | -------- | -------------------------------------------------------- |
| `@greenroom-key`            | `g`     | both     | Opening the popup on the host and closing it inside      |
| `@greenroom-root-key`       | none    | both     | The same without the prefix (root table), such as `M-g`  |
| `@greenroom-workspaces-key` | `G`     | both     | The workspace menu; on the host it opens the popup first |
| `@greenroom-send-key`       | `a`     | host     | Sending the copy-mode selection (both copy-mode tables)  |
| `@greenroom-send-pane-key`  | `S`     | host     | Sending the visible screen of the current pane           |
| `@greenroom-profiles-key`   | `c`     | popup    | The profile menu                                         |
| `@greenroom-commands-key`   | `M`     | popup    | The command menu; `''` binds no key                      |
| `@greenroom-large-key`      | `z`     | popup    | Toggling large mode; `''` binds no key                   |
| `@greenroom-grow-key`       | none    | popup    | Growing the popup by one step                            |
| `@greenroom-shrink-key`     | none    | popup    | Shrinking the popup by one step                          |
| `@greenroom-reset-key`      | none    | popup    | Going back to the size options                           |

An empty value means the default for `@greenroom-key`, `@greenroom-workspaces-key`, `@greenroom-profiles-key`, `@greenroom-send-key` and `@greenroom-send-pane-key`, and no key for the others.

### Menu options

| Option                          | Default                                                  | Description                                                              |
| ------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------ |
| `@greenroom-profiles`           | `claude codex gemini opencode \| shell`                  | Profile menu entries, in order                                           |
| `@greenroom-profile-<name>-cmd` | the name                                                 | Shell command of the profile; `shell` without it starts your login shell |
| `@greenroom-profile-<name>-key` | automatic                                                | Shortcut of the profile in the profile menu                              |
| `@greenroom-commands`           | `profiles workspaces \| large grow shrink reset \| hide` | Command menu entries, in order                                           |
| `@greenroom-command-<id>-label` | built-in label, or the id                                | Label of the entry                                                       |
| `@greenroom-command-<id>-key`   | built-in key, or automatic                               | Shortcut of the entry                                                    |
| `@greenroom-command-<id>-run`   | none                                                     | tmux command of a custom entry; ignored for built-in ids                 |

### Size and position options

| Option                    | Default   | Description                                                             |
| ------------------------- | --------- | ----------------------------------------------------------------------- |
| `@greenroom-width`        | `80%`     | Popup width, in cells or as a percentage of the terminal                |
| `@greenroom-height`       | `80%`     | Popup height, in cells or as a percentage of the terminal               |
| `@greenroom-large-width`  | `95%`     | Popup width in large mode                                               |
| `@greenroom-large-height` | `95%`     | Popup height in large mode                                              |
| `@greenroom-resize-step`  | `10`      | Percentage points that grow and shrink change the size by               |
| `@greenroom-x`            | `C`       | Horizontal position, a `display-popup -x` value                         |
| `@greenroom-y`            | `C`       | Vertical position, a `display-popup -y` value; `C` centers the popup    |
| `@greenroom-border-lines` | `rounded` | Popup border, a `popup-border-lines` value such as `single` or `double` |

### Workspace and server options

| Option                 | Default     | Description                                                                 |
| ---------------------- | ----------- | --------------------------------------------------------------------------- |
| `@greenroom-default`   | `claude`    | Profile of the first window of a new workspace; need not be in the menu     |
| `@greenroom-workspace` | `main`      | Workspace to open when the last one is gone, and to create when none exists |
| `@greenroom-socket`    | `greenroom` | Socket name of the greenroom server (`tmux -L`)                             |
| `@greenroom-config`    | none        | Extra config file that the greenroom server reads when it starts            |

## Troubleshooting

- A changed host key does nothing: the host keys are bound when the plugin loads. Reload the config with `tmux source-file ~/.tmux.conf`.
- `prefix` + `z`, `c` or `M` inside the popup no longer does what tmux does: the plugin uses them. Move them with `@greenroom-large-key`, `@greenroom-profiles-key` or `@greenroom-commands-key`; see [Popup keys](#popup-keys) for what a freed key does.
- The first window says `claude exited with status 127`: Claude Code is not installed, or not on the `PATH` of a login shell. Set `@greenroom-default` to another profile, or give `@greenroom-profile-claude-cmd` a full path. The key that closes the message also closes the window and, if it was the only one, the workspace and the popup.
- Shift+Enter arrives as a plain Enter: the host needs `extended-keys on` when the greenroom server starts, since the value is copied only then. Set it on the host and restart the greenroom server.
- `mouse`, `history-limit` or another of the copied options in `@greenroom-config` has no effect: the host's value wins. See [Customizing the greenroom server](#customizing-the-greenroom-server).
- `@greenroom-width` seems ignored: a size from grow or shrink is stored and wins. Reset it with the command menu's Reset size or `@greenroom-reset-key`.
- A size key does nothing: the popup is at the 20% or 95% limit, the command menu's Shrink stopped to keep the menu drawable, the client is attached to the greenroom server directly, or the popup belongs to another host server than the one that opened a popup last.
- The command menu does not open: the popup is shorter than the menu. Press `prefix` + `z` for a large popup and try again.
- No bell alert appears: the agent CLI must ring the terminal bell, a bell in the window you are looking at does not count, and the alert goes to the host server that opened a popup last. [Bell alerts](#bell-alerts) shows how to check the plugin side with a shell window.
- The popup shows `could not prepare workspace <name>`: on tmux 3.7b, a workspace that `prefix` + `$` renamed to a name with `.` or `:` cannot be found by name. Rename it by its session ID as shown in [Workspaces](#workspaces).
- A change to a menu list or a command option does not show: menus are built when the popup opens. Close it and open it again.

## Known limitations

- Two clients that show the same workspace at different popup sizes resize its windows back and forth, following whichever client was used last (`window-size latest`).
- The greenroom server has one `prefix` and one origin per workspace. When two host servers with different settings share it, the host that opened the popup last wins.
- Bell alerts and size keys go to the host server that opened a popup last. In a popup of another host server, size keys do nothing.
- Size keys do nothing in a client attached to the greenroom server directly, such as `tmux -L greenroom attach`, because it shows no popup.
- A size change takes about a quarter of a second. Size keys run one at a time, but keys pressed faster than the popup reopens can lose a step.
- Paste buffers are per server. On tmux 3.7b, when the host had `set-clipboard on` as the greenroom server started, a copy inside the popup reaches the host as a paste buffer, and the outer terminal, through OSC 52. On tmux 3.4 it stays inside the greenroom server.
- The greenroom server's environment comes from the popup that started it. A `PATH` changed later in a host pane, by nvm or direnv for example, does not reach new windows; only what the login shell sets up does.
- Text sent to a brand-new workspace is pasted once the first window looks settled. A program that starts reading input later than it draws its screen may miss the start of the text.
- After an upgrade of the plugin, `conf/greenroom-server.conf` takes effect only when the greenroom server restarts. The scripts and bindings are refreshed on the next open.

## Internals

The full record of decisions and measurements is [docs/design.md](docs/design.md), in Korean. In brief:

1. The host key runs `scripts/open.sh` with `run-shell -b`, which expands the client name and the pane's directory for it. `display-popup` expands neither its size nor its command as a format, so the script reads the size options and opens `display-popup -E -c <client> -d <origin>` itself. It is the only place that opens the popup.
2. Inside the popup, `scripts/attach.sh` picks the workspace and prepares the greenroom server in a single tmux call: start the server if needed, copy the host options, rebind the plugin keys, set the alert hooks, create the workspace if missing and record its origin. It then replaces itself with `tmux -L greenroom attach-session`.
3. Closing the popup detaches that client. The attach process ends, and `-E` closes the popup. The windows belong to the greenroom server and keep running.
4. Each window runs `scripts/run-profile.sh <name>`, which looks up the profile's command in the greenroom server's copy of the options, runs it through a login shell, and waits for a key if it fails.
5. tmux cannot resize an open popup, and a `display-popup` on a client that already shows one is dropped. So a size key runs `scripts/size.sh` in the greenroom server, which stores the new size on the host and has the host run `display-popup -C ; display-popup ...` as one command list. The new popup runs `attach.sh --reopen`, which attaches at once without preparing anything again.
6. To know which host client shows a popup, `attach.sh` records the host client's name under its own process ID (`@greenroom_host_client_<pid>`), which the inner client keeps after `exec`. A size key passes `#{client_pid}` and finds its own popup even when several host clients show one.
7. Hooks in the greenroom server run `scripts/alert.sh` on bells and on attach, window and session changes. It copies the list of windows whose bell flag is set to the host's `@greenroom_alert` and announces new bells on the host clients.
8. Sending puts the text in a host buffer and opens the popup with `--paste`. `attach.sh` moves the buffer into the greenroom server, and `scripts/paste.sh` pastes it into the target pane after attach.

The separate server keeps the host's session list free of agents, so `choose-tree`, `switch-client -n` and session savers see only your own sessions, and `prefix` + `s` inside the popup shows only workspaces. The agents also outlive the host server, and several host servers can share one greenroom server. Paste buffers and settings are per server, which is the price.

## Similar plugins

- [tmux-floax](https://github.com/omerxx/tmux-floax) floats a scratch session that lives on the host server itself, with a menu to resize it, go fullscreen or embed it, and needs tmux 3.3 or later.
- [tmux-toggle-popup](https://github.com/loichyan/tmux-toggle-popup) toggles general-purpose popups on a dedicated popup server, one per session or per directory by default (`@popup-id-format`), and needs tmux 3.4 or later.
- [tmux-claude-hatch](https://github.com/craftzdog/tmux-claude-hatch) is for Claude Code only, with one session per project on the host server and an fzf picker that shows each as working, waiting or idle, and needs fzf and jq.
- tmux-greenroom differs in keeping one set of workspaces for any CLI on a dedicated server, the same from every host session, with no dependency beyond bash and tmux.

## Development

`tests/run.sh` runs the integration tests. A harness server runs a real host client in a pane and types into it with `send-keys`; every server uses its own `tgr-test-<pid>-*` socket, and the default server and the `greenroom` socket are never touched. Pass part of a test name to run only the matching tests.

```bash
tests/run.sh
tests/run.sh command_menu
BASH_COMPAT=3.2 tests/run.sh
```

The tests run in four combinations: tmux 3.7b and tmux 3.4, each with bash 5.2 and with `BASH_COMPAT=3.2`. To test another tmux build, put a directory with a `tmux` symlink to it first in `PATH`:

```bash
mkdir -p /tmp/tmux-3.4-bin
ln -sf /path/to/tmux-3.4 /tmp/tmux-3.4-bin/tmux
PATH=/tmp/tmux-3.4-bin:$PATH tests/run.sh
```

Run `shellcheck greenroom.tmux scripts/*.sh` when shellcheck is installed. [AGENTS.md](AGENTS.md) lists the rules for changes, and [docs/design.md](docs/design.md) is updated together with this README when behavior, keys or options change.

## License

[MIT](LICENSE)
