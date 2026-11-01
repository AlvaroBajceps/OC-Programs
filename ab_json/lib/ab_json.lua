-- ab_json.lua
-- Small, deterministic JSON encoder for OpenComputers programs.
--
-- Encoding rules:
--   * arrays are tables with a positive `#value`;
--   * all other tables are objects and require string keys;
--   * object keys are sorted so output is stable;
--   * non-finite numbers become `null` because JSON has no NaN/Infinity.

local M = {}

M.VERSION = "1.0.0"

local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function escape(value)
  return (
    value:gsub('[%z\1-\31\\"]', function(char)
      return ESCAPES[char] or string.format("\\u%04x", char:byte())
    end)
  )
end

---@param value any
---@return string
function M.encode(value)
  local kind = type(value)

  if kind == "nil" then
    return "null"
  elseif kind == "boolean" then
    return value and "true" or "false"
  elseif kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return "null"
    end
    if value == math.floor(value) then
      local ok, text = pcall(string.format, "%d", value)
      if ok then
        return text
      end
    end
    return string.format("%.14g", value)
  elseif kind == "string" then
    return '"' .. escape(value) .. '"'
  elseif kind ~= "table" then
    error("cannot JSON-encode " .. kind)
  end

  if #value > 0 then
    local items = {}
    for index = 1, #value do
      items[index] = M.encode(value[index])
    end
    return "[" .. table.concat(items, ",") .. "]"
  end

  local items = {}
  for key, item in pairs(value) do
    if type(key) ~= "string" then
      error("JSON object keys must be strings")
    end
    items[#items + 1] = '"' .. escape(key) .. '":' .. M.encode(item)
  end
  table.sort(items)
  return "{" .. table.concat(items, ",") .. "}"
end

M.json_encode = M.encode

return M
