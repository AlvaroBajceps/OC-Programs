local format = require("laptop_reborn.format")

local M = {}

local DEFAULT_RING_SIZE = 96
local FILL_THRESHOLD = 8
local FILTER_MULTIPLIER = 20
local ZERO_EPSILON = 1e-9
local MAX_EDGE_SECONDS = 999 * 86400

local function as_number(value)
  if type(value) ~= "number" or value ~= value then
    return nil
  end
  return value
end

local function make_provider(factory)
  local created = factory()
  if type(created) == "function" then
    return created
  end
  if type(created) == "table" and type(created.update) == "function" then
    return function(raw)
      return created:update(raw)
    end
  end
  return function(raw)
    return raw
  end
end

---@param opts table|nil
---@return table
function M.new(opts)
  opts = opts or {}
  local factory = opts.kf_factory
  if factory == nil then
    factory = function()
      local KalmanFilter = require("ab_kalman")
      return KalmanFilter.new(1, 1000, 0)
    end
  end

  return {
    ring_size = opts.ring_size or DEFAULT_RING_SIZE,
    buffer = {},
    head = 1,
    count = 0,
    seq = 0,
    provider = make_provider(factory),
  }
end

local function push(model, sample)
  local size = model.ring_size
  if size < 1 then
    return
  end
  model.buffer[model.head] = sample
  model.head = model.head % size + 1
  if model.count < size then
    model.count = model.count + 1
  end
end

local function build_view(model, cache, provider)
  model.seq = model.seq + 1

  local view = {
    online = cache ~= nil,
    stored = nil,
    capacity_total = nil,
    percent = nil,
    passive_loss = nil,
    in_5s = nil,
    in_5m = nil,
    in_1h = nil,
    out_5s = nil,
    out_5m = nil,
    out_1h = nil,
    net_instant = nil,
    net_kf = nil,
    seconds_to_edge = 0,
    edge_text = "unknown",
    maintenance = nil,
    status_text = "",
    redstone_enabled = false,
    link = "OFF",
    seq = model.seq,
  }

  if cache ~= nil then
    view.stored = as_number(cache.stored)
    view.capacity_total = as_number(cache.capacityTotal)
    view.passive_loss = as_number(cache.passiveLoss)
    view.in_5s = as_number(cache.powerAvgIn_5s)
    view.in_5m = as_number(cache.powerAvgIn_5m)
    view.in_1h = as_number(cache.powerAvgIn_1h)
    view.out_5s = as_number(cache.powerAvgOut_5s)
    view.out_5m = as_number(cache.powerAvgOut_5m)
    view.out_1h = as_number(cache.powerAvgOut_1h)

    view.percent = as_number(cache.capacityUsed)
    if view.percent == nil and view.stored ~= nil and view.capacity_total ~= nil and view.capacity_total > 0 then
      view.percent = view.stored / view.capacity_total * 100
    end

    if type(cache.maintenanceStatus) == "boolean" then
      view.maintenance = cache.maintenanceStatus
    end
    view.status_text = format.strip_gt_colors(cache.energyStatusText)
  end

  if view.in_5s ~= nil and view.out_5s ~= nil then
    view.net_instant = view.in_5s - view.out_5s
  end

  if view.net_instant ~= nil then
    local filtered = view.net_instant
    local active_provider = provider or model.provider
    if active_provider ~= nil then
      local ok, result = pcall(active_provider, view.net_instant)
      if ok and type(result) == "number" and result == result then
        filtered = result
      end
    end
    view.net_kf = filtered * FILTER_MULTIPLIER
  end

  local edge = 0
  if view.net_instant ~= nil and view.net_kf ~= nil and math.abs(view.net_kf) >= ZERO_EPSILON then
    if view.net_instant > FILL_THRESHOLD and view.stored ~= nil and view.capacity_total ~= nil then
      edge = (view.capacity_total - view.stored) / view.net_kf
    elseif view.net_instant < -FILL_THRESHOLD and view.stored ~= nil then
      edge = view.stored / view.net_kf
    end
  end
  if edge ~= edge then
    edge = 0
  elseif edge > MAX_EDGE_SECONDS then
    edge = MAX_EDGE_SECONDS
  elseif edge < -MAX_EDGE_SECONDS then
    edge = -MAX_EDGE_SECONDS
  end
  view.seconds_to_edge = edge
  if view.net_instant == nil then
    view.edge_text = "unknown"
  else
    view.edge_text = format.edge_text(edge, view.percent)
  end

  push(model, { percent = view.percent, net = view.net_instant })

  return view
end

---@param model table
---@param cache table|nil
---@param provider function|nil
---@return table
function M.update(model, cache, provider)
  return build_view(model, cache, provider)
end

---@param model table
---@return table
function M.record_offline(model)
  return build_view(model, nil, nil)
end

---@param model table
---@return table
function M.history(model)
  local size = model.ring_size
  local count = model.count
  if size < 1 or count == 0 then
    return {}
  end

  local result = {}
  local first = (model.head - count - 1) % size + 1
  for offset = 0, count - 1 do
    local index = (first + offset - 1) % size + 1
    local sample = model.buffer[index] or {}
    result[#result + 1] = { percent = sample.percent, net = sample.net }
  end
  return result
end

return M
