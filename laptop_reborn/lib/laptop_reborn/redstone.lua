-- Redstone telegraph with exact parity to the old laptop v2.3.0 output math.
-- Sides are returned as names; apply resolves them through the OC sides table.

local M = {}

local IV_SCALE = 8 * (4 ^ 5)
local LUV_SCALE = 8 * (4 ^ 6)
local ZPM_SCALE = 8 * (4 ^ 7)

local function minmax(value, lower, upper)
  if value < lower then
    return lower
  end
  if value > upper then
    return upper
  end
  return value
end

local function number_or_zero(value)
  local n = tonumber(value)
  if n == nil or n ~= n then
    return 0
  end
  return n
end

local function level(value)
  local n = math.floor(number_or_zero(value))
  if n < 0 then
    return 0
  end
  if n > 15 then
    return 15
  end
  return n
end

---@param cache table|nil
---@param ticks number
---@return table
function M.compute(cache, ticks)
  cache = cache or {}
  ticks = math.floor(number_or_zero(ticks))

  local bat_bars = math.floor(number_or_zero(cache.capacityUsed) / 11)
  local in_out = number_or_zero(cache.powerAvgIn_5s) - number_or_zero(cache.powerAvgOut_5s)

  local iv_voltage_bars = minmax(in_out / IV_SCALE, -4, 3)
  local luv_voltage_bars = minmax(in_out / LUV_SCALE, -4, 4)
  local zpm_voltage_bars = minmax(in_out / ZPM_SCALE, -4, 5)
  local load_bars = math.modf(iv_voltage_bars + luv_voltage_bars + zpm_voltage_bars)

  local tick_parity = ticks % 2
  if in_out > 0 then
    bat_bars = bat_bars + tick_parity
  elseif bat_bars == 0 then
    bat_bars = (ticks % 8 < 2) and 1 or 0
  end

  if math.abs(load_bars) >= 12 then
    load_bars = load_bars * tick_parity
  end

  local load_plus
  local load_minus
  if load_bars > 0 then
    load_plus = load_bars
    load_minus = 0
  else
    load_plus = 0
    load_minus = -load_bars
  end

  return {
    battery = { side = "east", level = level(bat_bars) },
    load_plus = { side = "up", level = level(load_plus) },
    load_minus = { side = "west", level = level(load_minus) },
  }
end

local function resolve_sides(deps)
  local sides = deps and deps.sides
  if type(sides) == "table" then
    return sides
  end
  local ok, module = pcall(require, "sides")
  if ok and type(module) == "table" then
    return module
  end
  return nil
end

---@param reddev table|nil
---@param out table|nil
---@param deps table|nil
---@return boolean|nil
---@return string|nil
function M.apply(reddev, out, deps)
  if not reddev then
    return false, "no redstone device"
  end
  if type(reddev.setOutput) ~= "function" then
    return false, "no setOutput on redstone device"
  end

  local sides = resolve_sides(deps)
  if not sides then
    return false, "no sides table"
  end

  local ok_all = true
  for _, key in ipairs({ "battery", "load_plus", "load_minus" }) do
    local entry = out and out[key]
    if type(entry) == "table" then
      local side = sides[entry.side]
      if side ~= nil then
        local ok = pcall(reddev.setOutput, reddev, side, entry.level)
        if not ok then
          ok_all = false
        end
      end
    end
  end

  if ok_all then
    return true
  end
  return false, "setOutput failed"
end

---@param reddev table|nil
---@param _deps table|nil
---@return boolean|nil
---@return string|nil
function M.zero(reddev, _deps)
  if not reddev then
    return false, "no redstone device"
  end
  if type(reddev.setOutput) ~= "function" then
    return false, "no setOutput on redstone device"
  end

  local ok_all = true
  for side = 0, 5 do
    local ok = pcall(reddev.setOutput, reddev, side, 0)
    if not ok then
      ok_all = false
    end
  end

  if ok_all then
    return true
  end
  return false, "setOutput failed"
end

return M
