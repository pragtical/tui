-- mod-version:3.14 --priority:-3
local core = require "core"
local cli = require "core.cli"
local common = require "core.common"
local config = require "core.config"

---Terminal frontend. Loading the plugin only registers the CLI command unless
---the first argument explicitly requests it; no extra native module is required.
---@class plugins.tui
local tui = { active = false }
local prepared, session

---Configuration options for the terminal frontend.
---@class config.plugins.tui
---@field nerdicons boolean Use Nerd Font glyphs for the editor's bundled icons
config.plugins.tui = common.merge({
  nerdicons = false,
  config_spec = {
    name = "Terminal UI",
    {
      label = "Use Nerd Font Icons",
      description = "Use matching terminal icons. Requires a Nerd Font selected in your terminal. Restart to refresh cached icons.",
      path = "nerdicons",
      type = "toggle",
      default = false,
      on_apply = function() core.redraw = true end
    }
  }
}, config.plugins.tui)

---Restore the terminal before returning to the shell or replacing the Lua state.
function tui.close()
  if session and session.images then session.images:close() end
  if session and session.terminal then session.terminal:close() end
  tui.active = false
end

---Apply terminal geometry and process-local options after GUI settings are loaded.
local function set_terminal_metrics()
  local style = require "core.style"
  SCALE, DEFAULT_SCALE, DEFAULT_FPS = 1, 1, 50
  config.fps, core.fps, core.co_max_time = 50, 50, .016
  config.auto_fps, config.transitions, config.line_height = false, false, 1
  config.use_system_file_picker = false
  style.padding.x, style.padding.y = 8, 0
  style.divider_size, style.caret_width, style.tab_width = 1, 8, 160
  style.scrollbar_size, style.expanded_scrollbar_size = 8, 8
  style.minimum_thumb_size = 16
  style.contracted_scrollbar_margin, style.expanded_scrollbar_margin = 0, 0
end

---Prepare cell metrics before Settings and other plugins construct their UI.
local function prepare()
  if prepared then return end
  prepared = true
  local Grid = require "plugins.tui.grid"
  local drawing = require "plugins.tui.drawing"
  session = {grid = Grid.new(80, 24)}
  drawing.install(session)
  local widgets = require "plugins.tui.widgets"
  local refresh_widgets = widgets.install()
  local scale = require "plugins.scale"
  ---Terminal cells cannot be resized by the editor's font zoom controls.
  function scale.set() end
  ---Terminal code fonts use the same fixed cells as UI fonts.
  function scale.set_code() end
  ---@return number
  function scale.get() return 1 end
  ---@return number
  function scale.get_code() return 1 end
  -- Plugins construct controls before the CLI command runs. Give them their
  -- final metrics now so padding and cached row sizes never use GUI values.
  set_terminal_metrics()

  local run = core.run
  ---Replace the core's GUI placeholder after Settings applies terminal options.
  ---@param ... any Editor run arguments
  ---@return any result
  function core.run(...)
    set_terminal_metrics()
    local EmptyView = require "core.emptyview"
    local root = core.root_view.root_node
    for _, view in ipairs(root:get_children()) do
      if view:is(EmptyView) then
        root:get_node_for_view(view):add_view(EmptyView())
        view:destroy()
      end
    end
    refresh_widgets()
    return run(...)
  end
end

---Activate the frontend after CLI argument validation, before window creation.
function tui.start()
  if tui.active then return end
  if not LUAJIT then error("pragtical tui requires a LuaJIT build", 0) end
  prepare()
  local ffi = require "ffi"
  local Terminal = require "plugins.tui.terminal"
  local Input = require "plugins.tui.input"
  local style = require "core.style"
  local keymap = require "core.keymap"
  local DocView = require "core.docview"
  local views = require "plugins.tui.views"
  views.install()
  session.terminal = Terminal.open()
  -- The finalizer is a fallback for initialization failures and interpreter close.
  session.guard = ffi.gc(ffi.new("char[1]"), function() tui.close() end)
  local cols, rows = session.terminal:size()
  session.grid:resize(cols, rows)
  local colors = os.getenv("COLORTERM") or ""
  session.truecolor = PLATFORM == "Windows" or colors == "truecolor" or colors == "24bit"
  local input = Input.new()
  local clipboard, next_poll, focused = "", 0, true
  local window = {}

  ---@return number width
  ---@return number height
  function window:get_size() return session.grid.columns * 8, session.grid.rows * 16 end
  ---@return integer
  function window:get_refresh_rate() return 50 end
  ---@return table
  function window:get_renderer_info() return {backend = "terminal"} end
  ---VSync does not apply to terminal output.
  function window:set_vsync() end
  ---The next interpreter creates its own terminal adapter.
  function window:_persist() end
  ---@return renderer.color
  function window:get_color() return style.background end
  core.window = window
  -- Keep the previous GUI mode separately; macOS saves maximized geometry from
  -- get_window_size, which describes terminal cells during this session.
  core.window_mode = "normal"

  -- These are process-local adaptations; Settings stores explicitly changed
  -- options, and the window-state hook below preserves saved GUI geometry.
  set_terminal_metrics()


  ---Native decorations are replaced by the terminal application's window.
  function core.configure_borderless_window() core.title_view.visible = false end
  ---Preserve the GUI session's saved geometry instead of saving terminal cells.
  ---@return string
  function core.update_window_state() return core.window_mode end
  ---@return number width
  ---@return number height
  ---@return integer x
  ---@return integer y
  function system.get_window_size() local w, h = window:get_size(); return w, h, 0, 0 end
  ---@return string
  function system.get_window_mode() return "normal" end
  ---@return boolean
  function system.window_has_focus() return focused end
  ---@return number
  function system.get_scale() return 1 end
  ---@return number scale
  ---@return number fps
  ---@return number width
  ---@return number height
  ---@return number default_scale
  function system.get_display_info() local w, h = window:get_size(); return 1, 50, w, h, 1 end
  ---@return string
  function system.get_clipboard() return clipboard end
  ---@param value string
  function system.set_clipboard(value) clipboard = value end
  -- OS window controls and IME composition are owned by the terminal emulator.
  for _, name in ipairs({"set_window_size", "set_window_mode", "set_window_bordered",
    "set_window_hit_test", "set_window_title", "set_cursor", "raise_window",
    "text_input", "set_text_input_rect", "clear_ime"}) do
    system[name] = function() end
  end
  ---Use a block caret without erasing the character beneath it.
  ---@param x number
  ---@param y number
  function DocView:draw_caret(x, y) session.grid:caret(x / 8, y / 16) end

  -- Keep the normal command path, including predicates, focus and unsaved prompts.
  local bindings = {[PLATFORM == "Mac OS X" and "option+x" or "alt+x"] = "core:find-command"}
  if PLATFORM == "Mac OS X" then
    for stroke, commands in pairs(keymap.map) do
      if stroke:match("%f[%a]cmd%f[%A]") then
        bindings[stroke:gsub("%f[%a]cmd%f[%A]", "ctrl")] = commands
      end
    end
  end
  keymap.add_direct(bindings)

  -- Explicit native picker commands use the existing command-view equivalents.
  local command = require "core.command"
  for _, name in ipairs({"open-file", "open-project-folder", "change-project-folder", "add-directory"}) do
    command.map["core:" .. name .. "-picker"].perform = command.map["core:" .. name .. "-commandview"].perform
  end
  -- Plugins may call the native dialog APIs directly. Report their usual error
  -- callback instead of passing the virtual window to a native API.
  for _, name in ipairs({"open_file_dialog", "open_directory_dialog", "save_file_dialog"}) do
    system[name] = function(_, id)
      input:emit("dialogfinished", id, "error", "Native dialogs are unavailable in terminal mode")
    end
  end

  local native_poll, native_pending = system.poll_event, system.has_pending_events
  ---Merge terminal input with native worker and application lifecycle events.
  ---@return any ...
  function system.poll_event()
    local native = table.pack(native_poll())
    if native.n > 0 then return table.unpack(native, 1, native.n) end
    local e = table.pack(input:pop())
    -- Give prompts a layout/suggestion update between keystrokes read together.
    -- This also confines core.step's handled-key text suppression to that key.
    if e[1] == "tui-key-end" then return end
    if e[1] == "focuslost" then focused = false
    elseif e[1] == "focusgained" then focused = true end
    if e.n > 0 then return table.unpack(e, 1, e.n) end
  end
  ---@return boolean
  function system.has_pending_events() return input.first <= #input.events or native_pending() end

  local run_step = core.run_step
  ---Poll terminal input at most every 20 ms, leaving coroutine scheduling intact.
  ---@return boolean running
  ---@return number? delay
  local function step()
    local now = system.get_time()
    if now >= next_poll then
      session.terminal:flush()
      if input.first > #input.events and not session.terminal:read(input, now) then core.quit(true) end
      local w, h = session.terminal:size()
      if w ~= session.grid.columns or h ~= session.grid.rows then
        session.grid:resize(w, h)
        input:emit("resized", w * 8, h * 16)
        core.redraw = true
      end
      next_poll = now + .02
    end
    local running, delay = run_step()
    return running, math.min(delay or .02, math.max(0, next_poll - system.get_time()))
  end
  ---Restore terminal settings on failures in input, drawing or editor updates.
  ---@return boolean running
  ---@return number? delay
  function core.run_step()
    local result = table.pack(xpcall(step, debug.traceback))
    if not result[1] then tui.close(); error(result[2], 0) end
    if not result[2] then tui.close(); return false end
    return true, result[3]
  end

  local exit = os.exit
  ---Restore terminal state before any explicit process exit.
  ---@param ... any
  function os.exit(...) tui.close(); return exit(...) end
  ---Report fatal errors in the restored shell rather than a native dialog.
  ---@param title string
  ---@param message string
  function system.show_fatal_error(title, message)
    tui.close()
    io.stderr:write(title .. "\n" .. message .. "\n")
  end
  tui.active = true
  core.redraw = true
end

cli.register {
  command = "tui",
  description = "Run the editor in the current terminal (LuaJIT builds)",
  usage = "[files or project]",
  arguments = {paths = "Files or a project directory to open"},
  exit_editor = false,
  execute = function()
    -- Core skips launch paths on restart; keep the frontend without replaying
    -- the TUI command's original operands in the newly selected project.
    if RESTARTED then cli.unhandled_arguments = {} end
    local ok, err = pcall(tui.start)
    if not ok then
      tui.close()
      io.stderr:write(tostring(err) .. "\n")
      os.exit(1)
    end
  end
}

-- Help must never acquire the terminal or modify metrics. Registering from a
-- negative-priority plugin lets subsequently loaded UI plugins see cell fonts.
if ARGS[2] == "tui" and LUAJIT then
  local help = false
  for i = 3, #ARGS do if ARGS[i] == "--help" or ARGS[i] == "-h" then help = true end end
  if not help then prepare() end
end

return tui
