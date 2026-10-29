-- Capacitor discovery and cache adapter.
--
-- GTNH exposes two different energy-storage component surfaces:
--   * the classic lapotronic capacitor with 24-line getSensorInformation();
--   * a GT supercapacitor / energy container with direct EU getters.
-- The rest of the program consumes the same cache table either way.

local methods = require("laptop_reborn.methods")

local M = {}

local STORED_METHODS = { "getEUStored", "getStoredEU", "getStoredEUString" }
local CAPACITY_METHODS = { "getEUCapacity", "getEUMaxStored", "getEUCapacityString" }
local INPUT_METHODS = { "getAverageElectricInput", "getEUInputAverage" }
local OUTPUT_METHODS = { "getAverageElectricOutput", "getEUOutputAverage" }

local function call(proxy, name)
  local ok, value = methods.call(proxy, name)
  if ok then
    return value
  end
  return nil
end

local function as_number(value)
  if type(value) == "number" and value == value then
    return value
  end
  if type(value) == "string" then
    local cleaned = value:gsub("[,%s]", "")
    local mantissa, exponent = cleaned:match("([%d%.]+)[xX]10%^(%-?%d+)")
    if mantissa ~= nil and exponent ~= nil then
      local parsed = tonumber(mantissa) * (10 ^ tonumber(exponent))
      if parsed == parsed then
        return parsed
      end
    end
    local parsed = tonumber(cleaned)
    if parsed ~= nil and parsed == parsed then
      return parsed
    end
    local numeric = cleaned:match("[-+]?%d+%.?%d*[eE]?[-+]?%d*") or cleaned:match("[-+]?%.%d+[eE]?[-+]?%d*")
    parsed = tonumber(numeric)
    if parsed ~= nil and parsed == parsed then
      return parsed
    end
  end
  return nil
end

local function first_number(proxy, names)
  for _, name in ipairs(names) do
    local value = as_number(call(proxy, name))
    if value ~= nil then
      return value
    end
  end
  return nil
end

local function best_number(proxy, names)
  local best
  for _, name in ipairs(names) do
    local value = as_number(call(proxy, name))
    if value ~= nil and (best == nil or value > best) then
      best = value
    end
  end
  return best
end

local function has_any(proxy, names)
  for _, name in ipairs(names) do
    if methods.get(proxy, name) ~= nil then
      return true
    end
  end
  return false
end

local function pretty_name(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local text = name
    :gsub("^multimachine%.", "")
    :gsub("^gt%.blockmachines%.", "")
    :gsub("^gt%.", "")
    :gsub("^machine%.", "")
    :gsub("^machines%.", "")
    :gsub("_", " ")
  text = text:gsub("^%l", string.upper)
  return text
end

local function sensor_lines(proxy)
  local ok, lines = methods.call(proxy, "getSensorInformation")
  if ok and type(lines) == "table" and #lines == 24 then
    return lines
  end
  return nil
end

local function is_direct(proxy)
  return has_any(proxy, STORED_METHODS) and has_any(proxy, CAPACITY_METHODS)
end

local function sensor_signature(lines)
  if type(lines) ~= "table" then
    return false
  end
  local text = table.concat(lines, "\n"):lower()
  local stored = text:find("eu stored", 1, true) ~= nil or text:find("stored eu", 1, true) ~= nil
  local capacity = text:find("capacity", 1, true) ~= nil
  return stored and capacity
end

---@param proxy table
---@return number|nil score
---@return string|nil kind
local function classify(proxy)
  local name = pretty_name(call(proxy, "getName"))
  local lowered = name and name:lower() or ""
  local named = lowered:find("capacitor", 1, true) ~= nil or lowered:find("lapotron", 1, true) ~= nil
  local lines = sensor_lines(proxy)

  if lines ~= nil then
    if named then
      return 100, "sensor"
    end
    if sensor_signature(lines) then
      return 70, "sensor"
    end
  end
  if is_direct(proxy) then
    if named then
      return 90, "direct"
    end
    if name == nil then
      return 40, "direct"
    end
  end
  return nil, nil
end

local DirectReader = {}
DirectReader.__index = DirectReader

local function empty_cache()
  return {
    stored = 0,
    capacityUsed = 0,
    capacityTotal = 0,
    passiveLoss = 0,
    powerAvgIn_5s = 0,
    powerAvgOut_5s = 0,
    powerAvgIn_5m = 0,
    powerAvgOut_5m = 0,
    powerAvgIn_1h = 0,
    powerAvgOut_1h = 0,
    energyStatusText = "No data",
    maintenanceStatus = false,
  }
end

---@param proxy table
---@param address string
---@param name string|nil
---@return table
function DirectReader.new(proxy, address, name)
  return setmetatable({
    _dev = proxy,
    address = address,
    name = pretty_name(name),
    cache = empty_cache(),
  }, DirectReader)
end

---@param _reader boolean|nil
---@return number, string|nil
function DirectReader:pull(_reader)
  local stored = best_number(self._dev, STORED_METHODS)
  local capacity = best_number(self._dev, CAPACITY_METHODS)
  if stored == nil and capacity == nil then
    return 1, "component '" .. tostring(self.address) .. "' did not answer"
  end

  stored = stored or 0
  capacity = capacity or 0
  local percent = 0
  if capacity > 0 then
    percent = stored / capacity * 100
    if percent < 0 then
      percent = 0
    elseif percent > 100 then
      percent = 100
    end
  end

  local active = call(self._dev, "isMachineActive")
  local status
  if self.name then
    if active == true then
      status = self.name .. ": active"
    elseif active == false then
      status = self.name .. ": idle"
    else
      status = self.name
    end
  else
    status = "GT energy storage"
  end

  self.cache.stored = stored
  self.cache.capacityTotal = capacity
  self.cache.capacityUsed = percent
  self.cache.passiveLoss = 0
  self.cache.powerAvgIn_5s = first_number(self._dev, INPUT_METHODS) or 0
  self.cache.powerAvgOut_5s = first_number(self._dev, OUTPUT_METHODS) or 0
  self.cache.powerAvgIn_5m = nil
  self.cache.powerAvgOut_5m = nil
  self.cache.powerAvgIn_1h = nil
  self.cache.powerAvgOut_1h = nil
  self.cache.energyStatusText = status
  self.cache.maintenanceStatus = false

  return 0
end

---@return nil
function DirectReader:dispose()
  self._dev = nil
  self.cache = empty_cache()
end

local function list_addresses(component)
  local ok, listed = pcall(component.list)
  if not ok then
    return {}
  end
  local addresses = {}
  if type(listed) == "function" then
    while true do
      local address = listed()
      if address == nil then
        break
      end
      addresses[#addresses + 1] = tostring(address)
    end
  elseif type(listed) == "table" then
    for address in pairs(listed) do
      addresses[#addresses + 1] = tostring(address)
    end
  end
  table.sort(addresses)
  return addresses
end

local function proxy_for(component, address)
  if type(address) ~= "string" or address == "" then
    return nil
  end
  local get_ok, full = pcall(component.get, address)
  if get_ok and type(full) == "string" and full ~= "" then
    address = full
  end
  local proxy_ok, proxy = pcall(component.proxy, address)
  if proxy_ok and type(proxy) == "table" then
    return proxy, address
  end
  return nil
end

local function plausible(cache)
  if type(cache) ~= "table" then
    return false
  end
  local stored = cache.stored
  local capacity = cache.capacityTotal
  local percent = cache.capacityUsed
  if type(stored) ~= "number" or type(capacity) ~= "number" or type(percent) ~= "number" then
    return false
  end
  if stored ~= stored or capacity ~= capacity or percent ~= percent then
    return false
  end
  if capacity <= 0 or stored < 0 or percent < 0 or percent > 100 then
    return false
  end
  return stored <= capacity * 1.01 + 1
end

local HybridReader = {}
HybridReader.__index = HybridReader

local function make_hybrid(legacy, fallback)
  return setmetatable({
    _legacy = legacy,
    _fallback = fallback,
    cache = legacy.cache or fallback.cache or empty_cache(),
    backend = "legacy",
  }, HybridReader)
end

---@param _reader boolean|nil
---@return number, string|nil
function HybridReader:pull(_reader)
  if self._legacy ~= nil then
    local ok, status = pcall(self._legacy.pull, self._legacy, true)
    if ok and status == 0 and plausible(self._legacy.cache) then
      self.cache = self._legacy.cache
      self.backend = "legacy"
      return 0
    end
    pcall(self._legacy.dispose, self._legacy)
    self._legacy = nil
  end

  if self._fallback ~= nil then
    local ok, status = pcall(self._fallback.pull, self._fallback, true)
    if ok and status == 0 then
      self.cache = self._fallback.cache
      self.backend = "direct"
      return 0
    end
  end

  return 1, "capacitor did not answer"
end

---@return nil
function HybridReader:dispose()
  if self._legacy ~= nil then
    pcall(self._legacy.dispose, self._legacy)
    self._legacy = nil
  end
  if self._fallback ~= nil then
    pcall(self._fallback.dispose, self._fallback)
    self._fallback = nil
  end
  self.cache = empty_cache()
end

local function adapt(proxy, address, legacy_factory)
  local direct = is_direct(proxy)
  if sensor_lines(proxy) ~= nil then
    local reader, err = legacy_factory(address)
    if reader ~= nil then
      if direct then
        return make_hybrid(reader, DirectReader.new(proxy, address, call(proxy, "getName")))
      end
      return reader
    end
    if direct then
      return DirectReader.new(proxy, address, call(proxy, "getName"))
    end
    return nil, err
  end
  if direct then
    return DirectReader.new(proxy, address, call(proxy, "getName"))
  end
  return nil, "device '" .. tostring(address) .. "' is not a supported capacitor"
end

---@param cfg table
---@param deps table|nil
---@return table|nil reader
---@return string|nil err
function M.open(cfg, deps)
  deps = deps or {}
  local component = deps.component
  local legacy_factory = deps.legacy_factory
  if legacy_factory == nil then
    legacy_factory = function(address)
      return require("ab_lapotron").new(address)
    end
  end

  local wanted = cfg and cfg.DEV_LAPOTRON or ""
  if wanted == "v_lapotron" then
    return legacy_factory(wanted)
  end
  if type(component) ~= "table" then
    return nil, "no component API"
  end

  if wanted ~= nil and wanted ~= "" then
    local proxy, address = proxy_for(component, wanted)
    if proxy == nil then
      return nil, "device '" .. tostring(wanted) .. "' not found"
    end
    return adapt(proxy, address, legacy_factory)
  end

  if methods.get(component, "list") == nil then
    return nil, "no component API"
  end

  local best_proxy, best_address, best_score
  for _, address in ipairs(list_addresses(component)) do
    local proxy = proxy_for(component, address)
    if proxy ~= nil then
      local score = classify(proxy)
      if score ~= nil and (best_score == nil or score > best_score) then
        best_proxy, best_address, best_score = proxy, address, score
      end
    end
  end

  if best_proxy == nil then
    return nil, "no GT capacitor or energy storage found"
  end
  return adapt(best_proxy, best_address, legacy_factory)
end

M.pretty_name = pretty_name

return M
