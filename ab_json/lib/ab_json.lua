-- ab_json.lua
-- Small, deterministic JSON encoder & decoder for OpenComputers programs.
--
-- Encoding rules:
--   * arrays are tables with a positive `#value`;
--   * all other tables are objects and require string keys;
--   * object keys are sorted so output is stable;
--   * non-finite numbers become `null` because JSON has no NaN/Infinity.

local M = {}

M.VERSION = "1.1.0"

local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local UNESCAPES = {
  ['"'] = '"',
  ["\\"] = "\\",
  ["/"] = "/",
  ["b"] = "\b",
  ["f"] = "\f",
  ["n"] = "\n",
  ["r"] = "\r",
  ["t"] = "\t",
}

local str_sub = string.sub
local str_byte = string.byte
local str_char = string.char
local str_find = string.find
local str_match = string.match

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

-- ============================================================================
-- DECODER
-- ============================================================================

local function skip_ws(str, pos)
  local _, next_pos = str_find(str, "^[ \t\r\n]*", pos)
  return (next_pos or pos - 1) + 1
end

local function parse_unicode(hex)
  local code = tonumber(hex, 16)
  if not code then return "?" end
  if code < 0x80 then
    return str_char(code)
  elseif code < 0x800 then
    return str_char(
      0xC0 + math.floor(code / 0x40),
      0x80 + (code % 0x40)
    )
  else
    return str_char(
      0xE0 + math.floor(code / 0x1000),
      0x80 + (math.floor(code / 0x40) % 0x40),
      0x80 + (code % 0x40)
    )
  end
end

local parse_value -- forward declaration

local function parse_string(str, pos)
  pos = pos + 1 -- skip opening quote
  local chunks = {}
  local len = #str

  while pos <= len do
    local next_special = str_find(str, '["\\]', pos)
    if not next_special then
      error("unterminated JSON string")
    end

    if next_special > pos then
      chunks[#chunks + 1] = str_sub(str, pos, next_special - 1)
    end

    local ch = str_sub(str, next_special, next_special)
    if ch == '"' then
      return table.concat(chunks), next_special + 1
    end

    -- Escape sequence
    local esc = str_sub(str, next_special + 1, next_special + 1)
    if esc == "u" then
      local hex = str_sub(str, next_special + 2, next_special + 5)
      if #hex < 4 or not str_match(hex, "^%x%x%x%x$") then
        error("invalid unicode escape in JSON string")
      end
      chunks[#chunks + 1] = parse_unicode(hex)
      pos = next_special + 6
    elseif UNESCAPES[esc] then
      chunks[#chunks + 1] = UNESCAPES[esc]
      pos = next_special + 2
    else
      error("invalid escape sequence \\" .. esc)
    end
  end

  error("unterminated JSON string")
end

local function parse_number(str, pos)
  local _, end_pos = str_find(str, "^-?%d+", pos)
  if not end_pos then
    error("invalid JSON number at position " .. pos)
  end

  if str_sub(str, end_pos + 1, end_pos + 1) == "." then
    local _, frac_end = str_find(str, "^%d+", end_pos + 2)
    if not frac_end then
      error("invalid JSON fraction at position " .. (end_pos + 1))
    end
    end_pos = frac_end
  end

  local exp_char = str_sub(str, end_pos + 1, end_pos + 1)
  if exp_char == "e" or exp_char == "E" then
    local _, exp_end = str_find(str, "^[+-]?%d+", end_pos + 2)
    if not exp_end then
      error("invalid JSON exponent at position " .. (end_pos + 1))
    end
    end_pos = exp_end
  end

  local num = tonumber(str_sub(str, pos, end_pos))
  if not num then
    error("invalid JSON number at position " .. pos)
  end
  return num, end_pos + 1
end

local function parse_array(str, pos)
  local arr = {}
  local index = 1
  pos = skip_ws(str, pos + 1)

  if str_sub(str, pos, pos) == "]" then
    return arr, pos + 1
  end

  while true do
    local val
    val, pos = parse_value(str, pos)
    arr[index] = val
    index = index + 1

    pos = skip_ws(str, pos)
    local sep = str_sub(str, pos, pos)
    if sep == "]" then
      return arr, pos + 1
    elseif sep ~= "," then
      error("expected ',' or ']' in JSON array at position " .. pos)
    end
    pos = skip_ws(str, pos + 1)
  end
end

local function parse_object(str, pos)
  local obj = {}
  pos = skip_ws(str, pos + 1)

  if str_sub(str, pos, pos) == "}" then
    return obj, pos + 1
  end

  while true do
    if str_sub(str, pos, pos) ~= '"' then
      error("expected string key in JSON object at position " .. pos)
    end

    local key
    key, pos = parse_string(str, pos)
    pos = skip_ws(str, pos)

    if str_sub(str, pos, pos) ~= ":" then
      error("expected ':' after key in JSON object at position " .. pos)
    end
    pos = skip_ws(str, pos + 1)

    local val
    val, pos = parse_value(str, pos)
    obj[key] = val

    pos = skip_ws(str, pos)
    local sep = str_sub(str, pos, pos)
    if sep == "}" then
      return obj, pos + 1
    elseif sep ~= "," then
      error("expected ',' or '}' in JSON object at position " .. pos)
    end
    pos = skip_ws(str, pos + 1)
  end
end

parse_value = function(str, pos)
  pos = skip_ws(str, pos)
  local ch = str_sub(str, pos, pos)

  if ch == "" then
    error("unexpected end of JSON input")
  elseif ch == '"' then
    return parse_string(str, pos)
  elseif ch == "{" then
    return parse_object(str, pos)
  elseif ch == "[" then
    return parse_array(str, pos)
  elseif ch == "-" or (str_byte(ch) >= 48 and str_byte(ch) <= 57) then
    return parse_number(str, pos)
  else
    local word = str_match(str, "^%a+", pos)
    if word == "true" then
      return true, pos + 4
    elseif word == "false" then
      return false, pos + 5
    elseif word == "null" then
      return nil, pos + 4
    end
    error("unexpected token at position " .. pos)
  end
end

---@param str string
---@return any
function M.decode(str)
  if type(str) ~= "string" then
    error("JSON input must be a string, got " .. type(str))
  end
  local val, pos = parse_value(str, 1)
  pos = skip_ws(str, pos)
  if pos <= #str then
    error("unexpected trailing data at position " .. pos)
  end
  return val
end

M.json_decode = M.decode

return M