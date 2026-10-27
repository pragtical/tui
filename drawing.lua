local Grid = require "plugins.tui.grid"
local fonts = require "plugins.tui.fonts"
local style = require "core.style"
local RootView = require "core.rootview"
local Chafa = require "plugins.tui.chafa"

---Adapters for the renderer and offscreen canvas APIs, in logical pixels.
local drawing = {}
local canvases = setmetatable({}, {__mode = "k"})
local native_canvas_size
local images
local image_message = "Image preview unsupported"

---Draw a whole-cell popup outline with thin strokes and no solid border fill.
---@param x number Cell-aligned left edge
---@param y number Cell-aligned top edge
---@param w number Width in logical pixels
---@param h number Height in logical pixels
---@param color renderer.color
function drawing.draw_frame(x, y, w, h, color)
  renderer.draw_rect(x, y, w, 1, color)
  renderer.draw_rect(x, y + h - 16, w, 1, color)
  renderer.draw_rect(x, y, 1, h, color)
  renderer.draw_rect(x + w - 8, y, 1, h, color)
end

---Recognize copied selection/hover colors while retaining their original opacity.
---@param color renderer.color
---@param reference renderer.color
---@return boolean
local function same_rgb(color, reference)
  return color[1] == reference[1] and color[2] == reference[2] and color[3] == reference[3]
end

---Draw thin borders as cell lines and larger rectangles as cell backgrounds.
---@param grid plugins.tui.grid
---@param x number
---@param y number
---@param w number
---@param h number
---@param color renderer.color
local function rect(grid, x, y, w, h, color)
  if not grid or w <= 0 or h <= 0 or color[4] == 0 then return end
  if h <= 2 and w >= 8 then
    grid:line(x / 8, y / 16, w / 8, h / 16, color, true)
  elseif w <= 2 and h >= 16 then
    grid:line(x / 8, y / 16, w / 8, h / 16, color, false)
  else
    -- UI backgrounds and selections occupy complete text rows, including
    -- popup edges which must hide the text underneath. Keep precise bounds
    -- for inset-border preservation inside the compositor.
    local rows = color == style.selection or color == style.line_highlight
      or color == style.background or color == style.background2 or color == style.background3
      or same_rgb(color, style.line_highlight) or same_rgb(color, style.selection)
    grid:rect(x / 8, y / 16, w / 8, h / 16, color, rows)
  end
end

---Draw text with the same metrics used by the font adapter.
---@param grid plugins.tui.grid
---@param font renderer.font
---@param value string
---@param x number
---@param y number
---@param color renderer.color
---@param tab? renderer.tab_data
---@return number
local function draw_text(grid, font, value, x, y, color, tab)
  local d = fonts.describe(font)
  local attributes = (d.options.bold and ";1" or "") .. (d.options.italic and ";3" or "")
    .. (d.options.underline and ";4" or "") .. (d.options.strikethrough and ";9" or "")
  return grid:draw_text(fonts.translate(font, value), x / 8, y / 16, color,
    d.tabs, tab and (tab.tab_offset or 0) / 8 or 0, attributes) * 8
end

---Approximate a polygon's outline at cell resolution, including curve endpoints.
---@param grid plugins.tui.grid
---@param points table[]
---@param color renderer.color
local function poly(grid, points, color)
  local px, py
  for _, point in ipairs(points) do
    local x, y = point[#point - 1] / 8, point[#point] / 16
    if px then
      local steps = math.max(1, math.ceil(math.max(math.abs(x - px), math.abs(y - py))))
      for i = 0, steps do
        grid:draw_text("•", px + (x - px) * i / steps, py + (y - py) * i / steps, color)
      end
    end
    px, py = x, y
  end
end

---Resolve canvases created by plugins before terminal activation.
---@param c canvas
---@return table
local function canvas_data(c)
  if not canvases[c] then
    local w, h = native_canvas_size(c)
    canvases[c] = {width = w, height = h, image = true}
  end
  return canvases[c]
end

---Composite a cached image conversion using the normal clip and popup layers.
---@param grid plugins.tui.grid
---@param data table
---@param x number
---@param y number
local function image(grid, data, x, y)
  x, y = math.floor(x / 8 + .5), math.floor(y / 16 + .5)
  local columns, rows = math.ceil(data.width / 8), math.ceil(data.height / 16)
  if x >= grid.right or y >= grid.bottom
    or x + columns <= grid.left or y + rows <= grid.top then return end
  local preview, message
  if data.source then preview, message = images:get(data.source, data.width, data.height) end
  if not preview then
    local loading = message == "Loading image preview..."
    local label = loading and message or image_message
    x = math.max(grid.left, math.min(x, grid.right - math.max(#label, #(message or ""))))
    grid:draw_text(label, x, y, style.dim)
    if message and not loading then grid:draw_text(message, x, y + 1, style.dim) end
    return
  end
  for row = math.max(y, grid.top), math.min(y + rows, grid.bottom) - 1 do
    for col = math.max(x, grid.left), math.min(x + columns, grid.right) - 1 do
      local source = preview:cell(math.floor((col - x) * preview.columns / columns),
        math.floor((row - y) * preview.rows / rows))
      if source[6] then
        grid:erase(col, row)
        local target = grid:cell(col, row)
        target[1], target[2] = source[1], source[2] or target[3]
        if source[7] then target[3], target[7] = source[3], true end
        target[6], target[12] = true, grid.layer
      end
    end
  end
end

---Composite a retained text canvas or a Chafa image preview.
---@param grid plugins.tui.grid
---@param c canvas
---@param x number
---@param y number
local function blit(grid, c, x, y)
  local d = canvas_data(c)
  if d.image then
    image(grid, d, x, y)
    return
  end
  for row = 0, d.grid.rows - 1 do
    for col = 0, d.grid.columns - 1 do
      local source = d.grid.cells[row * d.grid.columns + col + 1]
      local tx, ty = math.floor(x / 8 + col + .5), math.floor(y / 16 + row + .5)
      local target = grid:cell(tx, ty)
      if target and source[6] then
        if source[4] ~= 0 then
          grid:erase(tx, ty)
          local tail = source[4] == 2 and grid:cell(tx + 1, ty)
          if source[4] == 1 or tail then
            if tail then
              grid:erase(tx + 1, ty)
              tail[1], tail[2], tail[4], tail[5], tail[6] = "", source[2], 0, source[5], true
              tail[12] = grid.layer
            end
            target[1], target[2], target[4], target[5] = source[1], source[2], source[4], source[5]
            target[8] = source[8]
            target[9] = source[9] and source[9] + tx - col
            target[13] = source[13] and source[13] + tx - col
            target[10] = source[10] and source[10] + ty - row
            target[11] = source[11]
          end
        elseif col == 0 or not grid:cell(tx - 1, ty) then
          -- A clipped leading cell must not leave an orphaned wide continuation.
          grid:erase(tx, ty)
        end
        target[6] = true
        target[12] = grid.layer
        if source[7] then target[3], target[7] = source[3], true end
      end
    end
  end
end

---Install all drawing overrides. The caller supplies the current screen buffer.
---@param session table
function drawing.install(session)
  fonts.install()
  images = Chafa.new()
  session.images = images
  local add_floating_view = RootView.add_floating_view
  local wrapped = setmetatable({}, {__mode = "kv"})
  ---Give each shown popup its own composition layer, wrapping once on registration.
  ---@param view core.view
  function RootView:add_floating_view(view)
    if not wrapped[view] or wrapped[view].draw ~= view.draw then
      local draw = view.draw
      local entry = {}
      ---Keep clipping and decorative-stroke preservation local to this popup.
      ---@param popup core.view
      ---@param ... any Drawing arguments
      ---@return any drawn
      local function draw_popup(popup, ...)
        if not popup.floating_visible then return draw(popup, ...) end
        local grid = session.grid
        local previous = grid.layer
        local owner = wrapped[popup.floating_options.owner]
        grid:begin_layer(owner and owner.frame == grid.frame and owner.layer or nil)
        entry.frame, entry.layer = grid.frame, grid.layer
        local ok, result = pcall(draw, popup, ...)
        grid.layer = previous
        if not ok then error(result, 0) end
        return result
      end
      entry.draw = draw_popup
      wrapped[view], view.draw = entry, draw_popup
    end
    return add_floating_view(self, view)
  end
  -- Unlike renderer.font, canvas keeps instance methods in a separate metatable.
  -- Preserve its native size query before adapting existing and loaded canvases.
  local native_api = getmetatable(canvas.new(1, 1, {0, 0, 0, 0})).__index
  native_canvas_size = native_api.get_size
  local native_image, native_svg = canvas.load_image, canvas.load_svg_image
  local api = canvas
  ---Create an offscreen cell canvas using logical pixel dimensions.
  ---@param w number
  ---@param h number
  ---@param color? renderer.color
  ---@param transparent? boolean
  ---@return canvas
  function api.new(w, h, color, transparent)
    w, h = math.max(1, w), math.max(1, h)
    local c = setmetatable({}, {__index = api})
    local grid = Grid.new(math.ceil(w / 8), math.ceil(h / 16))
    canvases[c] = {width = w, height = h, grid = grid, transparent = transparent}
    if color and (color[4] or 255) > 0 then grid:rect(0, 0, grid.columns, grid.rows, color) end
    return c
  end
  ---Keep native image validation and dimensions, converting its file on demand.
  ---@param path string
  ---@return canvas?
  ---@return string?
  function api.load_image(path)
    local c, err = native_image(path)
    if c then canvas_data(c).source = {path = system.absolute_path(path)} end
    return c, err
  end
  ---@param path string
  ---@param w? number
  ---@param h? number
  ---@return canvas?
  ---@return string?
  function api.load_svg_image(path, w, h)
    local c, err = native_svg(path, w, h)
    if c then canvas_data(c).source = {path = system.absolute_path(path)} end
    return c, err
  end
  ---@return number width
  ---@return number height
  function api:get_size() local d = canvas_data(self); return d.width, d.height end
  ---@param color? renderer.color
  function api:clear(color)
    local d = canvas_data(self)
    d.image, d.source = nil, nil
    d.grid = d.grid or Grid.new(math.ceil(d.width / 8), math.ceil(d.height / 16))
    d.grid:clear(color or {0, 0, 0})
    if color then d.grid:rect(0, 0, d.grid.columns, d.grid.rows, color) end
  end
  ---@param x number
  ---@param y number
  ---@param w number
  ---@param h number
  function api:set_clip_rect(x, y, w, h)
    local d = canvas_data(self)
    if d.grid then d.grid:set_clip(x / 8, y / 16, w / 8, h / 16) end
  end
  ---@param x number
  ---@param y number
  ---@param w number
  ---@param h number
  ---@param color renderer.color
  function api:draw_rect(x, y, w, h, color) rect(canvas_data(self).grid, x, y, w, h, color) end
  ---@param font renderer.font
  ---@param value string
  ---@param x number
  ---@param y number
  ---@param color renderer.color
  ---@param tab? renderer.tab_data
  ---@return number
  function api:draw_text(font, value, x, y, color, tab)
    local d = canvas_data(self)
    if not d.grid then self:clear() end
    return draw_text(d.grid, font, value, x, y, color, tab)
  end
  ---@param source canvas
  ---@param x number
  ---@param y number
  function api:draw_canvas(source, x, y)
    local d = canvas_data(self)
    if not d.grid then self:clear() end
    blit(d.grid, source, x, y)
  end
  ---@param points table[]
  ---@param color renderer.color
  function api:draw_poly(points, color)
    local d = canvas_data(self)
    if not d.grid then self:clear() end
    poly(d.grid, points, color)
  end
  ---Copy cell content, or retain the source file for a scaled image preview.
  ---@param x? number
  ---@param y? number
  ---@param w? number
  ---@param h? number
  ---@param new_width? number
  ---@param new_height? number
  ---@return canvas
  function api:copy(x, y, w, h, new_width, new_height)
    local d = canvas_data(self)
    local source = d.source
    if (x or 0) ~= 0 or (y or 0) ~= 0
      or (w and w ~= d.width) or (h and h ~= d.height) then
      source = nil -- Cropped raster canvases no longer represent the whole file.
    end
    w, h = math.max(1, new_width or w or d.width), math.max(1, new_height or h or d.height)
    if d.image then
      local c = setmetatable({}, {__index = api})
      canvases[c] = {width = w, height = h, image = true, source = source}
      return c
    end
    local c = api.new(w, h)
    blit(canvases[c].grid, self, -(x or 0), -(y or 0))
    return c
  end
  ---@param w number
  ---@param h number
  ---@return canvas
  function api:scaled(w, h) return self:copy(0, 0, nil, nil, w, h) end
  ---Cell canvases are updated immediately.
  function api:render() end
  ---Raster writes replace a canvas with an image placeholder.
  function api:set_pixels()
    local d = canvas_data(self)
    d.image, d.source = true, nil
  end
  ---Raster capture is unavailable in terminal mode.
  ---@return nil
  ---@return string
  function api:get_pixels() return nil, "Pixel capture is unavailable in terminal mode" end
  ---@return nil
  ---@return string
  function api:save_image() return nil, "Image export is unavailable in terminal mode" end

  -- Native images and canvases created before activation share these methods.
  -- Keep __gc intact so their native resources are still released normally.
  for name in pairs(native_api) do
    if api[name] then native_api[name] = api[name] end
  end

  ---Start a frame in the current terminal palette.
  function renderer.begin_frame() session.grid:clear(require("core.style").background) end
  ---Write a changed frame only when the previous output has drained.
  function renderer.end_frame()
    local core = require "core"
    if #session.terminal.pending > 0 then core.redraw = true; return end
    session.terminal:write(session.grid:present(session.truecolor))
  end
  ---@return number width
  ---@return number height
  function renderer.get_size() return session.grid.columns * 8, session.grid.rows * 16 end
  ---@param x number
  ---@param y number
  ---@param w number
  ---@param h number
  function renderer.set_clip_rect(x, y, w, h) session.grid:set_clip(x / 8, y / 16, w / 8, h / 16) end
  ---@param x number
  ---@param y number
  ---@param w number
  ---@param h number
  ---@param color renderer.color
  function renderer.draw_rect(x, y, w, h, color) rect(session.grid, x, y, w, h, color) end
  ---@param font renderer.font
  ---@param value string
  ---@param x number
  ---@param y number
  ---@param color renderer.color
  ---@param tab? renderer.tab_data
  ---@return number
  function renderer.draw_text(font, value, x, y, color, tab)
    return draw_text(session.grid, font, value, x, y, color, tab)
  end
  ---@param c canvas
  ---@param x number
  ---@param y number
  function renderer.draw_canvas(c, x, y) blit(session.grid, c, x, y) end
  ---@param points table[]
  ---@param color renderer.color
  function renderer.draw_poly(points, color) poly(session.grid, points, color) end
  ---@param pixels string
  ---@param x number
  ---@param y number
  function renderer.draw_pixels(pixels, x, y)
    session.grid:draw_text(image_message, x / 8, y / 16, {160, 160, 160})
  end
  ---@param window renwindow
  ---@param x? number
  ---@param y? number
  ---@param w? number
  ---@param h? number
  ---@return canvas
  function renderer.to_canvas(window, x, y, w, h)
    local c = api.new(w or session.grid.columns * 8, h or session.grid.rows * 16)
    local source = api.new(session.grid.columns * 8, session.grid.rows * 16)
    canvases[source].grid = session.grid
    blit(canvases[c].grid, source, -(x or 0), -(y or 0))
    return c
  end
  ---There are no native renderer debug regions in terminal mode.
  function renderer.show_debug() end
end

return drawing
