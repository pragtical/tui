# TUI Plugin for Pragtical

A terminal rendering backend (Text-Based UI) that allows running Pragtical
inside your terminal with its familiar editing commands, menus, settings and
plugins. It supports syntax highlighting, mouse interaction and floating dialogs.

https://github.com/user-attachments/assets/bb3a1ffd-bf7b-4dfa-9f00-ca9851eb7e83

## Features

- Terminal rendering of documents, split panes, tabs, the treeview and toolbar.
- Application menus, command palette, Find, Project Search and Settings.
- Floating prompts, context menus and draggable dialogs.
- Mouse selection, dragging, scrolling and clickable controls.
- Unicode text, combining marks and wide characters.
- Visible space and tab markers with Draw Whitespace.
- Terminal colors derived from the active editor theme, with true-color output
  when supported and a 256-color fallback.
- Optional Nerd Font icons for the editor's bundled icon set.
- Automatic image previews when Chafa is available in `PATH`.
- Box-drawing borders, compact buttons, checkboxes and toggle switches.
- Draggable scrollbars.
- Highlighted notebook tabs and terminal-sized audio controls and sliders.
- Color pickers with gradient controls and editable color values.
- Restoration of terminal settings on normal exit, restart and Lua errors.

## Usage and Requirements

Requires a LuaJIT build of Pragtical 3.14.0 or newer and its matching Widget
library. A terminal with Unicode and ANSI escape sequence support is needed.
Launch from an interactive terminal. On Windows, use a console with virtual
terminal support, such as Windows Terminal; launch through `pragtical.com` when
a console attachment is needed.

Install this repository as the `tui` folder in your Pragtical user plugins
directory (for example, `~/.config/pragtical/plugins/tui/` on Linux), then
restart Pragtical.

Launch from a terminal:

```sh
pragtical tui
pragtical tui path/to/project
pragtical tui file.lua another-file.lua
```

Run `pragtical help tui` for command help. Ordinary graphical launches keep their
normal renderer; terminal mode is activated only by the `tui` subcommand.
Launch paths apply on startup. Project changes and restarts keep terminal mode
and use the current project/session state.

## Commands and Keymaps

TUI uses Pragtical's existing commands and keybindings. Common shortcuts include:

| Shortcut | Action |
| --- | --- |
| `Alt+X` | Open the command palette |
| `Alt+M` | Open the application menu |
| `Ctrl+P` | Find a file in the project |
| `Ctrl+F` | Find text in the current document |
| `Ctrl+S` | Save the current document |
| `Escape` | Dismiss a menu or prompt |

On macOS, terminal Control shortcuts are supplied for the usual Command
shortcuts. Terminal applications may intercept some keys, and traditional
terminal protocols cannot distinguish every combination, such as `Ctrl+I` and
`Tab`. Use the menu or command palette for commands without a usable shortcut.

File and directory pickers use Pragtical's command view. Editor copy/paste
commands use an internal clipboard; use your terminal application's paste
action to insert text copied outside the editor.

## Configuration

Options are available under **Settings > Plugins > Terminal UI**, or through
`config.plugins.tui` in your user `init.lua`:

```lua
local config = require "core.config"

config.plugins.tui.nerdicons = true
```

| Option | Default | Description |
| --- | --- | --- |
| `nerdicons` | `false` | Use Nerd Font glyphs for the editor's bundled icons. |

To use **Use Nerd Font Icons**, select a Nerd Font 3 in your terminal's settings
(preferably its Mono variant), enable the option, then restart Pragtical.
The separate Pragtical `nerdicons` plugin is not required.

The terminal application controls the font and font size. Pragtical's font zoom
and smooth graphical transitions are disabled during terminal sessions. Editor
themes still control text, background and selection colors. Audio transport controls
use Nerd Font media icons when enabled, and readable text symbols otherwise;
R, S and V stand for repeat, shuffle and visualization in the text fallback.

## Image Previews

Install [Chafa](https://hpjansson.org/chafa/download/) and make its executable
available in `PATH`. Image previews are enabled automatically; no configuration
flag is needed. If it is missing, the image view displays an installation hint.
Restart Pragtical after installing Chafa.

Examples:

```sh
# Debian / Ubuntu
sudo apt install chafa
# Arch Linux
sudo pacman -S chafa
# macOS (Homebrew)
brew install chafa
# Windows
winget install hpjansson.Chafa
```

On Windows, use Chafa 1.16.1 or newer. A standalone Windows executable is also
available from Chafa's download page.

Previews work in compatible Unicode/ANSI terminals. Animated images display a
still frame. Supported file formats depend on the installed Chafa build.

## Limitations

- Image previews are approximate. Some graphics-heavy interfaces are unsupported,
  and image export is unavailable.
- Complex emoji sequences may occupy different widths across terminals.
- Plugins that depend on graphical windows may require terminal support of their
  own. Native file dialogs are unavailable; use the command-view pickers.
- Headless or SSH startup may require SDL's dummy video driver for Pragtical's
  initial display query. The TUI itself does not require a graphical display.
- Linux is the tested platform. Windows and macOS support remains unverified.
- A crash or forced termination can leave terminal settings altered. Run `reset`
  in a POSIX terminal to restore them.

See [IMPLEMENTATION.md](IMPLEMENTATION.md) for architecture, the module map, and
development and testing instructions.
