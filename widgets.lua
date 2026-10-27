local core = require "core"
local common = require "core.common"
local Widget = require "widget"
local NoteBook = require "widget.notebook"
local Button = require "widget.button"
local TextBox = require "widget.textbox"
local Toggle = require "widget.toggle"
local CheckBox = require "widget.checkbox"
local ListBox = require "widget.listbox"
local WidgetList = require "widget.widgetlist"
local Container = require "widget.container"
local colorpicker = require "plugins.tui.colorpicker"
local style = require "core.style"

---Terminal presentation for controls whose pixel borders cannot fit cell rows.
local widgets = {}

---Keep embedded input text, caret and clipping on the same terminal row.
---@param self widget.textbox.TextView
---@return number height
local function line_height(self)
  return self:get_font():get_height()
end

---Render styled spans for labels and list columns, accepting terminal font tables.
---@param widget widget
---@param spans widget.styledtext|widget.listbox.row
---@param x number
---@param y number
---@param only_calc? boolean
---@param first? integer
---@param last? integer
---@param row? integer List row passed to custom column renderers
---@return number width
---@return number height
local function draw_spans(widget, spans, x, y, only_calc, first, last, row)
  local font, color = widget:get_font(), widget.foreground_color or style.text
  local width, height, nx, new_line = 0, font:get_height(), x, false
  local newline = row and ListBox.NEWLINE or Widget.NEWLINE
  for i = first or 1, last or #spans do
    local element = spans[i]
    local kind = type(element)
    if kind == "userdata" or kind == "table" and (
      getmetatable(element) == renderer.font or (not element.type or element.type == "font")
      and (element.container or type(element[1]) == "userdata")) then
      font = kind == "table" and element.container and element.container[element.name] or element
    elseif kind == "table" and (not element.type or element.type == "color") then
      color = element.container and element.container[element.name] or element
    elseif element == newline then
      y, nx, new_line = y + font:get_height(), x, true
    elseif kind == "function" and row then
      local w, h = element(widget, row, nx, y, font, color, only_calc)
      nx, width, height = nx + width, width + w, math.max(height, h)
    elseif kind == "string" then
      local rx, ry, w, h = widget:draw_text_multiline(font, element, nx, y, color, only_calc)
      nx, y = rx, ry
      if new_line then
        width, height, new_line = math.max(width, w), height + h, false
      else
        width, height = width + w, math.max(height, h)
      end
    end
  end
  return width, height
end

---Align compact controls to terminal rows; retain full boxes for taller widgets.
---Only called when entering terminal mode, leaving normal GUI widgets unchanged.
---@return fun() refresh Refresh roots once after saved settings have been applied
function widgets.install()
  colorpicker.install()
  local roots = setmetatable({}, {__mode = "k"})
  local new_widget = Widget.new
  ---Remember widget roots whose cached sizes may precede saved icon settings.
  ---@param ... any Widget constructor arguments
  function Widget:new(...)
    new_widget(self, ...)
    if not self.parent then roots[self] = true end
  end
  local update_container = Container.update_size_position
  ---Reflow a container when its children are explicitly remeasured.
  function Container:update_size_position()
    update_container(self)
    self.old_size.x, self.old_size.y = -1, -1
  end
  local set_size = Widget.set_size
  ---Reserve whole content rows so node dividers and floating frames cannot cover controls.
  ---@param width? number
  ---@param height? number
  function Widget:set_size(width, height)
    set_size(self, width, height)
    if not self.parent then
      local size = self:get_size()
      if width and width > 0 then size.x = math.ceil(size.x / 8) * 8 end
      if height and height > 0 then size.y = math.ceil(size.y / 16) * 16 end
    end
  end
  local set_position = Widget.set_position
  ---Place floating widget contents on whole cells before positioning descendants.
  ---@param x? number
  ---@param y? number
  function Widget:set_position(x, y)
    if not self.parent and self.defer_draw then
      local border = self.border.width
      if x then x = math.floor((x + border) / 8 + .5) * 8 - border end
      if y then y = math.floor((y + border) / 16 + .5) * 16 - border end
    end
    return set_position(self, x, y)
  end
  ---Render labels with the same font identity used by the terminal renderer.
  ---@param text widget.styledtext
  ---@param x number
  ---@param y number
  ---@param only_calc? boolean
  ---@param first? integer
  ---@param last? integer
  ---@return number width
  ---@return number height
  function Widget:draw_styled_text(text, x, y, only_calc, first, last)
    return draw_spans(self, text, x, y, only_calc, first, last)
  end
  ---Use the shared styled renderer while retaining custom list column callbacks.
  ---@param row integer
  ---@param text widget.listbox.row
  ---@param first integer
  ---@param last integer
  ---@param x number
  ---@param y number
  ---@param only_calc? boolean
  ---@return number width
  ---@return number height
  function ListBox:draw_row_range(row, text, first, last, x, y, only_calc)
    return draw_spans(self, text, x, y, only_calc, first, last, row)
  end

  local draw_row = ListBox.draw_row
  ---Align row backgrounds, custom columns and labels without changing cached layout.
  ---@param row integer
  ---@param x number
  ---@param y number
  ---@param only_calc? boolean
  ---@return number width
  ---@return number height
  function ListBox:draw_row(row, x, y, only_calc)
    if not only_calc then
      local padding = style.padding.y / 2
      y = math.floor((y + padding) / 16 + .5) * 16 - padding
    end
    return draw_row(self, row, x, y, only_calc)
  end

  local visible_rows = ListBox.set_visible_rows
  ---Extend from the first visible row when a resized viewport exposes more rows.
  function ListBox:set_visible_rows()
    if self.terminal_viewport_height ~= self.size.y then
      self.visible_rendered = false
      self.terminal_viewport_height = self.size.y
    end
    return visible_rows(self)
  end

  local row_at_position = ListBox.get_row_at_position
  ---Resolve clicks against the same terminal rows used for drawing.
  ---@param x number
  ---@param y number
  ---@return integer? row
  function ListBox:get_row_at_position(x, y)
    if #self.visible_rows == 0 then self:set_visible_rows() end
    local first = self.rows[self.visible_rows[1]]
    local _, origin = self:get_content_offset()
    origin = origin + self.border.width + (first and first.y or 0) + style.padding.y / 2
    return row_at_position(self, x, y + origin - math.floor(origin / 16 + .5) * 16)
  end

  local mouse_moved = WidgetList.on_mouse_moved
  ---Highlight a widget-list row while the pointer is over one of its controls.
  ---@param x number
  ---@param y number
  ---@param dx number
  ---@param dy number
  ---@return boolean? handled
  function WidgetList:on_mouse_moved(x, y, dx, dy)
    local handled = mouse_moved(self, x, y, dx, dy)
    local row = self.hovered_child
    if handled and row then row.hovered = true end
    return handled
  end

  local update_widget_list = WidgetList.update
  ---Retarget an existing hover when scrolling or layout moves rows under the pointer.
  ---@return boolean? updated
  function WidgetList:update()
    local layout = self.layout_dirty or self.previous_width ~= self.size.x
      or self.previous_height ~= self.size.y
    local updated = update_widget_list(self)
    if updated then
      local x, y = self:get_content_offset()
      if self.hovered_child and (layout or self.terminal_hover_x ~= x or self.terminal_hover_y ~= y) then
        self:on_mouse_moved(self.mouse.x, self.mouse.y, 0, 0)
      end
      self.terminal_hover_x, self.terminal_hover_y = x, y
    end
    return updated
  end

  local add_pane = NoteBook.add_pane
  ---Use a full-cell selected background instead of a subcell tab underline.
  ---@param tab widget.button
  ---@return boolean drawn
  local function draw_tab(tab)
    local hover = tab.hover_back
    if tab.parent.active_pane.tab == tab then tab.hover_back = style.selection end
    local drawn = Button.draw(tab)
    tab.hover_back = hover
    return drawn
  end
  ---Attach the shared tab renderer once when constructing a pane.
  ---@param name string
  ---@param label string
  ---@return widget container
  function NoteBook:add_pane(name, label)
    local container = add_pane(self, name, label)
    self.panes[#self.panes].tab.draw = draw_tab
    return container
  end
  ---Draw tab backgrounds and contents without a second underline row.
  ---@return boolean drawn
  function NoteBook:draw()
    return Widget.draw(self)
  end

  local mouse_on_top = Widget.mouse_on_top
  ---Keep one-row controls clickable at the center of their rendered cells.
  ---@param x number
  ---@param y number
  ---@return boolean inside
  function Widget:mouse_on_top(x, y)
    if not self.visible then return false end
    if self:get_height() <= 16 then
      if #self.childs > 0 and self.on_click == Widget.on_click then
        for _, child in ipairs(self.childs) do
          if child:mouse_on_top(x, y) then return true end
        end
        return false
      end
      local row = math.floor(self.position.y / 16 + .5) * 16
      local left = math.floor((self.position.x - self.border.width) / 8 + .5) * 8
      local right = math.floor((self.position.x - self.border.width + self:get_width()) / 8 + .5) * 8
      return x >= left and x < right and y >= row and y < row + 16
    end
    return mouse_on_top(self, x, y)
  end
  local new = TextBox.new
  ---Construct a single-line input without the graphical 1.2 line-height factor.
  ---@param ... any TextBox constructor arguments
  function TextBox:new(...)
    new(self, ...)
    self.textview.get_line_height = line_height
  end
  local draw_border = Widget.draw_border
  ---Draw compact borders on the label row without changing layout or hit testing.
  ---@param x? number
  ---@param y? number
  ---@param w? number
  ---@param h? number
  function Widget:draw_border(x, y, w, h)
    local border = self.border.width
    if border <= 0 then return end
    x, y = x or self.position.x, y or self.position.y
    w, h = w or self.size.x, h or self.size.y
    if not self.parent and self.defer_draw and self.render_background then
      -- The frame occupies complete cells outside the native inset background.
      -- Clear those cells too, so an underlying scrollbar cannot tint the frame.
      local left, top = math.floor((x - border) / 8) * 8, math.floor((y - border) / 16) * 16
      local right = math.ceil((x + w + border) / 8) * 8
      local bottom = math.ceil((y + h + border) / 16) * 16
      renderer.draw_rect(left, top, right - left, bottom - top, self.background_color or style.background2)
    end
    if h + border * 2 >= 48 then return draw_border(self, x, y, w, h) end
    local row = math.floor((y + (h + border * 2 - 16) / 2) / 16 + .5) * 16
    local color = self.border.color or style.text
    renderer.draw_rect(x - border, row, border, 16, color)
    renderer.draw_rect(x + w, row, border, 16, color)
  end

  ---Measure switches on complete text rows instead of retaining GUI thumb padding.
  function Toggle:update_size_position()
    Toggle.super.update_size_position(self)
    self.padding = 0
    self:set_size(nil, self.caption_label:get_height())
  end

  ---Draw a compact switch whose markers stay distinct even in adjacent rows.
  ---@return boolean drawn Whether the widget was visible and drawn
  function Toggle:draw()
    if not Toggle.super.draw(self) then return false end
    local x = math.floor((self.position.x + self.toggle_x) / 8 + .5) * 8
    local y = math.floor(self.caption_label.position.y / 16 + .5) * 16
    renderer.draw_text(style.font, self.enabled and "[  ●]" or "[●  ]", x, y, self.toggle_bg)
    return true
  end

  ---Reserve three columns for a checkbox marker when laying out its label.
  ---@return number x
  ---@return number y
  ---@return number width
  ---@return number height
  function CheckBox:get_box_rect()
    return self.position.x, self.position.y, 24, 16
  end

  ---Render the checked state on the label row, independent of pixel fill rounding.
  ---@return boolean drawn Whether the widget was visible and drawn
  function CheckBox:draw()
    if not self:is_visible() then return false end
    local x, y, width = self:get_box_rect()
    local font = self:get_font()
    local marker = self.checked and "[✓]" or self.mixed and "[-]" or "[ ]"
    renderer.draw_text(font, marker, x, y,
      (self.checked or self.mixed) and style.caret
        or self.hover_text or self.border.color or style.text)
    for i, line in ipairs(self.label_lines or {self.label}) do
      renderer.draw_text(font, line, x + width + style.padding.x / 2,
        y + (i - 1) * font:get_height(),
        self.hover_text or self.foreground_color or style.text)
    end
    return true
  end
  return function()
    for root in pairs(roots) do root:update_size_position() end
    roots = setmetatable({}, {__mode = "k"})
  end
end

---Get the terminal cells used by a slider, shared by drawing and pointer input.
---@param slider widget
---@return number x
---@return number y
---@return integer columns
local function slider_bounds(slider)
  return math.floor(slider.position.x / 8 + .5) * 8,
    math.floor(slider.position.y / 16 + .5) * 16,
    math.max(1, math.floor(slider.size.x / 8))
end

---Draw a single-row track and handle instead of subcell rectangles.
---@param slider widget
local function draw_slider(slider)
  if not Widget.draw(slider) then return end
  local x, y, columns = slider_bounds(slider)
  local handle = math.floor(common.clamp(slider.value, 0, 1) * (columns - 1) + .5)
  renderer.draw_text(style.font, string.rep("─", columns), x, y, style.dim)
  if slider.enabled then
    if handle > 0 then renderer.draw_text(style.font, string.rep("━", handle), x, y, style.caret) end
    renderer.draw_text(style.font, "●", x + handle * 8, y, style.text)
  end
end

---Match slider endpoints to terminal mouse-cell centers.
---@param slider widget
---@param x number
local function set_slider(slider, x)
  local left, _, columns = slider_bounds(slider)
  slider.value = common.clamp((x - left - 4) / math.max(8, (columns - 1) * 8), 0, 1)
  slider:on_change(slider.value)
  core.redraw = true
end

---Adapt a normalized slider while retaining its existing mouse capture callbacks.
---The control must expose value (0..1), enabled, and on_change(value).
---@param slider widget
function widgets.adapt_slider(slider)
  slider.draw, slider.set_from_mouse = draw_slider, set_slider
end

return widgets
