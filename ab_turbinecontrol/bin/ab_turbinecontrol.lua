-- ab_turbinecontrol.lua
-- Headless turbine controller for redstone_bridge + MQTT/Home Assistant.
-- No GUI, no display access. Intended to be started in the background by rc.d.
--
-- Sides assume the redbridge microcontroller faces south:
--   front=south, back=north, left=east, right=west
--   Red=5 (east), Lime=2 (north), Light Blue=1 (top), Yellow=4 (west)
--
-- The bridge is listed once at startup, then the daemon only reacts to its
-- "changed" broadcasts. MQTT runs in its own OpenOS thread.

local M = {}

M.VERSION = "0.2.0"
M.CONFIG_PATH = "/etc/ab_turbinecontrol.config.lua"

package.path = "/usr/lib/?.lua;/usr/lib/?/init.lua;"
  .. "/lib/?.lua;/lib/?/init.lua;./?.lua;./?/init.lua;"
  .. package.path

local json = require("ab_json")

local DISCOVERY_PORT = 99
local SERVICE_PORT = 100

local SIG = {
  estop = 7, -- grey, EStop request pulse
  estop_request = 7, -- grey, latched request / critical fault
  estop_status = 14, -- red, current status: ON = stopped
  reset = 9, -- cyan, reset pulse
  down_flow = 1, -- orange
  down_boost = 2, -- magenta
  down_maint = 0, -- white
  up_flow = 3, -- light blue
  up_boost = 4, -- yellow
  up_maint = 15, -- black
}

local SET_LAYOUT = {
  { number = 1, title = "RED", side = 5 },
  { number = 2, title = "LIME", side = 2 },
  { number = 3, title = "LIGHT BLUE", side = 1 },
  { number = 4, title = "YELLOW", side = 4 },
}

local DEFAULTS = {
  BROKER_HOST = "172.16.69.4",
  BROKER_PORT = 1883,
  USERNAME = "",
  PASSWORD = "",
  DISCOVERY_PREFIX = "homeassistant",
  BASE_TOPIC = "gtnh/turbines",
  DEVICE_NAME = "GTNH Turbines",
  NODE_SUFFIX = "_turbines",
  KEEP_ALIVE = 30,
  STATE_INTERVAL = 30,
  PUBLISH_INTERVAL = 0.5,
  -- Each MQTT socket call is a synchronized component call that suspends the
  -- whole Lua VM for a server tick. Poll slowly and spread retained publishes
  -- so redstone events and interrupts are not queued behind socket traffic.
  IOLOOP_TIMEOUT = 0.5,
  IOLOOP_SLEEP = 0.5,
  PUBLISH_BATCH = 2,
  RESYNC_INTERVAL = 3,
  MQTT_RETRY = 10,
  MQTT_CONNECT_TIMEOUT = 30,
  PULSE_SECONDS = 0.2,
  FULL_POWER = 255,
  ENABLE_MQTT = true,
  LOG_FILE = "/etc/ab_turbinecontrol.log",
  LOG_MAX_BYTES = 65536,
}

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------
local function sanitize(value)
  return tostring(value or ""):gsub("[^%w]", ""):lower()
end

local function load_config_overrides(deps)
  deps = deps or {}
  local filesystem = deps.filesystem or require("filesystem")
  local path = deps.path or M.CONFIG_PATH

  local exists_ok, exists = pcall(filesystem.exists, path)
  if not exists_ok or not exists then
    return nil, nil
  end

  local loader = deps.loadfile or loadfile
  local chunk, load_err = loader(path)
  if not chunk then
    return nil, "cannot load " .. path .. ": " .. tostring(load_err)
  end

  local ok, value = pcall(chunk)
  if not ok then
    return nil, "error in " .. path .. ": " .. tostring(value)
  end
  if type(value) ~= "table" then
    return nil, path .. " must return a table"
  end
  return value, nil
end

local function build_config(computer, overrides)
  overrides = overrides or {}

  local cfg = {}
  for key, value in pairs(DEFAULTS) do
    cfg[key] = value
  end
  for key, value in pairs(overrides) do
    cfg[key] = value
  end

  local address = sanitize(computer.address())
  local node_suffix = overrides.NODE_SUFFIX or cfg.NODE_SUFFIX or "_turbines"
  cfg.node = "oc_" .. address:sub(1, 8) .. node_suffix
  if overrides.node ~= nil then
    cfg.node = tostring(overrides.node)
  end

  cfg.base_topic = cfg.BASE_TOPIC .. "/" .. cfg.node
  cfg.availability = cfg.base_topic .. "/availability"
  cfg.link_state = cfg.base_topic .. "/link/state"
  cfg.client_id = cfg.node
  cfg.discovery_prefix = overrides.discovery_prefix or cfg.DISCOVERY_PREFIX or "homeassistant"

  cfg.sets = {}
  for _, layout in ipairs(SET_LAYOUT) do
    local set = {}
    for key, value in pairs(layout) do
      set[key] = value
    end
    local prefix = cfg.base_topic .. "/turbine_" .. set.number
    set.command_topic = prefix .. "/set"
    set.state_topic = prefix .. "/state"
    set.estop_topic = prefix .. "/estop/state"
    set.bank_up_topic = prefix .. "/bank_up/state"
    set.bank_down_topic = prefix .. "/bank_down/state"
    cfg.sets[#cfg.sets + 1] = set
  end

  if overrides.device == nil then
    cfg.device = {
      identifiers = { cfg.node },
      name = cfg.DEVICE_NAME,
      manufacturer = "OpenComputers / GTNH",
      model = "Turbine Redstone Bridge",
      sw_version = M.VERSION,
    }
  end
  if overrides.origin == nil then
    cfg.origin = {
      name = "ab_turbinecontrol",
      sw_version = M.VERSION,
    }
  end

  return cfg
end

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------
local function make_logger(cfg, io, os_module, filesystem)
  local writes = 0

  local function truncate()
    local ok, size = pcall(filesystem.size, cfg.LOG_FILE)
    if ok and type(size) == "number" and size > cfg.LOG_MAX_BYTES then
      local file = io.open(cfg.LOG_FILE, "w")
      if file then
        file:close()
      end
    end
  end

  local function log(level, message)
    local stamp = "?"
    if type(os_module.date) == "function" then
      local ok, value = pcall(os_module.date, "%Y-%m-%d %H:%M:%S")
      if ok and value then
        stamp = value
      end
    end

    local line = string.format("%s [%s] %s\n", stamp, tostring(level), tostring(message))

    local ok, file = pcall(io.open, cfg.LOG_FILE, "a")
    if ok and file then
      pcall(file.write, file, line)
      pcall(file.close, file)
    end

    writes = writes + 1
    if writes % 64 == 0 then
      truncate()
    end
  end

  truncate()
  return log
end

-- ---------------------------------------------------------------------------
-- Home Assistant discovery
-- ---------------------------------------------------------------------------
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
  for key, value in pairs(fields or {}) do
    payload[key] = value
  end
  return payload
end

local function make_entries(cfg, specs)
  local entries = {}
  for _, spec in ipairs(specs) do
    entries[#entries + 1] = {
      component = spec.component,
      object_id = spec.object_id or (cfg.node .. "_" .. spec.suffix),
      payload = discovery_payload(cfg, spec.component, spec.suffix, spec.fields),
    }
  end
  return entries
end

local BANK_OPTIONS = { "Nominal", "Fault", "Overflow", "Idle", "Unknown" }

local function discovery_entries(cfg)
  local specs = {}

  for _, set in ipairs(cfg.sets) do
    local number = set.number
    local suffix = "turbine_" .. number

    specs[#specs + 1] = {
      component = "switch",
      suffix = suffix,
      fields = {
        name = "Turbine " .. number .. " " .. set.title,
        icon = "mdi:wind-turbine",
        command_topic = set.command_topic,
        state_topic = set.state_topic,
        payload_on = "ON",
        payload_off = "OFF",
        state_on = "ON",
        state_off = "OFF",
        optimistic = false,
        retain = false,
      },
    }

    specs[#specs + 1] = {
      component = "binary_sensor",
      suffix = suffix .. "_estop",
      fields = {
        name = "Turbine " .. number .. " EStop",
        device_class = "problem",
        entity_category = "diagnostic",
        icon = "mdi:alert-octagon",
        state_topic = set.estop_topic,
        payload_on = "ON",
        payload_off = "OFF",
      },
    }

    specs[#specs + 1] = {
      component = "sensor",
      suffix = suffix .. "_bank_up",
      fields = {
        name = "Turbine " .. number .. " Bank Up",
        device_class = "enum",
        options = BANK_OPTIONS,
        icon = "mdi:arrow-up-bold",
        state_topic = set.bank_up_topic,
      },
    }

    specs[#specs + 1] = {
      component = "sensor",
      suffix = suffix .. "_bank_down",
      fields = {
        name = "Turbine " .. number .. " Bank Down",
        device_class = "enum",
        options = BANK_OPTIONS,
        icon = "mdi:arrow-down-bold",
        state_topic = set.bank_down_topic,
      },
    }
  end

  specs[#specs + 1] = {
    component = "binary_sensor",
    suffix = "link",
    fields = {
      name = "Broker Link",
      device_class = "connectivity",
      entity_category = "diagnostic",
      icon = "mdi:lan-connect",
      state_topic = cfg.link_state,
      payload_on = "ONLINE",
      payload_off = "OFFLINE",
    },
  }

  return make_entries(cfg, specs)
end

local function publish_discovery(client, cfg, entries)
  for _, entry in ipairs(entries) do
    local topic = cfg.discovery_prefix .. "/" .. entry.component .. "/" .. entry.object_id .. "/config"
    local ok, err = client:publish({
      topic = topic,
      payload = json.encode(entry.payload),
      qos = 1,
      retain = true,
    })
    if not ok then
      return false, err
    end
  end
  return true
end

local function publish_state(client, topic, payload, retain)
  if retain == nil then
    retain = true
  end
  return client:publish({
    topic = topic,
    payload = tostring(payload),
    qos = 1,
    retain = retain,
  })
end

local function publish_availability(client, cfg, online)
  return publish_state(client, cfg.availability, online and "online" or "offline", true)
end

local function publish_link(client, cfg, online)
  return publish_state(client, cfg.link_state, online and "ONLINE" or "OFFLINE", true)
end

-- ---------------------------------------------------------------------------
-- Turbine state
-- ---------------------------------------------------------------------------
local function bank_state(flow, boost, maintenance)
  if maintenance then
    return "Fault"
  elseif boost then
    return "Overflow"
  elseif flow then
    return "Nominal"
  end
  return "Idle"
end

local function high(raw, color)
  return (raw[color] or 0) > 0
end

local function recompute_set(state, side)
  local raw = state.raw[side] or {}
  local view = state.sets[side] or {}
  local known = state.raw_known[side] == true

  view.known = known
  view.stopped = known and high(raw, SIG.estop_status)
  view.estop = known and high(raw, SIG.estop_request)
  view.bank_up = known and bank_state(high(raw, SIG.up_flow), high(raw, SIG.up_boost), high(raw, SIG.up_maint))
    or "Unknown"
  view.bank_down = known and bank_state(high(raw, SIG.down_flow), high(raw, SIG.down_boost), high(raw, SIG.down_maint))
    or "Unknown"

  state.sets[side] = view
end

local function build_state_payloads(cfg, state)
  local payloads = {}
  payloads[cfg.link_state] = state.link == "ONLINE" and "ONLINE" or "OFFLINE"

  for _, set in ipairs(cfg.sets) do
    local view = state.sets[set.side] or {}
    if view.known then
      payloads[set.state_topic] = view.stopped and "OFF" or "ON"
      payloads[set.estop_topic] = view.estop and "ON" or "OFF"
      payloads[set.bank_up_topic] = view.bank_up or "Unknown"
      payloads[set.bank_down_topic] = view.bank_down or "Unknown"
    else
      payloads[set.state_topic] = "unknown"
      payloads[set.estop_topic] = "unknown"
      payloads[set.bank_up_topic] = "Unknown"
      payloads[set.bank_down_topic] = "Unknown"
    end
  end

  return payloads
end

-- ---------------------------------------------------------------------------
-- redstone_bridge client
-- ---------------------------------------------------------------------------
local function parse_snapshot(csv)
  local values = {}
  for pair in tostring(csv or ""):gmatch("[^,]+") do
    local color, value = pair:match("^(%d+)=(%d+)$")
    if color then
      values[tonumber(color)] = tonumber(value)
    end
  end
  return values
end

local SIDE_NUM = {
  bottom = 0,
  top = 1,
  back = 2,
  front = 3,
  right = 4,
  left = 5,
}

local function parse_list(payload)
  local snapshots = {}
  for entry in tostring(payload or ""):gmatch("[^|]+") do
    local name, csv = entry:match("^([^:]+):(.*)$")
    local side = name and SIDE_NUM[name]
    if side then
      snapshots[side] = parse_snapshot(csv)
    end
  end
  return snapshots
end

local function discover_bridge(modem, timeout)
  local computer = require("computer")
  local event = require("event")
  local found
  local fallback

  local function on_message(_, _local_addr, from, port, _distance, cmd, name)
    if port == DISCOVERY_PORT and cmd == "iam" then
      if name == "rsbridge" then
        found = { address = from, name = name }
      else
        fallback = fallback or { address = from, name = name }
      end
    end
  end

  event.listen("modem_message", on_message)
  modem.broadcast(DISCOVERY_PORT, "discover")

  local deadline = computer.uptime() + (timeout or 3)
  while found == nil and computer.uptime() < deadline do
    os.sleep(0.05)
  end

  event.ignore("modem_message", on_message)

  if found then
    return found.address, found.name
  end
  if fallback then
    return fallback.address, fallback.name
  end
  return nil
end

local function list_snapshot(modem, bridge, timeout)
  local computer = require("computer")
  local event = require("event")
  local result

  local function on_message(_, _local_addr, from, port, _distance, cmd, payload)
    if from == bridge and port == SERVICE_PORT then
      if cmd == "list" then
        result = parse_list(payload)
      elseif cmd == "error" then
        result = false
      end
    end
  end

  event.listen("modem_message", on_message)
  modem.send(bridge, SERVICE_PORT, "list")

  local deadline = computer.uptime() + (timeout or 1)
  while result == nil and computer.uptime() < deadline do
    os.sleep(0.05)
  end

  event.ignore("modem_message", on_message)

  if result then
    return result
  end
  return nil
end

local function list_once(modem, bridge, state, timeout)
  local snapshots = list_snapshot(modem, bridge, timeout or 1.0)
  if not snapshots then
    return false
  end

  for side, snapshot in pairs(snapshots) do
    state.raw[side] = snapshot
    state.raw_known[side] = true
    recompute_set(state, side)
  end

  return true
end

local function apply_changed(state, side, color, value)
  if type(side) ~= "number" or type(color) ~= "number" then
    return false
  end
  if color < 0 or color > 15 then
    return false
  end

  local raw = state.raw[side]
  if raw == nil then
    raw = {}
    state.raw[side] = raw
  end
  raw[color] = tonumber(value) or 0
  state.raw_known[side] = true
  recompute_set(state, side)
  return true
end

local function pulse(modem, bridge, side, color, cfg, log)
  local sent, err = modem.send(bridge, SERVICE_PORT, "write", side, color, cfg.FULL_POWER)
  if not sent then
    log("error", "write pulse failed: " .. tostring(err))
    return false
  end

  os.sleep(cfg.PULSE_SECONDS)

  sent, err = modem.send(bridge, SERVICE_PORT, "write", side, color, 0)
  if not sent then
    log("error", "write pulse release failed: " .. tostring(err))
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- MQTT
-- ---------------------------------------------------------------------------
local function parse_command(cfg, topic, payload)
  local text = tostring(payload or ""):gsub("%s+$", "")
  local clean_topic = tostring(topic or ""):gsub("%s+$", "")

  for _, set in ipairs(cfg.sets) do
    if clean_topic == set.command_topic then
      if text == "ON" then
        return { number = set.number, action = "ON" }
      elseif text == "OFF" then
        return { number = set.number, action = "OFF" }
      end
    end
  end

  return nil
end

local function run_mqtt_session(cfg, state, log)
  local mqtt = require("ab_luamqtt")
  local ioloop = require("ab_luamqtt.ioloop")
  local connector = require("ab_luamqtt.luasocket_oc")
  local computer = require("computer")

  local args = {
    uri = cfg.BROKER_HOST .. ":" .. cfg.BROKER_PORT,
    id = cfg.client_id,
    clean = true,
    version = mqtt.v311,
    keep_alive = cfg.KEEP_ALIVE,
    will = {
      topic = cfg.availability,
      payload = "offline",
      qos = 1,
      retain = true,
    },
    connector = connector,
  }
  if cfg.USERNAME ~= nil and cfg.USERNAME ~= "" then
    args.username = cfg.USERNAME
    args.password = cfg.PASSWORD
  end

  local client = mqtt.client(args)
  local loop = ioloop.create({
    timeout = tonumber(cfg.IOLOOP_TIMEOUT) or 0.5,
    sleep = tonumber(cfg.IOLOOP_SLEEP) or 0.5,
    sleep_function = os.sleep,
  })

  local tick
  local torn_down = false
  local connected = false
  local last = {}
  local pending_topics = {}
  local pending_set = {}
  local latest_payloads = {}
  local session_started = computer.uptime()
  local last_all = session_started
  local last_diff = session_started
  local publish_batch = math.max(1, tonumber(cfg.PUBLISH_BATCH) or 2)

  local function enqueue_states(payloads, all)
    latest_payloads = payloads
    for topic, payload in pairs(payloads) do
      if all then
        last[topic] = nil
      end
      if (all or last[topic] ~= payload) and not pending_set[topic] then
        pending_topics[#pending_topics + 1] = topic
        pending_set[topic] = true
      end
    end
  end

  local function flush_states(limit)
    local published = 0
    while published < limit and #pending_topics > 0 do
      local topic = table.remove(pending_topics, 1)
      pending_set[topic] = nil
      local payload = latest_payloads[topic]
      if payload ~= nil and last[topic] ~= payload then
        local ok, err = publish_state(client, topic, payload, true)
        if not ok then
          last[topic] = nil
          return false, err
        end
        last[topic] = payload
        state.publishes = state.publishes + 1
        published = published + 1
      end
    end
    state.pending_count = #pending_topics
    return true
  end

  local function teardown()
    if torn_down then
      return
    end
    torn_down = true
    local was_connected = connected
    connected = false
    state.connected = false
    if tick ~= nil then
      pcall(loop.remove, loop, tick)
      tick = nil
    end
    pcall(loop.remove, loop, client)
    loop.running = false
    if was_connected then
      pcall(client.disconnect, client)
    end
    pcall(client.close_connection, client, "session closed")
  end

  client:on({
    connect = function(connack)
      if connack.rc ~= 0 then
        state.link = "OFFLINE"
        state.last_error = "CONNACK " .. tostring(connack.rc)
        log("error", "MQTT connect refused: " .. state.last_error)
        teardown()
        return
      end

      connected = true
      state.connected = true
      state.link = "ONLINE"
      state.last_error = nil
      log("info", "MQTT connected")

      local ok, err = publish_availability(client, cfg, true)
      if not ok then
        log("error", "availability publish failed: " .. tostring(err))
      end

      ok, err = publish_discovery(client, cfg, discovery_entries(cfg))
      if not ok then
        log("error", "discovery publish failed: " .. tostring(err))
      end

      enqueue_states(build_state_payloads(cfg, state), true)

      for _, set in ipairs(cfg.sets) do
        local sub_ok, sub_err = client:subscribe({
          topic = set.command_topic,
          qos = 1,
        })
        if not sub_ok then
          log("error", "subscribe " .. set.command_topic .. " failed: " .. tostring(sub_err))
        end
      end

      last_all = computer.uptime()
      last_diff = last_all
    end,

    acknowledge = function()
      -- QoS 1 publish acknowledgement; nothing else to do.
    end,

    message = function(message)
      pcall(client.acknowledge, client, message)
      local command = parse_command(cfg, message.topic, message.payload)
      if command then
        computer.pushSignal("ab_turbinecontrol_command", command.number, command.action)
      end
    end,

    close = function(conn)
      state.connected = false
      state.link = "OFFLINE"
      connected = false
      local reason = conn and conn.close_reason and tostring(conn.close_reason) or nil
      if reason ~= nil and reason ~= "" then
        state.last_error = "closed: " .. reason
        log("warn", "MQTT link down: " .. reason)
      end
      pcall(publish_link, client, cfg, false)
      pcall(publish_availability, client, cfg, false)
      teardown()
    end,

    error = function(err)
      state.connected = false
      state.link = "OFFLINE"
      connected = false
      state.last_error = tostring(err)
      log("error", "MQTT error: " .. tostring(err))
      teardown()
    end,
  })

  loop:add(client)

  tick = function()
    local now = computer.uptime()

    if state.stop then
      if connected then
        pcall(publish_link, client, cfg, false)
        pcall(publish_availability, client, cfg, false)
      end
      teardown()
      return
    end

    if not connected then
      if now - session_started >= cfg.MQTT_CONNECT_TIMEOUT then
        state.link = "OFFLINE"
        state.last_error = "connect timeout"
        log("warn", "MQTT connect timeout")
        teardown()
      end
      return
    end

    local payloads = build_state_payloads(cfg, state)
    latest_payloads = payloads
    if now - last_all >= cfg.STATE_INTERVAL then
      last_all = now
      last_diff = now
      enqueue_states(payloads, true)
    elseif now - last_diff >= cfg.PUBLISH_INTERVAL then
      last_diff = now
      enqueue_states(payloads, false)
    end

    local ok, err = flush_states(publish_batch)
    if not ok then
      log("error", "state publish failed: " .. tostring(err))
    end
  end

  loop:add(tick)

  local started, err = client:start_connecting()
  if not started then
    teardown()
    return false, err
  end

  loop:run_until_clients()
  teardown()
  return true
end

local function supervise_mqtt(cfg, state, log)
  while not state.stop do
    local called, ok, err = pcall(run_mqtt_session, cfg, state, log)
    if not called then
      state.connected = false
      state.link = "OFFLINE"
      log("error", "MQTT session crashed: " .. tostring(ok))
    elseif not ok then
      state.connected = false
      state.link = "OFFLINE"
      log("warn", "MQTT session failed: " .. tostring(err))
    end

    if not state.stop then
      local remaining = cfg.MQTT_RETRY
      while remaining > 0 and not state.stop do
        local slice = math.min(0.5, remaining)
        os.sleep(slice)
        remaining = remaining - slice
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------
function M.main(deps)
  deps = deps or {}

  local component = deps.component or require("component")
  local computer = deps.computer or require("computer")
  local event = deps.event or require("event")
  local filesystem = deps.filesystem or require("filesystem")
  local thread = deps.thread or require("thread")
  local process = deps.process or require("process")
  local io_module = deps.io or io
  local os_module = deps.os or os

  local overrides, override_err = load_config_overrides({
    filesystem = filesystem,
    loadfile = deps.loadfile,
    path = deps.config_path,
  })
  local cfg = build_config(computer, overrides)
  local log = make_logger(cfg, io_module, os_module, filesystem)

  if override_err then
    log("error", override_err)
  end
  log("info", "starting ab_turbinecontrol " .. M.VERSION .. " node=" .. cfg.node)

  local shared = package.loaded["ab_turbinecontrol.shared"]
  if shared == nil then
    shared = {}
    package.loaded["ab_turbinecontrol.shared"] = shared
  end
  local instance = process.findProcess()
  local previous_instance = shared.instance
  if previous_instance ~= nil and previous_instance ~= instance then
    local running = false
    for _, entry in pairs(process.list) do
      if entry == previous_instance then
        running = true
        break
      end
    end
    if running then
      log("warn", "another instance is already running; exiting")
      return
    end
  end
  shared.instance = instance
  local function release_instance()
    if shared.instance == instance then
      shared.instance = nil
    end
  end

  local state = {
    stop = false,
    connected = false,
    link = "OFFLINE",
    last_error = nil,
    sets = {},
    raw = {},
    raw_known = {},
    commands = {},
    needs_resync = false,
    changed_events = 0,
    resyncs = 0,
    publishes = 0,
    pending_count = 0,
  }
  for _, set in ipairs(cfg.sets) do
    state.sets[set.side] = {
      known = false,
      stopped = false,
      estop = false,
      bank_up = "Unknown",
      bank_down = "Unknown",
    }
    state.raw[set.side] = {}
    state.raw_known[set.side] = false
  end

  local modem_address = component.list("modem")()
  if not modem_address then
    log("error", "no modem / network card")
    release_instance()
    return
  end
  local modem = component.proxy(modem_address)
  modem.open(DISCOVERY_PORT)
  modem.open(SERVICE_PORT)

  local bridge
  local bridge_name
  while not state.stop do
    log("info", "looking for redstone_bridge on port " .. DISCOVERY_PORT)
    bridge, bridge_name = discover_bridge(modem, 3)
    if bridge then
      break
    end
    log("warn", "redstone_bridge not found; retrying")
    os_module.sleep(5)
  end

  if state.stop then
    pcall(modem.close, DISCOVERY_PORT)
    pcall(modem.close, SERVICE_PORT)
    release_instance()
    return
  end

  pcall(modem.close, DISCOVERY_PORT)
  log("info", "bridge found: " .. tostring(bridge_name))

  list_once(modem, bridge, state)

  local known_sides = 0
  for _, set in ipairs(cfg.sets) do
    if state.sets[set.side].known then
      known_sides = known_sides + 1
    end
  end
  log("info", string.format("initial turbine state listed (%d/%d sides)", known_sides, #cfg.sets))

  local function on_modem_message(_, _local_addr, from, port, _distance, cmd, side, color, _old_value, new_value)
    if from == bridge and port == SERVICE_PORT and cmd == "changed" then
      state.changed_events = state.changed_events + 1
      if color == -1 then
        state.needs_resync = true
      else
        apply_changed(state, side, color, new_value)
      end
    end
  end

  local function on_command(_, number, action)
    if type(number) == "number" and (action == "ON" or action == "OFF") then
      state.commands[#state.commands + 1] = { number = number, action = action }
    end
  end

  local function run_command(command)
    for _, set in ipairs(cfg.sets) do
      if set.number == command.number then
        local view = state.sets[set.side] or {}
        if command.action == "ON" then
          if not view.known or view.stopped then
            pulse(modem, bridge, set.side, SIG.reset, cfg, log)
          end
        elseif command.action == "OFF" then
          if not view.known or not view.stopped then
            pulse(modem, bridge, set.side, SIG.estop, cfg, log)
          end
        end
        break
      end
    end
  end

  local stop_daemon
  stop_daemon = function()
    if state.stop then
      return
    end
    state.stop = true
    pcall(event.ignore, "modem_message", on_modem_message)
    pcall(event.ignore, "ab_turbinecontrol_command", on_command)
    pcall(event.ignore, "ab_turbinecontrol_stop", stop_daemon)
    pcall(event.ignore, "shutdown", stop_daemon)
    pcall(event.ignore, "interrupted", stop_daemon)
  end

  event.listen("modem_message", on_modem_message)
  event.listen("ab_turbinecontrol_command", on_command)
  event.listen("ab_turbinecontrol_stop", stop_daemon)
  event.listen("shutdown", stop_daemon)
  event.listen("interrupted", stop_daemon)

  local mqtt_handle
  if cfg.ENABLE_MQTT then
    local created, handle = pcall(thread.create, function()
      local ok, err = pcall(supervise_mqtt, cfg, state, log)
      if not ok then
        log("error", "MQTT thread crashed: " .. tostring(err))
      end
    end)
    if created then
      mqtt_handle = handle
    else
      log("error", "cannot start MQTT thread: " .. tostring(handle))
    end
  else
    state.link = "OFFLINE"
  end

  local last_resync = computer.uptime()
  local last_stats = last_resync
  local resync_interval = math.max(1, tonumber(cfg.RESYNC_INTERVAL) or 3)
  while not state.stop do
    os_module.sleep(0.5)

    if not state.stop then
      if #state.commands > 0 then
        run_command(table.remove(state.commands, 1))
      end

      local now = computer.uptime()
      if state.needs_resync or now - last_resync >= resync_interval then
        state.needs_resync = false
        last_resync = now
        if list_once(modem, bridge, state, 1.0) then
          state.resyncs = state.resyncs + 1
        end
      end

      if now - last_stats >= 30 then
        last_stats = now
        log(
          "info",
          string.format(
            "stats changed=%d resync=%d published=%d pending=%d mqtt=%s",
            state.changed_events,
            state.resyncs,
            state.publishes,
            state.pending_count,
            state.link
          )
        )
      end
    end
  end

  state.stop = true

  if mqtt_handle ~= nil then
    pcall(thread.waitForAll, { mqtt_handle }, 1)
    local status_ok, status = pcall(mqtt_handle.status, mqtt_handle)
    if not status_ok or status ~= "dead" then
      pcall(mqtt_handle.kill, mqtt_handle)
    end
  end

  pcall(modem.close, DISCOVERY_PORT)
  pcall(modem.close, SERVICE_PORT)
  release_instance()
  log("info", "stopped")
end

-- selene: allow(global_usage)
if rawget(_G, "AB_TURBINECONTROL_NO_AUTORUN") ~= true then
  -- selene: allow(undefined_variable)
  return M.main({ ... })
end

return M
