#!/usr/bin/env python3
"""Capture and verify TUI in an isolated Xfce terminal (Linux).

Requires Xvfb, xfce4-terminal, xdotool, and Pillow. Uses the global pragtical
installation by default and links this checkout into an isolated test profile.
Artifacts and profiles are kept outside the repository by default; no global
settings are used. Pass --binary to select another Pragtical executable.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

from PIL import Image, ImageChops, ImageDraw, ImageGrab

INIT = r'''
local core = require "core"
local config = require "core.config"
local json = require "core.json"
local style = require "core.style"
local Grid = require "plugins.tui.grid"
config.plugins.ipc = false
config.plugins.tui.nerdicons = true
config.disable_blink = true
-- Settings can replace startup fonts with descriptors after TUI activation.
-- Status text must still distinguish these fonts from color tables.
style.font = style.font:copy()
style.icon_font = style.icon_font:copy()
local pending, caret, catalog_view
local function active_list(view)
  if view.recent_projects then return view.recent_projects end
  if view.colors and view.colors:is_visible() then
    for _, child in ipairs(view.colors.childs) do
      if child.type_name == "widget.listbox" then return child end
    end
  end
end
local function installed_list(view)
  if not view.plugin_sections or not view.plugins:is_visible() then return end
  local pane = view.plugin_sections:get_pane("enable_disable")
  if pane then
    for _, child in ipairs(pane.container.childs) do
      if child.type_name == "widget.widgetlist" then return child end
    end
  end
end
local request_path = USERDIR .. "/request.json"
local state_path = USERDIR .. "/state.json"
local clear, draw_caret, present = Grid.clear, Grid.caret, Grid.present
function Grid:clear(...) caret = nil; return clear(self, ...) end
function Grid:caret(x, y)
  caret = {math.floor(x+.5), math.floor(y+.5)}
  return draw_caret(self, x, y)
end
function Grid:present(...)
  if pending and pending.repaint then self.previous = {} end
  local output = present(self, ...)
  if pending then
    local state = {name=pending.name, columns=self.columns, rows=self.rows,
      cells={}, caret=caret}
    for i, cell in ipairs(self.cells) do
      state.cells[i] = {cell[1], cell[2], cell[3]}
    end
    if core.active_view.doc then
      state.selection = {core.active_view.doc:get_selection()}
    end
    local menu = core.menu_view.menu
    local item = menu:get_item_selected()
    state.menu_selected = item and item.text or ""
    state.line_highlight = style.line_highlight[1]*65536
      + style.line_highlight[2]*256 + style.line_highlight[3]
    local view = core.active_view
    state.viewport = {view.position.x/8, view.position.y/16, view.size.x/8, view.size.y/16}
    if view == core.command_view and view.floating then
      local x,y,w,h = view:get_floating_bounds()
      state.viewport = {x/8,y/16,w/8,h/16}
      local bar = view.suggestions_view.v_scrollbar
      local tx,ty,tw,th = bar:get_thumb_rect()
      local bx,by,bw,bh = bar:get_track_rect()
      state.palette = {scroll=view.suggestions_view.scroll.y,
        border_color=style.dim[1]*65536+style.dim[2]*256+style.dim[3],
        thumb={tx/8,ty/16,tw/8,th/16}, track={bx/8,by/16,bw/8,bh/16}}
    end
    state.scroll = view.scroll.y
    state.status = {top=core.status_view.position.y/16,
      background=style.background2[1]*65536+style.background2[2]*256+style.background2[3]}
    state.background = style.background[1]*65536+style.background[2]*256+style.background[3]
    local list = active_list(view)
    if list then
      state.list = {viewport={list.position.x/8,list.position.y/16,list.size.x/8,list.size.y/16},
        selected=list:get_selected(), hovered=list.hovered_row, scroll=list.scroll.y}
    end
    local installed = installed_list(view)
    if installed then
      state.installed = {viewport={installed.position.x/8,installed.position.y/16,
        installed.size.x/8,installed.size.y/16},
        pointer={installed.mouse.x/8,installed.mouse.y/16}, rows={}}
      for _, entry in ipairs(installed.items) do
        local row = entry.row
        local toggle
        for _, child in ipairs(row.childs) do
          if child.type_name == "widget.toggle" then toggle=child end
        end
        state.installed.rows[#state.installed.rows+1] = {name=entry.data.name,
          plugin=entry.data.plugin, height=entry.height, hovered=row.hovered or false,
          visible=row.visible, y=row.position.y/16, enabled=toggle.enabled,
          toggle_x=(toggle.position.x+toggle.toggle_x)/8}
      end
    end
    local tree = package.loaded["plugins.treeview"]
    if tree then
      local x, y, w, h = tree.h_scrollbar:get_track_rect()
      state.tree = {track={x/8,y/16,w/8,h/16},
        viewport={tree.position.x/8,tree.position.y/16,tree.size.x/8,tree.size.y/16}}
      local tx,ty,tw,th = tree.v_scrollbar:get_thumb_rect()
      local bx,by,bw,bh = tree.v_scrollbar:get_track_rect()
      state.tree.thumb, state.tree.vertical_track = {tx/8,ty/16,tw/8,th/16}, {bx/8,by/16,bw/8,bh/16}
      state.tree.hovered = tree.hovered_item and tree.hovered_item.name or ""
      state.tree.scroll = tree.scroll.y
    end
    if view.type_name == "core.audioview" then
      local slider = view.volume_slider
      state.audio = {volume=view.volume, slider={slider.position.x/8,
        slider.position.y/16, slider.size.x/8}}
    end
    if view.recent_projects then
      local list = view.recent_projects
      state.list_borders = {
        math.floor((list.position.x - list.border.width) / 8),
        math.floor((list.position.x + list.size.x) / 8)
      }
    end
    if view.image_scaled then
      state.image = {path=view.path, width=view.width, height=view.height,
        zoom=view.zoom_scale, source={view.image:get_size()}}
    end
    if catalog_view then
      state.catalog_scroll = catalog_view.list.scroll.y
      state.checkboxes = {}
      for _, entry in ipairs(catalog_view.list.items) do
        local box = entry.row.checkbox
        state.checkboxes[entry.data.id] = {checked=box:is_checked(),
          x=box.position.x/8, y=box.position.y/16}
      end
    end
    state.popups = {}
    for _, popup in ipairs(core.root_view.floating_views) do
      if popup.floating_visible then
        local x, y, w, h = popup:get_floating_bounds()
        state.popups[#state.popups+1] = {
          name=popup.name or tostring(popup), bounds={x/8, y/16, w/8, h/16}}
        if popup.panel and popup.panel.childs[1] and popup.panel.childs[1].contributors then
          local list = popup.panel.childs[1].contributors
          state.contributors = {position={list.position.x/8, list.position.y/16},
            size={list.size.x/8, list.size.y/16}, scroll=list.scroll.y,
            right=math.floor((list.position.x + list.size.x)/8)}
        end
      end
    end
    local f = assert(io.open(state_path .. ".tmp", "w"))
    f:write(json.encode(state)); f:close()
    os.rename(state_path .. ".tmp", state_path)
    pending = nil
  end
  return output
end
core.add_thread(function()
  while true do
    local f = io.open(request_path, "r")
    if f then
      pending = json.decode(f:read("*a")); f:close(); os.remove(request_path)
      if pending.commandview_position then
        config.commandview_position = pending.commandview_position
      end
      if pending.whitespace then
        local view=core.open_file(USERDIR.."/project/capture-whitespace.lua")
        view.doc:set_selection(1,1,1,3)
        local options=config.plugins.drawwhitespace
        options.enabled=pending.whitespace ~= "disabled"
        options.show_selected_only=pending.whitespace == "selected"
        options.show_trailing_error=pending.whitespace == "error"
        options.color=style.syntax.whitespace or style.syntax.comment
      end
      if pending.resume_fixture then core.open_file(USERDIR.."/project/capture.lua") end
      if pending.tree_prepare then
        require("plugins.projectsearch").hide()
        local tree = require "plugins.treeview"
        tree.visible = true
      end
      if pending.tree_scroll_end then
        local tree = require "plugins.treeview"
        tree.scroll.y = math.max(0, tree:get_scrollable_size() - tree.size.y)
        tree.scroll.to.y = tree.scroll.y
      end
      if pending.palette_fixture then
        local rows = {}
        for i=1,100 do
          rows[i] = {text=string.format("result-%03d-",i) .. string.rep("long-result-",18)}
        end
        core.command_view:enter("Open File From Project:", {
          suggest=function() return rows end, show_suggestions=true,
          typeahead=false, select_text=false
        })
      end
      if pending.palette_scroll then
        local view = core.command_view
        view.suggestions_view.scroll.y, view.suggestions_view.scroll.to.y =
          pending.palette_scroll, pending.palette_scroll
        view.suggestion_idx = math.floor(pending.palette_scroll/16)+5
        view.reveal_suggestion = false
      end
      if pending.audio then
        local player = core.open_audio("")
        for i = 1, 40 do
          player:add_track({path="/capture/track" .. i .. ".wav", name="Track " .. i,
            folder="/capture", format="wav"})
        end
      end
      if pending.welcome then
        local EmptyView = require "core.emptyview"
        core.recent_projects = {}
        for i=1,40 do
          core.recent_projects[i] = string.format("~/Development/project-%02d", i)
        end
        core.root_view:get_active_node():add_view(EmptyView())
      end
      if pending.list_scroll or pending.list_scroll_end then
        local list = assert(active_list(core.active_view))
        local offset = pending.list_scroll or math.max(0,list:get_scrollable_size()-list.size.y)
        list.scroll.y, list.scroll.to.y = offset, offset
      end
      if pending.installed_scroll then
        local list = assert(installed_list(core.active_view))
        list.scroll.y, list.scroll.to.y = pending.installed_scroll, pending.installed_scroll
      end
      if pending.scroll and core.active_view.doc then
        core.active_view.scroll.y = pending.scroll
        core.active_view.scroll.to.y = pending.scroll
      end
      if pending.plugin_manager then
        config.plugins.plugin_manager = config.plugins.plugin_manager or {}
        local PluginView = assert(loadfile(pending.plugin_manager))()
        local catalog = {}
        for i = 1, 30 do
          catalog[i] = {id=string.format("capture_plugin_%02d", i), type="plugin",
            status="available", version="1.0", description="Local capture fixture"}
        end
        local manager = {addons=catalog, valid_addons=catalog}
        function manager:refresh()
          return {done=function(self, callback) callback(); return self end,
            fail=function(self) return self end}
        end
        catalog_view = PluginView(manager)
        core.root_view:get_active_node():add_view(catalog_view)
      end
      if pending.catalog_scroll then
        catalog_view.list.scroll.y = pending.catalog_scroll
        catalog_view.list.scroll.to.y = pending.catalog_scroll
      end
      core.redraw = true
    end
    coroutine.yield(.05)
  end
end)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=shutil.which('pragtical'),
                        help='Pragtical executable (default: pragtical from PATH)')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--font', default='Hack Nerd Font 10')
    parser.add_argument('--theme', type=Path, help='Color theme Lua file for rendering checks')
    parser.add_argument('--columns', type=int, default=140, help='Terminal width in cells')
    parser.add_argument('--rows', type=int, default=38, help='Terminal height in cells')
    parser.add_argument('--plugin-manager', type=Path,
                        help='Plugin Manager view source (default: installed Pragtical copy)')
    args = parser.parse_args()
    if args.binary is None:
        parser.error('pragtical is not in PATH; provide --binary')
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error('binary must point to a Pragtical executable with its runtime data')
    if args.plugin_manager is None:
        prefix = os.environ.get('PRAGTICAL_PREFIX')
        if prefix or binary.parent.name == 'bin':
            data = Path(prefix) if prefix else binary.parent.parent
            data = data / 'share/pragtical'
        else:
            data = binary.parent / 'data'
        args.plugin_manager = data / 'plugins/plugin_manager/plugin_view.lua'
    for program in ('Xvfb', 'xfce4-terminal', 'xdotool'):
        if not shutil.which(program):
            parser.error('missing program: ' + program)
    output = args.output or Path(tempfile.mkdtemp(prefix='pragtical-tui-captures-'))
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    profile = Path(tempfile.mkdtemp(prefix='profile-', dir=output))
    plugins = profile / 'plugins'
    plugins.mkdir()
    (plugins / 'tui').symlink_to(Path(__file__).resolve().parents[1],
                               target_is_directory=True)
    project = profile / 'project'
    project.mkdir()
    fixture = project / 'capture.lua'
    fixture.write_text(''.join(f'local value_{i:03} = {i}\n' for i in range(1, 121)))
    (project/'capture-whitespace.lua').write_text('  local value = "with  spaces"  \n'
        '\tlocal tabbed\t= true \nlocal wide = "界 e\u0301"  \n  \n')
    (project / 'AGENTS.md').write_text('# Capture fixture\n')
    raster = project / 'capture-image.png'
    picture = Image.new('RGBA', (128, 64), (200, 80, 40, 255))
    shapes = ImageDraw.Draw(picture)
    shapes.ellipse((12, 6, 66, 60), fill=(30, 80, 230, 255))
    shapes.polygon([(72, 56), (98, 6), (122, 56)], fill=(40, 220, 60, 255))
    shapes.rectangle((26, 22, 50, 42), fill=(0, 0, 0, 0))
    picture.save(raster)
    vector = project / 'capture-image.svg'
    vector.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="128" height="64">'
                      '<rect width="128" height="64" fill="red"/></svg>')
    markdown = project / 'preview.md'
    markdown.write_text('# Terminal Preview\n\n' + ''.join(
        f'## Scrolling section {i}\n\n'
        'A paragraph spanning\nsource lines with **bold text**, `inline code`,\n'
        'and enough words to wrap within the preview pane.\n\n'
        '- A list item spanning\n  multiple source lines.\n'
        '- Another item with a [link](https://pragtical.dev).\n\n'
        '| Column | Value |\n| --- | --- |\n| First | One |\n| Second | Two |\n\n'
        for i in range(1, 7)))
    # Exercise both scrollbars and rows near a fractional viewport boundary.
    for index in range(70):
        (project / (f'tree-boundary-{index:02}-' + 'long-name-'*8 + '.txt')).write_text('')
    init = INIT
    if args.theme:
        init = 'assert(loadfile(' + json.dumps(str(args.theme.resolve())) + '))()\n' + init
    (profile / 'init.lua').write_text(init)
    xvfb = terminal = None
    checks = []
    with (output / 'display.log').open('w') as log:
        try:
            read_fd, write_fd = os.pipe()
            xvfb = subprocess.Popen(
                ['Xvfb', '-displayfd', str(write_fd), '-screen', '0', '1920x1080x24', '-nolisten', 'tcp'],
                pass_fds=(write_fd,), stdout=log, stderr=log)
            os.close(write_fd)
            display = ':' + os.read(read_fd, 30).decode().strip()
            os.close(read_fd)
            env = dict(os.environ, DISPLAY=display, GDK_BACKEND='x11',
                       PRAGTICAL_USERDIR=str(profile), PRAGTICAL_SCALE='1',
                       PRAGTICAL_SCALE_CODE='1', SDL_VIDEO_DRIVER='dummy',
                       SDL_AUDIO_DRIVER='dummy', PRAGTICAL_RENDERER='surface')
            terminal = subprocess.Popen(
                ['xfce4-terminal', '--disable-server', '--hide-menubar', '--hide-toolbar',
                 '--hide-scrollbar', '--font=' + args.font, '--geometry=' + str(args.columns) + 'x' + str(args.rows),
                 '--working-directory=' + str(project), '-x', str(binary), 'tui',
                 str(project), str(fixture)], env=env, stdout=log, stderr=log,
                start_new_session=True)

            def xdo(*arguments):
                return subprocess.run(['xdotool', *arguments], env=env, check=True,
                                      capture_output=True, text=True).stdout.strip()

            window = None
            for _ in range(50):
                time.sleep(.1)
                found = subprocess.run(['xdotool', 'search', '--onlyvisible', '--class',
                                        'Xfce4-terminal'], env=env, capture_output=True, text=True)
                if found.stdout.strip():
                    window = found.stdout.splitlines()[0]
                    break
            assert window, 'terminal did not open; see display.log'
            xdo('windowfocus', window)
            geometry = dict(line.split('=', 1) for line in xdo('getwindowgeometry', '--shell', window).splitlines())
            time.sleep(1)

            def capture(name, **options):
                request = dict(name=name, **options)
                (profile / 'request.tmp').write_text(json.dumps(request))
                (profile / 'request.tmp').replace(profile / 'request.json')
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    path = profile / 'state.json'
                    if path.exists():
                        state = json.loads(path.read_text())
                        if state['name'] == name:
                            (output / (name + '.json')).write_text(json.dumps(state))
                            time.sleep(.1)
                            ImageGrab.grab(xdisplay=display).save(output / (name + '.png'))
                            return state
                    time.sleep(.05)
                raise AssertionError('capture timed out: ' + name)

            def find(state, label, start_row=0):
                columns = state['columns']
                for row in range(start_row, state['rows']):
                    cells = state['cells'][row*columns:(row+1)*columns]
                    for col in range(columns):
                        text = ''.join(cell[0] for cell in cells[col:])
                        if text.startswith(label):
                            return col, row
                raise AssertionError('label not visible: ' + label)

            def point(state, col, row, click=False):
                width = (int(geometry['WIDTH']) - 2) / state['columns']
                height = (int(geometry['HEIGHT']) - 2) / state['rows']
                x = int(geometry['X']) + 1 + int((col+.5)*width)
                y = int(geometry['Y']) + 1 + int((row+.5)*height)
                xdo('mousemove', str(x), str(y))
                if click:
                    xdo('click', '1')
                time.sleep(.3)

            def click_label(state, label):
                point(state, *find(state, label), click=True)

            def key(*keys):
                xdo('key', *keys)
                time.sleep(.3)

            def command(name):
                key('alt+x', 'ctrl+a')
                xdo('type', '--clearmodifiers', name)
                time.sleep(.3)
                key('Return')

            def check(name, result):
                checks.append(dict(name=name, passed=bool(result)))
                assert result, name
                print('PASS', name, flush=True)

            def preview_image(name, state):
                width = (int(geometry['WIDTH']) - 2) / state['columns']
                height = (int(geometry['HEIGHT']) - 2) / state['rows']
                x, y, w, h = state['viewport']
                left = int(geometry['X']) + 1 + round(x * width)
                top = int(geometry['Y']) + 1 + round(y * height)
                with Image.open(output / (name + '.png')) as image:
                    return image.convert('RGB').crop((left, top, left+int(w*width), top+int(h*height)))

            def check_preview(name):
                state = capture(name)
                check(name + ' contains no terminal controls', all(
                    not any(ord(ch) < 32 or 127 <= ord(ch) < 160 for ch in cell[0])
                    for cell in state['cells']))
                fresh = capture(name + '-repaint', repaint=True)
                check(name + ' matches full repaint', ImageChops.difference(
                    preview_image(name, state), preview_image(name + '-repaint', fresh)
                ).getbbox() is None)
                return state

            def check_palette(name):
                state = check_preview(name)
                check(name + ' centered floating palette is visible', 'palette' in state)
                x,y,w,h = state['viewport']
                left, right = int(x), int(x+w-1/8)
                top, bottom = int(y), int(y+h-1/16)
                check(name + ' complete side borders', all(
                    state['cells'][r*state['columns']+c][0] == '│'
                    for r in range(top+1,bottom) for c in (left,right)))
                check(name + ' side borders retain their exact frame color', all(
                    state['cells'][r*state['columns']+c][1] == state['palette']['border_color']
                    for r in range(top+1,bottom) for c in (left,right)))
                check(name + ' bottom border excludes partial results', all(
                    state['cells'][bottom*state['columns']+c][0] == '─'
                    for c in range(left+1,right)))
                return state

            state = capture('01-document')
            for index, scroll in enumerate((0, 3.25)):
                state = capture(f'02-document-scroll-{index}', scroll=scroll)
                col, row = find(state, 'local value_012')
                point(state, col + 7, row, click=True)
                state = capture(f'03-document-click-{index}')
                check(f'document click at scroll {scroll}', state['selection'] == [12, 8, 12, 8])
                check(f'caret cell at scroll {scroll}', state['caret'] == [col + 7, row])
                columns = state['columns']
                bg = lambda r: state['cells'][r*columns + columns-10][2]
                check(f'highlight row at scroll {scroll}', bg(row) == state['line_highlight']
                      and bg(row-1) != bg(row) and bg(row+1) != bg(row))
            for mode in ('all','selected','error','disabled'):
                capture('03-whitespace-config-'+mode,whitespace=mode)
                state = check_preview('03-whitespace-'+mode)
                dots=sum(cell[0]=='·' for cell in state['cells'])
                tabs=sum(cell[0]=='»' for cell in state['cells'])
                errors=sum(cell[0]=='█' for cell in state['cells'])
                if mode == 'disabled':
                    check('disabling Draw Whitespace clears previous markers',dots == tabs == errors == 0)
                elif mode == 'selected':
                    check('selected-only whitespace keeps just the selected markers',dots == 2 and tabs == errors == 0)
                elif mode == 'error':
                    check('trailing-error spaces survive text drawing',errors > 0 and dots > 0 and tabs == 2)
                else:
                    check('space and tab markers survive text drawing',dots > 10 and tabs == 2 and errors == 0)
            capture('03-document-return',resume_fixture=True)
            capture('03-center-config', commandview_position='center')
            key('ctrl+p', 'ctrl+a')
            xdo('type', '--clearmodifiers', 'agent')
            time.sleep(.3)
            for name in ('03-centered-query', '03-centered-query-resized'):
                state = capture(name)
                col, row = find(state, 'agent')
                check(name + ' label and query share a row',
                      find(state, 'Open File From Project:')[1] == row)
                check(name + ' caret follows query', state['caret'] == [col+5, row])
                suggestion_row = find(state, 'AGENTS.md', row+1)[1]
                check(name + ' results remain visible', suggestion_row > row)
                frame = next(p['bounds'] for p in state['popups'] if p['name'] == 'CommandView')
                left, right = int(frame[0]), int(frame[0]+frame[2]-1/8)
                check(name + ' selection retains floating frame', all(
                    state['cells'][suggestion_row*state['columns']+col][0] == '│'
                    for col in (left, right)))
                if name == '03-centered-query':
                    cell_height = (int(geometry['HEIGHT']) - 2) / state['rows']
                    xdo('windowsize', window, geometry['WIDTH'],
                        str(round(int(geometry['HEIGHT']) + cell_height)))
                    time.sleep(.3)
                    geometry = dict(line.split('=', 1) for line in
                                    xdo('getwindowgeometry', '--shell', window).splitlines())
            key('Escape')
            capture('03-bottom-config', commandview_position='bottom')
            key('ctrl+f')
            capture('04-find')
            key('Escape')
            command('Project Search: Find')
            capture('05-project-search')
            key('Escape')
            command('Ui: Settings')
            state = capture('06-settings')
            click_label(state, 'General')
            state = capture('07-settings-general')
            check('numberbox value visible', find(state, '10') is not None)
            click_label(state, 'Colors')
            state = check_preview('07-settings-colors')
            capture('07-settings-colors-scroll', list_scroll_end=True)
            state = check_preview('07-settings-colors-bottom')
            check('color previews stay above the status bar', all(
                cell[0] != '▀' and cell[2] == state['status']['background']
                for row in range(int(state['status']['top']+.5), state['rows'])
                for cell in state['cells'][row*state['columns']:(row+1)*state['columns']]))
            lx,ly,lw,lh = state['list']['viewport']
            divider = int(state['status']['top'])-1
            check('color previews do not tint the bottom divider cells', all(
                state['cells'][divider*state['columns']+col][2] == state['background']
                for col in range(int(lx+lw/2),int(lx+lw)-2)))
            click_label(state, 'Plugins')
            state = capture('08-settings-plugins')
            click_label(state, 'Installed')
            state = capture('09-settings-installed')
            check('individual toggle markers', find(state, '[  ●]') is not None)
            check('installed plugin rows occupy one terminal line', all(
                row['height'] == 16 for row in state['installed']['rows']))
            for scroll in (0, 8, 15.25, 31.5):
                state = capture(f'09-installed-scroll-{scroll}', installed_scroll=scroll)
                lx,ly,lw,lh = state['installed']['viewport']
                visible = [row for row in state['installed']['rows']
                    if row['visible'] and int(ly+.5)+1 <= int(row['y']+.5) < int(ly+lh)-1]
                check(f'installed rows remain consecutive at scroll {scroll}', all(
                    int(b['y']+.5) == int(a['y']+.5)+1 for a,b in zip(visible,visible[1:])))
                if scroll:
                    px,py = state['installed']['pointer']
                    pointed = [item['plugin'] for item in visible if int(item['y']+.5) == int(py)]
                    hovered = [item['plugin'] for item in state['installed']['rows'] if item['hovered']]
                    check(f'installed hover follows scrolling at {scroll}',hovered == pointed and len(pointed) == 1)
                for item in visible[1:3]:
                    row = int(item['y']+.5)
                    for target,col in (('label',int(lx+.5)+4),('toggle',int(item['toggle_x']+.5)+2)):
                        point(state,col,row)
                        state = check_preview(f'09-installed-hover-{scroll}-{item["plugin"]}-{target}')
                        hovered = [r['plugin'] for r in state['installed']['rows'] if r['hovered']]
                        check(f'installed {target} hover targets its row at {scroll}',hovered == [item['plugin']])
                        color = state['line_highlight']
                        check(f'installed {target} highlight occupies one row at {scroll}',
                            state['cells'][row*state['columns']+int(lx+.5)+20][2] == color
                            and state['cells'][(row-1)*state['columns']+int(lx+.5)+20][2] != color
                            and state['cells'][(row+1)*state['columns']+int(lx+.5)+20][2] != color)
            state = capture('09-installed-toggle-ready', installed_scroll=0)
            item = next(row for row in state['installed']['rows'] if row['plugin'] == 'autocomplete')
            for enabled in (not item['enabled'],item['enabled']):
                point(state,int(item['toggle_x']+.5)+2,int(item['y']+.5),click=True)
                state = check_preview('09-installed-toggle-'+str(enabled))
                current = next(row for row in state['installed']['rows'] if row['plugin'] == item['plugin'])
                check('installed toggle updates and restores its state',current['enabled'] == enabled)
            key('alt+m', 'Up')
            state = capture('10-sessions-selected')
            check('Sessions keyboard selection', state['menu_selected'] == 'Sessions')
            point(state, *find(state, 'Sessions'))
            state = capture('11-sessions-hover')
            check('Sessions mouse selection', state['menu_selected'] == 'Sessions')
            key('Right')
            capture('12-sessions-submenu')
            key('Escape', 'Escape')
            command('Project Search: Find')
            command('Core: Open File')
            key('ctrl+a')
            xdo('type', '--clearmodifiers', str(markdown))
            key('Return')
            command('Markdown View: Preview')
            state = check_preview('13-markdown')
            point(state, state['columns']-12, 12)
            xdo('click', '--repeat', '12', '--delay', '80', '5')
            time.sleep(.3)
            state = check_preview('14-markdown-scrolled')
            check('Markdown scrolled down', state['scroll'] > 0)
            xdo('click', '--repeat', '16', '--delay', '80', '4')
            time.sleep(.3)
            state = check_preview('15-markdown-top')
            check('Markdown returned to top', state['scroll'] == 0)
            command('Core: View About')
            state = check_preview('16-about')
            list_view = state['contributors']
            lx, ly = list_view['position']
            point(state, lx+5, ly+4)
            xdo('click', '--repeat', '8', '--delay', '50', '5')
            state = check_preview('16-about-scrolled')
            check('contributors scrolled', state['contributors']['scroll'] > 0)
            list_view = state['contributors']
            lx, ly = list_view['position']
            width, height = list_view['size']
            frame = next(p['bounds'] for p in state['popups'] if p['name'] == 'About Pragtical')
            border = int(frame[0]+frame[2]-1/8)
            check('long contributor rows retain dialog border', all(
                state['cells'][r*state['columns']+border][0] == '│'
                for r in range(round(ly)+1, int(ly+height)-1)))
            check('contributor text stays inside its viewport', all(
                not state['cells'][r*state['columns']+col][0].isalnum()
                for r in range(round(ly)+1, int(ly+height)-1)
                for col in range(list_view['right'], border)))
            before = next(p['bounds'] for p in state['popups'] if p['name'] == 'About Pragtical')
            col, row = find(state, 'About Pragtical')
            point(state, col+5, row)
            xdo('mousedown', '1')
            # Leave the title's child label before moving back over the panel.
            point(state, col+13, max(0, row-2))
            point(state, col+13, row+2)
            xdo('mouseup', '1')
            time.sleep(.3)
            state = check_preview('17-about-moved')
            after = next(p['bounds'] for p in state['popups'] if p['name'] == 'About Pragtical')
            check('About dialog moved', before[:2] != after[:2])
            click_label(state, 'License')
            state = check_preview('17-about-license')
            check('license text visible', find(state, 'Permission') is not None)
            key('Escape')
            capture('17-audio-open', audio=True)
            state = check_preview('17-audio')
            check('audio transport symbols visible', find(state, '') is not None
                  and find(state, '') is not None and find(state, '') is not None)
            check('audio slider handle visible', find(state, '●') is not None)
            sx, sy, sw = state['audio']['slider']
            point(state, round(sx), round(sy), click=True)
            state = check_preview('17-audio-volume-zero')
            check('volume reaches zero at drawn start', state['audio']['volume'] == 0)
            point(state, round(sx) + int(sw) - 1, round(sy), click=True)
            state = capture('17-audio-volume-full')
            check('volume reaches maximum at drawn end', state['audio']['volume'] == 1)
            if args.plugin_manager.is_file():
                capture('18-plugin-manager-open', plugin_manager=str(args.plugin_manager.resolve()))
                state = capture('18-plugin-manager')

                def marker(state, plugin_id):
                    box = state['checkboxes'][plugin_id]
                    col, row = int(box['x']+.5), int(box['y']+.5)
                    cells = state['cells'][row*state['columns']+col:row*state['columns']+col+3]
                    return ''.join(cell[0] for cell in cells)

                for index in (3, 5):
                    plugin_id = f'capture_plugin_{index:02}'
                    box = state['checkboxes'][plugin_id]
                    check(plugin_id + ' initially unchecked', marker(state, plugin_id) == '[ ]')
                    point(state, int(box['x']+.5)+1, int(box['y']+.5), click=True)
                    state = capture(f'19-plugin-selected-{index}')
                    check(plugin_id + ' checked without scrolling',
                          state['checkboxes'][plugin_id]['checked'] and marker(state, plugin_id) == '[✓]')
                state = capture('20-plugin-fractional-scroll', catalog_scroll=5.25)
                check('checkbox persists at fractional scroll', marker(state, 'capture_plugin_05') == '[✓]')
                xdo('click', '5')
                time.sleep(.3)
                state = capture('21-plugin-scrolled')
                check('plugin list scrolled', state['catalog_scroll'] > 5.25)
                check('checkbox persists after wheel scroll', marker(state, 'capture_plugin_05') == '[✓]')
                state = capture('22-plugin-top', catalog_scroll=0)
                box = state['checkboxes']['capture_plugin_05']
                point(state, int(box['x']+.5)+1, int(box['y']+.5), click=True)
                state = check_preview('23-plugin-unchecked')
                check('checkbox clears without scrolling',
                      not state['checkboxes']['capture_plugin_05']['checked']
                      and marker(state, 'capture_plugin_05') == '[ ]')
                check('other selected checkbox persists', marker(state, 'capture_plugin_03') == '[✓]')
            else:
                print('SKIP Plugin Manager captures: provide --plugin-manager with its view source')
            for image_path in (raster, vector):
                kind = image_path.suffix[1:]
                command('Core: Open File')
                key('ctrl+a')
                xdo('type', '--clearmodifiers', str(image_path))
                key('Return')
                state = check_preview('24-image-' + kind)
                check(kind + ' opens with correct dimensions',
                      state.get('image', {}).get('source') == [128, 64])
                def check_image(name, state):
                    if shutil.which('chafa'):
                        # The opaque red/orange fixture must contribute colored
                        # cells, not merely retain dimensions and a placeholder.
                        check(name + ' draws Chafa colors', any(
                            color >> 16 > 150 and ((color >> 8) & 255) < 110
                            and (color & 255) < 70
                            for cell in state['cells'] for color in cell[1:3]))
                    else:
                        check(name + ' shows installation hint',
                              find(state, 'Install chafa') is not None)
                check_image(kind, state)
                command('Image View: Zoom In')
                state = check_preview('25-image-zoom-' + kind)
                check(kind + ' zooms without error', state['image']['zoom'] == 1.5
                      and state['image']['width'] == 192 and state['image']['height'] == 96)
                check_image(kind + ' zoomed', state)
            capture('26-welcome-open', welcome=True)
            # EmptyView lays out newly created children on the next update.
            state = capture('26-welcome')
            col, row = find(state, '~/Development/project')
            point(state, col + 2, row, click=True)
            state = check_preview('27-recent-project-highlight')
            for border in state['list_borders']:
                cell = state['cells'][row * state['columns'] + border]
                adjacent = state['cells'][(row + 2) * state['columns'] + border]
                check('recent project border at column ' + str(border),
                      cell[0] == '│' and cell[2] == adjacent[2]
                      and cell[2] != state['line_highlight'])
            for offset in (0,8,15.25,31.5):
                state = capture('27-recent-project-scroll-' + str(offset), list_scroll=offset)
                for index in (3,7):
                    col,row = find(state, f'~/Development/project-{index:02}')
                    point(state,col+5,row,click=True)
                    state = check_preview(f'27-recent-project-{offset}-{index}')
                    check(f'recent project click and hover agree at {offset}, item {index}',
                          state['list']['selected'] == index and state['list']['hovered'] == index)
                    background = lambda r: state['cells'][r*state['columns']+col+5][2]
                    check(f'recent project highlight occupies its label row at {offset}, item {index}',
                          background(row) == state['line_highlight']
                          and background(row-1) != background(row)
                          and background(row+1) != background(row))
            capture('27-palette-open', palette_fixture=True, commandview_position='center')
            state = check_palette('27-palette-long-results')
            for offset in (1,7,8,15,31.5,320.5):
                capture('27-palette-scroll-' + str(offset), palette_scroll=offset)
                state = check_palette('27-palette-checked-' + str(offset))
            px,py,pw,ph = state['palette']['thumb']
            bx,by,bw,bh = state['palette']['track']
            point(state, px, py)
            xdo('mousedown','1')
            point(state, bx, by+bh-2)
            xdo('mouseup','1')
            state = check_palette('27-palette-after-drag')
            key('Escape')
            capture('28-tree-show', tree_prepare=True)
            capture('28-tree-scroll-end', tree_scroll_end=True)
            state = check_preview('28-tree-bottom')
            tx, ty, tw, th = state['tree']['track']
            vx, vy, vw, vh = state['tree']['viewport']
            check('visible tree has horizontal overflow', vw > 0 and vh > 0 and tw > 0 and th == 1)
            check('last tree item is reachable above scrollbar', find(state, 'tree-boundary-69')[1] < ty)
            check('tree rows stay above horizontal scrollbar', all(
                not state['cells'][r*state['columns']+c][0].isalnum()
                for r in range(int(ty), int(vy+vh+.5))
                for c in range(int(vx+.5), int(vx+vw+.5))))
            previous_scroll = state['tree']['scroll']
            for attempt, fraction in enumerate((.25,.35,.45)):
                tx,ty,tw,th = state['tree']['thumb']
                bx,by,bw,bh = state['tree']['vertical_track']
                point(state,tx,ty)
                xdo('mousedown','1')
                point(state,bx,by+bh*fraction)
                xdo('mouseup','1')
                state = capture('29-tree-after-drag-' + str(attempt))
                vx,vy,vw,vh = state['tree']['viewport']
                if round(vy*16-state['tree']['scroll']) % 16 != 0:
                    break
            check('tree scrollbar drag changes the scroll offset',
                  abs(state['tree']['scroll']-previous_scroll) > 16)
            check('tree scrollbar drag exercises a partial text row',
                  round(vy*16-state['tree']['scroll']) % 16 != 0)
            # Mouse movement must highlight precisely the row whose label it covers.
            for row in (8,12,16):
                point(state,vx+8,row)
                time.sleep(.4)  # Let the path tooltip settle before repaint comparisons.
                state = check_preview('29-tree-hover-' + str(row))
                displayed = ''.join(c[0] for c in state['cells'][
                    row*state['columns']+int(vx)+1:row*state['columns']+int(vx+vw)-2])
                hovered = state['tree']['hovered']
                check('tree hover targets displayed file at row ' + str(row),
                      bool(hovered) and hovered[:16] in displayed)
                col = int(vx+.5)+1
                background = lambda r: state['cells'][r*state['columns']+col][2]
                check('tree hover fills only its label row ' + str(row),
                      background(row) != background(row-1)
                      and background(row) != background(row+1))
            command('Core: Force Quit')
            terminal.wait(timeout=5)
            check('clean exit', terminal.returncode == 0)
        finally:
            (output / 'checks.json').write_text(json.dumps(checks, indent=2))
            if terminal is not None and terminal.poll() is None:
                os.killpg(terminal.pid, signal.SIGTERM)
                terminal.wait(timeout=5)
            if xvfb is not None:
                xvfb.terminate()
                xvfb.wait(timeout=5)
    print('Captures:', output)


if __name__ == '__main__':
    main()
