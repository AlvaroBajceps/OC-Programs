-- HA identity (node/base topic, device, origin, unique ids) is shared verbatim
-- with laptop_reborn so both programs appear as the same device in Home
-- Assistant.
local M = {}

M.VERSION = "1.2.3"

local TOPIC_KEYS = {
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

local ATTRIBUTE_KEYS = {
  "power_net",
  "edge_time",
  "status",
}

local function make_defaults(address)
  local sanitized = tostring(address or ""):gsub("[^%w]", ""):lower()
  local node = "oc_" .. sanitized:sub(1, 8)
  local base_topic = "gtnh/laptop/" .. node

  local topics = {}
  for _, key in ipairs(TOPIC_KEYS) do
    topics[key] = base_topic .. "/" .. key .. "/state"
  end

  local attributes = {}
  for _, key in ipairs(ATTRIBUTE_KEYS) do
    attributes[key] = base_topic .. "/" .. key .. "/attributes"
  end

  return {
    VERSION = M.VERSION,
    node = node,
    base_topic = base_topic,
    availability = base_topic .. "/availability",
    discovery_prefix = "homeassistant",
    topics = topics,
    attributes = attributes,
    device = {
      identifiers = { node },
      name = "GTNH Laptop " .. node,
      manufacturer = "oc_gtnh",
      model = "Laptop Reborn",
      sw_version = M.VERSION,
    },
    origin = {
      name = "laptop_reborn",
      sw_version = M.VERSION,
    },
    BROKER_HOST = "172.16.69.4",
    BROKER_PORT = 1883,
    USERNAME = "",
    PASSWORD = "",
    KEEP_ALIVE = 30,
    RECONNECT = 5,
    STATE_INTERVAL = 30,
    MQTT_RETRY = 10,
    MQTT_CONNECT_TIMEOUT = 30,
    MQTT_ACK_TIMEOUT = 75,
    MQTT_DOWNLOAD_TIMEOUT = 30,
    MQTT_DIR = "/lib/mqtt",
    POLL_INTERVAL = 1.0,
    LOOP_INTERVAL = 0.4,
    UI_TICK = 2,
    SCALE = "1x",
    RES_DEFAULT = { 34, 12 },
    RES_MAX = { 80, 25 },
    THEME = "dark",
    ENABLE_MQTT = true,
    ENABLE_REDSTONE = true,
    REDSTONE_BATTERY_SIDE = "east",
    REDSTONE_LOAD_PLUS_SIDE = "up",
    REDSTONE_LOAD_MINUS_SIDE = "west",
    DEV_LAPOTRON = "",
    DEV_REDSTONE = "",
    CONFIG_PATH = "/etc/laptop_reborn.config.lua",
  }
end

---@param address string
---@param overrides table|nil
---@return table
function M.build(address, overrides)
  local cfg = make_defaults(address)
  overrides = overrides or {}
  for key, value in pairs(overrides) do
    cfg[key] = value
  end
  return cfg
end

---@param path string
---@param deps table|nil
---@return table|nil, string|nil
function M.load_override(path, deps)
  deps = deps or {}

  local fs = deps.filesystem
  if fs and type(fs.exists) == "function" then
    local ok_exists, exists = pcall(fs.exists, path)
    if not ok_exists or not exists then
      return nil
    end
  end

  local loader = deps.loadfile or loadfile
  if type(loader) ~= "function" then
    return nil, "no loader available"
  end

  local ok_load, chunk, load_err = pcall(loader, path)
  if not ok_load then
    return nil, tostring(chunk)
  end
  if not chunk then
    return nil, tostring(load_err)
  end

  local ok_run, result = pcall(chunk)
  if not ok_run then
    return nil, tostring(result)
  end
  if type(result) ~= "table" then
    return nil, "override did not return a table"
  end

  return result
end

return M
