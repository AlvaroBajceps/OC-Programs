--AlvaroBajceps 2026
local version = "2.4.0"

local _lap = require("ab_lapotron")
local _kfc = require("ab_kalman")
local _component = require("component")
local _computer = require("computer")
local _term = require("term")
local _ev = require("event")
local _io = require("io")
local _serialization = require("serialization")
local _shell = require("shell")
local _th = require("thread")
local _os = require("os")
local _sides = require("sides")
local _config = require("laptop.config")
local _model = require("laptop.model")
local _telemetry = require("laptop.telemetry")

local RES_LAPTOP = { 34, 12 }

local config = {
  ---@type string
  dev_lapotron = "",
  ---@type string
  dev_redstone = "",
  ---@type boolean
  mqtt_enable = true,
  ---@type string
  mqtt_host = "172.16.69.4",
  ---@type number
  mqtt_port = 1883,
  ---@type string
  mqtt_username = "",
  ---@type string
  mqtt_password = "",
}

local redshow_th = nil
local shared = {
  lbat_notok = false,
  ---@type LapotronReader
  lbat = nil,
  ---@type ComponentRedstone
  reddev = nil,
  ---@type KalmanFilter
  lbat_kf = nil,
}

---@param resolution table?
local function setResolution(resolution)
  if resolution ~= nil then
    _component.gpu.setResolution(table.unpack(resolution))
    return
  end
  _component.gpu.setResolution(_component.gpu.maxResolution())
end

local function onDevAdd(_self, _, uuid, type)
  if type ~= "screen" then
    return
  end
  _component.gpu.bind(uuid, true)
  setResolution(RES_LAPTOP)
end

---seconds to full or empty
---@param lbat LapotronReader
---@param bat_kf KalmanFilter
local function secondToEdge(lbat, bat_kf)
  local eu_filled = lbat.cache.stored
  local eu_empty = lbat.cache.capacityTotal - eu_filled
  local net_instant = (lbat.cache.powerAvgIn_5s - lbat.cache.powerAvgOut_5s)

  local net_kf = bat_kf:update(net_instant) * 20

  local readout
  if net_instant > 8 then
    readout = eu_empty / net_kf
  elseif net_instant < -8 then
    readout = eu_filled / net_kf
  else
    readout = 0
  end

  return readout
end

local function statusFromSeconds(sec, percent)
  local preText
  if sec > 1 then
    preText = "Filled in: "
  elseif sec < -1 then
    preText = "Empty in: "
  elseif percent < 5 or percent > 95 then
    return "Too cringed to say"
  else
    return "I don't care so you can too"
  end

  sec = math.abs(sec)

  if sec < 180 then
    return string.format(preText .. "%.2f seconds", sec)
  elseif sec < 3600 then
    return string.format(preText .. "%.0f:%02.0f minutes", math.floor(sec / 60), sec % 60)
  elseif sec < 86400 then
    return string.format(preText .. "%.0f:%02.0f hours", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
  elseif sec < 8553600 then
    return string.format(preText .. "%.2f days", sec / 86400)
  else
    return "Too long to show"
  end
end

---@param validator fun(uuid: string): boolean function that validates device
---@return string? uuid of selected device or nil
local function selectDevice(validator)
  local possibleDevices = {}
  for k in _component.list() do
    if validator(k) then
      table.insert(possibleDevices, k)
    end
  end

  if #possibleDevices == 0 then
    return nil
  end

  if #possibleDevices == 1 then
    return possibleDevices[1]
  end

  ---@type number?
  local input

  while true do
    _term.clear()
    for k, v in ipairs(possibleDevices) do
      print(k .. ". " .. v)
    end
    print("\nSelect device (0 to quit):")
    input = tonumber(_io.read())

    if input ~= nil and input > 0 and input <= #possibleDevices then
      break
    end
  end

  if input == 0 then
    return nil
  end

  return possibleDevices[input]
end

---@param cfg any
---@param path string
local function save_config(cfg, path)
  local f, msg = _io.open(path, "w")
  if not f then
    print("Error while saving config: " .. msg)
    return
  end
  f:write(_serialization.serialize(cfg, true))
  f:close()
end

local function read_config(cfg, path)
  local f, msg = _io.open(path, "r")
  if not f then
    print("Error while reading config: " .. msg)
    return
  end
  local new_config = _serialization.unserialize(f:read("a"))
  f:close()

  for k, _ in pairs(cfg) do
    if new_config[k] ~= nil then
      cfg[k] = new_config[k]
    end
  end
end

local function init_lbat(dev_uuid)
  if not _lap.isDeviceValid(dev_uuid) then
    dev_uuid = selectDevice(_lap.isDeviceValid)
  end

  if not dev_uuid then
    print("No valid lapotron capacitor selected!")
    return nil
  end

  return dev_uuid
end

local function init_reddev(dev_uuid, force_red)
  local function isDeviceValid(uuid)
    checkArg(1, uuid, "string")

    local dev_uuid_full = _component.get(uuid)

    if not dev_uuid_full or dev_uuid_full == "" then
      return false, ("No device found with UUID '" .. dev_uuid .. "'")
    end

    local dev_proxy = _component.proxy(dev_uuid_full)
    ---@diagnostic disable-next-line: cast-type-mismatch
    ---@cast dev_proxy ComponentRedstone

    if not dev_proxy.setOutput then
      return false, ("Device '" .. dev_uuid_full .. "' does not have `setOutput()` Probably not redstone component...")
    end

    return true
  end

  if not isDeviceValid(dev_uuid) and force_red then
    dev_uuid = selectDevice(isDeviceValid)
  end

  if not dev_uuid or dev_uuid == "" then
    if force_red then
      print("No valid redstone component!")
    end
    return nil
  end

  return dev_uuid
end

local function init_shared_from_config(redstone_required)
  if not config.dev_lapotron then
    _os.exit(-1)
  end

  local msg
  shared.lbat, msg = _lap.new(config.dev_lapotron)
  if not shared.lbat then
    print(msg)
    _os.exit(-1)
  end

  if not config.dev_redstone then
    if redstone_required then
      print("Redstone not set but required.")
      _os.exit(-1)
    end
    print("No redstone component in use.")
    return
  end

  ---@diagnostic disable-next-line: param-type-mismatch
  shared.reddev = _component.proxy(_component.get(config.dev_redstone))
  if not shared.reddev then
    print("No redstone component in use.")
  end
end

local function minmax(value, min, max)
  if value < min then
    return min
  end
  if value > max then
    return max
  end
  return value
end

local function shallow_copy(source)
  local copy = {}
  if type(source) == "table" then
    for key, value in pairs(source) do
      copy[key] = value
    end
  end
  return copy
end

local function redthread()
  local bat_side = _sides.east

  local load_side_plus = _sides.up
  local load_side_minus = _sides.west

  local ticks = 0

  while true do
    ticks = ticks + 1
    local ticks_mod = (ticks % 2)
    local bat_bars = math.floor(shared.lbat.cache.capacityUsed / 11)

    local in_out = shared.lbat.cache.powerAvgIn_5s - shared.lbat.cache.powerAvgOut_5s

    local iv_voltage_bars = minmax((in_out / (8 * (4 ^ 5))), -4, 3)
    local luv_voltage_bars = minmax((in_out / (8 * (4 ^ 6))), -4, 4)
    local zpm_voltage_bars = minmax((in_out / (8 * (4 ^ 7))), -4, 5)
    local load_bars = math.modf(iv_voltage_bars + luv_voltage_bars + zpm_voltage_bars)

    if in_out > 0 then
      bat_bars = bat_bars + (ticks % 2)
    else
      if bat_bars == 0 then
        bat_bars = (ticks % 8 < 2) and 1 or 0
      end
    end
    if math.abs(load_bars) >= 12 then
      load_bars = load_bars * ticks_mod
    end

    if load_bars > 0 then
      shared.reddev.setOutput(load_side_plus, load_bars)
      shared.reddev.setOutput(load_side_minus, 0)
    else
      shared.reddev.setOutput(load_side_plus, 0)
      shared.reddev.setOutput(load_side_minus, -load_bars)
    end
    shared.reddev.setOutput(bat_side, bat_bars)

    os.sleep(0.4)
  end
end

--
-- MAIN
--
local function main(...)
  local args, opts = _shell.parse(...)

  if opts.h or opts.help then
    print("Laptop v." .. version)
    print("-h, --help\tshow help")
    print("-r, --redstone\tforce redstone output")
    print("-R, --no-redstone\tforce redstone output")
    print("-S, --reset-cfg\tcreate fresh config")
    print("-s, --save-cfg\tsave config from runtime")
    print("-c, --config=[path]\tuse config at path")
    print("-V, --virtual\tvirtual lapotron device for testing")
    print("-M, --no-mqtt\tdisable MQTT/Home Assistant telemetry")
    return
  end

  if opts["virtual"] then
    opts.V = true
  end
  if opts["reset-cfg"] then
    opts.S = true
  end
  if opts["save-cfg"] then
    opts.s = true
  end
  if opts["redstone"] then
    opts.r = true
  end
  if opts["no-redstone"] then
    opts.R = true
  end
  if opts["no-mqtt"] then
    opts.M = true
  end

  if opts.S and opts.s then
    print("Cannot reset and save from runtime at same time!")
    return
  end

  if opts.c and opts.config then
    print("Duplicate config path option.")
    return
  end

  opts.config = opts.config or args.c or "/home/laptop.cfg"

  if opts.S then
    print("Reset config...")
    save_config(config, opts.config)
    return
  end

  ---init settings

  if opts.config and not opts.s then
    print("Read config...")
    read_config(config, opts.config)
  end

  if opts.V then
    config.dev_lapotron = "v_lapotron"
  end

  if opts.M then
    config.mqtt_enable = false
  end

  config.dev_lapotron = init_lbat(config.dev_lapotron)
  config.dev_redstone = init_reddev(config.dev_redstone, opts.r)

  if opts.R then
    print("Redstone is disabled")
    config.dev_redstone = nil
  end

  init_shared_from_config(opts.r)
  shared.lbat_kf = _kfc.new(1, 1000, 0)

  local address = "unknown"
  if type(_computer.address) == "function" then
    local ok, value = pcall(_computer.address)
    if ok and value ~= nil then
      address = value
    end
  end

  local ha_cfg = _config.build(address)
  ha_cfg.ENABLE_MQTT = config.mqtt_enable
  ha_cfg.BROKER_HOST = config.mqtt_host
  ha_cfg.BROKER_PORT = config.mqtt_port
  ha_cfg.USERNAME = config.mqtt_username
  ha_cfg.PASSWORD = config.mqtt_password

  if opts.s then
    print("Save config (from runtime)...")
    save_config(config, opts.config)
    return
  end

  _os.sleep(0.2)

  local fg_color = _component.gpu.getForeground()
  setResolution(RES_LAPTOP)

  _ev.listen("component_added", onDevAdd)

  if not shared.lbat then
    return -1
  end

  local status_avg = 0

  local model_state = _model.new()
  local session = {
    view = nil,
    pending = {},
    rediscover = false,
    stop = false,
    connected = false,
    link = "OFF",
    last_error = nil,
  }
  local lapotron_online = false

  local function pull_lapotron()
    if shared.lbat then
      local ok, status = pcall(shared.lbat.pull, shared.lbat, true)
      lapotron_online = ok and status == 0
    end
  end

  local function update_view()
    if lapotron_online then
      session.view = _model.update(model_state, shared.lbat.cache)
    else
      session.view = _model.record_offline(model_state)
    end
    session.view.link = session.link
    session.view.redstone_enabled = shared.reddev ~= nil
    session.view.mqtt_error = session.last_error
  end

  pull_lapotron()
  update_view()

  local lbat_refresh = function()
    pull_lapotron()
  end
  local lbat_refresh_handle = _ev.timer(1.0, lbat_refresh, math.huge)

  local mqtt_handle = nil
  if ha_cfg.ENABLE_MQTT then
    local created, thread_handle = pcall(_th.create, function()
      local ok, err = pcall(_telemetry.supervise_mqtt, ha_cfg, session, { computer = _computer, log = function() end })
      if not ok then
        session.link = "FAULT"
        session.last_error = "thread: " .. tostring(err)
      end
    end)
    if created and thread_handle ~= nil then
      mqtt_handle = thread_handle
    else
      session.link = "FAULT"
      session.last_error = "thread: " .. tostring(created and "no handle" or thread_handle)
    end
  else
    session.link = "DISABLED"
  end

  redshow_th = _th.create(redthread)

  local previous = nil
  while not _ev.pull(1, "interrupt") do
    update_view()

    if ha_cfg.ENABLE_MQTT and session.connected and session.view ~= nil then
      local dirty = _telemetry.dirty_keys(previous, session.view)
      for key in pairs(dirty) do
        session.pending[key] = true
      end
    end
    previous = shallow_copy(session.view)

    status_avg = secondToEdge(shared.lbat, shared.lbat_kf)
    local status_avg_str = statusFromSeconds(status_avg, shared.lbat.cache.capacityUsed)

    _term.clear()

    print("###   LAPTOP   ###")

    if not shared.lbat_notok then
      print("\nCharge: " .. shared.lbat.cache.capacityUsed .. "%")
      print("In: " .. shared.lbat.cache.powerAvgIn_5s .. "EU/t")
      print("Out: " .. shared.lbat.cache.powerAvgOut_5s .. "EU/t")
      print("Net: " .. shared.lbat.cache.powerAvgIn_5s - shared.lbat.cache.powerAvgOut_5s .. "EU/t")
      print("\nINST " .. shared.lbat.cache.energyStatusText)
      print("AVG  " .. status_avg_str)

      if shared.lbat.cache.maintenanceStatus then
        _component.gpu.setForeground(0xFF0000)
        print("\nMaintenance: fix my ass!")
        _component.gpu.setForeground(fg_color)
      else
        print("\nMaintenance: no problemo!")
      end
    else
      print("\nLapotron offline")
    end

    print("MQTT: " .. session.link)
  end

  session.stop = true
  if mqtt_handle ~= nil then
    local waited, all_done = pcall(_th.waitForAll, { mqtt_handle }, 2)
    local still_running = true
    if type(mqtt_handle.status) == "function" then
      local status_ok, status = pcall(mqtt_handle.status, mqtt_handle)
      still_running = not (status_ok and status == "dead")
    else
      still_running = not (waited and all_done)
    end
    if still_running then
      pcall(mqtt_handle.kill, mqtt_handle)
    end
  end

  redshow_th:kill()
  if shared.reddev then
    for side = 0, 5 do
      shared.reddev.setOutput(side, 0)
    end
  end

  _ev.ignore("component_added", onDevAdd)
  _ev.cancel(lbat_refresh_handle)
  _term.clear()
  setResolution()
  shared.lbat:dispose()
end

local M = { main = main }
-- selene: allow(global_usage)
if rawget(_G, "LAPTOP_NO_AUTORUN") ~= true then
  -- selene: allow(undefined_variable)
  return M.main({ ... })
end
return M
