local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local Scrollbar = require "core.scrollbar"
local ListBox = require "widget.listbox"

---Whole-cell scrollbar geometry shared by painting, hover and dragging.
local scrollbars = {}

---Whether the owner has content beyond this scrollbar's viewport.
---@param bar core.scrollbar
---@return boolean
local function visible(bar)
  return bar.rect.scrollable ~= math.huge
    and bar.rect.scrollable > (bar.direction == "v" and bar.rect.h or bar.rect.w)
end

---Get a one-cell track entirely inside the owning view's pixel bounds.
---@param bar core.scrollbar
---@return number x
---@return number y
---@return number width
---@return number height
local function track(bar)
  if not visible(bar) then return 0, 0, 0, 0 end
  local r = bar.rect
  local left, top = math.ceil(r.x / 8), math.ceil(r.y / 16)
  local right, bottom = math.floor((r.x + r.w) / 8), math.floor((r.y + r.h) / 16)
  if right <= left or bottom <= top then return 0, 0, 0, 0 end
  local peer = bar.terminal_peer
  if bar.direction == "v" then
    if peer and visible(peer) then
      if peer.alignment == "s" then top = top + 1 else bottom = bottom - 1 end
    end
    return (bar.alignment == "s" and left or right - 1) * 8, top * 16,
      8, math.max(0, bottom - top) * 16
  end
  if peer and visible(peer) then
    if peer.alignment == "s" then left = left + 1 else right = right - 1 end
  end
  return left * 8, (bar.alignment == "s" and top or bottom - 1) * 16,
    math.max(0, right - left) * 8, 16
end

---Install terminal-only geometry without changing scroll ranges or view layout.
function scrollbars.install()
  local scrollable_size = ListBox.get_scrollable_size
  ---Let the final row scroll above a horizontal bar occupying a full cell row.
  ---@return number height
  function ListBox:get_scrollable_size()
    local size = scrollable_size(self)
    local last = self.rows[#self.rows]
    if last and last.y and self:get_h_scrollable_size() > self.size.x then
      local bottom = self.position.y + self.size.y
      local padding = bottom - math.floor(bottom / 16) * 16 + 16
      size = math.max(size, last.y + last.h + padding)
    end
    return size
  end

  local background = View.draw_background
  ---Keep each scrollbar's cleared track consistent with its owning surface.
  ---@param color renderer.color
  function View:draw_background(color)
    self.v_scrollbar.terminal_background, self.h_scrollbar.terminal_background = color, color
    return background(self, color)
  end

  local update = View.update_scrollbar
  ---Keep intersecting scrollbars from painting or dragging each other's corner.
  function View:update_scrollbar()
    self.v_scrollbar.terminal_peer, self.h_scrollbar.terminal_peer = self.h_scrollbar, self.v_scrollbar
    return update(self)
  end

  ---@return number x
  ---@return number y
  ---@return number width
  ---@return number height
  function Scrollbar:_get_track_rect_normal()
    return self:real_to_normal(track(self))
  end

  ---Use integral cells and a minimum thumb of one cell within the track.
  ---@return number x
  ---@return number y
  ---@return number width
  ---@return number height
  function Scrollbar:_get_thumb_rect_normal()
    local x, y, w, h = self:_get_track_rect_normal()
    if w <= 0 or h <= 0 then return 0, 0, 0, 0 end
    local unit = self.direction == "v" and 16 or 8
    local size = self.direction == "v" and self.rect.h or self.rect.w
    local length = math.min(h, math.max(unit, math.floor(h * size / self.rect.scrollable / unit + .5) * unit))
    local offset = math.floor(common.clamp(self.percent, 0, 1) * (h - length) / unit + .5) * unit
    return x, y + offset, w, length
  end

  ---Hit-test the same half-open cell bounds used for drawing.
  ---@param x number
  ---@param y number
  ---@return string? part
  function Scrollbar:_overlaps_normal(x, y)
    local tx, ty, tw, th = self:_get_track_rect_normal()
    if tw <= 0 or th <= 0 or x < tx or x >= tx + tw or y < ty or y >= ty + th then return end
    local _, sy, _, sh = self:_get_thumb_rect_normal()
    return y >= sy and y < sy + sh and "thumb" or "track"
  end

  ---Begin dragging using the quantized track rather than the original pixel size.
  ---@param button string
  ---@param x number
  ---@param y number
  ---@return boolean|number?
  function Scrollbar:_on_mouse_pressed_normal(button, x, y)
    local hit = self:_overlaps_normal(x, y)
    if not hit then return end
    local _, sy, _, sh = self:_get_thumb_rect_normal()
    self.dragging = true
    self.drag_start_offset = hit == "thumb" and sy - y or -sh / 2
    if hit == "thumb" then return true end
    return self:_on_mouse_moved_normal(x, y, 0, 0)
  end

  ---Convert pointer movement into a clamped scroll percentage.
  ---@param x number
  ---@param y number
  ---@return boolean|number
  function Scrollbar:_on_mouse_moved_normal(x, y)
    if not self.dragging then return self:_update_hover_status_normal(x, y) end
    local _, ty, _, th = self:_get_track_rect_normal()
    local _, _, _, sh = self:_get_thumb_rect_normal()
    return th > sh and common.clamp((y - ty + self.drag_start_offset) / (th - sh), 0, 1) or 0
  end

  ---Draw a visible track without translucent half-cell edges.
  function Scrollbar:draw_track()
    local x, y, w, h = self:get_track_rect()
    if w <= 0 or h <= 0 then return end
    local r = self.rect
    local color = self.terminal_background or style.background
    -- Clearing the full edge also masks content rounded into the incomplete
    -- cell between the whole-cell track and the viewport's outer boundary.
    if self.direction == "v" then
      local left = self.alignment == "s" and r.x or x
      local right = self.alignment == "s" and x + w or r.x + r.w
      renderer.draw_rect(left, r.y, right - left, r.h, color)
    else
      local top = self.alignment == "s" and r.y or y
      local bottom = self.alignment == "s" and y + h or r.y + r.h
      renderer.draw_rect(r.x, top, r.w, bottom - top, color)
    end
    if self.direction == "v" then
      for row = y, y + h - 16, 16 do renderer.draw_text(style.font, "│", x, row, style.dim) end
    else
      renderer.draw_text(style.font, string.rep("─", w / 8), x, y, style.dim)
    end
  end
end

return scrollbars
