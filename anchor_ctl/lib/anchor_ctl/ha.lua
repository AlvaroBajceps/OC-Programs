---Home Assistant MQTT discovery, state publishing, and command parsing for the
---anchor_ctl daemon. Pure library: no component, event, or display access.
local M = {}

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

---@param value any
---@return string
function M.json_encode(value)
  local kind = type(value)
  if kind == "nil" then
    return "null"
  elseif kind == "boolean" then
    return value and "true" or "false"
  elseif kind == "number" then
    if value == math.floor(value) then
      return string.format("%d", value)
    end
    return string.format("%.14g", value)
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

---Maps a controller boolean to an HA payload. nil becomes the literal
---"unknown" so HA shows an unknown entity instead of a guessed state.
---@param value boolean|nil
---@return string
function M.payload(value)
  if value == nil then
    return "unknown"
  elseif value == true then
    return "ON"
  elseif value == false then
    return "OFF"
  end
  return tostring(value)
end

local function numeric_state(value)
  if value == nil then
    return "unknown"
  elseif type(value) == "number" then
    if value == math.floor(value) then
      return string.format("%d", value)
    end
    return string.format("%.14g", value)
  end
  return tostring(value)
end

local function text_state(value)
  if value == nil then
    return "unknown"
  end
  return tostring(value)
end

local function normalize_mode(value)
  if type(value) ~= "string" then
    return nil
  end
  local mode = value:gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if mode == "on" or mode == "off" or mode == "keep_state" then
    return mode
  end
  return nil
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

---Builds the eight discovery payloads in spec order.
---@param cfg table
---@return table[] entries `{component, object_id, payload}`
function M.discovery_entries(cfg)
  local node = cfg.node
  return {
    {
      component = "switch",
      object_id = node .. "_chunkloading",
      payload = discovery_payload(cfg, "switch", "chunkloading", {
        name = "Chunkloading",
        icon = "mdi:map-marker-radius",
        command_topic = cfg.chunk_command,
        state_topic = cfg.chunk_state,
        payload_on = "ON",
        payload_off = "OFF",
        state_on = "ON",
        state_off = "OFF",
        optimistic = false,
        -- HA must publish commands non-retained: a retained ON would re-enable
        -- chunkloading on every daemon reconnect.
        retain = false,
      }),
    },
    {
      component = "binary_sensor",
      object_id = node .. "_chunkloading_status",
      payload = discovery_payload(cfg, "binary_sensor", "chunkloading_status", {
        name = "Chunkloading Status",
        device_class = "running",
        state_topic = cfg.chunk_state,
        payload_on = "ON",
        payload_off = "OFF",
      }),
    },
    {
      component = "sensor",
      object_id = node .. "_ender_pearls",
      payload = discovery_payload(cfg, "sensor", "ender_pearls", {
        name = "Ender Pearls",
        unit_of_measurement = "pearls",
        state_class = "measurement",
        state_topic = cfg.pearls_state,
        json_attributes_topic = cfg.pearls_attributes,
        icon = "mdi:circle-multiple-outline",
      }),
    },
    {
      component = "select",
      object_id = node .. "_boot_mode",
      payload = discovery_payload(cfg, "select", "boot_mode", {
        name = "Boot Mode",
        command_topic = cfg.boot_command,
        state_topic = cfg.boot_state,
        options = { "on", "off", "keep_state" },
        entity_category = "config",
        icon = "mdi:restart",
        retain = false,
      }),
    },
    {
      component = "binary_sensor",
      object_id = node .. "_link",
      payload = discovery_payload(cfg, "binary_sensor", "link", {
        name = "Broker Link",
        device_class = "connectivity",
        entity_category = "diagnostic",
        state_topic = cfg.link_state,
        payload_on = "ONLINE",
        payload_off = "OFFLINE",
      }),
    },
    {
      component = "binary_sensor",
      object_id = node .. "_problem",
      payload = discovery_payload(cfg, "binary_sensor", "problem", {
        name = "Problem",
        device_class = "problem",
        entity_category = "diagnostic",
        state_topic = cfg.problem_state,
        json_attributes_topic = cfg.problem_attributes,
        payload_on = "ON",
        payload_off = "OFF",
      }),
    },
    {
      component = "sensor",
      object_id = node .. "_deployment",
      payload = discovery_payload(cfg, "sensor", "deployment", {
        name = "Deployment",
        state_topic = cfg.deployment_state,
        json_attributes_topic = cfg.deployment_attributes,
        icon = "mdi:map",
      }),
    },
    {
      component = "sensor",
      object_id = node .. "_anchor_fuel",
      payload = discovery_payload(cfg, "sensor", "anchor_fuel", {
        name = "Anchor Fuel",
        unit_of_measurement = "pearls",
        state_class = "measurement",
        entity_category = "diagnostic",
        state_topic = cfg.fuel_state,
        json_attributes_topic = cfg.fuel_attributes,
      }),
    },
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
---@param cfg table
---@param online boolean
---@return number|boolean|nil, string|nil
function M.publish_availability(client, cfg, online)
  return client:publish({
    topic = cfg.availability,
    payload = online and "online" or "offline",
    qos = 1,
    retain = true,
  })
end

---@param client table
---@param cfg table
---@param online boolean
---@return number|boolean|nil, string|nil
function M.publish_link(client, cfg, online)
  return client:publish({
    topic = cfg.link_state,
    payload = online and "ONLINE" or "OFFLINE",
    qos = 1,
    retain = true,
  })
end

---@param client table
---@param topic string
---@param payload string
---@return number|boolean|nil, string|nil
local function publish_state(client, topic, payload)
  return client:publish({ topic = topic, payload = payload, qos = 1, retain = true })
end

---Publishes the link plus every state and attribute topic. Availability is not
---part of this; the daemon publishes it before discovery and state.
---@param client table
---@param cfg table
---@param view table controller view; nil chunkloading/pearls/anchor_fuel publish "unknown"
---@return boolean|nil ok
---@return string|nil err
function M.publish_all_state(client, cfg, view)
  view = view or {}
  local ok, err = M.publish_link(client, cfg, true)
  if not ok then
    return false, err
  end
  ok, err = publish_state(client, cfg.chunk_state, M.payload(view.chunkloading))
  if not ok then
    return false, err
  end
  ok, err = publish_state(client, cfg.boot_state, text_state(view.boot_mode))
  if not ok then
    return false, err
  end
  ok, err = publish_state(client, cfg.pearls_state, numeric_state(view.pearls))
  if not ok then
    return false, err
  end
  ok, err = publish_state(client, cfg.pearls_attributes, M.json_encode(view.pearls_attributes or {}))
  if not ok then
    return false, err
  end
  ok, err = publish_state(client, cfg.fuel_state, numeric_state(view.anchor_fuel))
  if not ok then
    return false, err
  end
  ok, err = publish_state(client, cfg.fuel_attributes, M.json_encode(view.anchor_fuel_attributes or {}))
  if not ok then
    return false, err
  end
  ok, err = publish_state(client, cfg.problem_state, M.payload(view.problem))
  if not ok then
    return false, err
  end
  ok, err = publish_state(client, cfg.problem_attributes, M.json_encode(view.problem_attributes or {}))
  if not ok then
    return false, err
  end
  ok, err = publish_state(client, cfg.deployment_state, text_state(cfg.deployment_name))
  if not ok then
    return false, err
  end
  ok, err = publish_state(client, cfg.deployment_attributes, M.json_encode(view.deployment or {}))
  if not ok then
    return false, err
  end
  return true
end

---Publishes only the topics for dirty controller keys. Attributes ride along
---with their state topic; deployment is static but republished on change so a
---fresh connect/boot always carries it.
---@param client table
---@param cfg table
---@param view table controller view
---@param changed table dirty-key set (chunkloading, boot_mode, pearls, anchor_fuel, problem, deployment)
---@return boolean|nil ok
---@return string|nil err
function M.publish_changed(client, cfg, view, changed)
  view = view or {}
  changed = changed or {}
  local ok, err
  if changed.chunkloading then
    ok, err = publish_state(client, cfg.chunk_state, M.payload(view.chunkloading))
    if not ok then
      return false, err
    end
  end
  if changed.boot_mode then
    ok, err = publish_state(client, cfg.boot_state, text_state(view.boot_mode))
    if not ok then
      return false, err
    end
  end
  if changed.pearls then
    ok, err = publish_state(client, cfg.pearls_state, numeric_state(view.pearls))
    if not ok then
      return false, err
    end
    ok, err = publish_state(client, cfg.pearls_attributes, M.json_encode(view.pearls_attributes or {}))
    if not ok then
      return false, err
    end
  end
  if changed.anchor_fuel then
    ok, err = publish_state(client, cfg.fuel_state, numeric_state(view.anchor_fuel))
    if not ok then
      return false, err
    end
    ok, err = publish_state(client, cfg.fuel_attributes, M.json_encode(view.anchor_fuel_attributes or {}))
    if not ok then
      return false, err
    end
  end
  if changed.problem then
    ok, err = publish_state(client, cfg.problem_state, M.payload(view.problem))
    if not ok then
      return false, err
    end
    ok, err = publish_state(client, cfg.problem_attributes, M.json_encode(view.problem_attributes or {}))
    if not ok then
      return false, err
    end
  end
  if changed.deployment then
    ok, err = publish_state(client, cfg.deployment_state, text_state(cfg.deployment_name))
    if not ok then
      return false, err
    end
    ok, err = publish_state(client, cfg.deployment_attributes, M.json_encode(view.deployment or {}))
    if not ok then
      return false, err
    end
  end
  return true
end

---Only exact topic matches count. The switch stays case-sensitive ON/OFF
---(HA sends exactly those); boot modes are trimmed and case-insensitive.
---@param cfg table
---@param topic string|nil
---@param payload string|nil
---@return table|nil command `{name, value}` or nil when unrecognized
function M.parse_command(cfg, topic, payload)
  local text = (payload or ""):gsub("%s+$", "")
  local clean_topic = (topic or ""):gsub("%s+$", "")
  if clean_topic == cfg.chunk_command then
    if text == "ON" then
      return { name = "chunkloading", value = true }
    elseif text == "OFF" then
      return { name = "chunkloading", value = false }
    end
  elseif clean_topic == cfg.boot_command then
    local mode = normalize_mode(text)
    if mode then
      return { name = "boot_mode", value = mode }
    end
  end
  return nil
end

---@param _cfg table anchor_ctl config: node, discovery_prefix, topic fields,
---availability, device, origin, deployment_name. Api functions take cfg
---explicitly, so the factory itself does not bind it.
---@return table api
return function(_cfg)
  local _ = _cfg
  return {
    json_encode = M.json_encode,
    payload = M.payload,
    discovery_entries = M.discovery_entries,
    publish_discovery = M.publish_discovery,
    publish_availability = M.publish_availability,
    publish_link = M.publish_link,
    publish_all_state = M.publish_all_state,
    publish_changed = M.publish_changed,
    parse_command = M.parse_command,
  }
end
