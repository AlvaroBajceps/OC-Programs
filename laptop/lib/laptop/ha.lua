---Home Assistant MQTT discovery, state publishing, and command parsing for the
---laptop program. Pure library: no component, event, or display access.
local M = {}

local STATE_ORDER = {
  "charge",
  "stored",
  "capacity",
  "power_in",
  "power_out",
  "power_net",
  "edge_time",
  "status",
  "maintenance",
  "lapotron_online",
  "link",
}

local STATUS_VALUES = {
  Charging = true,
  Discharging = true,
  Idle = true,
  Full = true,
  Empty = true,
  Maintenance = true,
  Offline = true,
}

local STATUS_OPTIONS = {
  "Charging",
  "Discharging",
  "Idle",
  "Full",
  "Empty",
  "Maintenance",
  "Offline",
  "Unknown",
}

local function json_escape(value)
  return (
    value:gsub('[%z\1-\31\\"]', function(char)
      if char == '"' then
        return '\\"'
      elseif char == "\\" then
        return "\\\\"
      elseif char == "\b" then
        return "\\b"
      elseif char == "\f" then
        return "\\f"
      elseif char == "\n" then
        return "\\n"
      elseif char == "\r" then
        return "\\r"
      elseif char == "\t" then
        return "\\t"
      end
      return string.format("\\u%04x", char:byte())
    end)
  )
end

-- GT storage can exceed int64, where "%d" raises "number has no integer
-- representation" in Lua 5.3. Fall back to float formatting instead.
---@param value number
---@return string|nil
local function number_text(value)
  if value ~= value or value == math.huge or value == -math.huge then
    return nil
  end
  if value == math.floor(value) then
    local ok, text = pcall(string.format, "%d", value)
    if ok then
      return text
    end
  end
  return string.format("%.14g", value)
end

---@param value any
---@return string
function M.json_encode(value)
  local kind = type(value)
  if kind == "nil" then
    return "null"
  elseif kind == "boolean" then
    return value and "true" or "false"
  elseif kind == "number" then
    return number_text(value) or "null"
  elseif kind == "string" then
    return '"' .. json_escape(value) .. '"'
  elseif kind ~= "table" then
    error("cannot JSON-encode " .. kind)
  end

  if #value > 0 then
    local items = {}
    for index = 1, #value do
      items[index] = M.json_encode(value[index])
    end
    return "[" .. table.concat(items, ",") .. "]"
  end

  local items = {}
  for key, item in pairs(value) do
    if type(key) ~= "string" then
      error("JSON object keys must be strings")
    end
    items[#items + 1] = '"' .. json_escape(key) .. '":' .. M.json_encode(item)
  end
  table.sort(items)
  return "{" .. table.concat(items, ",") .. "}"
end

local function state_text(value)
  if value == nil then
    return "unknown"
  end
  local kind = type(value)
  if kind == "boolean" then
    return value and "ON" or "OFF"
  elseif kind == "number" then
    return number_text(value) or "unknown"
  end
  return tostring(value)
end

---Maps a value to an HA payload. nil becomes the literal "unknown" so HA shows
---an unknown entity instead of a guessed state.
---@param value any
---@return string
function M.payload(value)
  return state_text(value)
end

-- Two-significant-digit step: 98300 -> 1000, 57.7 -> 1, 1.5 -> 0.1.
---@param value any
---@return number
local function nice_step(value)
  if type(value) ~= "number" or value == 0 or value ~= value or value == math.huge or value == -math.huge then
    return 0
  end
  return 10 ^ (math.floor(math.log(math.abs(value), 10)) - 1)
end

---@param value any
---@param step number
---@return number|nil
local function quantize(value, step)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    return nil
  end
  if step == nil or step <= 0 then
    return value
  end
  return math.floor(value / step + 0.5) * step
end

---@param view table
---@return number|nil
local function quantized_percent(view)
  return quantize(view.percent, 1)
end

---@param view table
---@return number|nil
local function quantized_capacity(view)
  return quantize(view.capacity_total, 1)
end

---@param value any
---@return number|nil
local function quantized_power(value)
  return quantize(value, nice_step(value))
end

-- Stored energy quantizes to a thousandth of the total capacity so the state
-- moves in lockstep with the charge percentage; without a capacity it falls
-- back to a two-significant-digit step of the value itself.
---@param view table
---@return number|nil
local function quantized_stored(view)
  local capacity = view.capacity_total
  if type(capacity) == "number" and capacity == capacity and capacity > 0 and capacity ~= math.huge then
    return quantize(view.stored, capacity / 1000)
  end
  return quantized_power(view.stored)
end

---@param value number
---@return number
local function edge_step(value)
  local magnitude = math.abs(value)
  if magnitude >= 1200 then
    return 300
  elseif magnitude >= 300 then
    return 60
  elseif magnitude >= 60 then
    return 15
  end
  return 5
end

---@param view table
---@return number|nil
local function quantized_edge(view)
  local value = view.seconds_to_edge
  if type(value) ~= "number" then
    return nil
  end
  return quantize(value, edge_step(value))
end

---@param view table
---@return string
local function status_state(view)
  if type(view.status) == "string" and STATUS_VALUES[view.status] then
    return view.status
  end
  return "Unknown"
end

---@param key string
---@param view table
---@return string payload
local function state_value(key, view)
  if key == "charge" then
    return state_text(quantized_percent(view))
  elseif key == "stored" then
    return state_text(quantized_stored(view))
  elseif key == "capacity" then
    return state_text(quantized_capacity(view))
  elseif key == "power_in" then
    return state_text(quantized_power(view.in_5s))
  elseif key == "power_out" then
    return state_text(quantized_power(view.out_5s))
  elseif key == "power_net" then
    return state_text(quantized_power(view.net_instant))
  elseif key == "edge_time" then
    return state_text(quantized_edge(view))
  elseif key == "status" then
    return status_state(view)
  elseif key == "maintenance" then
    return state_text(view.maintenance)
  elseif key == "lapotron_online" then
    return state_text(view.online)
  elseif key == "link" then
    return view.link == "ONLINE" and "ON" or "OFF"
  end
  return "unknown"
end

---Returns exactly the payload that key would publish for view. app.lua diffs
---these strings so change detection and publishing agree byte-for-byte.
---@param key string
---@param view table|nil
---@return string
function M.state_payload(key, view)
  return state_value(key, view or {})
end

---@param view table
---@return table attributes
local function charge_attributes(view)
  return { capacity_total = quantized_capacity(view) }
end

---@param view table
---@return table attributes
local function power_net_attributes(view)
  return {
    in_5m = quantized_power(view.in_5m),
    out_5m = quantized_power(view.out_5m),
    in_1h = quantized_power(view.in_1h),
    out_1h = quantized_power(view.out_1h),
    net_5m = quantized_power(view.net_5m),
    net_1h = quantized_power(view.net_1h),
    passive_loss = quantized_power(view.passive_loss),
  }
end

---@param view table
---@return table attributes
local function edge_time_attributes(view)
  return { edge_text = view.edge_text, percent = quantized_percent(view) }
end

---@param view table
---@return table attributes
local function status_attributes(view)
  return {
    maintenance = view.maintenance,
    state = status_state(view),
    status_text = view.status_text,
    redstone_enabled = view.redstone_enabled,
    link = view.link,
  }
end

---@param key string
---@param view table
---@return table|nil attributes
local function attributes_for(key, view)
  if key == "charge" or key == "stored" then
    return charge_attributes(view)
  elseif key == "power_net" then
    return power_net_attributes(view)
  elseif key == "edge_time" then
    return edge_time_attributes(view)
  elseif key == "status" then
    return status_attributes(view)
  end
  return nil
end

---@param cfg table
---@param key string
---@return string topic
local function attribute_topic(cfg, key)
  local attributes = cfg.attributes
  if type(attributes) == "table" and attributes[key] then
    return attributes[key]
  end
  local topics = cfg.topics
  local state_topic = type(topics) == "table" and topics[key] or nil
  if type(state_topic) == "string" then
    local base = state_topic:match("^(.*)/[^/]+$")
    if base then
      return base .. "/attributes"
    end
  end
  return tostring(cfg.base_topic or "") .. "/" .. key .. "/attributes"
end

---@param cfg table
---@param component string
---@param suffix string
---@param fields table
---@return table payload
local function discovery_payload(cfg, component, suffix, fields)
  local unique_id = cfg.node .. "_" .. suffix
  local payload = {
    unique_id = unique_id,
    default_entity_id = component .. "." .. unique_id,
    availability_topic = cfg.availability,
    qos = 1,
    device = cfg.device,
    origin = cfg.origin,
  }
  for key, value in pairs(fields) do
    payload[key] = value
  end
  return payload
end

---@param cfg table
---@param suffix string
---@param fields table
---@return table entry `{component, object_id, payload}`
local function sensor_entry(cfg, suffix, fields)
  fields.state_topic = cfg.topics[suffix]
  return {
    component = "sensor",
    object_id = cfg.node .. "_" .. suffix,
    payload = discovery_payload(cfg, "sensor", suffix, fields),
  }
end

---@param cfg table
---@param suffix string
---@param fields table
---@return table entry `{component, object_id, payload}`
local function binary_sensor_entry(cfg, suffix, fields)
  fields.state_topic = cfg.topics[suffix]
  return {
    component = "binary_sensor",
    object_id = cfg.node .. "_" .. suffix,
    payload = discovery_payload(cfg, "binary_sensor", suffix, fields),
  }
end

---Builds the eleven discovery payloads in contract order.
---@param cfg table
---@return table[] entries `{component, object_id, payload}`
function M.discovery_entries(cfg)
  return {
    sensor_entry(cfg, "charge", {
      name = "Charge",
      unit_of_measurement = "%",
      device_class = "battery",
      state_class = "measurement",
      icon = "mdi:battery",
      json_attributes_topic = attribute_topic(cfg, "charge"),
    }),
    sensor_entry(cfg, "stored", {
      name = "Stored Energy",
      unit_of_measurement = "EU",
      state_class = "total",
      icon = "mdi:battery-charging",
      json_attributes_topic = attribute_topic(cfg, "stored"),
    }),
    sensor_entry(cfg, "capacity", {
      name = "Total Capacity",
      unit_of_measurement = "EU",
      state_class = "total",
      entity_category = "diagnostic",
      icon = "mdi:battery-high",
    }),
    sensor_entry(cfg, "power_in", {
      name = "Power In",
      unit_of_measurement = "EU/t",
      state_class = "measurement",
      icon = "mdi:arrow-down-bold",
    }),
    sensor_entry(cfg, "power_out", {
      name = "Power Out",
      unit_of_measurement = "EU/t",
      state_class = "measurement",
      icon = "mdi:arrow-up-bold",
    }),
    sensor_entry(cfg, "power_net", {
      name = "Net Power",
      unit_of_measurement = "EU/t",
      state_class = "measurement",
      icon = "mdi:swap-vertical",
      json_attributes_topic = attribute_topic(cfg, "power_net"),
    }),
    sensor_entry(cfg, "edge_time", {
      name = "Time To Edge",
      unit_of_measurement = "s",
      device_class = "duration",
      state_class = "measurement",
      icon = "mdi:timer-outline",
      json_attributes_topic = attribute_topic(cfg, "edge_time"),
    }),
    sensor_entry(cfg, "status", {
      name = "Energy Status",
      device_class = "enum",
      options = STATUS_OPTIONS,
      entity_category = "diagnostic",
      icon = "mdi:information-outline",
      json_attributes_topic = attribute_topic(cfg, "status"),
    }),
    binary_sensor_entry(cfg, "maintenance", {
      name = "Maintenance",
      device_class = "problem",
      entity_category = "diagnostic",
      payload_on = "ON",
      payload_off = "OFF",
    }),
    binary_sensor_entry(cfg, "lapotron_online", {
      name = "Lapotron Online",
      device_class = "connectivity",
      entity_category = "diagnostic",
      payload_on = "ON",
      payload_off = "OFF",
    }),
    binary_sensor_entry(cfg, "link", {
      name = "Broker Link",
      device_class = "connectivity",
      entity_category = "diagnostic",
      payload_on = "ON",
      payload_off = "OFF",
    }),
  }
end

---@param client table
---@param cfg table
---@return boolean|nil ok
---@return string|nil err
function M.publish_discovery(client, cfg)
  for _, entry in ipairs(M.discovery_entries(cfg)) do
    local topic = cfg.discovery_prefix .. "/" .. entry.component .. "/" .. entry.object_id .. "/config"
    local ok, err = client:publish({
      topic = topic,
      payload = M.json_encode(entry.payload),
      qos = 1,
      retain = true,
    })
    if not ok then
      return false, err
    end
  end
  return true
end

---@param client table
---@param topic string
---@param payload string
---@param retain boolean
---@return number|boolean|nil, string|nil
local function publish_state(client, topic, payload, retain)
  return client:publish({ topic = topic, payload = payload, qos = 1, retain = retain })
end

---@param client table
---@param cfg table
---@param online boolean
---@return number|boolean|nil, string|nil
function M.publish_availability(client, cfg, online)
  return publish_state(client, cfg.availability, online and "online" or "offline", true)
end

---@param client table
---@param cfg table
---@param view table|nil
---@param online boolean|nil
---@return number|boolean|nil, string|nil
function M.publish_link(client, cfg, view, online)
  local is_online
  if online == false then
    is_online = false
  elseif view ~= nil and view.link ~= nil then
    is_online = view.link == "ONLINE"
  else
    is_online = online ~= false
  end
  return publish_state(client, cfg.topics.link, is_online and "ON" or "OFF", true)
end

---@param client table
---@param cfg table
---@param view table
---@param key string
---@return number|boolean|nil ok
---@return string|nil err
local function publish_key(client, cfg, view, key)
  local ok, err = publish_state(client, cfg.topics[key], M.state_payload(key, view), true)
  if not ok then
    return false, err
  end
  local attributes = attributes_for(key, view)
  if attributes then
    ok, err = publish_state(client, attribute_topic(cfg, key), M.json_encode(attributes), true)
    if not ok then
      return false, err
    end
  end
  return true
end

---Publishes the link plus every state and attribute topic. Availability is not
---part of this; the daemon publishes it before discovery and state.
---@param client table
---@param cfg table
---@param view table runtime view; nil values publish "unknown"
---@return boolean|nil ok
---@return string|nil err
function M.publish_all_state(client, cfg, view)
  view = view or {}
  local ok, err = M.publish_link(client, cfg, { link = "ONLINE" }, true)
  if not ok then
    return false, err
  end
  for _, key in ipairs(STATE_ORDER) do
    if key ~= "link" then
      ok, err = publish_key(client, cfg, view, key)
      if not ok then
        return false, err
      end
    end
  end
  return true
end

---Publishes only the topics for dirty keys. Attributes ride along with their
---state topic.
---@param client table
---@param cfg table
---@param view table runtime view
---@param changed table dirty-key set keyed by the same names as STATE_ORDER
---@return boolean|nil ok
---@return string|nil err
function M.publish_changed(client, cfg, view, changed)
  view = view or {}
  changed = changed or {}
  for _, key in ipairs(STATE_ORDER) do
    if changed[key] then
      local ok, err = publish_key(client, cfg, view, key)
      if not ok then
        return false, err
      end
    end
  end
  return true
end

---v1 is telemetry-only, so no command is ever actionable.
---@param _cfg table
---@param _topic string|nil
---@param _payload string|nil
---@return nil
function M.parse_command(_cfg, _topic, _payload)
  return nil
end

return M
