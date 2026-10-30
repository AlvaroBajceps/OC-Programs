local format = require("laptop.format")

local M = {}

local DEFAULT_RING_SIZE = 96
local FILL_THRESHOLD = 8
local HYSTERESIS_THRESHOLD = 16
local TICKS_PER_SECOND = 20
local MAX_EDGE_SECONDS = 999 * 86400

local function as_number(value)
  if type(value) ~= "number" or value ~= value then
    return nil
  end
  return value
end

---@param opts table|nil
---@return table
function M.new(opts)
  opts = opts or {}
  return {
    ring_size = opts.ring_size or DEFAULT_RING_SIZE,
    buffer = {},
    head = 1,
    count = 0,
    seq = 0,
    status_state = nil,
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

-- Hysteresis: an 8 EU/t dead band keeps the current mode, a 16 EU/t band must
-- be crossed to leave Idle/Full/Empty, so sensor noise cannot flap the state.
---@param model table
---@param view table
---@return string
local function derive_status(model, view)
  if not view.online then
    return "Offline"
  end
  if view.maintenance == true then
    return "Maintenance"
  end
  local percent = view.percent
  if type(percent) == "number" then
    if percent <= 0.05 then
      return "Empty"
    end
    if percent >= 99.95 and (view.net_instant == nil or view.net_instant >= -FILL_THRESHOLD) then
      return "Full"
    end
  end

  local net = view.net_instant
  if net == nil then
    local previous = model.status_state
    if previous == "Charging" or previous == "Discharging" or previous == "Idle" then
      return previous
    end
    return "Idle"
  end

  local previous = model.status_state
  if previous == "Charging" then
    if net < -FILL_THRESHOLD then
      return "Discharging"
    elseif net < FILL_THRESHOLD then
      return "Idle"
    end
    return "Charging"
  elseif previous == "Discharging" then
    if net > FILL_THRESHOLD then
      return "Charging"
    elseif net > -FILL_THRESHOLD then
      return "Idle"
    end
    return "Discharging"
  end
  if net > HYSTERESIS_THRESHOLD then
    return "Charging"
  elseif net < -HYSTERESIS_THRESHOLD then
    return "Discharging"
  end
  return "Idle"
end

-- The 5 m GT average is stable and closer to GT's own estimate; the instant
-- net only decides direction. Rates are EU/t and must be scaled by the tick
-- rate to get EU/s for the time-to-edge division.
---@param view table
---@return number
local function compute_edge(view)
  local net = view.net_instant
  if net == nil then
    return 0
  end
  local rate
  if net > FILL_THRESHOLD and view.stored ~= nil and view.capacity_total ~= nil then
    rate = (view.net_5m ~= nil and view.net_5m > FILL_THRESHOLD) and view.net_5m or net
    return (view.capacity_total - view.stored) / (rate * TICKS_PER_SECOND)
  elseif net < -FILL_THRESHOLD and view.stored ~= nil then
    rate = (view.net_5m ~= nil and view.net_5m < -FILL_THRESHOLD) and view.net_5m or net
    return view.stored / (rate * TICKS_PER_SECOND)
  end
  return 0
end

local function build_view(model, cache)
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
    net_5m = nil,
    net_1h = nil,
    seconds_to_edge = 0,
    edge_text = "unknown",
    maintenance = nil,
    status = "Offline",
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
  if view.in_5m ~= nil and view.out_5m ~= nil then
    view.net_5m = view.in_5m - view.out_5m
  end
  if view.in_1h ~= nil and view.out_1h ~= nil then
    view.net_1h = view.in_1h - view.out_1h
  end

  view.status = derive_status(model, view)
  model.status_state = view.status

  local edge = compute_edge(view)
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
---@return table
function M.update(model, cache)
  return build_view(model, cache)
end

---@param model table
---@return table
function M.record_offline(model)
  return build_view(model, nil)
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
