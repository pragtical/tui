local text = require "plugins.tui.text"
local config = require "core.config"

---Terminal font adapters. Existing native fonts use the same patched metatable.
local fonts = {}
local descriptors = setmetatable({}, {__mode = "k"})
local native_path, native_metadata
local icons = {
  ["M"] = "≡", ["X"] = "×", ["<"] = "<", [">"] = ">",
  ["T"] = "×", ["["] = "−", ["]"] = "+", ["A"] = "⚒",
  ["+"] = "+", ["-"] = "-", ["_"] = "_", ["?"] = "?",
  ["f"] = "·", ["F"] = "·", ["d"] = "+", ["D"] = "+", ["L"] = "/",
  ["P"] = "*", ["p"] = "*", ["B"] = ":", ["s"] = "↔", ["S"] = "S",
  ["c"] = "×", ["C"] = "×", ["G"] = "@", ["g"] = "@", ["W"] = "□",
  ["w"] = "□", ["a"] = "<", ["b"] = ">", ["v"] = "v", ["h"] = "=",
  ["i"] = "i", ["e"] = "!", ["j"] = "!", ["k"] = "!", ["l"] = "P"
}

-- Match scripts/fontello-config.json to Nerd Fonts 3 glyphs. Custom search
-- symbols use the corresponding Codicons/Material icons; the Pragtical logo
-- layers have no Nerd Font equivalent and retain the ordinary fallback.
-- Glyph names: https://github.com/ryanoasis/nerd-fonts/blob/master/glyphnames.json
local nerdicons = {
  ["!"] = "", -- fa-triangle_exclamation
  ["&"] = "", -- fa-filter
  ["*"] = "󰒉", -- md-selection
  ["+"] = "", -- fa-angle_right
  ["-"] = "", -- fa-angle_down
  ["<"] = "", -- fa-chevron_left
  [">"] = "", -- fa-chevron_right
  ["?"] = "", -- fa-question_circle
  ["A"] = "", -- fa-wrench
  ["B"] = "", -- fa-book
  ["C"] = "", -- fa-close
  ["D"] = "", -- fa-folder_open
  ["E"] = "", -- fa-tint
  ["F"] = "", -- fa-file_text
  ["G"] = "", -- fa-globe
  ["K"] = "", -- fa-code
  ["L"] = "", -- fa-search
  ["M"] = "", -- fa-bars
  ["N"] = "", -- fa-compress
  ["O"] = "", -- cod-whole_word
  ["P"] = "", -- fa-cog
  ["R"] = "", -- fa-percent (Lua patterns)
  ["S"] = "", -- fa-floppy_o
  ["T"] = "", -- fa-trash
  ["W"] = "", -- fa-window_maximize
  ["X"] = "", -- fa-window_close
  ["Z"] = "", -- fa-search_minus
  ["["] = "", -- fa-minus
  ["]"] = "", -- fa-plus
  ["_"] = "", -- fa-window_minimize
  ["d"] = "", -- fa-folder
  ["e"] = "", -- fa-eyedropper
  ["f"] = "", -- fa-file_o
  ["g"] = "", -- fa-chart_line
  ["h"] = "󰔳", -- md-trending_down
  ["i"] = "", -- fa-info_circle
  ["k"] = "", -- fa-keyboard_o
  ["l"] = "", -- fa-list
  ["n"] = "", -- fa-expand
  ["o"] = "", -- cod-case_sensitive
  ["p"] = "", -- fa-plug
  ["r"] = "", -- cod-regex
  ["s"] = "", -- fa-exchange
  ["t"] = "", -- fa-terminal
  ["w"] = "", -- fa-window_restore
  ["z"] = "", -- fa-search_plus
  ["{"] = "", -- fa-angle_double_left
  ["}"] = "", -- fa-angle_double_right
}

-- Nerd Font glyphs have a one-cell terminal advance, but non-Mono variants
-- can draw beyond that cell. Reserve a real space so both layout and terminal
-- output advance by two columns without changing Unicode width rules.
for code, glyph in pairs(nerdicons) do nerdicons[code] = glyph .. " " end

---Identify the bundled ASCII-encoded font without remapping other icon fonts.
---@param path string
---@return boolean
local function is_icon_font(path)
  return path:match("[^/\\]+$"):lower() == "icons.ttf"
end

---Resolve metadata for fonts created before or after activation.
---@param font renderer.font
---@return table
function fonts.describe(font)
  if not descriptors[font] then
    local path = native_path(font)
    if type(path) == "table" then path = path[1] end
    descriptors[font] = {path = path, tabs = 4, options = {}, icon = is_icon_font(path)}
  end
  return descriptors[font]
end

---Map custom font glyphs to characters supplied by the terminal font.
---@param font renderer.font
---@param value string
---@return string
function fonts.translate(font, value)
  if not fonts.describe(font).icon then return tostring(value) end
  local map = config.plugins.tui.nerdicons and nerdicons or icons
  if map[value] then return map[value] end
  local result = {}
  text.each(value, function(ch)
    result[#result + 1] = map[ch] or icons[ch] or (ch == " " and " " or "◇")
  end)
  return table.concat(result)
end

---Install metrics on the shared font metatable without creating native fonts.
function fonts.install()
  native_path, native_metadata = renderer.font.get_path, renderer.font.get_metadata
  local api = renderer.font
  local native_gc = api.__gc
  ---Release native fonts while allowing descriptors to share the font type.
  ---@param self renderer.font
  function api:__gc()
    if type(self) == "userdata" then native_gc(self) end
  end
  ---Create a font descriptor; terminal font size is controlled by the terminal.
  ---@param path string
  ---@param size? number
  ---@param options? table
  ---@return renderer.font
  function api.load(path, size, options)
    -- Styled text identifies fonts by this exact metatable before checking colors.
    local font = setmetatable({}, api)
    descriptors[font] = {path = path, size = size or 16, tabs = 4,
      options = options or {}, icon = is_icon_font(path)}
    return font
  end
  ---Combine descriptors while preserving the usual font interface.
  ---@param members renderer.font[]
  ---@return renderer.font
  function api.group(members)
    local font = members[1]:copy()
    local paths = {}
    for _, member in ipairs(members) do paths[#paths + 1] = member:get_path() end
    descriptors[font].paths = paths
    return font
  end
  ---Copy font attributes and tab stops.
  ---@param size? number
  ---@param options? table
  ---@return renderer.font
  function api:copy(size, options)
    local d = fonts.describe(self)
    local font = api.load(d.path, size or d.size, options or d.options)
    descriptors[font].tabs = d.tabs
    return font
  end
  ---Measure logical pixels with terminal cell widths.
  ---@param value string
  ---@param tab? renderer.tab_data
  ---@return number
  function api:get_width(value, tab)
    return text.width(fonts.translate(self, value), fonts.describe(self).tabs,
      tab and (tab.tab_offset or 0) / 8 or 0) * 8
  end
  ---@return integer height
  function api:get_height() return 16 end
  ---@return integer size
  function api:get_size() return 16 end
  ---Remember the requested size without resizing terminal cells.
  ---@param size number
  function api:set_size(size) fonts.describe(self).size = size end
  ---@param size integer
  function api:set_tab_size(size) fonts.describe(self).tabs = math.max(1, size) end
  ---@return string|string[]
  function api:get_path()
    local d = fonts.describe(self)
    return d.paths or d.path
  end
  ---Preserve file metadata queries used by Settings' font selector.
  ---@param font renderer.font|string
  ---@return table?
  ---@return string?
  function api.get_metadata(font)
    if type(font) == "string" then return native_metadata(font) end
    return native_metadata(fonts.describe(font).path)
  end
end

return fonts
