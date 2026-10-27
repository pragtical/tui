local bit = bit

---@class plugins.tui.input
---@field buffer string
---@field events table[]
local Input = {}
Input.__index = Input

local arrows = { A = "up", B = "down", C = "right", D = "left", H = "home", F = "end" }
local tilde = { [1] = "home", [2] = "insert", [3] = "delete", [4] = "end",
  [5] = "pageup", [6] = "pagedown", [7] = "home", [8] = "end",
  [11] = "f1", [12] = "f2", [13] = "f3", [14] = "f4", [15] = "f5",
  [17] = "f6", [18] = "f7", [19] = "f8", [20] = "f9", [21] = "f10",
  [23] = "f11", [24] = "f12" }

---Create an incremental terminal input decoder.
---@return plugins.tui.input
function Input.new()
  return setmetatable({buffer = "", events = {}, first = 1, x = 0, y = 0}, Input)
end

---Queue an existing editor event.
---@param ... any
function Input:emit(...)
  self.events[#self.events + 1] = {...}
end

---Remove the next queued event without shifting the queue.
---@return any ...
function Input:pop()
  local e = self.events[self.first]
  if not e then return end
  self.first = self.first + 1
  if self.first > #self.events then self.events, self.first = {}, 1 end
  return table.unpack(e)
end

---Emit a complete keystroke; terminals generally do not report key releases.
---@param key string
---@param modifiers? integer xterm modifier mask: shift=1, alt=2, control=4
---@param character? string
function Input:key(key, modifiers, character)
  local mods = {}
  for _, mod in ipairs({{4, "left ctrl"}, {2, PLATFORM == "Mac OS X" and "left option" or "left alt"}, {1, "left shift"}}) do
    if bit.band(modifiers or 0, mod[1]) ~= 0 then
      mods[#mods + 1] = mod[2]
      self:emit("keypressed", mod[2])
    end
  end
  self:emit("keypressed", key)
  if character and bit.band(modifiers or 0, 6) == 0 then self:emit("textinput", character) end
  self:emit("keyreleased", key)
  for i = #mods, 1, -1 do self:emit("keyreleased", mods[i]) end
  self:emit("tui-key-end")
end

---Decode an SGR mouse report into pixel-coordinate editor events.
---@param button integer
---@param column integer One-based column
---@param row integer One-based row
---@param release boolean
---@param now number
function Input:mouse(button, column, row, release, now)
  local mods = {}
  for _, mod in ipairs({{4, "left shift"}, {8, PLATFORM == "Mac OS X" and "left option" or "left alt"}, {16, "left ctrl"}}) do
    if bit.band(button, mod[1]) ~= 0 then
      mods[#mods + 1] = mod[2]
      self:emit("keypressed", mod[2])
    end
  end
  local x, y = (column - 1) * 8 + 4, (row - 1) * 16 + 8
  self:emit("mousemoved", x, y, x - self.x, y - self.y)
  self.x, self.y = x, y
  local code = button % 4
  if bit.band(button, 64) ~= 0 then
    self:emit("mousewheel", code < 2 and (code == 0 and 1 or -1) or 0,
      code >= 2 and (code == 2 and 1 or -1) or 0)
  elseif bit.band(button, 32) == 0 then
    local name = ({"left", "middle", "right"})[code + 1]
    if name and release then
      self:emit("mousereleased", name, x, y)
    elseif name then
      local same = self.last_button == name and self.last_x == x and self.last_y == y
        and now - (self.last_click or 0) < .35
      self.clicks = same and (self.clicks % 3 + 1) or 1
      self.last_button, self.last_x, self.last_y, self.last_click = name, x, y, now
      self:emit("mousepressed", name, x, y, self.clicks)
    end
  end
  for i = #mods, 1, -1 do self:emit("keyreleased", mods[i]) end
end

---Decode a complete CSI sequence. Unknown terminal replies are consumed.
---@param body string
---@param final string
---@param now number
function Input:csi(body, final, now)
  local b, x, y = body:match("^<(%d+);(%d+);(%d+)$")
  if b and (final == "M" or final == "m") then
    self:mouse(tonumber(b), tonumber(x), tonumber(y), final == "m", now)
    return
  end
  if body == "200" and final == "~" then self.paste = {}; return end
  if body == "" and final == "I" then self:emit("focusgained"); return end
  if body == "" and final == "O" then self:emit("focuslost"); return end
  local number, modifier = body:match("^(%d*);?(%d*)$")
  if not number then return end
  modifier = (tonumber(modifier) or 1) - 1
  local key = arrows[final] or (final == "~" and tilde[tonumber(number)])
    or (final == "Z" and "tab")
  if key then self:key(key, final == "Z" and 1 or modifier) end
end

---Feed bytes without assuming read boundaries match UTF-8 or escape sequences.
---Calling with an empty string also expires the standalone Escape timeout.
---@param bytes string
---@param now number
function Input:feed(bytes, now)
  self.buffer = self.buffer .. bytes
  while #self.buffer > 0 do
    if self.paste then
      local finish = self.buffer:find("\27[201~", 1, true)
      if finish then
        self.paste[#self.paste + 1] = self.buffer:sub(1, finish - 1)
        self:emit("textinput", table.concat(self.paste):gsub("\r\n", "\n"):gsub("\r", "\n"))
        self:emit("tui-key-end")
        self.buffer, self.paste = self.buffer:sub(finish + 6), nil
      else
        -- Retain a possible partial end marker rather than the entire paste.
        if #self.buffer > 5 then
          self.paste[#self.paste + 1] = self.buffer:sub(1, -6)
          self.buffer = self.buffer:sub(-5)
        end
        break
      end
    elseif self.buffer:byte() == 27 then
      if self.buffer:sub(2, 2) == "[" then
        local body, final, finish = self.buffer:match("^\27%[([\032-\063]*)([\064-\126])()")
        if not final then
          self.escape_at = self.escape_at or now
          if now - self.escape_at < .05 and #self.buffer < 128 then break end
          self.buffer, self.escape_at = "", nil
        else
          self.buffer, self.escape_at = self.buffer:sub(finish), nil
          self:csi(body, final, now)
        end
      elseif self.buffer:sub(2, 2) == "O" then
        self.escape_at = self.escape_at or now
        if #self.buffer < 3 and now - self.escape_at < .05 then break end
        local k = self.buffer:sub(3, 3)
        local key = arrows[k] or ({P = "f1", Q = "f2", R = "f3", S = "f4"})[k]
        if key then self:key(key) end
        self.buffer, self.escape_at = self.buffer:sub(4), nil
      elseif #self.buffer == 1 then
        self.escape_at = self.escape_at or now
        if now - self.escape_at < .03 then break end
        self:key("escape")
        self.buffer, self.escape_at = "", nil
      else
        self.buffer, self.alt, self.escape_at = self.buffer:sub(2), true, nil
      end
    else
      local byte, length = self.buffer:byte(), 1
      if byte >= 240 then length = 4 elseif byte >= 224 then length = 3 elseif byte >= 192 then length = 2 end
      if #self.buffer < length then break end
      local ch = self.buffer:sub(1, length)
      self.buffer = self.buffer:sub(length + 1)
      local mods = self.alt and 2 or 0
      self.alt = nil
      local key = ({[9] = "tab", [10] = "return", [13] = "return", [127] = "backspace", [8] = "backspace"})[byte]
      if key then self:key(key, mods)
      elseif byte < 32 then
        self:key(({[0] = "space", [28] = "\\", [29] = "]", [30] = "^", [31] = "_"})[byte]
          or string.char(byte + 96), mods + 4)
      else self:key(ch == " " and "space" or ch:lower(), mods + (ch:match("^[A-Z]$") and 1 or 0), ch) end
    end
  end
end

return Input
