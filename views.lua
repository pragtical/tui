local core = require "core"
local common = require "core.common"
local style = require "core.style"
local DocView = require "core.docview"
local CommandView = require "core.commandview"
local ContextMenu = require "core.contextmenu"
local EmptyView = require "core.emptyview"
local scrollbars = require "plugins.tui.scrollbars"
local audio_view = require "plugins.tui.audio_view"
local menus = require "plugins.tui.menus"
local drawing = require "plugins.tui.drawing"

---Match view input coordinates to text drawn on the terminal cell grid.
local views = {}

---Round a pixel coordinate to its rendered cell origin.
---@param value number
---@param size number Cell size in logical pixels
---@return number
local function snap(value, size)
  return math.floor(value / size + .5) * size
end

---Adapt mouse-driven document resolution and popup hit testing in TUI mode.
function views.install()
  scrollbars.install()
  audio_view.install()
  menus.install()
  ---Use the list's terminal row geometry for recent-project context actions.
  ---@param x number
  ---@param y number
  ---@return integer? row
  function EmptyView:get_recent_project_row_at(x, y)
    local list = self.recent_projects
    if list:mouse_on_top(x, y) then return list:get_row_at_position(x, y) end
  end

  local tree = package.loaded["plugins.treeview"]
  if tree then
    local TreeView = getmetatable(tree)
    ---Render path tooltips with the same thin frame as other terminal popups.
    function TreeView:draw_tooltip()
      local text = common.home_encode(self.hovered_item.abs_filename)
      local root = core.root_view
      local w = math.min(style.font:get_width(text) + 16, math.floor(root.size.x / 8) * 8)
      local x = snap(self.tooltip.x + 16, 8)
      local y = snap(self.tooltip.y + 16, 16)
      x = common.clamp(x, 0, root.size.x - w)
      y = common.clamp(y, 0, math.floor(root.size.y / 16) * 16 - 48)
      renderer.draw_rect(x, y, w, 48, style.background2)
      core.push_clip_rect(x + 8, y + 16, w - 16, 16)
      renderer.draw_text(style.font, text, x + 8, y + 16, style.text)
      core.pop_clip_rect()
      drawing.draw_frame(x, y, w, 48, style.text)
    end
    local scrollable_size = TreeView.get_scrollable_size
    ---Keep TreeView's existing final padding row above a whole-cell scrollbar.
    ---@return number height
    function TreeView:get_scrollable_size()
      local height = scrollable_size(self)
      if self:get_h_scrollable_size() > self.size.x then
        local bottom = self.position.y + self.size.y
        height = height + bottom - math.floor(bottom / 16) * 16
      end
      return height
    end
  end

  ---Use one terminal row per document line regardless of saved GUI line spacing.
  ---@return number height
  function DocView:get_line_height()
    return self:get_font():get_height()
  end
  -- CommandView defines its own GUI spacing rather than inheriting DocView's.
  CommandView.get_line_height = DocView.get_line_height

  ---Keep caret and pointer geometry on the input's document row.
  ---@param line? integer Single-line input always resolves to line one
  ---@param col? integer
  ---@return number x
  ---@return number y
  function CommandView:get_line_screen_position(line, col)
    return DocView.get_line_screen_position(self, 1, col)
  end

  local move_towards = CommandView.move_towards
  ---Include a divider row in docked height targets without invalidating idle frames.
  ---@param target table|string
  ---@param key string|number
  ---@param destination? number
  ---@param ... any Remaining animation arguments
  function CommandView:move_towards(target, key, destination, ...)
    if target == self.size and key == "y" and destination > 0 and not self.floating then
      destination = destination + 16
    end
    return move_towards(self, target, key, destination, ...)
  end

  local update_floating = CommandView.update_floating
  ---Align centered input and result rows before their nested clipping is applied.
  function CommandView:update_floating()
    update_floating(self)
    self.position.y = snap(self.position.y, 16)
  end

  local mouse_event = false
  local on_event = core.on_event
  ---Keep programmatic document coordinate queries outside mouse events unchanged.
  ---@param kind string
  ---@param ... any Event arguments
  ---@return any handled
  function core.on_event(kind, ...)
    local previous = mouse_event
    mouse_event = kind == "mousepressed" or kind == "mousemoved"
    local ok, result = pcall(on_event, kind, ...)
    mouse_event = previous
    if not ok then error(result, 0) end
    return result
  end

  local resolve = DocView.resolve_screen_position
  ---Translate terminal mouse cells back to the document's unsnapped text origin.
  ---@param x number
  ---@param y number
  ---@return integer line
  ---@return integer column
  function DocView:resolve_screen_position(x, y)
    if mouse_event then
      local ox, oy = self:get_content_offset()
      ox = ox + self:get_gutter_width()
      oy = oy + style.padding.y + self:get_line_text_y_offset()
      x, y = x + ox - snap(ox, 8), y + oy - snap(oy, 16)
    end
    return resolve(self, x, y)
  end

  ---Include the complete terminal cells occupied by a popup.
  ---@param x number
  ---@param y number
  ---@return boolean inside
  function ContextMenu:hit_test(x, y)
    local bx, by, w, h = self:get_floating_bounds()
    return x >= snap(bx, 8) and x < snap(bx + w, 8)
      and y >= snap(by, 16) and y < snap(by + h, 16)
  end

  ---Resolve a menu row using the same rounded bounds as its selection background.
  ---@param x number
  ---@param y number
  ---@return integer index Row index, or -1 outside the menu
  function ContextMenu:row_at(x, y)
    if not self:hit_test(x, y) then return -1 end
    local left, top, width, height = self:get_floating_bounds()
    if x < left + 8 or x >= left + width - 8
      or y < top + 16 or y >= top + height - 16 then return -1 end
    for i, _, bx, by, w, h in self:each_item() do
      if x >= snap(bx, 8) and x < snap(bx + w, 8)
        and y >= snap(by, 16) and y < snap(by + h, 16) then
        return i
      end
    end
    return -1
  end
end

return views
