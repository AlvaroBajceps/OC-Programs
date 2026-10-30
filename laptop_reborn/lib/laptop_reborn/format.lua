local M = {}

local SECTION_SIGN = "\194\167"

local SCALES = {
  { 1e18, "EEU" },
  { 1e15, "PEU" },
  { 1e12, "TEU" },
  { 1e9, "GEU" },
  { 1e6, "MEU" },
  { 1e3, "kEU" },
  { 1, "EU" },
}

---@param s string|nil
---@return string
function M.strip_gt_colors(s)
  if s == nil then
    return ""
  end
  return (tostring(s):gsub(SECTION_SIGN .. ".", ""))
end

local function scaled(n, decimals)
  if n == nil then
    return nil
  end
  n = tonumber(n)
  if n == nil then
    return nil
  end
  if n == 0 then
    n = 0
  end

  local sign = ""
  if n < 0 then
    sign = "-"
    n = -n
  end

  local scale, unit = 1, "EU"
  for _, entry in ipairs(SCALES) do
    if n >= entry[1] then
      scale, unit = entry[1], entry[2]
      break
    end
  end

  local pattern = "%s%." .. decimals .. "f %s"
  return string.format(pattern, sign, n / scale, unit)
end

---@param n number|nil
---@return string
function M.eu(n)
  local text = scaled(n, 2)
  if text == nil then
    return "unknown"
  end
  return text
end

---@param n number|nil
---@return string
function M.eut(n)
  local text = scaled(n, 1)
  if text == nil then
    return "unknown"
  end
  return text .. "/t"
end

---@param s string|nil
---@return number
function M.width(s)
  if s == nil then
    return 0
  end
  local _, continuations = tostring(s):gsub("[\128-\191]", "")
  return #tostring(s) - continuations
end

local function take_codepoints(s, n)
  if n <= 0 then
    return ""
  end
  local count = 0
  local index = 1
  while index <= #s do
    local byte = s:byte(index)
    if byte < 0x80 or byte >= 0xC0 then
      if count == n then
        return s:sub(1, index - 1)
      end
      count = count + 1
    end
    index = index + 1
  end
  return s
end

---@param s string|nil
---@param w number
---@return string
function M.trunc(s, w)
  s = s and tostring(s) or ""
  w = tonumber(w) or 0
  if w <= 0 then
    return ""
  end
  if M.width(s) <= w then
    return s
  end
  if w >= 4 then
    return take_codepoints(s, w - 2) .. ".."
  end
  return take_codepoints(s, w)
end

---@param s string|nil
---@param width number
---@param max_lines number|nil
---@return table
function M.wrap(s, width, max_lines)
  s = s and tostring(s) or ""
  width = tonumber(width) or 0
  max_lines = tonumber(max_lines)
  if max_lines == nil then
    max_lines = math.huge
  else
    max_lines = math.floor(max_lines)
  end
  if width < 1 or s == "" or max_lines < 1 then
    return {}
  end

  local lines = {}
  local current = ""
  local function flush()
    if current ~= "" then
      lines[#lines + 1] = current
      current = ""
    end
  end

  for word in s:gmatch("%S+") do
    while M.width(word) > width do
      flush()
      local head = take_codepoints(word, width)
      lines[#lines + 1] = head
      word = word:sub(#head + 1)
    end
    if word ~= "" then
      if current == "" then
        current = word
      elseif M.width(current) + 1 + M.width(word) <= width then
        current = current .. " " .. word
      else
        flush()
        current = word
      end
    end
  end
  flush()

  if #lines <= max_lines then
    return lines
  end

  local kept = {}
  for index = 1, max_lines - 1 do
    kept[index] = lines[index]
  end
  local tail = lines[max_lines]
  for index = max_lines + 1, #lines do
    tail = tail .. " " .. lines[index]
  end
  kept[max_lines] = M.trunc(tail, width)
  return kept
end

---@param s string|nil
---@param w number
---@return string
function M.pad(s, w)
  s = s and tostring(s) or ""
  w = tonumber(w) or 0
  local current = M.width(s)
  if current >= w then
    return s
  end
  return s .. string.rep(" ", w - current)
end

---@param seconds number|nil
---@param _percent number|nil
---@return string
function M.edge_text(seconds, _percent)
  if seconds == nil then
    return "unknown"
  end
  local sec = tonumber(seconds)
  if sec == nil or sec ~= sec then
    return "unknown"
  end

  local magnitude = math.abs(sec)
  if magnitude < 1 then
    return "steady"
  end

  local prefix
  if sec > 0 then
    prefix = "Filled in "
  else
    prefix = "Empty in "
  end

  local body
  if magnitude < 3600 then
    body = string.format("%d:%02d", math.floor(magnitude / 60), math.floor(magnitude % 60))
  elseif magnitude < 86400 then
    body = string.format("%dh %02dm", math.floor(magnitude / 3600), math.floor((magnitude % 3600) / 60))
  elseif magnitude < 8553600 then
    body = string.format("%.2fd", magnitude / 86400)
  else
    body = "far"
  end

  return prefix .. body
end

---@param seconds number|nil
---@return string
function M.duration(seconds)
  if seconds == nil then
    return "unknown"
  end
  local sec = tonumber(seconds)
  if sec == nil or sec ~= sec then
    return "unknown"
  end
  sec = math.floor(math.abs(sec))

  if sec < 60 then
    return string.format("%ds", sec)
  elseif sec < 3600 then
    return string.format("%dm %02ds", math.floor(sec / 60), sec % 60)
  elseif sec < 86400 then
    return string.format("%dh %02dm", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
  end
  return string.format("%dd %02dh", math.floor(sec / 86400), math.floor((sec % 86400) / 3600))
end

return M
