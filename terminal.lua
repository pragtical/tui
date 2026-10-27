local ffi = require "ffi"
local bit = bit

---@class plugins.tui.terminal
---@field pending string Buffered output, including partial writes
local Terminal = {}
Terminal.__index = Terminal

local enter = "\27[?1049h\27[?25l\27[?7l\27[?1003h\27[?1006h\27[?1004h\27[?2004h"
local leave = "\27[0m\27[?2004l\27[?1004l\27[?1006l\27[?1003l\27[?7h\27[?25h\27[?1049l"

if ffi.os == "Windows" then
  ffi.cdef [[
    typedef struct { short X, Y; } CliCoord;
    typedef struct { short Left, Top, Right, Bottom; } CliRect;
    typedef struct { CliCoord size, cursor; unsigned short attributes;
      CliRect window; CliCoord maximum; } CliScreenInfo;
    typedef struct { int down; unsigned short repeat_count, key, scan, character;
      unsigned long modifiers; } CliKey;
    typedef struct { CliCoord position; unsigned long buttons, modifiers, flags; } CliMouse;
    typedef struct { unsigned short type; union { CliKey key; CliMouse mouse;
      CliCoord size; unsigned char padding[16]; } data; } CliRecord;
    void* __stdcall CreateFileW(const unsigned short*, unsigned long, unsigned long,
      void*, unsigned long, unsigned long, void*);
    int __stdcall CloseHandle(void*);
    int __stdcall GetConsoleMode(void*, unsigned long*);
    int __stdcall SetConsoleMode(void*, unsigned long);
    int __stdcall GetConsoleScreenBufferInfo(void*, CliScreenInfo*);
    int __stdcall GetNumberOfConsoleInputEvents(void*, unsigned long*);
    int __stdcall ReadConsoleInputW(void*, CliRecord*, unsigned long, unsigned long*);
    int __stdcall WriteFile(void*, const void*, unsigned long, unsigned long*, void*);
    unsigned int __stdcall GetConsoleOutputCP(void);
    int __stdcall SetConsoleOutputCP(unsigned int);
  ]]
  local C = ffi.load("kernel32")
  local invalid = ffi.cast("void*", -1)
  local keys = {[8] = "backspace", [9] = "tab", [13] = "return", [27] = "escape",
    [32] = "space", [33] = "pageup", [34] = "pagedown", [35] = "end", [36] = "home",
    [37] = "left", [38] = "up", [39] = "right", [40] = "down", [45] = "insert", [46] = "delete"}

  ---Open the attached console, including when the .com wrapper redirected stdio.
  ---@return plugins.tui.terminal
  function Terminal.open()
    local self = setmetatable({pending = "", buttons = 0}, Terminal)
    local function open(name)
      local wide = ffi.new("unsigned short[?]", #name + 1)
      for i = 1, #name do wide[i - 1] = name:byte(i) end
      local handle = C.CreateFileW(wide, 0xc0000000, 3, nil, 3, 0, nil)
      return handle ~= invalid and handle or nil
    end
    self.input, self.output = open("CONIN$"), open("CONOUT$")
    self.input_mode, self.output_mode = ffi.new("unsigned long[1]"), ffi.new("unsigned long[1]")
    if not self.input or not self.output or C.GetConsoleMode(self.input, self.input_mode) == 0
      or C.GetConsoleMode(self.output, self.output_mode) == 0 then
      self:close()
      error("pragtical tui requires an attached Windows console", 0)
    end
    self.saved = true
    self.codepage = C.GetConsoleOutputCP()
    if C.SetConsoleMode(self.input, 0x98) == 0
      or C.SetConsoleMode(self.output, bit.bor(self.output_mode[0], 4)) == 0
      or C.SetConsoleOutputCP(65001) == 0 then
      self:close()
      error("This console does not support virtual terminal output", 0)
    end
    self.count, self.records = ffi.new("unsigned long[1]"), ffi.new("CliRecord[128]")
    self.info = ffi.new("CliScreenInfo[1]")
    self.active = true
    local ok, err = pcall(self.write, self, enter)
    if not ok then self:close(); error(err, 0) end
    return self
  end

  ---Get the visible console viewport, excluding scrollback.
  ---@return integer columns
  ---@return integer rows
  function Terminal:size()
    if C.GetConsoleScreenBufferInfo(self.output, self.info) == 0 then return 80, 24 end
    local r = self.info[0].window
    return tonumber(r.Right - r.Left + 1), tonumber(r.Bottom - r.Top + 1)
  end

  ---Read available Windows input records without blocking the editor.
  ---@param decoder plugins.tui.input
  ---@param now number
  function Terminal:read(decoder, now)
    if C.GetNumberOfConsoleInputEvents(self.input, self.count) == 0 then return false end
    if self.count[0] == 0 then return true end
    if C.ReadConsoleInputW(self.input, self.records, math.min(128, self.count[0]), self.count) == 0 then return false end
    local utf8 = require "utf8extra"
    for i = 0, tonumber(self.count[0]) - 1 do
      local event = self.records[i]
      if event.type == 1 and event.data.key.down ~= 0 then
        local k = event.data.key
        local mods = (bit.band(k.modifiers, 0x10) ~= 0 and 1 or 0)
          + (bit.band(k.modifiers, 3) ~= 0 and 2 or 0)
          + (bit.band(k.modifiers, 12) ~= 0 and 4 or 0)
        local cp = tonumber(k.character)
        local character
        if cp >= 0xd800 and cp <= 0xdbff then self.surrogate = cp
        elseif cp >= 0xdc00 and cp <= 0xdfff and self.surrogate then
          character = utf8.char(0x10000 + (self.surrogate - 0xd800) * 1024 + cp - 0xdc00)
          self.surrogate = nil
        elseif cp >= 32 and (cp < 0xd800 or cp > 0xdfff) then
          character = utf8.char(cp); self.surrogate = nil
        elseif cp < 0xd800 or cp > 0xdbff then self.surrogate = nil end
        local key = keys[tonumber(k.key)] or (k.key >= 112 and k.key <= 123 and "f" .. (k.key - 111))
          or (k.key >= 65 and k.key <= 90 and string.char(k.key + 32)) or character
        if key then
          -- AltGr produces text, rather than a Control+Alt command.
          if character and bit.band(k.modifiers, 9) == 9 then mods = 0 end
          for _ = 1, math.min(128, tonumber(k.repeat_count)) do decoder:key(key, mods, character) end
        end
      elseif event.type == 2 then
        local m = event.data.mouse
        local mods = (bit.band(m.modifiers, 0x10) ~= 0 and 4 or 0)
          + (bit.band(m.modifiers, 3) ~= 0 and 8 or 0)
          + (bit.band(m.modifiers, 12) ~= 0 and 16 or 0)
        local x = tonumber(m.position.X) - self.info[0].window.Left + 1
        local y = tonumber(m.position.Y) - self.info[0].window.Top + 1
        if bit.band(m.flags, 12) ~= 0 then
          local delta = bit.arshift(tonumber(m.buttons), 16)
          local code = bit.band(m.flags, 8) ~= 0 and (delta > 0 and 66 or 67) or (delta > 0 and 64 or 65)
          decoder:mouse(code + mods, x, y, false, now)
        else
          decoder:mouse(32 + mods, x, y, false, now)
          for _, pair in ipairs({{1, 0}, {2, 2}, {4, 1}}) do
            local down, was = bit.band(m.buttons, pair[1]) ~= 0, bit.band(self.buttons, pair[1]) ~= 0
            if down ~= was then decoder:mouse(pair[2] + mods, x, y, not down, now) end
          end
          self.buttons = tonumber(m.buttons)
        end
      end
    end
    return true
  end

  ---Flush pending output, retaining any unwritten bytes.
  function Terminal:flush()
    if #self.pending == 0 then return end
    local written = ffi.new("unsigned long[1]")
    if C.WriteFile(self.output, self.pending, #self.pending, written, nil) == 0 then
      error("Unable to write to the terminal", 0)
    end
    self.pending = self.pending:sub(tonumber(written[0]) + 1)
  end

  ---Restore console modes and release owned handles; safe to call repeatedly.
  function Terminal:close()
    if self.active then self.pending = leave; pcall(self.flush, self); self.active = false end
    if self.saved then
      C.SetConsoleMode(self.input, self.input_mode[0])
      C.SetConsoleMode(self.output, self.output_mode[0])
      if self.codepage then C.SetConsoleOutputCP(self.codepage) end
      self.saved = false
    end
    if self.input then C.CloseHandle(self.input); self.input = nil end
    if self.output then C.CloseHandle(self.output); self.output = nil end
  end
else
  assert(ffi.os == "Linux" or ffi.os == "OSX", "tui supports Linux, macOS and Windows")
  local mac = ffi.os == "OSX"
  ffi.cdef(mac and [[
    typedef struct { unsigned long input, output, control, localflags;
      unsigned char chars[20]; unsigned long input_speed, output_speed; } CliTermios;
  ]] or [[
    typedef struct { unsigned int input, output, control, localflags;
      unsigned char line, chars[32]; unsigned int input_speed, output_speed; } CliTermios;
  ]])
  ffi.cdef [[
    typedef struct { unsigned short rows, columns, xpixel, ypixel; } CliWinSize;
    int open(const char*, int, ...);
    int close(int);
    int fcntl(int, int, ...);
    int ioctl(int, unsigned long, ...);
    int tcgetattr(int, CliTermios*);
    int tcsetattr(int, int, const CliTermios*);
    void cfmakeraw(CliTermios*);
    long read(int, void*, size_t);
    long write(int, const void*, size_t);
  ]]
  local C = ffi.C

  ---Open the controlling terminal without changing the caller's stdio handles.
  ---@return plugins.tui.terminal
  function Terminal.open()
    local self = setmetatable({pending = ""}, Terminal)
    self.fd = C.open("/dev/tty", 2)
    if self.fd < 0 then error("pragtical tui requires an interactive terminal", 0) end
    self.saved = ffi.new("CliTermios[1]")
    if C.tcgetattr(self.fd, self.saved) ~= 0 then
      C.close(self.fd)
      error("Unable to read terminal settings", 0)
    end
    local raw = ffi.new("CliTermios[1]")
    ffi.copy(raw, self.saved, ffi.sizeof(raw))
    C.cfmakeraw(raw)
    self.flags = C.fcntl(self.fd, 3)
    if C.tcsetattr(self.fd, 0, raw) ~= 0 or self.flags < 0
      or C.fcntl(self.fd, 4, ffi.cast("int", bit.bor(self.flags, mac and 4 or 2048))) < 0 then
      self:close()
      error("Unable to configure the terminal", 0)
    end
    self.buffer, self.winsize = ffi.new("char[4096]"), ffi.new("CliWinSize[1]")
    self.active = true
    local ok, err = pcall(self.write, self, enter)
    if not ok then self:close(); error(err, 0) end
    return self
  end

  ---Query terminal dimensions without installing asynchronous Lua signal handlers.
  ---@return integer columns
  ---@return integer rows
  function Terminal:size()
    if C.ioctl(self.fd, mac and 0x40087468 or 0x5413, self.winsize) == 0 then
      return math.max(1, tonumber(self.winsize[0].columns)), math.max(1, tonumber(self.winsize[0].rows))
    end
    return 80, 24
  end

  ---Read at most one bounded chunk per poll, preserving decoder state.
  ---@param decoder plugins.tui.input
  ---@param now number
  ---@return boolean connected
  function Terminal:read(decoder, now)
    local n = tonumber(C.read(self.fd, self.buffer, ffi.sizeof(self.buffer)))
    if n > 0 then decoder:feed(ffi.string(self.buffer, n), now); return true end
    if n == 0 then return false end
    local err = ffi.errno()
    if err ~= 4 and err ~= (mac and 35 or 11) then return false end
    decoder:feed("", now)
    return true
  end

  ---Flush available output without blocking on a slow terminal or SSH connection.
  function Terminal:flush()
    while #self.pending > 0 do
      local n = tonumber(C.write(self.fd, self.pending, #self.pending))
      if n > 0 then self.pending = self.pending:sub(n + 1)
      elseif n < 0 and ffi.errno() == 4 then -- interrupted: retry
      elseif n < 0 and ffi.errno() == (mac and 35 or 11) then return
      else error("Unable to write to the terminal", 0) end
    end
  end

  ---Restore exact terminal settings, including after a partially failed startup.
  function Terminal:close()
    if not self.fd or self.fd < 0 then return end
    -- Exit sequences are small; restore blocking writes so cleanup is not lost.
    if self.flags and self.flags >= 0 then C.fcntl(self.fd, 4, ffi.cast("int", self.flags)) end
    if self.active then self.pending = leave; pcall(self.flush, self); self.active = false end
    if self.saved then C.tcsetattr(self.fd, 0, self.saved) end
    C.close(self.fd)
    self.fd = nil
  end
end

---Queue output and attempt to flush it immediately.
---@param value string
function Terminal:write(value)
  self.pending = self.pending .. value
  self:flush()
end

return Terminal
