#!/usr/bin/env python3
"""Compare global Pragtical's GUI and TUI in isolated profiles (Linux).

Creates paired screenshots, geometry snapshots and contact sheets for built-in
views. Requires Xvfb, xfce4-terminal, xdotool and Pillow. Profiles and artifacts
stay under /tmp by default; the normal editor configuration is never modified.
"""
import argparse
from html import escape
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

from PIL import Image, ImageDraw, ImageGrab


SCENES = (
    'welcome-startup', 'welcome-reopened', 'welcome-hover', 'welcome-scrolled',
    'docview', 'docview-scrolled', 'docview-blank-lines',
    'docview-whitespace', 'docview-whitespace-selected',
    'docview-whitespace-error', 'docview-whitespace-disabled',
    'settings-core', 'settings-expanded', 'settings-imageviewer', 'settings-colors',
    'settings-colors-bottom', 'settings-plugins', 'settings-plugins-expanded',
    'settings-plugins-hover', 'settings-plugins-toggle-hover', 'settings-plugins-scrolled',
    'settings-keybindings', 'commandview-bottom', 'commandview-top',
    'commandview-center', 'commandview-scrolled', 'find', 'projectsearch-left',
    'projectsearch-right', 'projectsearch-center', 'markdownview',
    'markdownview-scrolled', 'markdownview-returned', 'imageview', 'imageview-zoom',
    'audioview', 'logview', 'about-contributors', 'about-scrolled', 'about-moved',
    'about-license', 'nagview', 'messagebox', 'colorpicker', 'fontslist',
    'plugin-manager', 'application-menu', 'application-search',
    'application-edit-submenu', 'application-sessions', 'contextmenu',
    'contextmenu-selected', 'treeview-scrolled', 'treeview-tooltip', 'docview-split', 'titleview',
)

DRIVER = r'''
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local json = require "core.json"
local fixture = __FIXTURE__
config.plugins.ipc = false
config.plugins.workspace = false
config.transitions = false
config.disable_blink = true
-- Xvfb can advertise a zero refresh rate; use a bounded test frame rate.
config.auto_fps, config.fps = false, 60
local pending, frames, document, drawn, rectangles, draw_clip, after_layout, about, terminal_grid
if ARGS[2] == "tui" then
  local Grid=require "plugins.tui.grid"
  local present=Grid.present
  function Grid:present(...) terminal_grid=self;return present(self,...) end
end
local begin_frame, draw_text, draw_rect, set_clip = renderer.begin_frame, renderer.draw_text, renderer.draw_rect, renderer.set_clip_rect
function renderer.begin_frame(...)
  if pending then drawn,rectangles = {},{} end
  return begin_frame(...)
end
function renderer.set_clip_rect(x,y,w,h)
  draw_clip = {x,y,w,h}
  return set_clip(x,y,w,h)
end
function renderer.draw_text(font,text,x,y,color,...)
  if pending then drawn[#drawn+1] = {text=tostring(text),x=x,y=y,clip=draw_clip} end
  return draw_text(font,text,x,y,color,...)
end
function renderer.draw_rect(x,y,w,h,color)
  if pending then rectangles[#rectangles+1] = {x=x,y=y,w=w,h=h,color=color,clip=draw_clip} end
  return draw_rect(x,y,w,h,color)
end
local dialogs = {}
local function add(view)
  core.root_view:get_active_node_default():add_view(view)
  return view
end
local function doc()
  if not document then document = core.open_file(fixture .. "/sample.lua") end
  local node = core.root_view.root_node:get_node_for_view(document)
  if node then node:set_active_view(document) end
  return document
end
local function rect(view)
  return {view.position.x, view.position.y, view.size.x, view.size.y}
end
local function snapshot()
  local view = core.active_view
  local data = {name=pending.name, view=tostring(view), bounds=rect(view),
    scale=SCALE, padding={style.padding.x,style.padding.y}, widgets={}, popups={}, drawn=drawn,rectangles=rectangles}
  if view.doc then data.line_height=view:get_line_height() end
  data.divider_color=style.divider[1]*65536+style.divider[2]*256+style.divider[3]
    data.highlight_color=style.line_highlight[1]*65536+style.line_highlight[2]*256+style.line_highlight[3]
  if terminal_grid then
    data.columns,data.rows=terminal_grid.columns,terminal_grid.rows
    data.cells={}
    for i,cell in ipairs(terminal_grid.cells) do data.cells[i]={cell[1],cell[2],cell[3]} end
  end
  data.views = {}
  for _, item in ipairs(core.root_view.root_node:get_children()) do
    if item.childs then
      data.views[#data.views+1] = {type=tostring(item),bounds=rect(item),
        h=item:get_h_scrollable_size(),v=item:get_scrollable_size(),
        hbar={item.h_scrollbar.rect.w,item.h_scrollbar.rect.h,
          tostring(item.h_scrollbar.rect.scrollable)}}
    end
  end
  if view.subparent then
    data.input = {text=view.doc.lines[1], scroll={view.scroll.x,view.scroll.y},
      parent=rect(view.subparent), origin={view:get_content_offset()},
      line_height=view:get_line_height(),range={view:get_visible_line_range()},
      line_position={view:get_line_screen_position(1)}}
  end
  local function widget(item, path)
    if not item.childs or not item:is_visible() then return end
    local entry = {path=path, type=item.type_name, bounds=rect(item)}
    if type(item.label) == "string" then entry.label = item.label end
    if type(item.padding) == "table" then entry.padding = {item.padding.x,item.padding.y} end
    if item.type_name == "widget.colorpicker" then
      entry.selector={item.selector.x,item.selector.y,item.selector.w,item.selector.h}
    end
    if item.rows then
      entry.row_heights = {}
      for i,row in ipairs(item.rows) do
        if type(row) == "table" then entry.row_heights[i] = row.h end
      end
      entry.visible_rows=item.visible_rows
    end
    if item.type_name == "widget.widgetlist" then
      entry.items={}
      for _,row in ipairs(item.items) do
        entry.items[#entry.items+1]={name=row.data.name,height=row.height,
          hovered=row.row.hovered or false,bounds=rect(row.row)}
      end
    end
    data.widgets[#data.widgets+1] = entry
    for i,child in ipairs(item.childs) do widget(child,path.."/"..i) end
  end
  widget(view,"active")
  if view.recent_projects then
    data.welcome = {buttons={}, top={view.top_container.padding.x,
      view.top_container.padding.y,view.top_container.spacing},
      center={view.center_container.padding.x,view.center_container.padding.y,
        view.center_container.spacing}, rows={}}
    for _,name in ipairs({"new_file","open_file","open_folder","change_folder",
      "find_file","run_command","settings","website","docs","plugins"}) do
      local button = view[name]
      data.welcome.buttons[name] = {button.size.x,button.size.y,
        button.padding.x,button.padding.y,button.position.rx,button.position.ry}
    end
    for i,row in ipairs(view.recent_projects.rows) do data.welcome.rows[i] = row.h end
  end
  for _,popup in ipairs(core.root_view.floating_views) do
    if popup.floating_visible then
      data.popups[#data.popups+1] = {name=tostring(popup),bounds={popup:get_floating_bounds()}}
      widget(popup,"popup"..#data.popups)
    end
  end
  return data
end
local function scene(name)
  if name == "welcome-startup" then return end
  for _,dialog in ipairs(dialogs) do
    dialog:hide()
  end
  dialogs = {}
  if core.nag_view.visible then core.nag_view:next() end
  core.menu_view.menu:hide()
  if core.command_view.state then core.command_view:exit() end
  command.perform("search-replace:hide")
  require("plugins.projectsearch").hide()
  config.plugins.drawwhitespace.enabled = false
  if name:match("^welcome") then
    local EmptyView = require "core.emptyview"
    local view = core.active_view.recent_projects and core.active_view or add(EmptyView())
    if name == "welcome-reopened" then view=add(EmptyView()) end
    if name == "welcome-hover" or name == "welcome-scrolled" then
      after_layout = function()
        local list = view.recent_projects
        list.scroll.y = name == "welcome-scrolled" and 8 or 0
        list.scroll.to.y = list.scroll.y
        list:update()
        local x = list.position.x+40
        local y = list.position.y + style.font:get_height()*4+8
        core.on_event("mousemoved",x,y,0,0)
        core.on_event("mousepressed","left",x,y,1)
        core.on_event("mousereleased","left",x,y)
      end
    end
  elseif name == "docview" or name == "docview-scrolled" then
    local view = doc()
    view.doc:set_selection(4,3,5,18)
    view.scroll.y = name == "docview" and 0 or view:get_line_height()*10+3.25
    view.scroll.to.y = view.scroll.y
  elseif name == "docview-blank-lines" then
    core.open_file(fixture.."/sample.sh")
  elseif name:match("^docview%-whitespace") then
    local view=core.open_file(fixture.."/whitespace.lua")
    view.doc:set_selection(1,1,1,3)
    local options=config.plugins.drawwhitespace
    options.enabled=name ~= "docview-whitespace-disabled"
    options.show_selected_only=name == "docview-whitespace-selected"
    options.show_trailing_error=name == "docview-whitespace-error"
    options.color=style.syntax.whitespace or style.syntax.comment
  elseif name:match("^settings") then
    command.perform("ui:settings")
    local settings = require("plugins.settings").ui
    local pane = name:gsub("^settings%-", "")
    if pane == "expanded" then
      pane = "core"
      for _,section in ipairs(settings.core_sections.panes) do
        settings.core_sections:toggle_pane(section.name,true)
      end
    elseif pane == "imageviewer" then
      pane = "core"
      for _,section in ipairs(settings.core_sections.panes) do
        if section.name:lower():find("image") then
          settings.core_sections:toggle_pane(section.name,true)
          after_layout=function() settings.core.scroll.y=section.tab.position.ry
            settings.core.scroll.to.y=settings.core.scroll.y end
        end
      end
    elseif pane:match("^plugins%-") then
      local mode=pane
      pane = "plugins"
      local section = settings.plugin_sections:get_pane("enable_disable")
      settings.plugin_sections:toggle_pane("enable_disable",true)
      after_layout=function()
        for _,list in ipairs(section.container.childs) do
          if list.type_name == "widget.widgetlist" then
            list.scroll.y=mode == "plugins-scrolled" and 31.5 or 0
            list.scroll.to.y=list.scroll.y
            if mode:find("hover") then
              local row=list.items[4].row
              local x=row.position.x+32
              if mode == "plugins-toggle-hover" then
                for _,child in ipairs(row.childs) do
                  if child.type_name == "widget.toggle" then x=child.position.x+child.toggle_x+16 end
                end
              end
              local y=row.position.y+row.size.y/2
              if ARGS[2] == "tui" then
                x=math.floor(x/8)*8+4
                y=math.floor(row.position.y/16+.5)*16+8
              end
              core.on_event("mousemoved",x,y,0,0)
            end
          end
        end
      end
    elseif pane == "colors-bottom" then
      pane = "colors"
      after_layout=function()
        for _,child in ipairs(settings.colors.childs) do
          if child.type_name == "widget.listbox" then
            child.scroll.y=math.max(0,child:get_scrollable_size()-child.size.y)
            child.scroll.to.y=child.scroll.y
          end
        end
      end
    end
    settings.notebook:set_pane(pane)
  elseif name:match("^commandview") then
    doc()
    config.commandview_position = name == "commandview-scrolled" and "center" or name:gsub("^commandview%-", "")
    core.command_view:enter("Search:", {text="sample", select_text=false,
      suggest=function() local rows={} for i=1,30 do
        rows[i]={text="sample result "..i..string.rep(" long text",8), info="line: "..i}
      end return rows end, show_suggestions=true})
    if name == "commandview-scrolled" then
      after_layout=function()
        core.command_view.suggestions_view.scroll.y=31.5
        core.command_view.suggestions_view.scroll.to.y=31.5
        core.command_view.reveal_suggestion=false
      end
    end
  elseif name == "find" then
    doc().doc:set_selection(1,7,1,13)
    command.perform("find-replace:find")
  elseif name:match("^projectsearch") then
    doc().doc:set_selection(1,7,1,13)
    config.plugins.projectsearch.position = name:gsub("^projectsearch%-", "")
    command.perform("project-search:find")
  elseif name:match("^markdownview") then
    local view=core.open_markdown(fixture.."/sample.md")
    view.scroll.y=name == "markdownview-scrolled" and 203.25 or 0
    view.scroll.to.y=view.scroll.y
  elseif name:match("^imageview") then
    core.open_image(fixture.."/sample.png")
    if name == "imageview-zoom" then command.perform("image-view:zoom-in") end
  elseif name == "audioview" then
    local player = core.open_audio("")
    for i=1,12 do player:add_track({path=fixture.."/track"..i..".wav",
      name="Track "..i,folder=fixture,format="wav"}) end
  elseif name == "logview" then
    core.log("Comparison info entry")
    core.warn("Comparison warning entry")
    core.error("Comparison error entry")
    command.perform("core:open-log")
  elseif name:match("^about") then
    command.perform("core:view-about")
    for _,popup in ipairs(core.root_view.floating_views) do
      if popup.panel then
        dialogs[#dialogs+1] = popup
        about = popup.panel.childs[1]
        if about and about.notebook then
          about.notebook:set_pane(name == "about-license" and "license" or "contributors")
          if name == "about-scrolled" then
            after_layout=function()
              about.contributors.scroll.y=120.5
              about.contributors.scroll.to.y=120.5
            end
          elseif name == "about-moved" then
            after_layout=function()
              local x,y = popup:get_floating_drag_region()
              core.on_event("mousepressed","left",x+40,y+8,1)
              core.on_event("mousemoved",x+80,y+40,40,32)
              core.on_event("mousereleased","left",x+80,y+40)
            end
          end
        end
      end
    end
  elseif name == "nagview" then
    doc()
    core.nag_view:show("Unsaved Changes", "A comparison prompt with wrapping text. "
      ..string.rep("Keep all controls and text visible. ",8),
      {{text="Cancel"},{text="Discard"},{text="Save",default_yes=true}},function() end)
  elseif name == "messagebox" then
    local MessageBox = require "widget.messagebox"
    local dialog = MessageBox(nil,"Message", "A message with buttons and wrapped text.",MessageBox.ICON_INFO)
    dialog:add_button("Cancel")
    dialog:add_button("Continue")
    dialog:show()
    dialogs[#dialogs+1] = dialog
  elseif name == "colorpicker" then
    local Widget = require "widget"
    local ColorPicker = require "widget.colorpicker"
    local panel = Widget(nil,false)
    panel.name = "Color Picker"
    panel.scrollable = true
    local picker = ColorPicker(panel,{80,160,220,255})
    picker:set_position(style.padding.x,style.padding.y)
    add(panel)
    panel:show()
  elseif name == "fontslist" then
    local Widget = require "widget"
    local FontsList = require "widget.fontslist"
    local panel = Widget(nil,false)
    panel.name="Fonts"
    local list=FontsList(panel)
    list:set_size(500,400)
    add(panel);panel:show()
  elseif name == "plugin-manager" then
    local PluginView=assert(loadfile(DATADIR.."/plugins/plugin_manager/plugin_view.lua"))()
    config.plugins.plugin_manager=config.plugins.plugin_manager or {}
    local catalog={}
    for i=1,30 do catalog[i]={id="capture_plugin_"..i,type="plugin",status="available",version="1.0",
      description="Offline comparison fixture"} end
    local manager={addons=catalog,valid_addons=catalog}
    function manager:refresh() return {done=function(self,fn) fn();return self end,fail=function(self) return self end} end
    add(PluginView(manager))
  elseif name:match("^application") then
    if name == "application-search" or name == "application-edit-submenu" then
      local EmptyView = require "core.emptyview"
      add(EmptyView())
    else doc() end
    core.menu_view:open(name == "application-search" and 3 or name == "application-edit-submenu" and 2 or 1)
    if name == "application-edit-submenu" or name == "application-sessions" then
      after_layout=function()
        local menu=core.menu_view.menu
        for i,item in ipairs(menu.items) do
          if item.text == (name == "application-sessions" and "Sessions" or "Lines") then
            menu.selected=i;menu:open_submenu();break
          end
        end
      end
    end
  elseif name:match("^contextmenu") then
    doc()
    local ContextMenu = require "core.contextmenu"
    local menu = ContextMenu()
    menu:register(nil,{{text="Copy",command="doc:copy"},ContextMenu.DIVIDER,
      {text="Select All",command="doc:select-all"},{text="Checked item",checked=true,command=function() end}})
    menu:show(360,200)
    if name == "contextmenu-selected" then menu:focus_next() end
    dialogs[#dialogs+1] = menu
  elseif name == "treeview-scrolled" then
    doc()
    local tree=require "plugins.treeview"
    after_layout=function()
      tree.scroll.y,tree.scroll.to.y=203.5,203.5
      core.on_event("mousemoved",tree.position.x+80,tree.position.y+80,0,0)
    end
  elseif name == "treeview-tooltip" then
    doc()
    local tree=require "plugins.treeview"
    after_layout=function()
      for item,x,y,w,h in tree:each_item() do
        if item.type == "file" and y > tree.position.y and y+h < tree.position.y+tree.size.y then
          core.on_event("mousemoved",x+60,y+h/2,0,0)
          tree.tooltip.begin=system.get_time()-2
          tree.tooltip.alpha=255
          break
        end
      end
    end
  elseif name == "docview-split" then
    local DocView = require "core.docview"
    local view = doc()
    core.root_view:get_active_node_default():split("right",DocView(view.doc))
  elseif name == "titleview" then
    config.borderless = true
    core.configure_borderless_window()
  end
end
local end_frame = renderer.end_frame
function renderer.end_frame(...)
  end_frame(...)
  if not pending then return end
  frames = frames+1
  if frames == 3 and after_layout then
    local action=after_layout
    after_layout=nil
    action()
    frames=0;core.redraw=true;return
  end
  if frames < 5 then core.redraw=true; return end
  local file = assert(io.open(USERDIR.."/state.tmp","w"))
  file:write(json.encode(snapshot())); file:close()
  os.rename(USERDIR.."/state.tmp",USERDIR.."/state.json")
  pending = nil
end
core.add_thread(function()
  while true do
    local file = io.open(USERDIR.."/request.json","r")
    if file then
      local request = json.decode(file:read("*a")); file:close()
      os.remove(USERDIR.."/request.json")
      if request.name == "quit" then core.quit(true); return end
      local ok,err = xpcall(function() scene(request.name) end, debug.traceback)
      if not ok then
        local output=assert(io.open(USERDIR.."/state.json","w"))
        output:write(json.encode({name=request.name,error=err})); output:close()
      else pending,frames=request,0 end
      core.redraw = true
    end
    coroutine.yield(.05)
  end
end)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=shutil.which('pragtical'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--sizes', default='100x36,147x41', help='Terminal columns x rows')
    parser.add_argument('--scenes', default=','.join(SCENES))
    parser.add_argument('--font', default='Hack Nerd Font 10')
    parser.add_argument('--gui-scale', type=float, default=1, help='Graphical UI scale for comparison')
    args = parser.parse_args()
    unknown = set(args.scenes.split(','))-set(SCENES)
    if unknown: parser.error('unknown scenes: '+', '.join(sorted(unknown)))
    scenes = args.scenes.split(',')
    if 'welcome-startup' in scenes:
        scenes.remove('welcome-startup')
        scenes.insert(0,'welcome-startup')
    output = (args.output or Path(tempfile.mkdtemp(prefix='pragtical-tui-compare-'))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    fixture = output/'project'
    fixture.mkdir(exist_ok=True)
    (fixture/'sample.lua').write_text(''.join(
        f'local sample_{i} = "line {i}: visible text and syntax"\n' for i in range(1,101)))
    (fixture/'sample.sh').write_text(('''# Shell fixture with empty lines
case $- in
  *i*) ;;
  *) return ;;
esac

# Comment followed by a blank line

export VALUE="example"

''')*8)
    (fixture/'whitespace.lua').write_text('  local value = "with  spaces"  \n'
        '\tlocal tabbed\t= true \nlocal wide = "界 e\u0301"  \n  \n')
    (fixture/'sample.md').write_text('# Preview\n\n' + ('## Heading\n\nA **bold** paragraph '
        'with `inline code`, Unicode café and [links](https://pragtical.dev).\n\n'
        '- First item\n- Second item\n\n| A | B |\n| --- | --- |\n| One | Two |\n\n')*8)
    Image.new('RGB',(160,80),(80,160,220)).save(fixture/'sample.png')
    recents = [fixture]
    for i in range(1,30):
        path = fixture/f'project-{i:02}'
        path.mkdir(exist_ok=True)
        recents.append(path)
    checks,errors = [],[]
    xvfb = None
    with (output/'display.log').open('w') as log:
        try:
            read_fd,write_fd = os.pipe()
            xvfb = subprocess.Popen(['Xvfb','-displayfd',str(write_fd),'-screen','0',
                '1920x1200x24','-nolisten','tcp'],pass_fds=(write_fd,),stdout=log,stderr=log)
            os.close(write_fd)
            display = ':'+os.read(read_fd,30).decode().strip()
            os.close(read_fd)
            env = dict(os.environ, DISPLAY=display,GDK_BACKEND='x11',SDL_VIDEO_DRIVER='x11',
                SDL_AUDIO_DRIVER='dummy',PRAGTICAL_SCALE='1',PRAGTICAL_SCALE_CODE='1',
                PRAGTICAL_RENDERER='surface')

            def xdo(*args):
                return subprocess.run(['xdotool',*map(str,args)],env=env,check=True,
                    capture_output=True,text=True).stdout.strip()

            for size in args.sizes.split(','):
                cols,rows = map(int,size.split('x'))
                dimensions = (cols*8+2,rows*17+2)
                for backend in ('tui','gui'):
                    directory = output/size/backend
                    directory.mkdir(parents=True,exist_ok=True)
                    profile = directory/'profile'
                    (profile/'plugins').mkdir(parents=True,exist_ok=True)
                    (profile/'plugins/tui').symlink_to(Path(__file__).resolve().parents[1],
                        target_is_directory=True)
                    config = ('return {config={theme="cold_lime",borderless=false,transitions=false,line_height=1.2,auto_fps=false,fps=60,'
                        'use_system_file_picker=false,plugins={tui={nerdicons=true},'
                        'ipc=false,workspace=false,scale={autodetect=false,default_scale=1}}}}')
                    (profile/'user_settings.lua').write_text(config)
                    (profile/'session.lua').write_text('return {window={'
                        +f'{dimensions[0]},{dimensions[1]},0,0'+'},recents={'
                        +','.join(json.dumps(str(path)) for path in recents)+'}}')
                    (profile/'init.lua').write_text(DRIVER.replace('__FIXTURE__',json.dumps(str(fixture))))
                    run_env = dict(env,PRAGTICAL_USERDIR=str(profile))
                    if backend == 'gui':
                        run_env['PRAGTICAL_SCALE']=str(args.gui_scale)
                        run_env['PRAGTICAL_SCALE_CODE']=str(args.gui_scale)
                        config=config.replace('default_scale=1}',f'default_scale={args.gui_scale}'+'}')
                        (profile/'user_settings.lua').write_text(config)
                    if backend == 'tui':
                        run_env['SDL_VIDEO_DRIVER'] = 'dummy'
                        command = ['xfce4-terminal','--disable-server','--hide-menubar','--hide-toolbar',
                            '--hide-scrollbar','--font='+args.font,'--geometry='+size,
                            '--working-directory='+str(fixture),'-x',str(args.binary),'tui',str(fixture)]
                        pattern = 'Xfce4-terminal'
                    else:
                        command = [str(args.binary),str(fixture)]
                        pattern = 'pragtical'
                    with (directory/'process.log').open('w') as process_log:
                        process = subprocess.Popen(command,env=run_env,stdout=process_log,
                            stderr=process_log,start_new_session=True)
                        try:
                            window = None
                            for _ in range(100):
                                search = ['--pid',str(process.pid)] if backend == 'gui' else ['--class',pattern]
                                visibility = [] if backend == 'gui' else ['--onlyvisible']
                                result = subprocess.run(['xdotool','search',*visibility,*search],
                                    env=env,capture_output=True,text=True)
                                if result.stdout.strip():
                                    window = result.stdout.splitlines()[-1]
                                    break
                                if process.poll() is not None: break
                                time.sleep(.1)
                            if window is None: raise RuntimeError('No window: '+str(directory/'process.log'))
                            if backend == 'gui': xdo('windowmap',window)
                            xdo('windowfocus',window)
                            xdo('windowmove',window,0,0)
                            time.sleep(.7)
                            geometry = dict(line.split('=',1) for line in
                                xdo('getwindowgeometry','--shell',window).splitlines())
                            dimensions = (int(geometry['WIDTH']),int(geometry['HEIGHT']))
                            for name in scenes:
                                (profile/'request.tmp').write_text(json.dumps({'name':name}))
                                (profile/'request.tmp').replace(profile/'request.json')
                                deadline = time.monotonic()+15
                                while time.monotonic()<deadline:
                                    state_file = profile/'state.json'
                                    if state_file.exists():
                                        state = json.loads(state_file.read_text())
                                        if state['name'] == name: break
                                    if process.poll() is not None: raise RuntimeError('Editor exited: '+str(directory))
                                    time.sleep(.05)
                                else: raise RuntimeError('Scene timed out: '+name+' in '+str(directory))
                                if 'error' in state:
                                    errors.append({'backend':backend,'size':size,'scene':name,'error':state['error']})
                                    print('ERROR',backend,size,name,state['error'].splitlines()[0],flush=True)
                                (directory/(name+'.json')).write_text(json.dumps(state,indent=2))
                                time.sleep(.15)
                                frame = ImageGrab.grab(xdisplay=display)
                                frame.crop((0,0,*dimensions)).save(directory/(name+'.png'))
                                print('CAPTURE',backend,size,name,flush=True)
                                if backend == 'tui' and 'error' not in state:
                                    def check(label, passed):
                                        checks.append({'name':size+' '+name+' '+label,'passed':bool(passed)})
                                        print('PASS' if passed else 'FAIL',checks[-1]['name'],flush=True)
                                    if 'line_height' in state:
                                        check('uses one row per text line',state['line_height'] == 16)
                                    if name.startswith('docview-whitespace'):
                                        dots=sum(cell[0]=='·' for cell in state['cells'])
                                        tabs=sum(cell[0]=='»' for cell in state['cells'])
                                        error_blocks=sum(cell[0]=='█' for cell in state['cells'])
                                        if name.endswith('disabled'):
                                            check('disabled markers disappear',dots == tabs == error_blocks == 0)
                                        elif name.endswith('selected'):
                                            check('only selected spaces have markers',dots == 2 and tabs == error_blocks == 0)
                                        elif name.endswith('error'):
                                            check('trailing error blocks and other markers survive',error_blocks > 0 and dots > 0 and tabs == 2)
                                        else:
                                            check('spaces and tabs remain visible',dots > 10 and tabs == 2 and error_blocks == 0)
                                    if 'input' in state:
                                        left,top,width,height=state['input']['parent']
                                        row=int(top/16+.5)
                                        cells=state['cells'][row*state['columns']:(row+1)*state['columns']]
                                        text=''.join(cell[0] for cell in cells[int(left/8+.5):int((left+width)/8+.5)])
                                        check('focused query is visible',state['input']['text'].strip()[:12] in text)
                                    for index,popup in enumerate(state['popups']):
                                        if popup['name'] != 'ContextMenu': continue
                                        x,y,w,h=popup['bounds']
                                        left,right=int(x/8),int((x+w)/8)-1
                                        top,bottom=int(y/16),int((y+h)/16)-1
                                        check('menu '+str(index)+' has thin top and bottom strokes',all(
                                            state['cells'][row*state['columns']+col][0] == '─'
                                            and state['cells'][row*state['columns']+col][2] != state['divider_color']
                                            for row in (top,bottom) for col in range(left+1,right)))
                                    for widget in state['widgets']:
                                        if name.startswith('settings-plugins-') and 'items' in widget:
                                            check('installed rows occupy whole text lines',all(
                                                item['height'] == 16 for item in widget['items']))
                                            if 'hover' in name:
                                                hovered=[item for item in widget['items'] if item['hovered']]
                                                check('exactly the pointed row is highlighted',len(hovered) == 1
                                                    and hovered[0]['name'] == widget['items'][3]['name'])
                                                if len(hovered) == 1:
                                                    x,y,w,h=hovered[0]['bounds']
                                                    col,row=int(x/8+.5)+20,int(y/16+.5)
                                                    check('highlight occupies one terminal row',
                                                        state['cells'][row*state['columns']+col][2] == state['highlight_color']
                                                        and state['cells'][(row-1)*state['columns']+col][2] != state['highlight_color']
                                                        and state['cells'][(row+1)*state['columns']+col][2] != state['highlight_color'])
                                        if 'selector' in widget and 0 <= widget['selector'][1] <= (state['rows']-4)*16:
                                            check('color gradients have full cell rows',widget['selector'][3] == 16)
                                            check('four visible gradient handles',sum(cell[0]=='◆' for cell in state['cells']) == 4)
                                        if name == 'messagebox' and widget['type'] == 'widget.button':
                                            x,y,w,h=widget['bounds']
                                            row=int(y/16+.5)
                                            text=''.join(cell[0] for cell in state['cells'][row*state['columns']:(row+1)*state['columns']])
                                            check(widget['label']+' button is visible',widget['label'] in text)
                                        if name == 'about-contributors' and widget.get('visible_rows'):
                                            height=widget['bounds'][3]
                                            expected=min(len(widget['row_heights']),int(height/16)-3)
                                            check('contributors fill the resized list',max(widget['visible_rows']) >= expected)
                            if all((directory/(name+'.json')).is_file() for name in
                                ('welcome-startup','welcome-reopened')):
                                before = json.loads((directory/'welcome-startup.json').read_text())
                                after = json.loads((directory/'welcome-reopened.json').read_text())
                                passed = bool(before.get('welcome')) and before.get('welcome') == after.get('welcome')
                                checks.append({'name':backend+' '+size+' startup equals reopened Welcome','passed':passed})
                                print('PASS' if passed else 'FAIL',checks[-1]['name'],flush=True)
                            (profile/'request.json').write_text('{"name":"quit"}')
                            process.wait(timeout=8)
                        finally:
                            if process.poll() is None:
                                os.killpg(process.pid,signal.SIGTERM)
                                process.wait(timeout=5)
                for name in scenes:
                    paths = [output/size/backend/(name+'.png') for backend in ('gui','tui')]
                    images = [Image.open(path).convert('RGB') for path in paths]
                    width = max(image.width for image in images)
                    height = max(image.height for image in images)
                    sheet = Image.new('RGB',(width*2,height+28),(35,35,35))
                    draw = ImageDraw.Draw(sheet)
                    for i,(backend,image) in enumerate(zip(('GUI','TUI'),images)):
                        draw.text((width*i+8,7),backend+' / '+size+' / '+name,fill='white')
                        sheet.paste(image,(width*i,28))
                    sheet.save(output/size/(name+'-comparison.png'))
        finally:
            (output/'report.json').write_text(json.dumps({'checks':checks,'errors':errors},indent=2))
            if xvfb is not None:
                xvfb.terminate()
                xvfb.wait(timeout=5)
    print('Comparisons:',output)
    cards = []
    for size in args.sizes.split(','):
        for name in scenes:
            path = escape(size+'/'+name+'-comparison.png',quote=True)
            label = escape(size+' / '+name)
            cards.append(f'<figure><figcaption>{label}</figcaption><a href="{path}">'
                f'<img loading="lazy" src="{path}" alt="{label}"></a></figure>')
    (output/'index.html').write_text('<!doctype html><meta charset="utf-8">'
        '<title>Pragtical GUI and TUI comparisons</title><style>'
        'body{background:#202020;color:#eee;font:16px sans-serif;margin:24px}'
        'figure{margin:32px 0}figcaption{margin-bottom:8px}img{max-width:100%}'
        '</style><h1>GUI and TUI comparisons</h1>'
        '<p>GUI is on the left, TUI on the right. Click an image for full size.</p>'
        +''.join(cards))
    print('Checks:',sum(check['passed'] for check in checks),'passed,',
        sum(not check['passed'] for check in checks),'failed;',len(errors),'scene errors')
    if errors or any(not check['passed'] for check in checks): raise SystemExit(1)


if __name__ == '__main__':
    main()
