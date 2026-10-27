local test = require "core.test"
local Grid = require "plugins.tui.grid"
local Input = require "plugins.tui.input"
local text = require "plugins.tui.text"
local cli = require "core.cli"
local config = require "core.config"
local utf8 = require "utf8extra"

local white, black = {255, 255, 255}, {0, 0, 0}

---Drain decoder events while hiding internal frame boundaries from comparisons.
---@param input plugins.tui.input
---@return table[]
local function drain(input)
  local events = {}
  while true do
    local e = table.pack(input:pop())
    if e.n == 0 then break end
    if e[1] ~= "tui-key-end" then events[#events + 1] = e end
  end
  return events
end

test.describe("terminal drawing", function()
  test.test("companion backgrounds retain frames at their exact shared edges", function()
    local grid = Grid.new(10, 5)
    grid:begin_layer()
    local owner = grid.layer
    grid:line(1.25, 0, .125, 5, white, false)
    grid:line(7.125, 0, .125, 5, white, false)
    grid:begin_layer(owner)
    grid:rect(1.25, 1, 6, 2, {40, 40, 40}, true)
    test.equal(grid:cell(1, 1)[1], "│")
    test.equal(grid:cell(7, 1)[1], "│")
    test.equal(grid:cell(1, 1)[3], 0)
    test.equal(grid:cell(7, 1)[3], 0)
  end)

  test.test("translucent hover fills do not tint borders excluded by their clip", function()
    local grid = Grid.new(12,4)
    grid:line(1,0,.125,4,white,false)
    grid:line(8.875,0,.125,4,white,false)
    grid:set_clip(1.125,0,7.75,4)
    grid:rect(0,1,12,1,{60,90,120,160},true)
    for _, col in ipairs({1,8}) do
      local cell = grid.cells[12+col+1]
      test.equal(cell[1],"│")
      test.equal(cell[2],0xffffff)
      test.equal(cell[3],0)
    end
  end)

  test.test("clipped text retains excluded side borders including wide glyphs", function()
    for _, value in ipairs({"abcdefghijk", "界界界界界"}) do
      for offset = 0, .875, .125 do
        local grid = Grid.new(12, 4)
        grid:line(1 + offset, 0, .125, 4, white, false)
        grid:line(8 + offset, 0, .125, 4, white, false)
        grid:set_clip(1.125 + offset, 0, 6.875, 4)
        grid:draw_text(value, 1 + offset, 1, white)
        test.equal(grid.cells[14][1], "│", "left edge offset " .. offset)
        test.equal(grid.cells[21][1], "│", "right edge offset " .. offset)
      end
    end
  end)

  test.test("registers tui without activating terminal mode in ordinary launches", function()
    local plugin = require "plugins.tui"
    test.not_ok(plugin.active)
    test.equal(cli.commands.tui.exit_editor, false)
    test.type(cli.commands.tui.execute, "function")
    test.equal(type(renderer.font.load(DATADIR .. "/fonts/FiraSans-Regular.ttf", 14)), "userdata")
    test.equal(config.plugins.tui.nerdicons, false)
    local option = config.plugins.tui.config_spec[1]
    test.equal(option.path, "nerdicons")
    local settings = require "plugins.settings"
    test.ok(option.type == "toggle" or option.type == settings.type.TOGGLE)
    test.equal(option.default, false)
  end)

  test.test("reports a LuaJIT requirement before touching the terminal", function()
    local plugin = require "plugins.tui"
    local original = LUAJIT
    LUAJIT = false
    local ok, err = pcall(plugin.start)
    LUAJIT = original
    test.not_ok(ok)
    test.equal(err, "pragtical tui requires a LuaJIT build")
    test.not_ok(plugin.active)
  end)

  test.test("measures wide characters, combining marks and tab offsets consistently", function()
    local grid = Grid.new(20, 2)
    for _, value in ipairs({"hello", "界", "e\204\129", "a\tb", "界\te\204\129"}) do
      local expected = text.width(value, 4, 1)
      test.equal(grid:draw_text(value, 0, 0, white, 4, 1), expected)
    end
    test.equal(text.width("界"), 2)
    test.equal(text.width("e\204\129"), 1)
  end)

  test.test("does not emit any output for unchanged frames", function()
    local grid = Grid.new(12, 3)
    grid:draw_text("hello", 1, 1, white)
    test.ok(#grid:present(true) > 0)
    test.equal(grid:present(true), "")
    grid:clear(black)
    grid:draw_text("hello", 1, 1, white)
    test.equal(grid:present(true), "")
    grid:draw_text("j", 1, 1, white)
    local output = grid:present(true)
    test.ok(output:find("\27[2;2H", 1, true))
    test.not_ok(output:find("hello", 1, true))
  end)

  test.test("clears old text and invalidates the entire frame on resize", function()
    local grid = Grid.new(4, 1)
    grid:draw_text("test", 0, 0, white)
    grid:present()
    grid:clear(black)
    test.ok(grid:present():find("    ", 1, true))
    grid:resize(6, 2)
    test.ok(grid:present():find("\27[2;1H", 1, true))
  end)

  test.test("clips text and backgrounds to the same bounds", function()
    local grid = Grid.new(6, 2)
    grid:set_clip(1, 0, 3, 1)
    grid:rect(0, 0, 6, 2, {255, 0, 0})
    grid:draw_text("abcdef", 0, 0, white)
    test.equal(grid.cells[1][1], " ")
    test.equal(grid.cells[2][1], "b")
    test.equal(grid.cells[4][1], "d")
    test.equal(grid.cells[5][1], " ")
    test.equal(grid.cells[7][3], 0)
  end)

  test.test("does not draw half a wide character at the clip boundary", function()
    local grid = Grid.new(3, 1)
    grid:draw_text("界", 2, 0, white)
    test.equal(grid.cells[3][1], " ")
    grid:draw_text("界", 0, 0, white)
    test.equal(grid.cells[2][4], 0)
    grid:draw_text("x", 1, 0, white)
    test.equal(grid.cells[1][1], " ")
    test.equal(grid.cells[1][4], 1)
    test.equal(grid.cells[2][1], "x")
  end)

  test.test("plain spaces advance without erasing text underlays or wide continuations", function()
    local grid = Grid.new(8, 1)
    grid:draw_text("·界·", 0, 0, {80, 160, 220})
    grid:present(true)
    test.equal(grid:draw_text("    ", 0, 0, white), 4)
    test.equal(grid:cell(0, 0)[1], "·")
    test.equal(grid:cell(0, 0)[2], 0x50a0dc)
    test.equal(grid:cell(1, 0)[1], "界")
    test.equal(grid:cell(2, 0)[4], 0)
    test.equal(grid:cell(3, 0)[1], "·")
    test.equal(grid:present(true), "")
    grid:clear(black)
    grid:draw_text("    ", 0, 0, white)
    test.equal(grid:cell(0, 0)[1], " ")
    test.not_ok(grid:present(true) == "", "clearing the next frame must still remove old markers")
  end)

  test.test("retains short input viewports without expanding empty or offscreen clips", function()
    local grid = Grid.new(4, 4)
    grid:set_clip(1, 1.5, 3, 14 / 16)
    grid:draw_text("10", 1, 1.5, white)
    test.equal(grid:cell(1, 2)[1], "1")
    test.equal(grid:cell(2, 2)[1], "0")
    for _, bounds in ipairs({
      {1, 1.5, 0, .875}, {1, 1.5, 3, 0},
      {-5, 0, 1, 2}, {4, 0, 1, 1}, {0, -2, 4, .5}, {0, 4, 4, 1}
    }) do
      grid:clear(black)
      grid:set_clip(table.unpack(bounds))
      grid:rect(0, 0, 4, 4, white)
      for _, cell in ipairs(grid.cells) do test.equal(cell[3], 0) end
    end
  end)

  test.test("alpha overlays preserve text and blend its colors", function()
    local grid = Grid.new(3, 1)
    grid:draw_text("abc", 0, 0, white)
    grid:rect(0, 0, 3, 1, {0, 0, 0, 128})
    test.equal(grid.cells[1][1], "a")
    test.equal(grid.cells[1][2], 0x7f7f7f)
    grid:caret(0, 0)
    test.equal(grid.cells[1][1], "a")
    test.equal(grid.cells[1][3], 0x7f7f7f)
  end)

  test.test("half-block fills stop at the exact clip edge", function()
    local grid = Grid.new(4, 4)
    grid:set_clip(0, 0, 4, 1.5)
    grid:rect(0, 1.5, 4, 1, {255, 0, 0})
    for _, cell in ipairs(grid.cells) do
      test.equal(cell[3], 0)
      test.equal(cell[1], " ")
    end
    grid:rect(0, 1, 4, 1, {255, 0, 0})
    local cell = grid:cell(0, 1)
    test.equal(cell[1], "▀")
    test.equal(cell[2], 0xff0000)
    test.equal(cell[3], 0)
  end)

  test.test("fills leave excluded horizontal frame cells untinted", function()
    for _, alpha in ipairs({160, 255}) do
      local grid = Grid.new(6, 4)
      grid:line(0, 1.9375, 6, .0625, white, true)
      grid:set_clip(0, 0, 6, 1.9375)
      grid:rect(0, 1, 6, 1, {255, 0, 0, alpha})
      for col = 0, 5 do
        local cell = grid:cell(col, 1)
        test.equal(cell[2], 0xffffff)
        test.equal(cell[3], 0)
      end
    end
  end)

  test.test("clipped row highlights retain border cells and their backgrounds", function()
    local grid = Grid.new(14, 5)
    for _, offset in ipairs({0, .125, .5, .875}) do
      grid:clear(black)
      local right = 10 + offset
      grid:line(right, 0, .125, 5, white, false)
      grid:set_clip(1.125, 0, right - 1.125, 5)
      grid:rect(1.25, 2, 12, 1, {100, 100, 100}, true)
      local border = grid.cells[2 * grid.columns + math.floor(right) + 1]
      test.equal(border[8], 2, "right border erased at " .. offset)
      test.equal(border[2], 0xffffff)
      test.equal(border[3], 0, "highlight extends into the border cell")
      test.equal(grid:cell(5, 2)[3], 0x646464)
    end
  end)

  test.test("popup borders cover underlying text while preserving their own labels", function()
    local grid = Grid.new(14, 5)
    for row = 0, 4 do grid:draw_text("xxxxxxxxxxxxxx", 0, row, white) end
    grid:begin_layer()
    grid:line(1, 0, 12, .1, white, true)
    grid:line(1, 4, 12, .1, white, true)
    grid:line(1, 0, .1, 5, white, false)
    grid:line(12, 0, .1, 5, white, false)
    grid:rect(1.125, .0625, 11, 4, black, true)
    grid:draw_text("Title", 3, 1, white)
    grid:line(2, 1.9, 10, .1, white, true)
    grid:present()
    for row = 1, 3 do
      test.equal(grid:cell(1, row)[1], "│")
      test.equal(grid:cell(12, row)[1], "│")
    end
    test.equal(grid:cell(1, 0)[1], "┌")
    test.equal(grid:cell(12, 4)[1], "┘")
    test.equal(grid:cell(3, 1)[1], "T")
    test.equal(grid:cell(0, 2)[1], "x")
  end)

  test.test("popup text does not erase a background separator beyond its own cells", function()
    local grid = Grid.new(12, 2)
    grid:line(0, 0, 12, .1, white, true)
    grid:begin_layer()
    grid:draw_text("popup", 3, 0, white)
    test.equal(grid:cell(0, 0)[1], "─")
    test.equal(grid:cell(11, 0)[1], "─")
    test.equal(grid:cell(3, 0)[1], "p")
  end)

  test.test("a companion popup keeps the containing frame sides when drawing a separator", function()
    local grid = Grid.new(14, 5)
    grid:begin_layer()
    grid:line(1, 0, .1, 5, white, false)
    grid:line(12, 0, .1, 5, white, false)
    grid:begin_layer(1)
    grid:line(1.125, 2, 11, .1, {24,24,24}, true)
    grid:set_clip(3, 2, 6, 1)
    grid:draw_text("Result", 3, 2, white)
    grid:set_clip(0, 0, 14, 5)
    grid:present()
    for row = 0, 4 do
      test.equal(grid:cell(1, row)[1], "│")
      test.equal(grid:cell(12, row)[1], "│")
      test.equal(grid:cell(1, row)[2], 0xffffff, "left frame color changed")
      test.equal(grid:cell(12, row)[2], 0xffffff, "right frame color changed")
    end
    test.equal(grid:cell(3, 2)[1], "R")
  end)

  test.test("popup edges neither join nor retain strokes from the document behind them", function()
    local grid = Grid.new(12, 5)
    grid:line(6, 0, .1, 5, white, false)
    grid:line(0, 2, 12, .1, white, true)
    grid:begin_layer()
    grid:line(1, 1, 10, .1, white, true)
    grid:rect(1, 2.0625, 10, 1, black, true)
    grid:present()
    test.equal(grid:cell(6, 1)[1], "─")
    test.equal(grid:cell(6, 2)[1], " ")
    test.equal(grid:cell(2, 2)[1], " ")
    test.equal(grid:cell(0, 2)[1], "─")
  end)

  test.test("sanitizes embedded terminal escapes and malformed text", function()
    local grid = Grid.new(30, 1)
    grid:draw_text("a\27]52;c;evil\7\255", 0, 0, white)
    local output = grid:present(true)
    test.not_ok(output:find("\27]52", 1, true))
    test.not_ok(output:find("\7", 1, true))
    test.not_ok(output:find("\255", 1, true))
  end)

  test.test("renders embedded line endings as spaces without moving the terminal cursor", function()
    local grid = Grid.new(20, 2)
    for _, ending in ipairs({"\n", "\r", "\r\n"}) do
      grid:clear(black)
      local value = "soft" .. ending .. "break"
      test.equal(text.width(value), 10)
      test.equal(grid:draw_text(value, 1, 0, white), 11)
      local output = grid:present(true)
      test.not_ok(output:find("[\r\n]"))
      test.equal(grid:cell(5, 0)[1], " ")
      test.equal(grid:cell(6, 0)[1], "b")
    end
  end)

  test.test("supports RGB and 256 color output", function()
    local grid = Grid.new(1, 1)
    test.ok(grid:present(true):find("38;2;", 1, true))
    grid.previous = {}
    test.ok(grid:present(false):find("38;5;", 1, true))
  end)

  test.test("composes partial rectangle rows and clears their colors on overwrite", function()
    local grid = Grid.new(4, 2)
    grid:rect(0, .5, 4, .5, {255, 0, 0})
    test.equal(grid.cells[1][1], "▀")
    test.equal(grid.cells[1][2], 0)
    test.equal(grid.cells[1][3], 0xff0000)
    grid:rect(0, 0, 4, .5, {0, 0, 255})
    test.equal(grid.cells[1][2], 0x0000ff)
    test.equal(grid.cells[1][3], 0xff0000)
    grid:rect(0, 0, 4, 1, {0, 0, 0, 128})
    test.equal(grid.cells[1][2], 0x00007f)
    test.equal(grid.cells[1][3], 0x7f0000)
    grid:present(true)
    test.equal(grid:present(true), "")
    grid:draw_text("界", 0, 0, white)
    test.is_nil(grid.cells[1][11])
    grid:rect(1, 0, 1, 1, white)
    test.equal(grid.cells[1][1], " ")
    test.equal(grid.cells[2][4], 1)
    grid:rect(0, 0, 4, 2, black)
    test.equal(grid.cells[2][1], " ")
    test.is_nil(grid.cells[2][11])
    grid:rect(0, .5, 1, .5, white)
    grid:clear(black)
    test.is_nil(grid.cells[1][11])
  end)

  test.test("keeps labels when neighboring background edges share their row", function()
    local grid = Grid.new(8, 2)
    grid:draw_text("Label 界", 0, 0, white)
    grid:rect(0, .5, 8, 1.5, {0, 0, 255})
    test.equal(grid.cells[1][1], "L")
    test.equal(grid.cells[1][2], 0xffffff)
    test.equal(grid.cells[7][1], "界")
    test.equal(grid.cells[8][4], 0)
    grid:rect(0, 0, 8, 1, black)
    test.equal(grid.cells[1][1], " ")
  end)
end)

test.describe("terminal input", function()
  test.test("decodes fragmented UTF-8 once", function()
    local input = Input.new()
    input:feed("\231", 0)
    test.equal(#drain(input), 0)
    input:feed("\149\140", .01)
    local e = drain(input)
    test.equal(e[2][1], "textinput")
    test.equal(e[2][2], "界")
    test.equal(#e, 3)
  end)

  test.test("delays Escape but recognizes an Alt chord without inserting text", function()
    local input = Input.new()
    input:feed("\27", 1)
    input:feed("", 1.02)
    test.equal(#drain(input), 0)
    input:feed("", 1.04)
    test.equal(drain(input)[1][2], "escape")
    input:feed("\27x", 2)
    local e = drain(input)
    test.equal(e[1][1], "keypressed")
    test.equal(e[2][2], "x")
    test.equal(e[4][1], "keyreleased")
    test.equal(#e, 4)
  end)

  test.test("decodes fragmented arrows and modified navigation", function()
    local input = Input.new()
    input:feed("\27[1;", 1)
    test.equal(#drain(input), 0)
    input:feed("6D", 1.01)
    local e = drain(input)
    test.equal(e[1][2], "left ctrl")
    test.equal(e[2][2], "left shift")
    test.equal(e[3][2], "left")
    test.equal(e[#e][1], "keyreleased")
  end)

  test.test("recovers from incomplete or unknown escape sequences", function()
    local input = Input.new()
    input:feed("\27O", 1)
    input:feed("", 1.1)
    input:feed("\27[?99za", 1.2)
    local e = drain(input)
    test.equal(e[1][2], "a")
    test.equal(e[2][2], "a")
  end)

  test.test("keeps bracketed paste atomic and normalizes line endings", function()
    local input = Input.new()
    for _, bytes in ipairs({"\27[20", "0~hello\r\n", "\27[Atext", "\27[2", "01~"}) do input:feed(bytes, 1) end
    local e = drain(input)
    test.equal(#e, 1)
    test.equal(e[1][1], "textinput")
    test.equal(e[1][2], "hello\n\27[Atext")
  end)

  test.test("places a frame boundary between text and submission", function()
    local input = Input.new()
    input:feed("x\r", 1)
    local kinds = {}
    while true do local kind = input:pop(); if not kind then break end; kinds[#kinds + 1] = kind end
    test.equal(table.concat(kinds, ","), "keypressed,textinput,keyreleased,tui-key-end,keypressed,keyreleased,tui-key-end")
  end)

  test.test("reports Space as a command key while preserving its text", function()
    local input = Input.new()
    input:feed(" ", 1)
    local events = drain(input)
    test.equal(events[1][2], "space")
    test.equal(events[2][2], " ")
  end)

  test.test("maps mouse clicks, release, drag and wheel to editor coordinates", function()
    local input = Input.new()
    input:feed("\27[<0;10;5M\27[<32;11;5M\27[<0;11;5m\27[<64;11;5M", 1)
    local e = drain(input)
    test.equal(e[1][2], 76)
    test.equal(e[1][3], 72)
    test.equal(e[2][1], "mousepressed")
    test.equal(e[2][5], 1)
    test.equal(e[3][1], "mousemoved")
    test.equal(e[5][1], "mousereleased")
    test.equal(e[7][1], "mousewheel")
    test.equal(e[7][2], 1)
  end)

  test.test("preserves shift-click modifiers and detects double clicks", function()
    local input = Input.new()
    input:mouse(4, 3, 2, false, 1)
    local e = drain(input)
    test.equal(e[1][2], "left shift")
    test.equal(e[#e][1], "keyreleased")
    input:mouse(0, 3, 2, false, 1.1)
    test.equal(drain(input)[2][5], 2)
  end)
end)

test.describe("terminal renderer adapters", function()
  local session, saved, nerdicons, padding, transitions, roots, menus, clip
  local core = require "core"
  local style = require "core.style"
  local Widget = require "widget"
  local TextBox = require "widget.textbox"
  local Toggle = require "widget.toggle"
  local CheckBox = require "widget.checkbox"
  local DocView = require "core.docview"
  local CommandView = require "core.commandview"
  local RootView = require "core.rootview"
  local ContextMenu = require "core.contextmenu"
  local on_event, active_view, last_active_view, root_size
  local native_canvas, native_save_image, temp_files, refresh_widgets
  test.before_each(function()
    nerdicons = config.plugins.tui.nerdicons
    config.plugins.tui.nerdicons = false
    saved = {}
    padding = {style.padding.x, style.padding.y}
    style.padding.x, style.padding.y = 8, 0
    transitions, config.transitions = config.transitions, false
    roots, menus = {}, {}
    clip, core.clip_rect_stack = core.clip_rect_stack, {{0, 0, 640, 192}}
    on_event, active_view = core.on_event, core.active_view
    last_active_view = core.last_active_view
    root_size = {core.root_view.size.x, core.root_view.size.y}
    core.root_view.size.x, core.root_view.size.y = 640, 192
    native_canvas = canvas.new(64, 32, {255, 0, 0, 255}, true)
    native_save_image = native_canvas.save_image
    temp_files = {}
    for _, api in ipairs({renderer, renderer.font, canvas, getmetatable(native_canvas).__index,
      Widget, TextBox, Toggle, CheckBox, DocView, CommandView, RootView, ContextMenu,
      require "core.view", require "core.scrollbar", require "core.audioview", require "core.emptyview",
      require "widget.notebook", require "widget.listbox", require "widget.widgetlist",
      require "widget.colorpicker", require "widget.container", config.plugins.drawwhitespace,
      getmetatable(require "plugins.treeview")}) do
      local entries = {}
      for k, v in pairs(api) do entries[k] = v end
      saved[#saved + 1] = {api, entries}
    end
    session = {grid = Grid.new(20, 6), terminal = {pending = "", write = function() end}}
    require("plugins.tui.drawing").install(session)
    refresh_widgets = require("plugins.tui.widgets").install()
    require("plugins.tui.views").install()
  end)

  test.after_each(function()
    session.images:close()
    for _, path in ipairs(temp_files) do os.remove(path) end
    for _, menu in ipairs(menus) do menu:hide() end
    for _, root in ipairs(roots) do root:destroy() end
    config.plugins.tui.nerdicons = nerdicons
    config.transitions = transitions
    core.clip_rect_stack = clip
    core.on_event, core.active_view = on_event, active_view
    core.last_active_view = last_active_view
    core.root_view.size.x, core.root_view.size.y = table.unpack(root_size)
    style.padding.x, style.padding.y = padding[1], padding[2]
    for _, entry in ipairs(saved) do
      for k in pairs(entry[1]) do entry[1][k] = nil end
      for k, v in pairs(entry[2]) do entry[1][k] = v end
    end
  end)

  test.test("terminal fonts retain their type when used in styled status text", function()
    local Object = require "core.object"
    local StatusView = require "core.statusview"
    local font = renderer.font.load("terminal", 16)
    local copy = font:copy(18, {bold = true})
    local group = renderer.font.group({copy, font})
    local status = StatusView()
    status.size.x, status.size.y = 160, 16
    for _, current in ipairs({font, copy, group}) do
      test.ok(Object.is(current, renderer.font))
      test.equal(current:get_width("Status"), 48)
      session.grid:clear(black)
      status:draw_items({white, current, "Status"})
      for i = 1, 6 do
        test.equal(session.grid:cell(i, 0)[1], ("Status"):sub(i, i))
        test.equal(session.grid:cell(i, 0)[2], 0xffffff)
      end
      -- The shared font metatable also owns native userdata finalization.
      getmetatable(current).__gc(current)
      test.equal(current:get_width("Status"), 48)
    end
  end)

  test.test("scrollbar tracks and drag endpoints use interior cells in every direction", function()
    local Scrollbar = require "core.scrollbar"
    for _, direction in ipairs({"v", "h"}) do
      for _, alignment in ipairs({"s", "e"}) do
        local bar = Scrollbar {direction=direction, alignment=alignment}
        bar:set_size(3.5, 5.5, 120, 100, 400)
        bar.percent = 0
        local x, y, w, h = bar:get_track_rect()
        test.ok(x >= 3.5 and y >= 5.5 and x+w <= 123.5 and y+h <= 105.5)
        test.equal(x % 8, 0)
        test.equal(y % 16, 0)
        test.equal(w % 8, 0)
        test.equal(h % 16, 0)
        local sx, sy, sw, sh = bar:get_thumb_rect()
        test.equal(bar:on_mouse_pressed("left", sx+sw/2, sy+sh/2), true)
        local ex, ey = direction == "h" and x+w+100 or sx+sw/2,
          direction == "v" and y+h+100 or sy+sh/2
        test.equal(bar:on_mouse_moved(ex, ey, 0, 0), 1)
        test.equal(bar:on_mouse_moved(x-100, y-100, 0, 0), 0)
        bar:on_mouse_released("left", x, y)
        test.ok(not bar:overlaps(x+w, y+h))
      end
    end
  end)

  test.test("paired scrollbars reserve their corner and disappear without overflow", function()
    local View = require "core.view"
    local view = View()
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 160, 96
    view.get_scrollable_size = function() return 192 end
    view.get_h_scrollable_size = function() return 320 end
    view:update_scrollbar()
    local vx, vy, vw, vh = view.v_scrollbar:get_track_rect()
    local hx, hy, hw, hh = view.h_scrollbar:get_track_rect()
    test.equal(vh, 80)
    test.equal(hw, 152)
    test.ok(vy+vh <= hy and hx+hw <= vx)
    view.get_scrollable_size = function() return 96 end
    view.get_h_scrollable_size = function() return 160 end
    view:update_scrollbar()
    local _, _, w, h = view.h_scrollbar:get_track_rect()
    test.equal(w, 0)
    test.equal(h, 0)
  end)

  test.test("wide lists can scroll their final row above the horizontal scrollbar", function()
    local ListBox = require "widget.listbox"
    local list = ListBox()
    list.position.x, list.position.y = 0, 0
    list.size.x, list.size.y = 80, 64
    list.rows = {{x=0, y=48, w=160, h=16}}
    test.equal(list:get_scrollable_size(), 80)
    list.rows[1].w = 80
    test.equal(list:get_scrollable_size(), 64)
    list:destroy()
  end)

  test.test("treeview can reach its final row above a scrollbar at fractional heights", function()
    local TreeView = getmetatable(require "plugins.treeview")
    local view = {count_lines=70, position={y=17}, size={x=160,y=103.5},
      get_item_height=function() return 16 end,
      get_h_scrollable_size=function() return 320 end}
    local height = TreeView.get_scrollable_size(view)
    test.equal(height, 71*16 + 8.5)
    local last_y = view.position.y - (height - view.size.y) + 69*16
    local bar_y = math.floor((view.position.y+view.size.y)/16)*16-16
    test.ok(math.floor(last_y/16+.5)*16+16 <= bar_y)
  end)

  test.test("scrollbar tracks cover content in their cells and trailing viewport fragments", function()
    local View = require "core.view"
    session.grid:resize(24, 10)
    local view = View()
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 163.5, 103.5
    view.get_scrollable_size = function() return 208 end
    view.get_h_scrollable_size = function() return 320 end
    view:update_scrollbar()
    core.push_clip_rect(0, 0, view.size.x, view.size.y)
    view:draw_background(style.background2)
    renderer.draw_text(style.font, "Xcode", 0, 80, white)
    renderer.draw_text(style.font, "Xcode", 0, 96, white)
    renderer.draw_text(style.font, "Q", 152, 32, white)
    view:draw_scrollbar()
    core.pop_clip_rect()
    for _, cell in ipairs(session.grid.cells) do
      test.not_ok(cell[1]:find("[XcodeQ]"), "content survived beneath a scrollbar")
    end
  end)

  test.test("shared slider uses visible cell centers for both endpoints", function()
    local slider = Widget(nil, false)
    slider.position.x, slider.position.y = 3.5, 5
    slider.size.x = 80
    slider.value, slider.enabled = 0, true
    local changed
    slider.on_change = function(_, value) changed = value end
    require("plugins.tui.widgets").adapt_slider(slider)
    slider:set_from_mouse(4)
    test.equal(changed, 0)
    slider:set_from_mouse(76)
    test.equal(changed, 1)
    slider:set_from_mouse(40)
    test.equal(changed, .5)
    slider:destroy()
  end)

  test.test("audio controls wrap without repeating list layout on idle updates", function()
    local AudioView = require "core.audioview"
    local threads = {}
    for key in pairs(core.threads) do threads[key] = true end
    local player = AudioView()
    player:show()
    roots[#roots + 1] = player
    local ok, err = pcall(function()
      player:set_size(200, 400)
      for _ = 1, 3 do player:update() end
      local recalculate = player.list.recalc_all_rows
      local calls = 0
      player.list.recalc_all_rows = function(list, ...)
        calls = calls + 1
        return recalculate(list, ...)
      end
      for _ = 1, 10 do player:update() end
      test.equal(calls, 0)
      test.ok(player.volume_slider.position.ry > player.previous.position.ry)
      test.ok(player.filter.position.ry > player.volume_slider.position.ry)
      player:set_size(640, 400)
      player:update()
      test.equal(calls, 1)
      test.equal(player.volume_slider.position.ry, player.previous.position.ry)
      player.state = "playing"
      player:update()
      test.equal(player.play_button.transport_shape, "pause")
      test.equal(calls, 1)
      session.grid:resize(80, 25)
      for _, enabled in ipairs({false, true}) do
        config.plugins.tui.nerdicons = enabled
        session.grid:clear(style.background)
        player.previous:draw()
        local found = false
        for _, cell in ipairs(session.grid.cells) do
          if cell[1] == (enabled and "" or "<") then found = true end
        end
        test.ok(found)
      end
    end)
    player.closed = true
    for key in pairs(core.threads) do
      if not threads[key] then core.threads[key] = nil end
    end
    if not ok then error(err) end
  end)

  ---Construct a visible offscreen widget tree using the actual terminal metrics.
  ---@return widget
  local function widget_root()
    session.grid:resize(80, 10)
    local root = Widget(nil, false)
    roots[#roots + 1] = root
    root.border.width = 0
    root:set_position(0, 0)
    root:set_size(640, 160)
    root:show()
    return root
  end

  ---Read one row without depending on ANSI serialization.
  ---@param row integer Zero-based terminal row
  ---@return string
  local function row_text(row)
    local out = {}
    for col = 0, session.grid.columns - 1 do
      out[#out + 1] = session.grid.cells[row * session.grid.columns + col + 1][1]
    end
    return table.concat(out)
  end

  test.test("focused textbox text remains visible after vertical caret scrolling", function()
    local root = widget_root()
    local textbox = TextBox(root, "search text")
    textbox:set_size(160)
    textbox:activate()
    for offset = 0, 15 do
      textbox:set_position(8, 16 + offset)
      textbox.textview.scroll.y, textbox.textview.scroll.to.y = 2, 2
      root:update()
      session.grid:clear(black)
      root:draw()
      local row = math.floor(textbox.position.y / 16 + .5)
      test.ok(row_text(row):find("search text", 1, true), "offset " .. offset)
    end
  end)

  test.test("docked widgets reserve full rows before a node divider", function()
    local root = widget_root()
    root:set_size(640, 55)
    test.equal(root.size.y, 64)
    root:set_position(0, 127 - root.size.y)
    local input = TextBox(root, "visible search")
    input:set_size(240)
    input:set_position(8, 33)
    root:update()
    session.grid:clear(black)
    renderer.draw_rect(0, 127, 640, 1, style.divider)
    root:draw()
    local row = math.floor(input.position.y / 16 + .5)
    test.ok(row_text(row):find("visible search", 1, true))
  end)

  test.test("startup refresh remeasures icons on existing and hidden widget roots", function()
    local Container = require "widget.container"
    local Button = require "widget.button"
    local root = widget_root()
    local container = Container(root)
    local button = Button(container, "Open")
    button:set_icon("d")
    root:update()
    local width = button:get_width()
    root:hide()
    config.plugins.tui.nerdicons = true
    refresh_widgets()
    test.equal(button:get_width(), width + 8)
    test.equal(container.old_size.x, -1)
  end)

  test.test("floating widget frames leave room for message box buttons", function()
    local MessageBox = require "widget.messagebox"
    local dialog = MessageBox(nil, "Message", "Continue?", MessageBox.ICON_INFO)
    roots[#roots + 1] = dialog
    dialog:add_button("Cancel")
    dialog:add_button("Continue")
    dialog:show()
    dialog:update()
    session.grid:resize(80, 12)
    for offset = 0, 15 do
      dialog:set_position(16, 16 + offset)
      session.grid:clear(black)
      renderer.draw_rect(8, 0, 8, 192, {128, 0, 128})
      dialog:draw()
      local row = math.floor(dialog.buttons[1].position.y / 16 + .5)
      test.ok(row_text(row):find("Cancel", 1, true), "offset " .. offset)
      test.ok(row_text(row):find("Continue", 1, true), "offset " .. offset)
      local frame_col = math.floor((dialog.position.x - dialog.border.width) / 8)
      test.equal(session.grid:cell(frame_col, row)[3],
        style.background2[1] * 65536 + style.background2[2] * 256 + style.background2[3])
    end
  end)

  test.test("resizing a list fills the newly available terminal rows", function()
    local ListBox = require "widget.listbox"
    local root = widget_root()
    local list = ListBox(root)
    list:add_column("Items")
    for i = 1, 40 do list:add_row({"Item " .. i}) end
    list:set_position(8, 16)
    list:set_size(240, 48)
    root:update()
    list:set_visible_rows()
    list:set_size(240, 112)
    root:update()
    list:set_visible_rows()
    session.grid:clear(black)
    root:draw()
    test.ok(row_text(6):find("Item 5", 1, true), "enlarged list must fill its viewport")
    test.equal(list:get_row_at_position(32, 6 * 16 + 8), 5)
  end)

  test.test("document and command line heights ignore saved graphical line spacing", function()
    local previous = config.line_height
    config.line_height = 1.2
    local Doc = require "core.doc"
    local view = DocView(Doc())
    local prompt = CommandView()
    local document_height, prompt_height = view:get_line_height(), prompt:get_line_height()
    config.line_height = previous
    test.equal(document_height, 16)
    test.equal(prompt_height, 16)
  end)

  test.test("Draw Whitespace markers survive document text and honor selection and error options", function()
    local Doc = require "core.doc"
    local options = config.plugins.drawwhitespace
    options.enabled, options.show_selected_only, options.show_trailing_error = true, false, false
    options.show_leading, options.show_middle, options.show_trailing = true, true, true
    options.show_middle_min, options.color = 1, {80, 160, 220}
    options.leading_color, options.middle_color, options.trailing_color = nil, nil, nil
    session.grid:resize(80, 12)
    local doc = Doc()
    doc:insert(1, 1, "  leading middle  \n\t tab\tend \n")
    local view = DocView(doc)
    view.size.x, view.size.y = 640, 192
    session.grid:clear(black)
    view:draw_line_text(1, 0, 16)
    test.contains(row_text(1), "··leading·middle··")
    test.equal(session.grid:cell(0, 1)[2], 0x50a0dc)
    view:draw_line_text(2, 0, 32)
    test.contains(row_text(2), "»")

    options.show_selected_only = true
    doc:set_selection(1, 2, 1, 5)
    view:update()
    session.grid:clear(black)
    view:draw_line_text(1, 0, 16)
    test.contains(row_text(1), " ·leading middle  ")

    options.show_selected_only, options.show_trailing_error = false, true
    view:update()
    session.grid:clear(black)
    view:draw_line_text(1, 0, 16)
    test.contains(row_text(1), "··leading·middle██")

    options.enabled = false
    session.grid:clear(black)
    view:draw_line_text(1, 0, 16)
    test.contains(row_text(1), "  leading middle  ")
    test.not_ok(row_text(1):find("·", 1, true))
  end)

  test.test("cached text canvases preserve underlays through spaces and retain decorated blanks", function()
    local font = renderer.font.load("terminal", 16)
    local image = canvas.new(64, 16, nil, true)
    image:draw_text(font, "  X", 0, 0, white)
    renderer.draw_text(font, "···", 0, 0, {80, 160, 220})
    renderer.draw_canvas(image, 0, 0)
    test.equal(session.grid:cell(0, 0)[1], "·")
    test.equal(session.grid:cell(1, 0)[1], "·")
    test.equal(session.grid:cell(2, 0)[1], "X")
    image:clear(black)
    renderer.draw_canvas(image, 0, 0)
    test.equal(session.grid:cell(0, 0)[1], " ", "explicit canvas backgrounds must still cover old text")
    for _, decoration in ipairs({"underline", "strikethrough"}) do
      local decorated = font:copy(16, {[decoration] = true})
      renderer.draw_text(decorated, " ", 32, 0, white)
      test.equal(session.grid:cell(4, 0)[5], decoration == "underline" and ";4" or ";9")
    end
  end)

  test.test("widget lists keep toggle rows on one terminal line and hover over their children", function()
    local WidgetList = require "widget.widgetlist"
    local Label = require "widget.label"
    local root = widget_root()
    local list = WidgetList(root)
    for i = 1, 20 do
      list:add_item(i, function(row)
        row.caption = Label(row, "Plugin " .. i)
        row:set_child_properties(row.caption, {stretch = 1})
        row.toggle = Toggle(row, "", false)
        function row.toggle:on_change() row.changed = (row.changed or 0) + 1 end
      end)
    end
    list:set_size(320, 112)
    for offset = 0, 15 do
      for _, scroll in ipairs({0, 8, 15.25, 31.5}) do
        list:set_position(8, 16 + offset)
        list.scroll.y, list.scroll.to.y = scroll, scroll
        root:update()
        root:update()
        session.grid:clear(black)
        root:draw()
        for _, entry in ipairs(list.items) do
          test.equal(entry.height, 16, "toggle rows must not accumulate subcell padding")
        end
        for row = 3, 5 do
          local index = tonumber(row_text(row):match("Plugin (%d+)"))
          test.ok(index, "list must have no gaps at offset " .. offset .. ", scroll " .. scroll)
          local item = list.items[index].row
          local x, y = item.caption.position.x + 24, row * 16 + 8
          root:on_mouse_moved(x, y, 0, 0)
          test.ok(item.hovered, "hovering the label must highlight its row " .. index)
          for _, entry in ipairs(list.items) do
            if entry.row ~= item then test.not_ok(entry.row.hovered) end
          end
          session.grid:clear(black)
          root:draw()
          local highlight = style.line_highlight
          local color = highlight[1] * 65536 + highlight[2] * 256 + highlight[3]
          test.equal(session.grid:cell(25, row)[3], color)
          test.not_ok(session.grid:cell(25, row - 1)[3] == color)
          test.not_ok(session.grid:cell(25, row + 1)[3] == color)
          local toggle = item.toggle
          local col = math.floor((toggle.position.x + toggle.toggle_x) / 8 + .5) + 2
          root:on_mouse_moved(col * 8 + 4, y, 0, 0)
          test.ok(item.hovered, "hovering the toggle must highlight the same row")
          local enabled, changed = toggle.enabled, item.changed or 0
          root:on_mouse_pressed("left", col * 8 + 4, y, 1)
          root:on_mouse_released("left", col * 8 + 4, y)
          test.equal(toggle.enabled, not enabled)
          test.equal(item.changed, changed + 1)
        end
        local hovered = list.hovered_child
        local index = hovered.data
        list.scroll.to.y = list.scroll.y + 16
        root:update()
        test.equal(list.hovered_child.data, index + 1, "scrolling must retarget the stationary pointer")
        test.ok(list.hovered_child.hovered)
        test.not_ok(hovered.hovered)
        root:on_mouse_moved(620, 152, 0, 0)
        for _, entry in ipairs(list.items) do test.not_ok(entry.row.hovered) end
      end
    end
  end)

  test.test("path tooltips have thin frames at fractional positions and screen edges", function()
    local TreeView = getmetatable(require "plugins.treeview")
    session.grid:resize(80, 12)
    for _, point in ipairs({{8.5, 24.5}, {620, 170}}) do
      session.grid:clear(black)
      TreeView.draw_tooltip({hovered_item = {abs_filename = "/tmp/tooltip.lua"},
        tooltip = {x = point[1], y = point[2], alpha = 255}})
      session.grid:present(true)
      local found = false
      for row = 1, 10 do
        if row_text(row):find("/tmp/tooltip.lua", 1, true) then
          found = true
          for col = 0, session.grid.columns - 1 do
            local glyph = session.grid:cell(col, row)[1]
            test.not_ok(glyph == "█" or glyph == "▀" or glyph == "▄")
          end
          test.ok(row_text(row - 1):find("─", 1, true))
          test.ok(row_text(row + 1):find("─", 1, true))
        end
      end
      test.ok(found, "tooltip text must remain inside the screen")
    end
  end)

  test.test("styled widgets and list columns accept terminal font descriptors", function()
    local Label = require "widget.label"
    local ListBox = require "widget.listbox"
    local root = widget_root()
    local font = renderer.font.load(DATADIR .. "/fonts/icons.ttf", 16)
    local label = Label(root, {font, white, "d"})
    label:set_position(8, 16)
    local list = ListBox(root)
    list:add_column("Items")
    list:add_row({font, white, "d"})
    list:set_position(8, 48)
    list:set_size(200, 64)
    root:update()
    session.grid:clear(black)
    root:draw()
    test.ok(row_text(1):find("+", 1, true))
    test.ok(row_text(4):find("+", 1, true))
  end)

  test.test("color picker has four cell rows and reachable alpha endpoints", function()
    local ColorPicker = require "widget.colorpicker"
    local root = widget_root()
    local picker = ColorPicker(root, {80, 160, 220, 255})
    picker:set_position(8, 16)
    root:update()
    session.grid:clear(black)
    root:draw()
    test.equal(picker.selector.h, 16)
    local selector = picker.selector
    test.ok(picker.html_notation.position.y >= selector.y + selector.h * 4)
    for _, endpoint in ipairs({0, 1}) do
      local x = selector.x + 4 + endpoint * (selector.w - 8)
      local y = selector.y + 3 * selector.h + 8
      picker:on_mouse_pressed("left", x, y, 1)
      test.equal(picker.alpha_pos, endpoint * 100)
      test.equal(picker:get_color()[4], endpoint * 255)
      test.not_ok(picker.brightness_mouse_down)
      picker:on_mouse_released("left", x, y)
    end
    local rectangles, draw_rect = 0, renderer.draw_rect
    renderer.draw_rect = function(...)
      rectangles = rectangles + 1
      return draw_rect(...)
    end
    root:draw()
    renderer.draw_rect = draw_rect
    test.ok(rectangles < 250, "gradient paint should scale with terminal columns")
  end)

  test.test("floating registration isolates drawing without wrapping on each frame or raise", function()
    local View = require "core.view"
    local root, popup = RootView(), View()
    popup:set_floating(true)
    popup.floating_visible = true
    popup.draw = function()
      renderer.draw_rect(0, 16, 160, 1, white)
    end
    root:add_floating_view(popup)
    local draw = popup.draw
    root:add_floating_view(popup)
    test.equal(popup.draw, draw)
    for _ = 1, 2 do
      renderer.begin_frame()
      renderer.draw_text(style.font, "background", 8, 16, white)
      popup:draw()
      test.equal(session.grid.layer, 0)
      test.not_ok(row_text(1):find("background", 1, true))
    end
    popup.floating_visible = false
    renderer.begin_frame()
    renderer.draw_text(style.font, "label", 8, 16, white)
    popup:draw()
    test.ok(row_text(1):find("label", 1, true))
    popup.floating_visible = true
    popup.draw = function() error("popup drawing failed") end
    root:add_floating_view(popup)
    test.not_ok(pcall(popup.draw, popup))
    test.equal(session.grid.layer, 0)
  end)

  for _, position in ipairs({"bottom", "top"}) do
    test.test(position .. " command inputs keep their text above node dividers", function()
      local Node = require "core.node"
      local View = require "core.view"
      local function leaf(view, height)
        local node = Node()
        node.views, node.active_view = {view}, view
        node.locked = {x = false, y = height ~= nil}
        if height then view.size.y = height end
        view._core_step_first_update = true
        return node
      end
      local view = CommandView()
      view.display_position = position
      view.label = "Find Command:"
      view.state = {suggest = function() return {} end, cancel = function() end,
        show_suggestions = false, typeahead = false}
      view.doc:insert(1, 1, "agent")
      view.doc:set_selection(1, 6)
      local root, body, bars = Node("vsplit"), Node("vsplit"), Node("vsplit")
      root.a, root.b = leaf(View(), 16), body
      if position == "bottom" then
        body.a, body.b = leaf(View()), bars
        bars.a, bars.b = leaf(view, 0), leaf(View(), 16)
      else
        body.a, body.b = leaf(view, 0), bars
        bars.a, bars.b = leaf(View()), leaf(View(), 16)
      end
      core.active_view = view
      session.grid:resize(80, 12)
      root.size.x, root.size.y = 640, 176
      for offset = 0, 15.5, .5 do
        view:update()
        root.position.y = offset
        root:update_layout()
        renderer.begin_frame()
        root:draw()
        local _, y = view:get_line_screen_position(1, 6)
        local row = math.floor(y / 16 + .5)
        local context = position .. " input at viewport offset " .. offset
          .. " (y=" .. view.position.y .. ", scroll=" .. view.scroll.y
          .. ", height=" .. view.size.y .. ", row=" .. row .. "): " .. row_text(row)
        test.ok(row_text(row):find(view.label, 1, true), context .. " lost its label")
        test.ok(row_text(row):find("agent", 1, true), context .. " lost its query")
        local height = view.size.y
        local redraw = core.redraw
        core.redraw = false
        view:update()
        local invalidated = core.redraw
        core.redraw = redraw
        test.equal(view.size.y, height, context .. " grows on repeated updates")
        test.not_ok(invalidated, context .. " requests a redraw while idle")
      end
      core.active_view = active_view
      view:update()
      test.equal(view.size.y, 0, "closed input must release its reserved rows")
    end)
  end

  test.test("centered command inputs keep their label and query visible at every row offset", function()
    session.grid:resize(80, 12)
    local view = CommandView()
    view.display_position = "center"
    view:set_floating(true)
    view.label = "Open File From Project:"
    view.gutter_width = view:get_font():get_width(view.label) + style.padding.x
    view.size.x, view.size.y = 480, 16
    view.center_height = 64
    view.suggestions = {{text = "AGENTS.md"}}
    view.suggestions_height = 16
    view.doc:insert(1, 1, "agent")
    view.doc:set_selection(1, 6)
    core.active_view = view
    for offset = 0, 15.5, .5 do
      core.root_view.size.y = 192 - offset
      view:update_floating()
      renderer.begin_frame()
      view:draw()
      view.suggestions_view:draw()
      local row = math.floor(view.position.y / 16 + .5)
      test.ok(row_text(row):find(view.label, 1, true), "missing label at offset " .. offset)
      test.ok(row_text(row):find("agent", 1, true), "missing query at offset " .. offset)
      local _, caret_y = view:get_line_screen_position(1, 6)
      test.equal(math.floor(caret_y / 16 + .5), row)
      local _, suggestions_y = view:get_suggestions_bounds()
      local suggestion_row = math.floor(suggestions_y / 16 + .5)
      test.ok(row_text(suggestion_row):find("AGENTS.md", 1, true),
        "missing suggestion at offset " .. offset)
      local x, _, w = view:get_floating_bounds()
      for _, col in ipairs({math.floor(x / 8), math.floor((x + w - style.divider_size) / 8)}) do
        test.equal(session.grid:cell(col, suggestion_row)[1], "│",
          "suggestion erases palette side at offset " .. offset)
      end
    end
  end)

  test.test("markdown soft breaks stay inline when drawing and scrolling", function()
    local MarkdownView = require "core.markdownview"
    session.grid:resize(80, 12)
    local markdown = MarkdownView(("A soft\nbreak with **bold** and `code`.\n\n"):rep(20))
    markdown.size.x, markdown.size.y = 640, 192
    for _, scroll in ipairs({0, 67, 135.5, 0}) do
      markdown.scroll.y, markdown.scroll.to.y = scroll, scroll
      renderer.begin_frame()
      markdown:draw()
      local output = session.grid:present(true)
      test.not_ok(output:find("[\r\n]"), "line ending emitted at scroll " .. scroll)
      local found = false
      for row = 0, 11 do
        found = found or row_text(row):find("A soft break with bold and code.", 1, true)
      end
      test.ok(found, "missing inline paragraph at scroll " .. scroll)
    end
  end)

  test.test("hover color copies fill the same terminal row as their text", function()
    local hover = {style.line_highlight[1], style.line_highlight[2], style.line_highlight[3], 160}
    for offset = 0, 15 do
      renderer.begin_frame()
      renderer.draw_rect(8, 16+offset, 80, 16, hover)
      renderer.draw_text(style.font, "hovered", 8, 16+offset, white)
      local row = math.floor((16+offset)/16+.5)
      for y = 0, 4 do
        test.equal(session.grid:cell(2, y)[3] ~= session.grid:cell(15, y)[3], y == row,
          "hover background row at offset " .. offset)
      end
    end
  end)

  test.test("scrolling long results preserves every side and bottom of a floating palette", function()
    session.grid:resize(80, 18)
    core.root_view.size.x, core.root_view.size.y = 640, 288
    core.clip_rect_stack = {{0,0,640,288}}
    local view = CommandView()
    view.display_position = "center"
    view:set_floating(true)
    view.label, view.gutter_width = "Find:", 48
    view.position.x, view.position.y = 32, 32
    view.size.x, view.size.y = 480, 16
    view.center_height = 179
    view.suggestions_height = 160
    for i = 1, 40 do view.suggestions[i] = {text=string.rep("result-" .. i .. "-", 12)} end
    view.floating_visible, view.suggestions_view.floating_visible = true, true
    core.root_view:add_floating_view(view)
    core.root_view:add_floating_view(view.suggestions_view)
    local ok, err = pcall(function()
      for offset = 0, 63 do
        view.position.x = offset < 32 and 32 or 36
        view.suggestion_idx = 5
        view.suggestions_view.scroll.y = offset % 32
        renderer.begin_frame()
        view:draw()
        view.suggestions_view:draw()
        local x, y, w, h = view:get_floating_bounds()
        local left, right = math.floor(x/8), math.floor((x+w-style.divider_size)/8)
        local top, bottom = math.floor(y/16), math.floor((y+h-style.divider_size)/16)
        for row = top+1, bottom-1 do
          for _, col in ipairs({left, right}) do
            local cell = session.grid:cell(col, row)
            test.ok(cell[8] and bit.band(cell[8], 2) ~= 0,
              "side missing at scroll " .. offset .. ", row " .. row)
          end
        end
        for col = left+1, right-1 do
          local cell = session.grid:cell(col, bottom)
          test.ok(cell[8] and bit.band(cell[8], 1) ~= 0,
            "bottom overwritten at scroll " .. offset .. ", column " .. col)
        end
      end
    end)
    view.suggestions_view:hide_floating()
    view:hide_floating()
    if not ok then error(err) end
  end)

  test.test("compact widget buttons keep borders beside labels at every row offset", function()
    local Button = require "widget.button"
    local root = widget_root()
    local button = Button(root, "User Module")
    button:set_icon("F")
    for offset = 0, 15 do
      button:set_position(8, 16 + offset)
      root:update()
      session.grid:clear(black)
      button:draw()
      session.grid:present()
      local row = math.floor(button.position.y / 16 + .5)
      local line = row_text(row)
      test.ok(line:find("User Module", 1, true), "offset " .. offset)
      test.not_ok(line:find("─", 1, true), "border crosses label at offset " .. offset)
      local _, sides = line:gsub("│", "")
      test.equal(sides, 2, "missing button sides at offset " .. offset)
      test.ok(button:mouse_on_top(button.position.x + 12, row * 16 + 8))
    end
  end)

  test.test("numberbox inputs remain visible at every row offset", function()
    local NumberBox = require "widget.numberbox"
    local root = widget_root()
    local number = NumberBox(root, 10, 0, 100)
    for offset = 0, 15 do
      number:set_position(8, 16 + offset)
      number:update_size_position()
      root:update()
      session.grid:clear(black)
      number:draw()
      local row = math.floor(number.textbox.textview.position.y / 16 + .5)
      test.ok(row_text(row):find("10", 1, true), "missing number at offset " .. offset)
      test.ok(number:mouse_on_top(number.textbox.position.x + 12, row * 16 + 8))
    end
    number:increase()
    root:update()
    session.grid:clear(black)
    number:draw()
    test.equal(number:get_value(), 11)
    test.ok(row_text(2):find("11", 1, true))
  end)

  test.test("toggle markers stay distinct on their caption row at every offset", function()
    local root = widget_root()
    local toggle = Toggle(root, "Enabled", true)
    root:update()
    for _, enabled in ipairs({true, false}) do
      toggle:set_toggle(enabled)
      for offset = 0, 15 do
        toggle:set_position(8, 16 + offset)
        root:update()
        session.grid:clear(black)
        toggle:draw()
        local row = math.floor(toggle.caption_label.position.y / 16 + .5)
        local col = math.floor((toggle.position.x + toggle.toggle_x) / 8 + .5)
        test.ok(row_text(row):find("Enabled", 1, true))
        test.ok(row_text(row):find(enabled and "[  ●]" or "[●  ]", 1, true))
        for x = col, col + 4 do
          test.equal(session.grid:cell(x, row)[3], 0)
          test.is_nil(session.grid:cell(x, row)[11])
          test.equal(session.grid:cell(x, row - 1)[3], 0)
          test.equal(session.grid:cell(x, row + 1)[3], 0)
        end
      end
    end
  end)

  test.test("checkbox selection draws immediately and survives every scroll offset", function()
    local root = widget_root()
    local checkbox = CheckBox(root, "Install plugin")
    local changes = 0
    function checkbox:on_change() changes = changes + 1 end
    for offset = 0, 15 do
      checkbox:set_position(8, 16 + offset)
      root:update()
      local row = math.floor(checkbox.position.y / 16 + .5)
      test.ok(checkbox:mouse_on_top(20, row * 16 + 8))
      for _, checked in ipairs({true, false}) do
        checkbox:on_click()
        test.equal(checkbox:is_checked(), checked)
        session.grid:clear(black)
        renderer.set_clip_rect(0, row * 16, 640, 16)
        checkbox:draw()
        session.grid:present()
        renderer.set_clip_rect(0, 0, 640, 160)
        test.contains(row_text(row), checked and "[✓]" or "[ ]", "offset " .. offset)
        test.contains(row_text(row), "Install plugin")
        test.equal(session.grid:cell(2, row - 1)[1], " ")
        test.equal(session.grid:cell(2, row + 1)[1], " ")
      end
    end
    test.equal(changes, 32)
  end)

  test.test("checkbox labels reserve marker width including wrapped labels", function()
    local root = widget_root()
    local checkbox = CheckBox(root, "Plugin selection")
    checkbox:set_wrap_width(100)
    checkbox:set_position(8, 16)
    root:update()
    checkbox:set_checked(true)
    session.grid:clear(black)
    checkbox:draw()
    test.contains(row_text(1), "[✓] Plugin")
    test.contains(row_text(2), "selection")
    checkbox:set_checked(false)
    checkbox.mixed = true
    session.grid:clear(black)
    checkbox:draw()
    test.contains(row_text(1), "[-] Plugin")
    checkbox:hide()
    session.grid:clear(black)
    test.equal(checkbox:draw(), false)
    test.equal(row_text(1):match("^%s*$") ~= nil, true)
  end)

  test.test("context menu selections fill the label row after dividers", function()
    local ContextMenu = require "core.contextmenu"
    session.grid:resize(80, 12)
    local menu = ContextMenu()
    menus[#menus + 1] = menu
    menu:register(nil, {
      {text = "Open"}, ContextMenu.DIVIDER,
      {text = "Sessions"}, {text = "Close"}
    })
    test.ok(menu:show(8, 16))
    menu.size.x, menu.size.y = menu.items.width, menu.items.height
    menu.height = menu.size.y
    menu.selected = 3
    for offset = 0, 15 do
      menu.position.y = 16 + offset
      session.grid:clear(black)
      menu:draw()
      local row = -1
      for candidate = 0, session.grid.rows - 1 do
        if row_text(candidate):find("Sessions", 1, true) then row = candidate; break end
      end
      test.ok(row >= 0, "missing menu label at offset " .. offset)
      test.equal(menu:row_at(20, row * 16 + 8), 3)
      local selected = style.selection[1] * 65536 + style.selection[2] * 256 + style.selection[3]
      for col = 2, 7 do
        test.equal(session.grid:cell(col, row)[3], selected, "offset " .. offset)
        test.not_ok(session.grid:cell(col, row - 1)[3] == selected)
        test.not_ok(session.grid:cell(col, row + 1)[3] == selected)
      end
    end
  end)

  test.test("context menus keep thin frames and reveal their final scrolling row", function()
    widget_root()
    local menu = ContextMenu()
    menus[#menus + 1] = menu
    local items = {}
    for i = 1, 40 do items[i] = {text="Menu row " .. i, command=function() end} end
    test.ok(menu:show_items(items, 8, 0))
    menu:focus_previous()
    menu:update()
    session.grid:resize(80, 12)
    session.grid:clear(black)
    menu:draw()
    session.grid:present()
    local x, y, w, h = menu:get_floating_bounds()
    local top, bottom = math.floor(y / 16), math.floor((y + h) / 16) - 1
    local divider = style.divider[1] * 65536 + style.divider[2] * 256 + style.divider[3]
    for _, row in ipairs({top, bottom}) do
      for col = math.floor(x / 8) + 1, math.floor((x + w) / 8) - 2 do
        local cell = session.grid:cell(col, row)
        test.equal(cell[1], "─")
        test.equal(cell[2], divider)
        test.not_ok(cell[3] == divider)
      end
    end
    local found = false
    for row = top + 1, bottom - 1 do
      if row_text(row):find("Menu row 40", 1, true) then found = true end
    end
    test.ok(found, "last item should remain visible inside the frame")
    test.equal(menu:row_at(x + 16, y + 8), -1)
    test.equal(menu:row_at(x + 16, y + h - 8), -1)
  end)

  test.test("mouse clicks and drags resolve the rendered document row at every offset", function()
    local Doc = require "core.doc"
    local doc = Doc()
    doc:insert(1, 1, "one\ntwo\nthree\nfour\nfive\n")
    local view = DocView(doc)
    view.position.x, view.size.x, view.size.y = 32, 480, 144
    core.active_view = view
    local line_height = config.line_height
    config.line_height = 1
    local root = core.root_view
    local pressed, moved = rawget(root, "on_mouse_pressed"), rawget(root, "on_mouse_moved")
    root.on_mouse_pressed = function() return false end
    root.on_mouse_moved = function(_, ...) view:on_mouse_moved(...) end
    local ok, err = pcall(function()
      for offset = 0, 15 do
        view.position.y = 16 + offset
        view.scroll.y, view.scroll.to.y = 3.25, 3.25
        local x, y = view:get_line_screen_position(3)
        local column, row = math.floor(x / 8 + .5), math.floor(y / 16 + .5)
        core.on_event("mousepressed", "left", column * 8 + 4, row * 16 + 8, 1)
        test.equal(select(1, doc:get_selection()), 3, "click at offset " .. offset)
        test.equal(select(1, view:resolve_screen_position(x + 4, y + 8)), 3)
        core.on_event("mousemoved", column * 8 + 4, (row + 1) * 16 + 8, 0, 16)
        local line, _, anchor = doc:get_selection()
        test.equal(line, 4, "drag at offset " .. offset)
        test.equal(anchor, 3)
        view.mouse_selecting = nil
      end
    end)
    config.line_height = line_height
    root.on_mouse_pressed, root.on_mouse_moved = pressed, moved
    if not ok then error(err, 0) end
  end)

  test.test("opts into Nerd Font icons with matching drawing and measurement", function()
    local fonts = require "plugins.tui.fonts"
    local style = require "core.style"
    local icon = style.icon_font
    test.equal(fonts.translate(icon, "dLS"), "+/S")
    config.plugins.tui.nerdicons = true
    local folder, search, save = utf8.char(0xf07b), utf8.char(0xf002), utf8.char(0xf0c7)
    test.equal(fonts.translate(icon, "dLS"), folder .. " " .. search .. " " .. save .. " ")
    test.equal(icon:get_width("dLS"), 48)
    test.equal(renderer.draw_text(icon, "dLS", 0, 0, white), 48)
    test.equal(session.grid.cells[1][1], folder)
    test.equal(session.grid.cells[2][1], " ")
    test.equal(session.grid.cells[3][1], search)
    test.equal(session.grid.cells[5][1], save)
    test.equal(renderer.draw_text(style.font, "Label", 48, 0, white), 88)
    test.equal(session.grid.cells[7][1], "L")
    test.ok(session.grid:present(true):find(save .. " Label", 1, true))
    test.equal(fonts.translate(style.code_font, "dLS"), "dLS")
    test.equal(fonts.translate(icon, "d #"), folder .. "  ◇")
    config.plugins.tui.nerdicons = false
    test.equal(fonts.translate(icon, "dLS"), "+/S")
  end)

  test.test("preserves existing Nerd Font glyphs from other icon fonts", function()
    local fonts = require "plugins.tui.fonts"
    local font = renderer.font.load("/plugins/nerdicons/SymbolsNerdFontMono-Regular.ttf", 16)
    local glyph = utf8.char(0xe620)
    for _, enabled in ipairs({false, true}) do
      config.plugins.tui.nerdicons = enabled
      test.equal(fonts.translate(font, glyph), glyph)
      test.equal(fonts.translate(font, "L"), "L")
    end
  end)

  test.test("keeps subcell separators from erasing labels", function()
    local font = renderer.font.load("terminal", 16)
    renderer.draw_text(font, "General", 8, 14, white)
    renderer.draw_rect(0, 30, 160, 2, {80, 80, 80})
    test.equal(session.grid.cells[22][1], "G")
    renderer.draw_rect(0, 46, 160, 2, {80, 80, 80})
    test.equal(session.grid.cells[41][1], "─")
  end)

  test.test("removes an entire border stroke when text must share its row", function()
    renderer.draw_rect(0, 16, 160, 1, white)
    renderer.draw_rect(0, 16, 1, 48, white)
    renderer.draw_rect(159, 16, 1, 48, white)
    renderer.draw_text(style.font, "Label", 8, 16, white)
    session.grid:present()
    test.ok(row_text(1):find("Label", 1, true))
    test.not_ok(row_text(1):find("─", 1, true))
    test.equal(session.grid:cell(0, 1)[1], "│")
    test.equal(session.grid:cell(19, 1)[1], "│")
  end)

  test.test("popup backgrounds cover underlying text at partial row boundaries", function()
    renderer.draw_text(style.font, "behind popup", 8, 64, white)
    renderer.draw_rect(0, 24, 160, 48, style.background3)
    test.not_ok(row_text(4):find("behind", 1, true))
    test.is_nil(session.grid:cell(1, 4)[11])
    local bg = style.background3
    test.equal(session.grid:cell(1, 4)[3], bg[1] * 65536 + bg[2] * 256 + bg[3])
  end)

  test.test("joins widget borders into boxes and preserves them under inset fills", function()
    renderer.draw_rect(8, 16, 80, 1, white)
    renderer.draw_rect(8, 63, 80, 1, white)
    renderer.draw_rect(8, 17, 1, 46, white)
    renderer.draw_rect(87, 17, 1, 46, white)
    renderer.draw_rect(9, 17, 78, 46, black)
    local font = renderer.font.load("terminal", 16)
    renderer.draw_text(font, "Button", 16, 32, white)
    session.grid:present(true)
    test.equal(session.grid.cells[22][1], "┌")
    test.equal(session.grid.cells[31][1], "┐")
    test.equal(session.grid.cells[62][1], "└")
    test.equal(session.grid.cells[71][1], "┘")
    test.equal(session.grid.cells[43][1], "B")
    test.equal(session.grid.cells[22][2], 0xffffff)
    renderer.draw_rect(0, 0, 160, 96, black)
    session.grid:present(true)
    test.equal(session.grid.cells[22][1], " ")
    test.is_nil(session.grid.cells[22][8])
  end)

  test.test("ListBox selection and hover stay inside their side borders", function()
    local ListBox = require "widget.listbox"
    local root = widget_root()
    local list = ListBox(root)
    list:add_column("Recent Projects")
    list:add_row({"~/Development/project"})
    list:add_row({"another project"})
    list:set_size(243, 128)
    list:show()
    local color = list.border.color or style.text
    local border_color = color[1] * 65536 + color[2] * 256 + color[3]
    for offset = 0, 7.75, .25 do
      list:set_position(8 + offset, 0)
      root:update()
      list:set_selected(1)
      -- Also hover the second row so both background paths are exercised.
      list.mouse.x = list.position.x + 30
      list.mouse.y = list.position.y + 34
      session.grid:clear(black)
      root:draw()
      local left = math.floor((list.position.x - list.border.width) / 8)
      local right = math.floor((list.position.x + list.size.x) / 8)
      for row = 1, 2 do
        for _, col in ipairs({left, right}) do
          local cell = session.grid:cell(col, row)
          test.equal(cell[8], 2, "border missing at offset " .. offset)
          test.equal(cell[2], border_color)
          local bg = session.grid:cell(col, 5)[3]
          test.equal(cell[3], bg, "highlight spills into border at " .. offset)
        end
      end
    end
  end)

  test.test("ListBox clicks and hover target the displayed row at fractional offsets", function()
    local ListBox = require "widget.listbox"
    local root = widget_root()
    local list = ListBox(root)
    list:add_column("Items")
    for i = 1, 8 do list:add_row({"row-" .. i}) end
    list:set_size(120, 90)
    list:show()
    local highlight = style.line_highlight
    local highlight_rgb = highlight[1] * 65536 + highlight[2] * 256 + highlight[3]
    for _, border in ipairs({0, 1}) do
      list.border.width = border
      list:recalc_all_rows()
      for offset = 0, 15 do
        for _, scroll in ipairs({0, 3.25, 8, 15}) do
          list:set_position(8, offset)
          list.scroll.y, list.scroll.to.y = scroll, scroll
          list:set_selected(nil)
          list.mouse.x, list.mouse.y = -100, -100
          root:update()
          session.grid:clear(black)
          root:draw()
          for row = 1, 4 do
            local label = row_text(row):match("row%-(%d)")
            if label then
              local x, y = 28, row * 16 + 8
              local context = "border " .. border .. ", offset " .. offset
                .. ", scroll " .. scroll .. ", row " .. row
              test.equal(list:get_row_at_position(x, y), tonumber(label), context)
              test.equal(require("core.emptyview").get_recent_project_row_at(
                {recent_projects = list}, x, y), tonumber(label), context .. " context target")
              list:on_mouse_moved(x, y, 0, 0)
              session.grid:clear(black)
              root:draw()
              test.equal(list.hovered_row, tonumber(label), context)
              test.equal(session.grid:cell(3, row)[3], highlight_rgb, context)
              test.not_ok(session.grid:cell(3, row - 1)[3] == highlight_rgb, context)
              test.not_ok(session.grid:cell(3, row + 1)[3] == highlight_rgb, context)
              list:on_click("left", x, y)
              test.equal(list:get_selected(), tonumber(label), context)
              break
            end
          end
        end
      end
    end
  end)

  test.test("keeps inset toggle thumbs centered across partial terminal rows", function()
    for _, offset in ipairs({3, 22}) do
      session.grid:clear(black)
      -- Toggle draws a 40x20 track and a 15x14 thumb inset by three pixels.
      -- At y=4, whole-row rounding made the track twice the thumb's height.
      renderer.draw_rect(8, 4, 40, 20, {0, 0, 255})
      renderer.draw_rect(8 + offset, 7, 15, 14, white)
      local col = math.floor((8 + offset) / 8 + .5)
      local top, bottom = session.grid:cell(col, 0), session.grid:cell(col, 1)
      test.equal(top[1], "▀")
      test.equal(top[2], 0)
      test.equal(top[3], 0xffffff)
      test.equal(bottom[1], "▀")
      test.equal(bottom[2], 0xffffff)
      test.equal(bottom[3], 0)
      test.equal(session.grid:cell(col, 2)[3], 0)
    end
  end)

  test.test("clips partial fills and retains their colors through canvas composition", function()
    renderer.set_clip_rect(8, 16, 16, 16)
    renderer.draw_rect(0, 8, 80, 16, white)
    test.equal(session.grid:cell(1, 1)[1], "▀")
    test.equal(session.grid:cell(1, 1)[2], 0xffffff)
    test.equal(session.grid:cell(1, 1)[3], 0)
    test.equal(session.grid.cells[2][3], 0)
    test.equal(session.grid.cells[21][3], 0)
    session.grid:clear(black)
    local c = canvas.new(40, 32, black)
    c:draw_rect(0, 4, 40, 20, {0, 0, 255})
    renderer.draw_canvas(c, 8, 16)
    renderer.draw_rect(8, 16, 40, 8, white)
    local top = session.grid:cell(1, 1)
    test.equal(top[1], "▀")
    test.equal(top[2], 0xffffff)
    test.equal(top[3], 0x0000ff)
    test.equal(session.grid:cell(1, 2)[2], 0x0000ff)
    test.equal(session.grid:cell(1, 2)[3], 0)
  end)

  test.test("draws junctions without joining adjacent parallel separators", function()
    renderer.draw_rect(0, 16, 160, 1, white)
    renderer.draw_rect(0, 32, 160, 1, white)
    renderer.draw_rect(80, 0, 1, 33, white)
    session.grid:present()
    test.equal(session.grid.cells[31][1], "┼")
    test.equal(session.grid.cells[51][1], "┴")
    test.equal(session.grid.cells[26][1], "─")
    test.equal(session.grid.cells[46][1], "─")
    test.equal(session.grid:present(), "")
  end)

  test.test("clips strokes and carries box borders through cached canvases", function()
    renderer.set_clip_rect(8, 16, 24, 32)
    renderer.draw_rect(0, 0, 160, 1, white)
    renderer.draw_rect(0, 0, 1, 96, white)
    renderer.draw_rect(0, 16, 160, 1, white)
    test.equal(session.grid.cells[21][1], " ")
    test.equal(session.grid.cells[22][1], "─")
    test.equal(session.grid.cells[25][1], " ")
    session.grid:clear(black)
    local c = canvas.new(80, 48)
    c:draw_rect(0, 0, 80, 1, white)
    c:draw_rect(0, 47, 80, 1, white)
    c:draw_rect(0, 1, 1, 46, white)
    c:draw_rect(79, 1, 1, 46, white)
    c:draw_rect(1, 1, 78, 46, black)
    renderer.draw_canvas(c, 8, 16)
    session.grid:present()
    test.equal(session.grid.cells[22][1], "┌")
    test.equal(session.grid.cells[31][1], "┐")
    test.equal(session.grid.cells[62][1], "└")
    test.equal(session.grid.cells[71][1], "┘")
  end)

  test.test("uses matching font and drawing metrics for existing and new fonts", function()
    local style = require "core.style"
    local value = "a\t界e\204\129"
    local tab = {tab_offset = 8}
    for _, font in ipairs({style.code_font, renderer.font.load("terminal", 30)}) do
      font:set_tab_size(4)
      local measured = font:get_width(value, tab)
      test.equal(renderer.draw_text(font, value, 0, 0, white, tab), measured)
      test.equal(font:get_height(), 16)
      test.equal(font:copy(80):get_height(), 16)
    end
  end)

  test.test("composites cached text canvases and labels raster content", function()
    local c = canvas.new(80, 16)
    local font = renderer.font.load("terminal", 16)
    c:draw_text(font, "cached", 0, 0, white)
    renderer.draw_canvas(c, 8, 16)
    test.equal(session.grid.cells[22][1], "c")
    test.equal(session.grid.cells[27][1], "d")
    renderer.draw_canvas(c:copy(), 8, 32)
    test.equal(session.grid.cells[42][1], "c")
    c:set_pixels("", 0, 0, 0, 0)
    renderer.draw_canvas(c, 0, 0)
    test.equal(session.grid.cells[1][1], "I")
  end)

  test.test("canvases created before activation use terminal instance methods", function()
    session.grid:resize(60, 6)
    local w, h = native_canvas:get_size()
    test.equal(w, 64)
    test.equal(h, 32)
    renderer.draw_canvas(native_canvas, 0, 0)
    test.contains(row_text(0), "Image preview unsupported")
    native_canvas:clear(black)
    native_canvas:draw_text(renderer.font.load("terminal", 16), "cached", 0, 0, white)
    native_canvas:render()
    session.grid:clear(black)
    renderer.draw_canvas(native_canvas, 0, 0)
    test.contains(row_text(0), "cached")
    local pixels, err = native_canvas:get_pixels()
    test.is_nil(pixels)
    test.contains(err, "unavailable in terminal mode")
  end)

  test.test("missing Chafa keeps PNG loading and zooming with an install hint", function()
    session.images.missing = true
    session.grid:resize(60, 6)
    local path = core.temp_filename(".png")
    temp_files[#temp_files + 1] = path
    local ok, err = native_save_image(native_canvas, path)
    test.ok(ok, err)
    local ImageView = require "core.imageview"
    local view = ImageView(path, "fixed", 1)
    test.not_nil(view.image, view.errmsg)
    view.size.x, view.size.y = 480, 96
    for _, scale in ipairs({1, 2, .5}) do
      view.zoom_scale = scale
      view:scale_image()
      test.equal(view.width, 64 * scale)
      test.equal(view.height, 32 * scale)
      if scale ~= 1 then test.type(view.image_scaled, "table") end
      session.grid:clear(black)
      view:draw()
      local row = math.floor(((96 - view.height) / 2) / 16 + .5)
      test.contains(row_text(row), "Image preview unsupported")
      test.contains(row_text(row + 1), "Install chafa")
    end
    local saved_image, save_error = view.image:save_image(path .. ".copy.png")
    test.is_nil(saved_image)
    test.contains(save_error, "unavailable in terminal mode")
  end)

  test.test("loads and resizes SVG images while preserving load errors", function()
    session.images.missing = true
    session.grid:resize(60, 6)
    local path = core.temp_filename(".svg")
    temp_files[#temp_files + 1] = path
    local file = assert(io.open(path, "w"))
    file:write('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="32">'
      .. '<rect width="64" height="32" fill="red"/></svg>')
    file:close()
    local c, err = canvas.load_svg_image(path, 80, 48)
    test.not_nil(c, err)
    local w, h = c:get_size()
    test.equal(w, 80)
    test.equal(h, 40) -- Native SVG loading preserves the image's aspect ratio.
    renderer.draw_canvas(c, 0, 0)
    test.contains(row_text(0), "Image preview unsupported")
    local ImageView = require "core.imageview"
    local view = ImageView(path, "fixed", 2)
    view.size.x, view.size.y = 480, 96
    view:update()
    test.equal(view.width, 128)
    test.equal(view.height, 64)
    view:draw()
    test.contains(row_text(1), "Image preview unsupported")
    c, err = canvas.load_image(path .. ".missing")
    test.is_nil(c)
    test.type(err, "string")
  end)

  test.test("Chafa previews real PNG and SVG files with zoom, clipping and overlays", function()
    session.grid:resize(60, 10)
    local ImageView = require "core.imageview"
    for _, ext in ipairs({".png", ".svg"}) do
      local path = core.temp_filename(ext)
      temp_files[#temp_files + 1] = path
      if ext == ".png" then
        test.ok(native_save_image(native_canvas, path))
      else
        local file = assert(io.open(path, "w"))
        file:write('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="32">'
          .. '<rect width="64" height="32" fill="red"/></svg>')
        file:close()
      end
      local view = ImageView(path, "fixed", 1)
      view.size.x, view.size.y = 480, 160
      for _, scale in ipairs({1, 2, .5}) do
        view.zoom_scale = scale
        view:scale_image()
        session.grid:clear(black)
        view:draw()
        local deadline = system.get_time() + 12
        while session.images.worker and system.get_time() < deadline do
          local key = session.images.worker
          local thread = core.threads[key]
          test.ok(coroutine.resume(thread.cr))
          if coroutine.status(thread.cr) == "dead" then core.threads[key] = nil end
          system.sleep(.001)
        end
        test.not_ok(session.images.worker, "Chafa conversion did not finish")
        test.skip_if(session.images.missing, "Chafa is not installed")
        session.grid:clear(black)
        view:draw()
        -- The fixture is opaque red. Chafa may encode it as a space with a red
        -- background or a block with a red foreground, with minor quantization.
        local cell = session.grid:cell(30, 5)
        local function red(color) return color >= 0xf00000 and color % 65536 < 256 end
        test.ok(red(cell[2]) or red(cell[3]), "Chafa did not render the fixture")
        session.grid:clear(black)
        session.grid:set_clip(1, 1, 2, 1)
        renderer.draw_canvas(view.image_scaled, 0, 0)
        test.equal(session.grid.cells[1][3], 0)
        test.equal(session.grid.cells[4][3], 0)
        session.grid:set_clip(0, 0, 60, 10)
        session.grid:begin_layer()
        session.grid:rect(0, 0, 4, 2, black, true)
        session.grid:draw_text("menu", 0, 0, white)
        test.contains(row_text(0), "menu")
        session.grid:present(true)
        test.equal(session.grid:present(true), "")
      end
    end
  end)

  test.test("does not queue another frame while terminal output is pending", function()
    local writes = 0
    session.terminal.write = function() writes = writes + 1 end
    session.terminal.pending = "pending bytes"
    renderer.end_frame()
    test.equal(writes, 0)
    test.equal(next(session.grid.previous), nil)
    session.terminal.pending = ""
    renderer.end_frame()
    test.equal(writes, 1)
  end)

  test.test("clips cached wide glyphs and erases overwritten continuations", function()
    local font = renderer.font.load("terminal", 16)
    local c = canvas.new(16, 16)
    c:draw_text(font, "界", 0, 0, white)
    renderer.draw_canvas(c, -8, 0)
    test.equal(session.grid.cells[1][4], 1)
    renderer.draw_canvas(c, 152, 0)
    test.equal(session.grid.cells[20][1], " ")
    renderer.draw_canvas(c, 0, 0)
    test.equal(session.grid.cells[2][4], 0)
    local narrow = canvas.new(8, 16)
    narrow:draw_text(font, "x", 0, 0, white)
    renderer.draw_canvas(narrow, 8, 0)
    test.equal(session.grid.cells[1][1], " ")
    test.equal(session.grid.cells[1][4], 1)
    test.equal(session.grid.cells[2][1], "x")
  end)
end)
