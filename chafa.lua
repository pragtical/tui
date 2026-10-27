local core = require "core"
local process = require "process"
local Grid = require "plugins.tui.grid"
local text = require "plugins.tui.text"

---Asynchronous, cached image conversion to portable colored terminal cells.
---@class plugins.tui.chafa
---@field missing boolean Whether launching Chafa failed in this session
---@field queue table[] Pending conversions
---@field worker integer? Conversion coroutine key in the editor scheduler
---@field process process? Currently running converter
local Chafa = {}
Chafa.__index = Chafa

local missing_message = "Install chafa and add it to PATH for image previews"

---Create a lazy backend; ordinary editor launches never probe or start Chafa.
---@return plugins.tui.chafa
function Chafa.new()
  return setmetatable({queue = {}, missing = false}, Chafa)
end

---Decode Chafa's unoptimized true-color symbol output, never forwarding escapes
---to the terminal. Unset colors retain the background beneath transparent pixels.
---@param output string
---@param columns integer
---@param rows integer
---@param yield_row? fun() Allow large conversions to share the editor's time
---@return plugins.tui.grid?
---@return string? error
function Chafa.decode(output, columns, rows, yield_row)
  local grid = Grid.new(columns, rows)
  local fg, bg, reverse
  local y = 0
  for line in (output .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local x, offset = 0, 1
    while offset <= #line do
      if line:byte(offset) == 27 then
        local first, last, codes = line:find("\27%[([%d;]*)m", offset)
        if first ~= offset then return nil, "Unexpected Chafa escape sequence" end
        local values = {}
        for value in (codes .. ";"):gmatch("(.-);") do
          values[#values + 1] = tonumber(value) or 0
        end
        local i = 1
        while i <= #values do
          local code = values[i]
          if code == 0 then fg, bg, reverse = nil, nil, false
          elseif code == 7 then reverse = true
          elseif code == 27 then reverse = false
          elseif code == 39 then fg = nil
          elseif code == 49 then bg = nil
          elseif (code == 38 or code == 48) and values[i + 1] == 2
            and values[i + 4] then
            local r, g, b = values[i + 2], values[i + 3], values[i + 4]
            if math.max(r, g, b) > 255 then return nil, "Invalid Chafa color" end
            local color = r * 65536 + g * 256 + b
            if code == 38 then fg = color else bg = color end
            i = i + 4
          else
            return nil, "Unexpected Chafa color sequence"
          end
          i = i + 1
        end
        offset = last + 1
      else
        local last = line:find("\27", offset, true) or #line + 1
        local run = line:sub(offset, last - 1)
        if run:find("[%z\1-\31\127]") then return nil, "Invalid Chafa symbol" end
        text.each(run, function(ch, width)
          local cell = grid:cell(x, y)
          local front, back = fg, bg
          if reverse then front, back = bg, fg end
          if cell and width == 1 and (front or back) then
            cell[1], cell[2], cell[3] = ch, front, back
            cell[6], cell[7] = true, back ~= nil
          end
          x = x + width
        end)
        offset = last
      end
    end
    y = y + 1
    if yield_row and y % 16 == 0 then yield_row() end
  end
  return grid
end

---Convert one image without blocking input, bounding output and runtime.
---@param entry table
function Chafa:convert(entry)
  local proc = process.start({
    PLATFORM == "Windows" and "chafa.exe" or "chafa",
    "--format=symbols", "--colors=full", "--symbols=block",
    "--size=" .. entry.columns .. "x" .. entry.rows, "--stretch",
    "--animate=off", "--probe=off", "--polite=on", "--optimize=0",
    "--threads=1", "--", entry.path
  }, {stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_DISCARD})
  if not proc then
    self.missing = true
    entry.message = missing_message
    return
  end
  self.process = proc
  local chunks, bytes, deadline = {}, 0, system.get_time() + 10
  local limit = entry.columns * entry.rows * 96 + entry.rows * 32 + 4096
  while true do
    -- Drain at most 64 KiB per iteration so large previews cannot monopolize Lua.
    local chunk = proc:read_stdout(65536)
    if chunk and #chunk > 0 then
      bytes = bytes + #chunk
      chunks[#chunks + 1] = chunk
    elseif not proc:running() then
      break
    end
    if entry.cancelled or bytes > limit or system.get_time() > deadline then
      proc:kill()
      entry.message = "Chafa preview cancelled or exceeded its limits"
      break
    end
    coroutine.yield(.01)
  end
  if not entry.message then
    if proc:returncode() == 0 and bytes > 0 then
      entry.grid, entry.message = Chafa.decode(table.concat(chunks),
        entry.columns, entry.rows, function() coroutine.yield(0) end)
    else
      entry.message = "Chafa could not decode this image"
    end
  end
  proc:close_stream(process.STREAM_STDOUT)
  self.process = nil
end

---Return a cached conversion or queue it once. Keep only two sizes per image;
---rapid zoom changes discard obsolete requests instead of spawning more workers.
---@param source table File identity shared by a loaded image and its scaled copies
---@param width number Logical pixel width
---@param height number Logical pixel height
---@return plugins.tui.grid?
---@return string? message
function Chafa:get(source, width, height)
  if self.missing then return nil, missing_message end
  local columns, rows = math.max(1, math.ceil(width / 8)), math.max(1, math.ceil(height / 16))
  local factor = math.min(1, math.sqrt(65536 / (columns * rows)))
  columns, rows = math.max(1, math.floor(columns * factor)), math.max(1, math.floor(rows * factor))
  source.previews = source.previews or {}
  for i, entry in ipairs(source.previews) do
    if entry.columns == columns and entry.rows == rows then
      if i > 1 then
        table.remove(source.previews, i)
        table.insert(source.previews, 1, entry)
      end
      return entry.grid, entry.message or "Loading image preview..."
    end
  end
  local entry = {path = source.path, columns = columns, rows = rows}
  table.insert(source.previews, 1, entry)
  if #source.previews > 2 then table.remove(source.previews).cancelled = true end
  self.queue[#self.queue + 1] = entry
  if not self.worker then
    self.worker = core.add_thread(function()
      while #self.queue > 0 do
        local next_entry = table.remove(self.queue, 1)
        if not next_entry.cancelled then
          if self.missing then next_entry.message = missing_message
          else self:convert(next_entry) end
          core.redraw = true
        end
      end
      self.worker = nil
    end)
  end
  return nil, "Loading image preview..."
end

---Stop pending conversions when the terminal session ends.
function Chafa:close()
  if self.process then self.process:kill(); self.process = nil end
  if self.worker then core.threads[self.worker] = nil; self.worker = nil end
  self.queue = {}
end

return Chafa
