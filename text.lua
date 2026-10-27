local utf8 = require "utf8extra"

---Text measurement shared by terminal fonts and drawing.
local text = { cell_width = 8, cell_height = 16 }
local widths, width_count = {}, 0

---Render line endings as spaces and replace other terminal controls with markers.
---Drawing calls position each line explicitly; embedded breaks are inline
---whitespace (for example Markdown soft breaks), never terminal cursor movement.
---@param value string
---@return string
function text.clean(value)
  value = utf8.clean(tostring(value))
  return (value:gsub("\r\n", " "):gsub("[\r\n]", " ")
    :gsub("[%z\1-\8\11-\31\127]", "?")
    :gsub("\194[\128-\159]", "?"))
end

---Visit display characters, grouping combining marks with their base character.
---The visitor receives the string and its cell width; tabs have width -1.
---@param value string
---@param visit fun(character:string, width:integer)
function text.each(value, visit)
  value = tostring(value)
  -- Most UI labels and source lines need neither grapheme segmentation nor
  -- Unicode width lookups. Keep the common drawing path in LuaJIT.
  if not value:find("[^\032-\126]") then
    for i = 1, #value do visit(value:sub(i, i), 1) end
    return
  end
  value = text.clean(value)
  for first, last in utf8.grapheme_indices(value) do
    local cluster, width = value:sub(first, last), 0
    for _, code in utf8.codes(cluster) do
      local ch = utf8.char(code)
      -- The core width table checks East Asian ambiguity before combining
      -- marks; explicitly exclude its %t (Grapheme_Extend) category here.
      local w = code == 9 and -1 or (utf8.match(ch, "^%t$") and 0 or utf8.width(code, false, 0))
      if code == 0xfe0f or (code >= 0x1f1e6 and code <= 0x1f1ff and #cluster > 4) then w = 2 end
      if w < 0 then width = -1; break end
      width = math.max(width, math.min(2, w))
    end
    visit(cluster, width)
  end
end

---Measure text in cells using the same tab stops as the drawing path.
---@param value string
---@param tabs? integer
---@param offset? number Starting cell offset relative to the tab origin
---@return number
function text.width(value, tabs, offset)
  value = tostring(value)
  if not value:find("[^\032-\126]") then return #value end
  -- Labels containing icons or Unicode recur on every layout update. Cache
  -- only short, tab-free values, whose width cannot depend on the caller.
  local cacheable = #value <= 256 and not value:find("\t", 1, true)
  if cacheable and widths[value] then return widths[value] end
  local width, start = offset or 0, offset or 0
  tabs = math.max(1, tabs or 4)
  text.each(value, function(_, w)
    width = width + (w < 0 and (tabs - width % tabs) or w)
  end)
  width = width - start
  if cacheable then
    if width_count == 256 then widths, width_count = {}, 0 end
    widths[value], width_count = width, width_count + 1
  end
  return width
end

return text
