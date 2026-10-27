local core = require "core"
local common = require "core.common"
local style = require "core.style"
local ContextMenu = require "core.contextmenu"
local drawing = require "plugins.tui.drawing"

---Whole-cell frames and rows shared by context menus and application submenus.
local menus = {}

---Fit cached menu contents, reserving one terminal row for each frame edge.
---@param menu core.contextmenu
local function fit(menu)
  if not menu.items then return end
  menu.items.width = math.max(24, math.ceil(menu.items.width / 8) * 8)
  menu.items.height = (#menu.items + 2) * 16
  local height = math.max(48, math.floor(core.root_view.size.y / 16) * 16)
  local scrollbar = menu.items.height > height and 8 or 0
  menu.size.x = math.min(menu.items.width + scrollbar, math.floor(core.root_view.size.x / 8) * 8)
  menu.size.y = math.min(menu.items.height, height)
  menu.height = menu.size.y
end

---Install terminal menu geometry while retaining command dispatch and predicates.
function menus.install()
  local show_items = ContextMenu.show_items
  ---Measure a new menu snapshot with room for a thin complete frame.
  ---@param ... any Native show_items arguments
  ---@return boolean? shown
  function ContextMenu:show_items(...)
    local shown = show_items(self, ...)
    if shown then fit(self) end
    return shown
  end

  local update = ContextMenu.update
  ---Refresh terminal geometry after native font, hover and submenu updates.
  function ContextMenu:update()
    update(self)
    if self.show_context_menu then fit(self); self:update_scrollbar() end
  end

  ---@return number height Including the fixed top and bottom frame rows
  function ContextMenu:get_scrollable_size()
    return self.items and (#self.items + 2) * 16 or 0
  end

  ---Return the exact terminal rectangle used for drawing and pointer input.
  ---@return number x
  ---@return number y
  ---@return number width
  ---@return number height
  function ContextMenu:get_floating_bounds()
    return math.floor(self.position.x / 8 + .5) * 8,
      math.floor(self.position.y / 16 + .5) * 16, self.size.x, self.height
  end

  ---Apply outer menu bounds without the native pixel-border inset.
  ---@param x number
  ---@param y number
  ---@param width number
  ---@param height number
  function ContextMenu:set_floating_bounds(x, y, width, height)
    self.position.x, self.position.y = x, y
    self.size.x, self.size.y, self.height = width, height, height
  end

  ---Iterate visible-layout rows with a whole-cell separator and frame inset.
  ---@return fun():integer,core.contextmenu.item,number,number,number,number
  function ContextMenu:each_item()
    local x, y, w = self:get_floating_bounds()
    local scrollbar = self:get_scrollable_size() > self.size.y and 8 or 0
    y = y + 16 - math.floor(self.scroll.y / 16 + .5) * 16
    return coroutine.wrap(function()
      for i, item in ipairs(self.items or {}) do
        coroutine.yield(i, item, x, y, w - scrollbar, 16)
        y = y + 16
      end
    end)
  end

  ---Keep a long menu's thumb inside the frame and outside its hint column.
  function ContextMenu:update_scrollbar()
    local x, y, w, h = self:get_floating_bounds()
    self.v_scrollbar:set_size(x, y + 16, math.max(0, w - 8), math.max(0, h - 32),
      self.items and #self.items * 16 or 0)
    self.v_scrollbar:set_percent(self.scroll.y / math.max(1, self:get_scrollable_size() - h))
    self.h_scrollbar:set_size(x, y, w, h, math.huge)
  end

  local focus_step = ContextMenu.focus_step
  ---Reveal the selected row inside the frame, retaining native predicate checks.
  ---@param step integer
  function ContextMenu:focus_step(step)
    focus_step(self, step)
    if self.selected > 0 then
      local top = (self.selected - 1) * 16
      self.scroll.to.y = math.max(0, common.clamp(self.scroll.to.y, top + 16 - (self.size.y - 32), top))
    end
  end

  ---Draw explicit thin strokes instead of a filled rectangle behind the menu.
  function ContextMenu:draw_context_menu()
    if not self.items then return end
    local x, y, w, h = self:get_floating_bounds()
    renderer.draw_rect(x, y, w, h, style.background3)
    core.push_clip_rect(x + 8, y + 16, math.max(0, w - 16), math.max(0, h - 32))
    for i, item, bx, by, bw, bh in self:each_item() do
      if item == self.DIVIDER then
        renderer.draw_rect(bx + 8, by + 8, bw - 16, 1, style.divider)
      else
        local color = item.enabled and style.text or style.dim
        if i == self.selected and item.enabled then renderer.draw_rect(bx, by, bw, bh, style.selection) end
        local left = bx + 8
        if item.checked ~= nil then
          if item.checked_value then renderer.draw_text(style.font, "✓", left, by, color) end
          left = left + common.round(style.font:get_height() * .65) + 8
        end
        local hint = item.items and ">" or item.info
        local right = bx + bw - 8 - (hint and style.font:get_width(hint) + 8 or 0)
        core.push_clip_rect(left, by, math.max(0, right - left), bh)
        common.draw_text(style.font, color, item.text, "left", left, by, bw, bh)
        core.pop_clip_rect()
        if hint then
          common.draw_text(style.font, style.dim, hint, "right", bx, by, bw - 8, bh)
        end
      end
    end
    self:draw_scrollbar()
    core.pop_clip_rect()
    drawing.draw_frame(x, y, w, h, style.divider)
  end
end

return menus
