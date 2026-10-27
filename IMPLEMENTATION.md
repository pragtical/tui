# TUI Implementation

For installation, configuration and user-facing limitations, see [README.md](README.md).

## Rendering and Runtime Integration

TUI adapts the editor's drawing and input to terminal cells. Linux and macOS use
the controlling terminal; Windows uses an attached console with virtual terminal
support.

Whitespace markers and other text underlays are preserved, including through
cached transparent text. Scrollbar drawing and pointer hit testing use whole-cell
geometry. Color pickers use cell-aligned gradient rows and separate text inputs.
Mapped Nerd Font icons reserve two columns so wider glyphs do not overlap
adjacent labels. Changing the icon option requires a restart to refresh cached
icons.

Terminal updates are incremental: unchanged frames emit no drawing output.
Terminal settings are restored on normal exit, restart and Lua errors; native
crashes and forced termination can bypass cleanup.

## Image Backend

Chafa is detected on the first image preview. Previews use colored Unicode blocks,
with true color or the TUI's 256-color fallback. This works across Unicode/ANSI
terminals without requiring SIXEL, Kitty or iTerm2 graphics support. Conversions
run asynchronously and are cached; scrolling and repainting reuse the result.
Zooming requests a new size, and the normal TUI compositor handles clipping,
menus and floating views over images.

Windows requires Chafa 1.16.1 or newer for its redirected-output fix.

File-backed images use Chafa. Arbitrary pixel buffers and cropped raster canvases
still display “Image preview unsupported”. Polygons are approximated, and pixel
capture or image export is unavailable. Native terminal graphics protocols are
not implemented.

## Integration Constraints

Plugins that draw outside the Lua renderer or call native window APIs may need
their own terminal adaptations. Direct native dialog calls report an error
callback.

Pragtical performs its initial display query before plugins load. TUI prevents
creation of an editor window but cannot recover if that earlier query fails;
display-free SSH startup is not yet supported reliably on every installation.

## Main Files

| File | Purpose |
| --- | --- |
| `init.lua` | Configuration, launch command and editor integration |
| `terminal.lua` | Operating-system terminal access and restoration |
| `input.lua` | Keyboard, paste, focus and mouse input decoding |
| `grid.lua` | Cell composition, clipping, borders and incremental output |
| `text.lua` | Unicode cleaning and cell-width measurement |
| `fonts.lua` | Terminal font metrics and icon mappings |
| `drawing.lua` | Renderer, canvas and floating-layer adapters |
| `chafa.lua` | Asynchronous image conversion and cached colored cells |
| `widgets.lua` | Compact controls, notebook tabs and reusable slider presentation |
| `colorpicker.lua` | Cached color gradients, selectors and matching pointer input |
| `menus.lua` | Thin frames and whole-cell rows for menus and submenus |
| `scrollbars.lua` | Shared cell-aligned scrollbar drawing and pointer geometry |
| `audio_view.lua` | Audio transport symbols and responsive terminal layout |
| `views.lua` | View alignment and mouse hit testing |
| `tests/` | Runtime regressions and GUI/TUI screenshot comparisons |

## Tests

With the plugin installed, run its tests from this directory:

```sh
SDL_VIDEO_DRIVER=dummy SDL_AUDIO_DRIVER=dummy pragtical test tests
```

This uses the globally installed editor and its normal profile. For reproducible
tests without other user plugins or settings, use a temporary `PRAGTICAL_USERDIR`
containing a `plugins/tui` link to this checkout.

The Linux capture script launches an isolated Xfce terminal under Xvfb and checks
mouse/caret/highlight alignment, prompts, menus, Settings, floating dialogs,
Markdown scrolling, audio controls and volume endpoints, About tabs, and PNG/SVG
loading and zooming. It checks installed-plugin row spacing, label/switch hover,
stationary-pointer scrolling and toggle clicks at fractional offsets. It also
checks space/tab markers, selected-only whitespace, trailing error blocks and
disabling markers. It drags tree and palette scrollbars, checks hover rows
at fractional offsets, and checks the full floating frame and its exact stroke
colors with long results. It compares captures against a fresh terminal repaint
to detect stale output. With installed PPM sources, it also tests Plugin Manager
selection against an offline catalog without installing plugins.

Requires `Xvfb`, `xfce4-terminal`, `xdotool` and Python's Pillow package. Install
Chafa to exercise image previews; otherwise captures check the installation hint.
It uses the global `pragtical` executable and links this checkout into its isolated
profile automatically:

```sh
python3 tests/capture.py
```

Use `--binary /path/to/pragtical` to select another installation.

Use `--theme /path/to/theme.lua` to check another color theme and `--columns 147`
to exercise a centered popup at a half-cell horizontal position. Use `--rows 41`
to check another terminal height.

Captures and the isolated profile are saved under `/tmp` by default. Options
include `--output /path/to/captures`, `--font "Your Terminal Font 15"`, and
`--plugin-manager /path/to/plugin_manager/plugin_view.lua` for another PPM
checkout. The script does not use your normal editor profile.

For paired screenshots against the normal graphical renderer, run:

```sh
python3 tests/compare.py
```

This uses Cold Lime and isolated profiles for both renderers. It captures 56
scenes at two terminal sizes, including startup and reopened Welcome views,
document scrolling and blank lines, Settings sections, color pickers, all prompt
positions, search, Markdown and image previews, audio, dialogs, menus, submenus,
Plugin Manager, split documents, tree scrolling and path tooltips. It also checks
line heights, query visibility, gradient handles and thin menu frames. Each scene
saves GUI and TUI PNGs, geometry snapshots and a labeled comparison image;
`report.json` records the checks and `index.html` collects the images. Font
density differs between renderers, so inspect the pairs for clipping, alignment
and missing content.

Use `--sizes 100x36,147x41` to select dimensions, `--gui-scale 1.25` to check saved
graphical scaling, or `--scenes application-search,application-edit-submenu` for
a focused comparison. `--binary`, `--font` and `--output` work as above. All
artifacts stay outside the checkout by default.

The restart regression uses a controlling PTY and SDL dummy drivers with the
global executable and isolated profiles:

```sh
python3 tests/restart.py
```

It exercises absolute and relative project/file arguments, launching without
paths, changing projects twice through the normal command, and a plain restart.
It checks the selected project, terminal mode and clean exit, and verifies that
old launch paths do not reopen as documents. Snapshots and terminal transcripts
go under `/tmp`; use `--binary` or `--output` to override those defaults.
