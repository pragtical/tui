local text = require "plugins.tui.text"

---@class plugins.tui.grid
---@field columns integer
---@field rows integer
---@field cells table[]
---@field previous table[]
---@field layer integer Current drawing layer
---@field last_layer integer Last popup layer assigned in this frame
---@field frame integer Frame generation for retained popup registrations
---@field layer_groups table<integer,integer> Related popup layers which can share border strokes
---@field clip_left number Exact clip boundary before cell rounding
---@field clip_top number Exact clip boundary before cell rounding
---@field clip_right number Exact clip boundary before cell rounding
---@field clip_bottom number Exact clip boundary before cell rounding
local Grid = {}
Grid.__index = Grid
local bit = bit
local box_chars = {
  [0] = "─", "│", "─", "└", "│", "│", "┌", "├",
  "─", "┘", "─", "┴", "┐", "┤", "┬", "┼"
}

---Pack RGB channels into a number for inexpensive comparison.
---@param color renderer.color
---@return integer
local function rgb(color)
  return color[1] * 65536 + color[2] * 256 + color[3]
end

---Blend a drawing color over an existing cell color.
---@param base integer
---@param color renderer.color
---@return integer
local function blend(base, color)
  local a = (color[4] or 255) / 255
  if a >= 1 then return rgb(color) end
  local r, g, b = math.floor(base / 65536), math.floor(base / 256) % 256, base % 256
  return math.floor(r + (color[1] - r) * a + .5) * 65536
    + math.floor(g + (color[2] - g) * a + .5) * 256
    + math.floor(b + (color[3] - b) * a + .5)
end

---Create a terminal screen. Coordinates passed to drawing methods are cell units.
---@param columns integer
---@param rows integer
---@return plugins.tui.grid
function Grid.new(columns, rows)
  local self = setmetatable({}, Grid)
  self:resize(columns, rows)
  return self
end

---Resize and invalidate both retained buffers.
---@param columns integer
---@param rows integer
function Grid:resize(columns, rows)
  self.columns, self.rows = math.max(1, columns), math.max(1, rows)
  self.cells, self.previous = {}, {}
  self:clear({0, 0, 0})
end

---Begin a new frame without allocating new cell records for existing positions.
---@param color renderer.color
function Grid:clear(color)
  local bg = rgb(color)
  self.layer, self.last_layer = 0, 0
  self.frame = (self.frame or 0) + 1
  self.layer_groups = self.layer_groups or {[0] = 0}
  for i = 1, self.columns * self.rows do
    local c = self.cells[i] or {}
    c[1], c[2], c[3], c[4], c[5] = " ", 0xffffff, bg, 1, ""
    c[6], c[7] = false, false
    c[8], c[9], c[10], c[11], c[13] = nil, nil, nil, nil, nil
    c[12] = 0
    self.cells[i] = c
  end
  self:set_clip(0, 0, self.columns, self.rows)
end

---Start a distinct popup layer without clearing the screen underneath it.
---Cell 12 records which layer painted a glyph or stroke for overlap decisions.
---Cell 13 retains a vertical stroke's far edge to protect shared frame bounds.
---@param owner? integer Owner's layer, allowing a companion to share its frame
function Grid:begin_layer(owner)
  self.last_layer = self.last_layer + 1
  self.layer = self.last_layer
  self.layer_groups[self.layer] = owner and self.layer_groups[owner] or self.layer
end

---Clip against the screen using draw-coordinate rounding, retaining one cell
---for a nonempty subcell viewport such as a single-line input.
---@param x number
---@param y number
---@param width number
---@param height number
function Grid:set_clip(x, y, width, height)
  self.clip_left, self.clip_top = x, y
  self.clip_right, self.clip_bottom = x + width, y + height
  self.left, self.top = math.max(0, math.floor(x + .5)), math.max(0, math.floor(y + .5))
  self.right = math.min(self.columns, math.floor(x + width + .5))
  self.bottom = math.min(self.rows, math.floor(y + height + .5))
  if width > 0 and x < self.columns and x + width > 0 then
    self.right = math.min(self.columns, math.max(self.left + 1, self.right))
  end
  if height > 0 and y < self.rows and y + height > 0 then
    self.bottom = math.min(self.rows, math.max(self.top + 1, self.bottom))
  end
end

---Return a cell inside the clip rectangle, using zero-based coordinates.
---@param x integer
---@param y integer
---@return table?
function Grid:cell(x, y)
  if x >= self.left and x < self.right and y >= self.top and y < self.bottom then
    return self.cells[y * self.columns + x + 1]
  end
end

---Remove both halves when overwriting a wide character.
---@param x integer
---@param y integer
function Grid:erase(x, y)
  local c = self.cells[y * self.columns + x + 1]
  if not c then return end
  local other = c[4] == 0 and x > 0 and self.cells[y * self.columns + x]
    or c[4] == 2 and x + 1 < self.columns and self.cells[y * self.columns + x + 2]
  if other then
    other[1], other[4], other[5] = " ", 1, ""
    other[8], other[9], other[10], other[11], other[13] = nil, nil, nil, nil, nil
  end
  c[1], c[4], c[5] = " ", 1, ""
  c[8], c[9], c[10], c[11], c[13] = nil, nil, nil, nil, nil
end

---Draw a thin axis-aligned stroke in cell units. Retain its precise position
---so an inset background does not erase a border sharing the same cell.
---@param x number
---@param y number
---@param width number
---@param height number
---@param color renderer.color
---@param horizontal boolean
function Grid:line(x, y, width, height, color, horizontal)
  local x1 = math.max(self.left, math.floor(x))
  local y1 = math.max(self.top, math.floor(y))
  local x2 = math.min(self.right, horizontal and math.ceil(x + width) or math.floor(x) + 1)
  local y2 = math.min(self.bottom, horizontal and math.floor(y) + 1 or math.ceil(y + height))
  if horizontal then
    for col = x1, x2 - 1 do
      local c = self:cell(col, y1)
      if c and c[12] == self.layer and not c[8] and c[1] ~= " " then return end
    end
  end
  for row = y1, y2 - 1 do
    for col = x1, x2 - 1 do
      local c = self:cell(col, row)
      if c and (c[12] ~= self.layer or c[8] or c[1] == " ") then
        if c[12] ~= self.layer and (not c[8]
          or self.layer_groups[c[12]] ~= self.layer_groups[self.layer]) then
          self:erase(col, row)
        end
        c[8] = bit.bor(c[8] or 0, horizontal and 1 or 2)
        if horizontal then c[10] = y else c[9], c[13] = x, x + width end
        -- A separator can cross a frame side in the same terminal cell.
        -- Keep the vertical stroke's color when text later removes the separator.
        if not horizontal or not c[9] then c[2] = blend(c[3], color) end
        c[1], c[6] = horizontal and "─" or "│", true
        c[12] = self.layer
      end
    end
  end
end

---Join surviving strokes into corners and junctions, without connecting
---parallel lines in adjacent rows or columns.
---@param x integer
---@param y integer
---@param cell table
---@return string
function Grid:line_character(x, y, cell)
  local i, axes = y * self.columns + x + 1, cell[8]
  local function connects(index, axis)
    local other = self.cells[index]
    return other and other[8]
      and self.layer_groups[other[12]] == self.layer_groups[cell[12]]
      and bit.band(bit.bor(axes, other[8]), axis) ~= 0
  end
  local mask = (y > 0 and connects(i - self.columns, 2) and 1 or 0)
    + (x + 1 < self.columns and connects(i + 1, 1) and 2 or 0)
    + (y + 1 < self.rows and connects(i + self.columns, 2) and 4 or 0)
    + (x > 0 and connects(i - 1, 1) and 8 or 0)
  if mask == 0 then return axes == 2 and "│" or "─" end
  return box_chars[mask]
end

---Remove a horizontal stroke sharing a text row, keeping its vertical sides.
---@param x integer
---@param y integer
function Grid:clear_text_line(x, y)
  local c = self:cell(x, y)
  local axis = c and c[10]
  if not axis then return end
  for direction = -1, 1, 2 do
    local col = direction == -1 and x or x + 1
    -- The text clip may cover only one column of a multi-column row. Remove
    -- the connected decorative stroke, including the gaps between columns.
    while col >= 0 and col < self.columns do
      local cell = self.cells[y * self.columns + col + 1]
      if cell[10] ~= axis or cell[12] ~= self.layer then break end
      cell[10] = nil
      cell[8] = cell[9] and 2 or nil
      cell[1] = cell[9] and "│" or " "
      col = col + direction
    end
  end
end

---Fill a rectangle, using half blocks for partial rows. Translucent overlays
---preserve and tint underlying text; cell 11 marks composed half-block colors.
---@param x number
---@param y number
---@param width number
---@param height number
---@param color renderer.color
---@param whole_rows? boolean Fill complete text rows for UI backgrounds
function Grid:rect(x, y, width, height, color, whole_rows)
  if width <= 0 or height <= 0 or color[4] == 0 then return end
  local left, top = math.max(x, self.clip_left), math.max(y, self.clip_top)
  local right, bottom = math.min(x + width, self.clip_right), math.min(y + height, self.clip_bottom)
  if left >= right or top >= bottom then return end
  local x1 = math.max(self.left, math.floor(x + .5))
  local x2 = math.min(self.right, math.floor(x + width + .5))
  local units = whole_rows and 1 or 2
  local y1 = math.max(self.top * 2, math.floor(top * units + .5) * (2 / units))
  local end_y = math.floor(bottom * units + .5) * (2 / units)
  if whole_rows and y + height > self.top then end_y = math.max(y1 + 2, end_y) end
  local y2 = math.min(self.bottom * 2, end_y)
  if x1 >= x2 or y1 >= y2 then return end
  local opaque = (color[4] or 255) == 255
  for row = math.floor(y1 / 2), math.ceil(y2 / 2) - 1 do
    local upper, lower = row * 2 >= y1, row * 2 + 1 < y2
    for col = x1, x2 - 1 do
      local c = self:cell(col, row)
      -- A background edge can share a row with text from the preceding
      -- control. Keep the glyph; terminals cannot give it two backgrounds.
      local preserve = opaque and c[12] == self.layer
        and (not upper or not lower) and not c[8] and not c[11]
        and c[1] ~= " "
      local border = false
      if c[8] and self.layer_groups[c[12]] == self.layer_groups[self.layer] then
        -- Both opaque backgrounds and translucent hovers can round onto a
        -- border outside their clip. Keep that border's glyph and colors.
        local vertical = c[9] and (c[9] <= left or c[13] >= right)
        local horizontal = c[10] and (c[10] < top or c[10] >= bottom)
        if vertical or horizontal then
          c[8] = (horizontal and 1 or 0) + (vertical and 2 or 0)
          if not vertical then c[9], c[13] = nil, nil end
          if not horizontal then c[10] = nil end
          preserve, border = true, vertical or c[10]
            and (c[10] < self.clip_top or c[10] >= self.clip_bottom)
        end
      end
      if not preserve and (not upper or not lower or c[11])
        and (opaque or c[11] or c[1] == " ") then
        local top, bottom = c[11] and c[2] or c[3], c[3]
        if upper then top = blend(top, color) end
        if lower then bottom = blend(bottom, color) end
        self:erase(col, row)
        c[1], c[2], c[3] = top == bottom and " " or "▀", top, bottom
        c[11] = top ~= bottom or nil
      else
        if opaque and not preserve then self:erase(col, row) end
        if not preserve then c[2] = blend(c[2], color) end
        -- Excluded frame cells retain their whole background. Interior dividers
        -- can share a label row and must retain its fill.
        if not border then c[3] = blend(c[3], color) end
      end
      c[6], c[7] = true, true
      c[12] = self.layer
    end
  end
end

---Get a text cell without overwriting a side or bottom frame outside the clip.
---Whole glyphs, including both cells of wide characters, must respect that edge.
---@param grid plugins.tui.grid
---@param x integer
---@param y integer
---@return table?
local function text_cell(grid, x, y)
  local cell = grid:cell(x, y)
  if cell and grid.layer_groups[cell[12]] == grid.layer_groups[grid.layer] then
    local side = cell[9] and (cell[9] < grid.clip_left or cell[9] >= grid.clip_right)
    -- Top separators may share the first label row; a clipped final result
    -- must leave the panel's bottom frame intact.
    local bottom = cell[10] and cell[10] >= grid.clip_bottom
    if side or bottom then return end
  end
  return cell
end

---Draw text with transparent plain spaces, returning its end column even when clipped.
---@param value string
---@param x number
---@param y number
---@param color renderer.color
---@param tabs? integer
---@param offset? number
---@param attributes? string SGR attributes owned by the font adapter
---@return number
function Grid:draw_text(value, x, y, color, tabs, offset, attributes)
  local start, advance = x, 0
  local decorated_space = attributes and (attributes:find(";4", 1, true) or attributes:find(";9", 1, true))
  x, y = math.floor(x + .5), math.floor(y + .5)
  tabs = math.max(1, tabs or 4)
  text.each(value, function(ch, width)
    if width < 0 then
      advance = advance + tabs - ((offset or 0) + advance) % tabs
    elseif width > 0 then
      local col = x + math.floor(advance + .5)
      -- Spaces have no ink in the graphical renderer. Advancing without painting
      -- retains underlays such as whitespace markers and cached transparent text.
      local c = (ch ~= " " or decorated_space) and text_cell(self, col, y)
      if c and (width == 1 or text_cell(self, col + 1, y)) then
        if c[10] and c[12] == self.layer then self:clear_text_line(col, y) end
        self:erase(col, y)
        if width == 2 then self:erase(col + 1, y) end
        c[1], c[2], c[4], c[5] = ch, blend(c[3], color), width, attributes or ""
        c[6] = true
        c[12] = self.layer
        if width == 2 then
          local next_cell = self:cell(col + 1, y)
          next_cell[1], next_cell[2], next_cell[4], next_cell[5] = "", c[2], 0, c[5]
          next_cell[6] = true
          next_cell[12] = self.layer
        end
      end
      advance = advance + width
    end
  end)
  return start + advance
end

---Invert the cell under a caret without covering its character.
---@param x number
---@param y number
function Grid:caret(x, y)
  local c = self:cell(math.floor(x + .5), math.floor(y + .5))
  if c then
    c[2], c[3] = c[3], c[2]
    if c[2] == c[3] then c[3] = 0xffffff - c[3] end
  end
end

---Encode one color, using the xterm palette when RGB output is unavailable.
---@param color integer
---@param background boolean
---@param truecolor boolean
---@return string
local function sgr_color(color, background, truecolor)
  local r, g, b = math.floor(color / 65536), math.floor(color / 256) % 256, color % 256
  local prefix = background and "48;" or "38;"
  if truecolor then return prefix .. "2;" .. r .. ";" .. g .. ";" .. b end
  local function cube(v) return v < 48 and 0 or v < 115 and 1 or math.min(5, math.floor((v - 35) / 40)) end
  local index = 16 + 36 * cube(r) + 6 * cube(g) + cube(b)
  if math.max(r, g, b) - math.min(r, g, b) < 10 then
    index = r < 8 and 16 or r > 248 and 231 or 232 + math.floor((r - 8) / 10)
  end
  return prefix .. "5;" .. index
end

---Serialize changed cell runs and retain the frame. An unchanged frame is empty.
---@param truecolor? boolean
---@return string
function Grid:present(truecolor)
  local out, last_style = {}, nil
  for row = 0, self.rows - 1 do
    local contiguous = false
    for col = 0, self.columns - 1 do
      local i = row * self.columns + col + 1
      local c, old = self.cells[i], self.previous[i]
      if c[8] then c[1] = self:line_character(col, row, c) end
      local changed = not old
      if old then
        for k = 1, 5 do if old[k] ~= c[k] then changed = true; break end end
      end
      if changed and c[4] ~= 0 then
        if not contiguous then out[#out + 1] = string.format("\27[%d;%dH", row + 1, col + 1) end
        local style = c[2] .. ":" .. c[3] .. ":" .. c[5]
        if last_style ~= style then
          out[#out + 1] = "\27[0;" .. sgr_color(c[2], false, truecolor)
            .. ";" .. sgr_color(c[3], true, truecolor) .. c[5] .. "m"
          last_style = style
        end
        out[#out + 1] = c[1]
        contiguous = true
      elseif c[4] ~= 0 then
        contiguous = false
      end
      old = old or {}
      for k = 1, 5 do old[k] = c[k] end
      self.previous[i] = old
    end
  end
  return table.concat(out)
end

return Grid
