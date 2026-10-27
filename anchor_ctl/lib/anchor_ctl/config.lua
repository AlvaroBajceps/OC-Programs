-- Editable deployment constants.
local DEPLOYMENT = {
  DIMENSION_ID = 0,
  DIMENSION_NAME = "Overworld",
  CHUNKS_CHUNKLOADED = 0,
}

local BROKER_HOST = "172.16.69.4"
local BROKER_PORT = 1883
local USERNAME = ""
local PASSWORD = ""

local DISCOVERY_PREFIX = "homeassistant"
local KEEP_ALIVE = 30
local STATE_INTERVAL = 30
local RECONNECT = 5
local POLL_INTERVAL = 5
local COMMAND_SETTLE = 0.4
local MISMATCH_TIMEOUT = 10
local MQTT_RETRY = 10
local MQTT_DIR = "/lib/mqtt"

local STATE_FILE = "/etc/anchor_ctl.state"
local LOG_FILE = "/etc/anchor_ctl.log"
local LOG_MAX_BYTES = 65536

-- Redstone wiring: sides are 0 = bottom, 1 = top. LOW (0) = chunkloading ON,
-- HIGH (15) = disabled.
local REDSTONE_SIDES = { 0, 1 }
-- nil prefers an external component (Redstone I/O block, slot -1) over the
-- in-case card; set an address to pin one when several are connected.
local REDSTONE_ADDRESS = nil
local ENABLED_LEVEL = 0
local DISABLED_LEVEL = 15

local BOOT_MODE = "keep_state"
local KEEP_STATE_FALLBACK_ENABLED = true

local ANCHOR_ADDRESS = nil
local DRAWER_ADDRESS = nil
local DRAWER_SLOT = 1

local PEARL_ITEM_NAMES = {
  ["item.enderPearl"] = true,
  ["minecraft:ender_pearl"] = true,
}

local DEVICE_NAME = "Chunk Anchor"
local VERSION = "1.1.0"

---@param computer table
---@param overrides table|nil
---@return table
local function build(computer, overrides)
  overrides = overrides or {}
  local raw_address = tostring(computer.address())
  local address = raw_address:gsub("[^%w]", ""):lower()

  local cfg = {}
  cfg.address = address
  cfg.node = "oc_" .. address:sub(1, 8)
  cfg.base_topic = "gtnh/anchor/" .. cfg.node
  local base = cfg.base_topic

  cfg.discovery_prefix = DISCOVERY_PREFIX
  cfg.availability = base .. "/availability"
  cfg.link_state = base .. "/link/state"
  cfg.chunk_command = base .. "/chunkloading/set"
  cfg.chunk_state = base .. "/chunkloading/state"
  cfg.boot_command = base .. "/boot_mode/set"
  cfg.boot_state = base .. "/boot_mode/state"
  cfg.pearls_state = base .. "/ender_pearls/state"
  cfg.pearls_attributes = base .. "/ender_pearls/attributes"
  cfg.fuel_state = base .. "/anchor_fuel/state"
  cfg.fuel_attributes = base .. "/anchor_fuel/attributes"
  cfg.problem_state = base .. "/problem/state"
  cfg.problem_attributes = base .. "/problem/attributes"
  cfg.deployment_state = base .. "/deployment/state"
  cfg.deployment_attributes = base .. "/deployment/attributes"

  cfg.DEPLOYMENT = DEPLOYMENT
  cfg.BROKER_HOST = BROKER_HOST
  cfg.BROKER_PORT = BROKER_PORT
  cfg.USERNAME = USERNAME
  cfg.PASSWORD = PASSWORD
  cfg.KEEP_ALIVE = KEEP_ALIVE
  cfg.STATE_INTERVAL = STATE_INTERVAL
  cfg.RECONNECT = RECONNECT
  cfg.POLL_INTERVAL = POLL_INTERVAL
  cfg.COMMAND_SETTLE = COMMAND_SETTLE
  cfg.MISMATCH_TIMEOUT = MISMATCH_TIMEOUT
  cfg.MQTT_RETRY = MQTT_RETRY
  cfg.MQTT_DIR = MQTT_DIR
  cfg.STATE_FILE = STATE_FILE
  cfg.LOG_FILE = LOG_FILE
  cfg.LOG_MAX_BYTES = LOG_MAX_BYTES
  cfg.REDSTONE_SIDES = REDSTONE_SIDES
  cfg.REDSTONE_ADDRESS = REDSTONE_ADDRESS
  cfg.ENABLED_LEVEL = ENABLED_LEVEL
  cfg.DISABLED_LEVEL = DISABLED_LEVEL
  cfg.BOOT_MODE = BOOT_MODE
  cfg.KEEP_STATE_FALLBACK_ENABLED = KEEP_STATE_FALLBACK_ENABLED
  cfg.ANCHOR_ADDRESS = ANCHOR_ADDRESS
  cfg.DRAWER_ADDRESS = DRAWER_ADDRESS
  cfg.DRAWER_SLOT = DRAWER_SLOT
  cfg.PEARL_ITEM_NAMES = PEARL_ITEM_NAMES
  cfg.DEVICE_NAME = DEVICE_NAME
  cfg.VERSION = VERSION

  cfg.broker = cfg.BROKER_HOST
  cfg.port = cfg.BROKER_PORT
  cfg.username = cfg.USERNAME
  cfg.password = cfg.PASSWORD
  cfg.client_id = cfg.node

  for key, value in pairs(overrides) do
    cfg[key] = value
  end

  if overrides.REDSTONE_SIDES == nil and overrides.REDSTONE_SIDE ~= nil then
    cfg.REDSTONE_SIDES = { overrides.REDSTONE_SIDE }
  end
  if type(cfg.REDSTONE_SIDES) == "number" then
    cfg.REDSTONE_SIDES = { cfg.REDSTONE_SIDES }
  end
  if type(cfg.REDSTONE_SIDES) ~= "table" or #cfg.REDSTONE_SIDES == 0 then
    cfg.REDSTONE_SIDES = { 0 }
  end

  -- Merge rather than replace so an override may change one constant only.
  local deployment = {}
  for key, value in pairs(DEPLOYMENT) do
    deployment[key] = value
  end
  if type(overrides.DEPLOYMENT) == "table" then
    for key, value in pairs(overrides.DEPLOYMENT) do
      deployment[key] = value
    end
  end
  cfg.DEPLOYMENT = deployment

  -- Derived fields must reflect the effective deployment, so build them last.
  if overrides.deployment_name == nil then
    cfg.deployment_name = tostring(cfg.DEPLOYMENT.DIMENSION_NAME)
  end

  if overrides.device == nil then
    cfg.device = {
      identifiers = { cfg.node },
      name = cfg.DEVICE_NAME .. " " .. cfg.deployment_name,
      manufacturer = "OpenComputers / GTNH",
      model = "World Anchor Controller",
      sw_version = cfg.VERSION,
    }
  end
  if overrides.origin == nil then
    cfg.origin = {
      name = "oc_gtnh anchor_ctl",
      sw_version = cfg.VERSION,
    }
  end

  if overrides.broker == nil then
    cfg.broker = cfg.BROKER_HOST
  end
  if overrides.port == nil then
    cfg.port = cfg.BROKER_PORT
  end
  if overrides.username == nil then
    cfg.username = cfg.USERNAME
  end
  if overrides.password == nil then
    cfg.password = cfg.PASSWORD
  end
  if overrides.client_id == nil then
    cfg.client_id = cfg.node
  end

  return cfg
end

return build
