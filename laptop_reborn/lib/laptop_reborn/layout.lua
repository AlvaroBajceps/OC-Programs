-- Deterministic screen partitions for laptop_reborn. Every layout returns the
-- same eight named rects; sizes degrade by class instead of overlapping.

local M = {}

local PRESETS = {
  ["1x"] = { 34, 12 },
  ["2x"] = { 68, 24 },
  max = { 80, 25 },
}

local ORDER = { "header", "battery", "gauge", "power", "edge", "status", "spark", "footer" }

local function int(value, fallback)
  local n = tonumber(value)
  if not n then
    return fallback
  end
  return math.floor(n)
end

local function rect(x, y, w, h, screen_w, screen_h)
  x = int(x, 1)
  y = int(y, 1)
  w = int(w, 1)
  h = int(h, 1)
  if x < 1 then
    x = 1
  elseif x > screen_w then
    x = screen_w
  end
  if y < 1 then
    y = 1
  elseif y > screen_h then
    y = screen_h
  end
  if w < 1 then
    w = 1
  end
  if h < 1 then
    h = 1
  end
  if x + w - 1 > screen_w then
    w = screen_w - x + 1
  end
  if y + h - 1 > screen_h then
    h = screen_h - y + 1
  end
  return { x = x, y = y, w = w, h = h }
end

---@param mode string?
---@param max_w number?
---@param max_h number?
---@return number, number
function M.pick(mode, max_w, max_h)
  local limit_w = math.max(1, int(max_w, 80))
  local limit_h = math.max(1, int(max_h, 25))
  if mode == "auto" then
    local best_w, best_h, best_area = nil, nil, -1
    for _, key in ipairs({ "1x", "2x", "max" }) do
      local preset = PRESETS[key]
      if preset[1] <= limit_w and preset[2] <= limit_h and preset[1] * preset[2] > best_area then
        best_w, best_h, best_area = preset[1], preset[2], preset[1] * preset[2]
      end
    end
    if best_w and best_h then
      return best_w, best_h
    end
    return math.min(80, limit_w), math.min(25, limit_h)
  end
  local preset = PRESETS[mode] or PRESETS.max
  return math.min(preset[1], limit_w), math.min(preset[2], limit_h)
end

---@param w number
---@param h number
---@return string
function M.class(w, h)
  w = int(w, 0)
  h = int(h, 0)
  if w <= 44 or h <= 16 then
    return "compact"
  end
  if w >= 70 and h >= 22 then
    return "full"
  end
  return "medium"
end

local function micro(screen_w, screen_h)
  local rects = {}
  for index, name in ipairs(ORDER) do
    local cell = index - 1
    local x = (cell % screen_w) + 1
    local y = math.min(screen_h, math.floor(cell / screen_w) + 1)
    rects[name] = { x = x, y = y, w = 1, h = 1 }
  end
  return rects
end

local function compact(screen_w, screen_h)
  local body_h = screen_h - 4
  local left_w = math.max(1, math.floor(screen_w * 0.45))
  if left_w > screen_w - 1 then
    left_w = screen_w - 1
  end
  local right_w = screen_w - left_w
  local battery_h = math.max(1, math.min(body_h - 1, math.ceil(body_h * 0.6)))
  local gauge_h = body_h - battery_h
  local strip_w = math.max(1, math.floor(screen_w / 2))
  if strip_w > screen_w - 1 then
    strip_w = screen_w - 1
  end
  return {
    header = rect(1, 1, screen_w, 1, screen_w, screen_h),
    battery = rect(1, 2, left_w, battery_h, screen_w, screen_h),
    gauge = rect(1, 2 + battery_h, left_w, gauge_h, screen_w, screen_h),
    power = rect(1 + left_w, 2, right_w, body_h, screen_w, screen_h),
    edge = rect(1, screen_h - 2, strip_w, 1, screen_w, screen_h),
    status = rect(1 + strip_w, screen_h - 2, screen_w - strip_w, 1, screen_w, screen_h),
    spark = rect(1, screen_h - 1, screen_w, 1, screen_w, screen_h),
    footer = rect(1, screen_h, screen_w, 1, screen_w, screen_h),
  }
end

local function medium(screen_w, screen_h)
  local body_h = screen_h - 2
  local left_w = math.floor(screen_w * 0.42)
  if left_w < 8 then
    left_w = math.floor(screen_w / 2)
  end
  left_w = math.max(1, math.min(screen_w - 1, left_w))
  local right_w = screen_w - left_w
  local battery_h = math.max(3, math.floor(body_h * 0.45))
  local gauge_h = math.max(2, math.floor(body_h * 0.25))
  if battery_h + gauge_h >= body_h then
    battery_h = math.max(1, body_h - gauge_h - 1)
  end
  local spark_h = body_h - battery_h - gauge_h
  local power_h = math.max(3, math.floor(body_h * 0.55))
  local edge_h = math.max(2, math.floor(body_h * 0.25))
  if power_h + edge_h >= body_h then
    power_h = math.max(1, body_h - edge_h - 1)
  end
  local status_h = body_h - power_h - edge_h
  return {
    header = rect(1, 1, screen_w, 1, screen_w, screen_h),
    battery = rect(1, 2, left_w, battery_h, screen_w, screen_h),
    gauge = rect(1, 2 + battery_h, left_w, gauge_h, screen_w, screen_h),
    spark = rect(1, 2 + battery_h + gauge_h, left_w, spark_h, screen_w, screen_h),
    power = rect(1 + left_w, 2, right_w, power_h, screen_w, screen_h),
    edge = rect(1 + left_w, 2 + power_h, right_w, edge_h, screen_w, screen_h),
    status = rect(1 + left_w, 2 + power_h + edge_h, right_w, status_h, screen_w, screen_h),
    footer = rect(1, screen_h, screen_w, 1, screen_w, screen_h),
  }
end

local function full(screen_w, screen_h)
  local body_h = screen_h - 2
  local left_w = math.max(1, math.floor(screen_w * 0.33))
  local mid_w = math.max(1, math.floor(screen_w * 0.34))
  local right_w = screen_w - left_w - mid_w
  if right_w < 1 then
    right_w = 1
    mid_w = math.max(1, screen_w - left_w - 1)
  end
  local battery_h = math.max(3, math.floor(body_h * 0.42))
  local gauge_h = body_h - battery_h
  local power_h = math.max(3, math.floor(body_h * 0.55))
  local edge_h = math.max(2, math.floor(body_h * 0.2))
  local spark_h = body_h - power_h - edge_h
  if spark_h < 1 then
    edge_h = math.max(1, body_h - power_h - 1)
    spark_h = body_h - power_h - edge_h
  end
  return {
    header = rect(1, 1, screen_w, 1, screen_w, screen_h),
    battery = rect(1, 2, left_w, battery_h, screen_w, screen_h),
    gauge = rect(1, 2 + battery_h, left_w, gauge_h, screen_w, screen_h),
    power = rect(1 + left_w, 2, mid_w, power_h, screen_w, screen_h),
    edge = rect(1 + left_w, 2 + power_h, mid_w, edge_h, screen_w, screen_h),
    spark = rect(1 + left_w, 2 + power_h + edge_h, mid_w, spark_h, screen_w, screen_h),
    status = rect(1 + left_w + mid_w, 2, right_w, body_h, screen_w, screen_h),
    footer = rect(1, screen_h, screen_w, 1, screen_w, screen_h),
  }
end

---@param w number
---@param h number
---@return table, string
function M.layout(w, h)
  local screen_w = math.max(1, int(w, 1))
  local screen_h = math.max(1, int(h, 1))
  local class = M.class(screen_w, screen_h)
  local rects
  if screen_w < 6 or screen_h < 6 then
    rects = micro(screen_w, screen_h)
  elseif class == "full" then
    rects = full(screen_w, screen_h)
  elseif class == "medium" then
    rects = medium(screen_w, screen_h)
  else
    rects = compact(screen_w, screen_h)
  end
  return rects, class
end

return M
