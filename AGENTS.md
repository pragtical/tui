# TUI plugin agent guidance

## Scope and local files

This is a standalone Pragtical plugin repository. Its module namespace is
`plugins.tui`, configuration is `config.plugins.tui`, and its Settings section is
**Terminal UI**. The editor source is in `../pragtical`, but development and
verification here use the **globally installed Pragtical** and its matching
Widget library. Do not default to building the editor or using `scripts/run-local`.

**Never commit anything listed under `.git/info/exclude`.** It is local agent
knowledge, also, keep screenshots, temporary profiles, profiler reports and
generated files outside the repository too. Do not stage or commit changes
unless the user asks.

Before starting work, search `memories/` for relevant subjects and read the
matching notes. Verify referenced APIs and paths before relying on historical
entries. Record new non-obvious root causes and constraints in the matching
subject file, using dated notes. Terminal frontend notes are in
`memories/TERMINAL_UI.md`; use standalone plugin paths and global Pragtical
commands when updating them.

## Global installation and commands

The development checkout is linked at
`~/.config/pragtical/plugins/tui`. Keep this link pointing at the repository.
For development, link your checkout into that directory instead of copying it:

```sh
ln -s /absolute/path/to/tui ~/.config/pragtical/plugins/tui
```

Ordinary graphical launches register the configuration and CLI command without
activating terminal rendering.

Run these commands from this repository:

```sh
pragtical --version
pragtical help tui
pragtical tui
pragtical tui path/to/project
SDL_VIDEO_DRIVER=dummy SDL_AUDIO_DRIVER=dummy pragtical test tests
python3 tests/capture.py
python3 tests/restart.py
```

The runtime requires LuaJIT and Pragtical 3.14.0 or newer with its matching Widget
library. The terminal controls the real font and font size. Test with a Nerd Font
when `config.plugins.tui.nerdicons` is enabled. Chafa in PATH enables image previews.

The direct test command uses the normal user profile. For repeatable tests without
other user plugins or settings, create an isolated profile while still using the
global executable:

```sh
tui_test_profile=$(mktemp -d /tmp/pragtical-tui-tests-XXXXXX)
mkdir -p "$tui_test_profile/plugins"
ln -s "$PWD" "$tui_test_profile/plugins/tui"
PRAGTICAL_USERDIR="$tui_test_profile" SDL_VIDEO_DRIVER=dummy \
  SDL_AUDIO_DRIVER=dummy pragtical test tests
```

For temporary Lua scripts, use `pragtical run /tmp/script.lua`; add `-n` after
`run` when the script schedules coroutines that need the editor loop to continue.
Use SDL dummy drivers for headless graphical-runtime checks. Actual terminal
interaction needs a controlling terminal; the capture harness supplies one.

## Tests and captures

Lua regressions belong in `tests/`, beside the plugin, rather than the editor's
general test suite. Use `core.test` and add meaningful regressions for rendering
and input defects. Keep test fixtures independent of personal configuration.

`tests/capture.py` launches the global editor in an isolated Xfce terminal under
Xvfb, links this checkout into its temporary profile, and compares incremental
output with a fresh repaint. Requires Xvfb, xfce4-terminal, xdotool and Pillow.
Artifacts and profiles go under `/tmp` by default. Useful options:

```sh
python3 tests/capture.py --columns 147 --rows 41
python3 tests/capture.py --theme /path/to/theme.lua
python3 tests/capture.py --binary /path/to/pragtical
```

`tests/compare.py` captures paired normal GUI/TUI screenshots using Cold Lime and
isolated profiles, at two terminal sizes by default. It covers 56 scenes, saves
geometry and cell snapshots, and checks startup layout, input visibility, menu
frames and color-picker handles. Use `--scenes` for a focused comma-separated
selection, `--sizes 100x36,147x41`, or `--gui-scale 1.25` to exercise saved GUI
scaling. Inspect paired PNGs as well as `report.json`; density differs naturally
between the renderers. Force `auto_fps=false` in Xvfb fixtures: its advertised
refresh rate can be zero and stall the GUI before its first frame.

`tests/restart.py` exercises real TUI launches, project changes and soft restarts
in a controlling PTY with isolated profiles. It needs no X server and uses SDL
dummy drivers. It checks absolute/relative paths and startup files, retaining
state snapshots and terminal transcripts under `/tmp`.

Plugin Manager captures use the selected installation's PPM view source. Override
with `--plugin-manager /path/to/plugin_manager/plugin_view.lua` when needed.
The catalog is an offline fixture; captures must not install real plugins.

## Architecture and rendering constraints

See IMPLEMENTATION.md for architecture, the module map and test workflows.
README.md covers installation and use. `init.lua` activates the terminal frontend;
`terminal.lua` handles OS terminal access, `input.lua` decodes events, and
`grid.lua` composes cells. `fonts.lua` supplies metrics and icons; `drawing.lua`
adapts renderer/canvas calls and floating layers. `widgets.lua`, `colorpicker.lua`,
`menus.lua`, `scrollbars.lua`, `views.lua` and `audio_view.lua` adapt controls and
pointer geometry. `chafa.lua` converts file-backed images asynchronously and
caches results.

- Layout uses fixed logical cells of 8 by 16 pixels. Rendering and hit testing
  must agree after clipping, fractional scrolling and floating view movement.
- Preserve wide-character continuations, combining marks, border stroke colors
  and floating-layer ownership. Test actual colors as well as glyphs: a surviving
  border with a background-colored stroke still looks missing.
- Plain text spaces have no ink and only advance the cursor; they must preserve
  underlays such as Draw Whitespace markers. Underline/strikethrough spaces still
  draw decorations. Explicit backgrounds and opaque canvases still cover text.
- Keep normal graphical launches unchanged. Prepare adapters early only for a TUI
  launch, and restore terminal modes on exit, restart and Lua errors.
- Retain native event polling for workers and directory monitoring. Avoid blocking
  reads or image conversions in the UI loop.
- Reuse cached layouts and image conversions. Unchanged frames must emit no
  drawing output; avoid unnecessary redraws and per-frame function assignments.
- Prefer generic control/renderer fixes within this plugin. Do not change editor
  core or Widget solely to work around terminal presentation when an adapter fits.
- Follow existing Lua style, document new APIs, and avoid underscore-prefixed
  property conventions. Keep changes focused and verify cross-platform branches.

If asked to commit, use a short natural subject and a brief body wrapped at 72
characters. Write multiline messages to a temporary file and use `git commit -F`.
