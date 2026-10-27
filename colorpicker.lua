local common = require "core.common"
local style = require "core.style"
local Widget = require "widget"
local ColorPicker = require "widget.colorpicker"

---Cell-aligned gradients and input for the shared color picker widget.
local colorpicker = {}
local properties = {"hue", "saturation", "brightness", "alpha"}
local white, black = {255, 255, 255}, {0, 0, 0}

---Get the four gradient rows, regenerating colors only when their inputs change.
---@param picker widget.colorpicker
---@param columns integer
---@return renderer.color[][] rows
local function gradients(picker, columns)
  local cache = picker.terminal_colors
  local h, s, v = picker.hue_pos / 100, picker.saturation_pos / 100, picker.brightness_pos / 100
  if not cache or cache.columns ~= columns or cache.h ~= h or cache.s ~= s or cache.v ~= v then
    cache = {columns = columns, h = h, s = s, v = v, rows = {{}, {}, {}, {}}}
    for col = 1, columns do
      local t = (col - 1) / math.max(1, columns - 1)
      cache.rows[1][col] = ColorPicker.hsv_to_rgb(t, 1, 1, 1)
      cache.rows[2][col] = ColorPicker.hsv_to_rgb(h, t, 1, 1)
      cache.rows[3][col] = ColorPicker.hsv_to_rgb(h, s, t, 1)
      cache.rows[4][col] = ColorPicker.hsv_to_rgb(h, s, v, t)
    end
    picker.terminal_colors = cache
  end
  return cache.rows
end

---Map a terminal cell center to the native slider's exact endpoint range.
---@param picker widget.colorpicker
---@param x number
---@return number x
local function slider_x(picker, x)
  local selector = picker.selector
  local columns = math.max(1, math.floor(selector.w / 8))
  local col = common.clamp(math.floor((x - selector.x) / 8), 0, columns - 1)
  return selector.x + col / math.max(1, columns - 1) * selector.w
end

---Install terminal presentation without changing color conversion or text input.
function colorpicker.install()
  ---Keep four distinct slider rows and place text inputs below the preview.
  function ColorPicker:update_size_position()
    ColorPicker.super.update_size_position(self)
    self.selector.h = 16
    self.html_notation:set_position(0, 80)
    self.html_notation:set_size(144)
    self.rgba_notation:set_position(self.html_notation:get_right() + 8, 80)
    self.rgba_notation:set_size(208)
    self:set_size(self.rgba_notation:get_right() + 8, self.rgba_notation:get_bottom() + 2)
  end

  ---Draw gradients by terminal columns, with one contrasting selector per row.
  ---@return boolean drawn
  function ColorPicker:draw()
    if not Widget.draw(self) then return false end
    local selector = self.selector
    selector.x = math.floor(self.position.x / 8 + .5) * 8
    selector.y = math.floor(self.position.y / 16 + .5) * 16
    selector.w = math.max(8, math.floor((self.size.x - 80) / 8) * 8)
    selector.h = 16
    local columns = selector.w / 8
    local rows = gradients(self, columns)
    for row, property in ipairs(properties) do
      local y = selector.y + (row - 1) * 16
      for col, color in ipairs(rows[row]) do
        renderer.draw_rect(selector.x + (col - 1) * 8, y, 8, 16, color)
      end
      local col = math.floor(self[property .. "_pos"] / 100 * (columns - 1) + .5)
      local color = rows[row][col + 1]
      local alpha = (color[4] or 255) / 255
      local brightness = 0
      for channel = 1, 3 do
        brightness = brightness + color[channel] * alpha + style.background[channel] * (1 - alpha)
      end
      renderer.draw_text(style.font, "◆", selector.x + col * 8, y, brightness > 382 and black or white)
    end
    renderer.draw_rect(selector.x + selector.w + 8, selector.y, 72, 64, self:get_color())
    return true
  end

  local mouse_moved = ColorPicker.on_mouse_moved
  ---Drag through the same complete cells used to paint the gradient.
  ---@param x number
  ---@param y number
  ---@param dx number
  ---@param dy number
  ---@return boolean? handled
  function ColorPicker:on_mouse_moved(x, y, dx, dy)
    for _, property in ipairs(properties) do
      if self[property .. "_mouse_down"] then
        return mouse_moved(self, slider_x(self, x), y, dx, dy)
      end
    end
    return mouse_moved(self, x, y, dx, dy)
  end

  ---Select exactly one gradient row, including the separate alpha control.
  ---@param button core.view.mousebutton
  ---@param x number
  ---@param y number
  ---@param clicks integer
  ---@return boolean handled
  function ColorPicker:on_mouse_pressed(button, x, y, clicks)
    if not Widget.on_mouse_pressed(self, button, x, y, clicks) then return false end
    local selector = self.selector
    local row = math.floor((y - selector.y) / 16) + 1
    if button == "left" and properties[row]
      and x >= selector.x and x < selector.x + selector.w then
      for i, property in ipairs(properties) do self[property .. "_mouse_down"] = i == row end
      self:capture_mouse(false, button)
      mouse_moved(self, slider_x(self, x), y, 0, 0)
    end
    return true
  end
end

return colorpicker
