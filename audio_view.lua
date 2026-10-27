local core = require "core"
local config = require "core.config"
local common = require "core.common"
local style = require "core.style"
local Widget = require "widget"
local AudioView = require "core.audioview"
local widgets = require "plugins.tui.widgets"

---Terminal presentation of the audio player's custom graphical controls.
local audio_view = {}
local transport_icons = {"", "", "", "", "", "", ""}

---Paint a transport control in its own cell row, using recognizable text symbols.
---@param button widget.button
---@return boolean drawn
local function draw_button(button)
  button.background_color = (button.enabled or button.hover_text or button.toggle_hovered)
    and style.selection or style.background
  if not Widget.draw(button) then return false end
  local label = button.transport_shape == "pause" and "||" or button.terminal_label
  if config.plugins.tui.nerdicons then
    label = (button.transport_shape == "pause" and "" or button.terminal_icon) .. " "
  end
  local columns = config.plugins.tui.nerdicons and 2 or #label
  local x = math.floor(button.position.x / 8 + .5) * 8
  local y = math.floor(button.position.y / 16 + .5) * 16
  core.push_clip_rect(x, y, button.size.x, 16)
  renderer.draw_text(style.font, label, x + math.max(0, math.floor((button.size.x / 8 - columns) / 2)) * 8,
    y, button.enabled and style.accent or style.text)
  core.pop_clip_rect()
  return true
end

---Place a control in whole terminal rows, preserving its existing callbacks.
---@param child widget
---@param x number
---@param y number
---@param width number
local function place(child, x, y, width)
  child:set_position(x, y)
  child:set_size(math.max(8, width), 16)
end

---Install adaptations once at terminal startup; the graphical player is untouched.
function audio_view.install()
  local new = AudioView.new
  ---Replace instance-specific polygon controls after the player creates them.
  function AudioView:new()
    new(self)
    for i, label in ipairs({"|<", ">", "[]", ">|", "R", "S", "V"}) do
      local button = self.controls[i]
      button.terminal_label, button.draw = label, draw_button
      button.terminal_icon = transport_icons[i]
      button.border.width = 0
    end
    for _, slider in ipairs({self.seek, self.volume_slider}) do
      widgets.adapt_slider(slider)
    end
  end

  ---Lay out controls on complete rows, wrapping transport and volume when narrow.
  function AudioView:update()
    if not AudioView.super.update(self) then return end
    if self.filter_due and system.get_time() >= self.filter_due then
      self.filter_due = nil
      self:filter_tracks()
    end
    self.play_button.transport_shape = self.state == "playing" and "pause" or nil
    self.seek.enabled = self.voice ~= nil and self.duration ~= nil and self.duration > 0
    if not self.seek.dragging then
      self.seek.value = self.seek.enabled
        and common.clamp(self.position_seconds / self.duration, 0, 1) or 0
    end
    local width = math.max(8, math.floor(self.size.x / 8) * 8 - 16)
    local layout_changed = self.terminal_width ~= width
      or self.terminal_height ~= self.size.y
      or self.terminal_visualization ~= self.visualization
    if not layout_changed then
      if self.list_row_count ~= #self.list.rows then
        self.list_row_count = #self.list.rows
        self.list.visible_rendered = false
        self.list:set_visible_rows()
      end
      return
    end
    self.terminal_width, self.terminal_height = width, self.size.y
    self.terminal_visualization = self.visualization
    place(self.folder, 8, 0, width)
    self.title_y, self.graph_y = 32, 48
    self.graph_h = self.visualization and 64 or 0
    local y = self.graph_y + self.graph_h
    place(self.seek, 8, y, width)
    self.time_y = y + 16
    y = y + 32
    local x = 8
    for _, button in ipairs(self.controls) do
      if x + 24 > width + 8 then x, y = 8, y + 16 end
      place(button, x, y, 24)
      x = x + 32
    end
    if width + 8 - x < 64 then x, y = 8, y + 16 end
    place(self.volume_slider, x, y, width + 8 - x)
    y = y + 32
    place(self.filter, 8, y, width)
    y = y + 32
    self.list:set_position(8, y)
    self.list:set_size(width, math.max(0, math.floor((self.size.y - y - 32) / 16) * 16))
    local content = math.max(0, self.list.size.x - 32)
    local format = math.min(content, style.font:get_width("Format"))
    self.list.columns[1].width = (content - format) * .65
    self.list.columns[2].width = (content - format) * .35
    self.list.columns[3].width = format
    self.list:recalc_all_rows()
    self.list_row_count = #self.list.rows
    self.list.visible_rendered = false
    self.list:set_visible_rows()
  end
end

return audio_view
