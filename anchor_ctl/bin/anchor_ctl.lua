-- Headless MQTT / Home Assistant daemon for a GregTech world anchor and
-- Computronics drawer. No display access: rc.d starts it before the shell and
-- all state goes to Home Assistant.

local M = {}

M.VERSION = "1.0.0"

---@param info table|nil
---@return string|nil
function M.process_identity(info)
  if type(info) ~= "table" then
    return nil
  end
  if info.command == "lua" then
    return nil
  end
  local command = info.command
  local path = info.path
  if command == nil and path == nil then
    return nil
  end
  return tostring(command or "") .. "\0" .. tostring(path or "")
end

---@param process table|nil
---@param current thread
---@return boolean
function M.has_running_instance(process, current)
  if not process or not process.list or not process.info then
    return false
  end
  local ok, this = pcall(process.info, current)
  if not ok or not this then
    return false
  end
  local this_id = M.process_identity(this)
  if not this_id then
    return false
  end
  for thread in pairs(process.list) do
    if thread ~= current then
      local info_ok, info = pcall(process.info, thread)
      if info_ok and info and M.process_identity(info) == this_id then
        return true
      end
    end
  end
  return false
end

---@param cfg table
---@param io table
---@param os table
---@param filesystem table
---@return fun(level: string, message: string)
local function make_logger(cfg, io, os, filesystem)
  local path = cfg.LOG_FILE

  local size_ok, size = pcall(filesystem.size, path)
  if size_ok and type(size) == "number" and size > cfg.LOG_MAX_BYTES then
    pcall(function()
      local file = io.open(path, "w")
      if file then
        file:close()
      end
    end)
  end

  local writes = 0
  return function(level, message)
    local stamp = "?"
    if type(os.date) == "function" then
      local date_ok, value = pcall(os.date, "%Y-%m-%d %H:%M:%S")
      if date_ok and value then
        stamp = value
      end
    end
    local line = string.format("%s [%s] %s\n", stamp, tostring(level), tostring(message))
    pcall(function()
      local file = io.open(path, "a")
      if file then
        file:write(line)
        file:close()
      end
    end)
    pcall(io.write, line)
    writes = writes + 1
    if writes % 64 == 0 then
      local check_ok, check_size = pcall(filesystem.size, path)
      if check_ok and type(check_size) == "number" and check_size > cfg.LOG_MAX_BYTES then
        pcall(function()
          local file = io.open(path, "w")
          if file then
            file:close()
          end
        end)
      end
    end
  end
end

---@param deps table|nil
---@return nil
function M.main(deps)
  deps = deps or {}

  package.path = "/lib/?.lua;/lib/?/init.lua;./?.lua;./?/init.lua;" .. package.path

  local computer = deps.computer or require("computer")
  local event = deps.event or require("event")
  local component = deps.component or require("component")
  local io = deps.io or io
  local os_mod = deps.os or os
  local now = deps.now or function()
    return computer.uptime()
  end
  local sleep = deps.sleep or rawget(os_mod, "sleep") or function() end

  local process_ok, process = pcall(require, "process")
  if deps.process then
    process_ok = true
    process = deps.process
  end

  if process_ok and M.has_running_instance(process, coroutine.running()) then
    pcall(io.write, "anchor_ctl is already running; refusing to start a second instance\n")
    return
  end

  local cfg = require("anchor_ctl.config")(computer, deps.config)

  local log = deps.log
  if not log then
    local filesystem = deps.filesystem or require("filesystem")
    log = make_logger(cfg, io, os_mod, filesystem)
  end

  local state = require("anchor_ctl.state")({ io = deps.io, os = deps.os })
  local anchor = require("anchor_ctl.anchor")(component, cfg)
  local drawer = require("anchor_ctl.drawer")(component, cfg)
  local redstone = require("anchor_ctl.redstone")(component, cfg)
  local controller = require("anchor_ctl.controller")({
    cfg = cfg,
    anchor = anchor,
    drawer = drawer,
    redstone = redstone,
    state = state,
    now = now,
    log = log,
  })
  controller.boot()

  local ha = require("anchor_ctl.ha")(cfg)
  local mqtt_boot = require("anchor_ctl.mqtt_boot")

  local stop_requested = false
  local owner_thread = coroutine.running()
  local function owner_alive()
    if not process_ok or not process or not process.list then
      return true
    end
    return process.list[owner_thread] ~= nil
  end

  local on_interrupted, on_shutdown
  local function request_stop()
    if not owner_alive() then
      pcall(event.ignore, "interrupted", on_interrupted)
      pcall(event.ignore, "shutdown", on_shutdown)
      return
    end
    stop_requested = true
  end
  on_interrupted = function()
    request_stop()
  end
  on_shutdown = function()
    request_stop()
  end
  event.listen("interrupted", on_interrupted)
  event.listen("shutdown", on_shutdown)

  local client
  local loop
  local tick
  local connected = false
  local last_state = now()
  local stopping = false

  local function clear_changed()
    for key in pairs(controller.changed) do
      controller.changed[key] = nil
    end
  end

  local function finish()
    if stopping then
      return
    end
    stopping = true
    if client and connected then
      pcall(ha.publish_link, client, cfg, false)
      pcall(ha.publish_availability, client, cfg, false)
      pcall(function()
        client:disconnect()
      end)
      connected = false
    end
    if loop then
      pcall(function()
        loop:remove(tick)
      end)
      pcall(function()
        loop:remove(client)
      end)
    end
  end

  local connector = deps.connector
  if not connector then
    connector = mqtt_boot.create_connector({
      internet = deps.internet,
      buffer = deps.buffer,
      now = now,
      sleep = sleep,
      should_stop = function()
        return stop_requested
      end,
    })
  end

  local function run_session(mqtt)
    stopping = false
    local client_args = {
      uri = cfg.BROKER_HOST .. ":" .. cfg.BROKER_PORT,
      id = cfg.node,
      clean = true,
      version = mqtt.v311,
      keep_alive = cfg.KEEP_ALIVE,
      reconnect = cfg.RECONNECT,
      will = {
        topic = cfg.availability,
        payload = "offline",
        qos = 1,
        retain = true,
      },
      connector = connector,
    }
    if cfg.USERNAME ~= "" then
      client_args.username = cfg.USERNAME
      client_args.password = cfg.PASSWORD
    end

    client = mqtt.client(client_args)
    client:on({
      connect = function(connack)
        if connack.rc ~= 0 then
          log("error", "CONNACK " .. tostring(connack.rc))
          return
        end
        connected = true
        log("info", "mqtt connected: " .. client_args.uri)

        local ok, err = ha.publish_availability(client, cfg, true)
        if not ok then
          log("error", "availability publish failed: " .. tostring(err))
        end
        ok, err = ha.publish_discovery(client, cfg)
        if not ok then
          log("error", "discovery publish failed: " .. tostring(err))
        end
        local state_ok, state_err = ha.publish_all_state(client, cfg, controller.view())
        if not state_ok then
          log("error", "state publish failed: " .. tostring(state_err))
        end
        ok, err = client:subscribe({ topic = cfg.base_topic .. "/+/set", qos = 1 })
        if not ok then
          log("error", "subscribe failed: " .. tostring(err))
        end
        if state_ok then
          clear_changed()
        end
        last_state = now()
      end,
      message = function(msg)
        client:acknowledge(msg)
        if msg.retain then
          log("info", "ignored retained command on " .. tostring(msg.topic))
          return
        end
        local command = ha.parse_command(cfg, msg.topic, msg.payload)
        if not command then
          log("warn", "unexpected topic: " .. tostring(msg.topic))
          return
        end
        local ok, err = controller.command(command.name, command.value)
        if not ok then
          log("warn", "command failed: " .. tostring(err))
          return
        end
        if command.name == "boot_mode" then
          local published, publish_err = ha.publish_changed(client, cfg, controller.view(), { boot_mode = true })
          if not published then
            log("error", "boot mode publish failed: " .. tostring(publish_err))
          else
            controller.changed.boot_mode = nil
          end
        end
      end,
      close = function(conn)
        connected = false
        local reason = conn and conn.close_reason and tostring(conn.close_reason) or "closed"
        log("info", "mqtt link down: " .. reason)
        pcall(ha.publish_link, client, cfg, false)
      end,
      error = function(err)
        log("error", "mqtt error: " .. tostring(err))
      end,
    })

    loop = mqtt.get_ioloop(true, mqtt_boot.ioloop_options())
    loop:add(client)

    tick = function()
      if stop_requested then
        finish()
        return
      end
      controller.tick(now())
      local view = controller.view()
      local ok, err = ha.publish_changed(client, cfg, view, controller.changed)
      if not ok then
        log("error", "state publish failed: " .. tostring(err))
      else
        clear_changed()
      end
      local at = now()
      if at - last_state >= cfg.STATE_INTERVAL then
        last_state = at
        pcall(ha.publish_all_state, client, cfg, view)
      end
    end
    loop:add(tick)

    loop:run_until_clients()
    finish()
  end

  local ensure_mqtt = deps.ensure_mqtt
  if not ensure_mqtt then
    ensure_mqtt = function(target_cfg)
      return mqtt_boot.ensure_luamqtt(target_cfg, {
        internet = deps.internet,
        filesystem = deps.filesystem,
        io = deps.io,
        os = deps.os,
        log = log,
      })
    end
  end

  while not stop_requested do
    local mqtt = deps.mqtt
    local err = nil
    if not mqtt then
      local ensured, result, ensure_err = pcall(ensure_mqtt, cfg)
      if ensured then
        mqtt = result
        err = ensure_err
      else
        err = result
      end
    end
    if not mqtt then
      log("error", "luamqtt unavailable: " .. tostring(err))
      sleep(cfg.MQTT_RETRY)
    else
      local ok, session_err = pcall(run_session, mqtt)
      if not ok then
        log("error", "mqtt session failed: " .. tostring(session_err))
        finish()
      end
      if not stop_requested then
        sleep(cfg.MQTT_RETRY)
      end
    end
  end

  pcall(event.ignore, "interrupted", on_interrupted)
  pcall(event.ignore, "shutdown", on_shutdown)
end

-- selene: allow(global_usage)
if rawget(_G, "ANCHOR_CTL_NO_AUTORUN") ~= true then
  M.main()
end

return M
