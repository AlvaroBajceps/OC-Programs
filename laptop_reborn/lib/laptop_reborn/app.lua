-- Orchestrates the lapotron reader, redstone mirror, MQTT telemetry thread, and
-- the graphical UI. Every external facility is injected so the loop is testable
-- without an OpenComputers runtime.

local methods = require("laptop_reborn.methods")

local M = {}

local DIFF_KEYS = {
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

local function shallow_copy(source)
  local copy = {}
  if type(source) == "table" then
    for key, value in pairs(source) do
      copy[key] = value
    end
  end
  return copy
end

local function process_identity(info)
  if type(info) ~= "table" then
    return nil
  end
  local command = info.command
  local path = info.path
  if command == nil and path == nil then
    return nil
  end
  return tostring(command or "") .. "\0" .. tostring(path or "")
end

local function is_laptop_process(info)
  if type(info) ~= "table" then
    return false
  end
  local command = tostring(info.command or "")
  local path = tostring(info.path or "")
  return command:find("laptop_reborn", 1, true) ~= nil or path:find("laptop_reborn", 1, true) ~= nil
end

---@param process table|nil
---@param current thread
---@return boolean
function M.has_running_instance(process, current)
  if type(process) ~= "table" then
    return false
  end
  if type(process.list) ~= "table" or type(process.info) ~= "function" then
    return false
  end

  local current_ok, current_info = pcall(process.info, current)
  local current_identity = current_ok and process_identity(current_info) or nil

  for thread in pairs(process.list) do
    if thread ~= current then
      local ok, info = pcall(process.info, thread)
      if ok and is_laptop_process(info) then
        if current_identity == nil or process_identity(info) == current_identity then
          return true
        end
      end
    end
  end
  return false
end

local function require_first(deps, key, module)
  if deps[key] ~= nil then
    return deps[key]
  end
  local ok, loaded = pcall(require, module)
  if ok then
    return loaded
  end
  return nil
end

local function make_reader(cfg, deps, component)
  local factory = deps.lapotron_factory
  if factory == nil then
    local adapter = deps.lapotron or require("laptop_reborn.lapotron")
    return adapter.open(cfg, {
      component = component or deps.component,
      legacy_factory = deps.legacy_lapotron_factory,
    })
  end
  if type(factory) == "table" and type(factory.new) == "function" then
    return factory.new(factory, cfg.DEV_LAPOTRON)
  end
  return factory(cfg.DEV_LAPOTRON)
end

local function resolve_redstone(cfg, deps, component)
  if deps.redstone_device ~= nil then
    return deps.redstone_device
  end
  if not component then
    return nil
  end
  local address = cfg.DEV_REDSTONE
  if address ~= nil and address ~= "" then
    local get_ok, full = pcall(component.get, address)
    if get_ok and full ~= nil and full ~= "" then
      local proxy_ok, proxy = pcall(component.proxy, full)
      if proxy_ok and methods.get(proxy, "setOutput") ~= nil then
        return proxy
      end
    end
    return nil
  end
  if methods.get(component.redstone, "setOutput") ~= nil then
    return component.redstone
  end
  return nil
end

local function resolve_model(deps)
  local model_module = deps.model or require("laptop_reborn.model")
  return model_module, model_module.new()
end

local function resolve_component(deps)
  local candidates = { deps.component, package.loaded.component }
  for _, candidate in ipairs(candidates) do
    if methods.get(candidate, "list") ~= nil then
      return candidate
    end
  end
  local ok, loaded = pcall(require, "component")
  if ok and type(loaded) == "table" then
    return loaded
  end
  for _, candidate in ipairs(candidates) do
    if type(candidate) == "table" then
      return candidate
    end
  end
  return nil
end

local function read_uptime(computer)
  local uptime = methods.get(computer, "uptime")
  if uptime ~= nil then
    local ok, value = pcall(uptime)
    if ok and type(value) == "number" then
      return value
    end
  end
  if type(os.time) == "function" then
    local ok, value = pcall(os.time)
    if ok and type(value) == "number" then
      return value
    end
  end
  return 0
end

---Compares the quantized MQTT payload of every entity key between two views,
---so sub-quantum drift does not queue a publish.
---@param previous table|nil
---@param view table|nil
---@param ha_module table|nil
---@return table dirty set keyed by entity key
function M.dirty_keys(previous, view, ha_module)
  local ha = ha_module or require("laptop_reborn.ha")
  local dirty = {}
  for _, key in ipairs(DIFF_KEYS) do
    if previous == nil or ha.state_payload(key, previous) ~= ha.state_payload(key, view) then
      dirty[key] = true
    end
  end
  return dirty
end

---@param cfg table
---@param session table
---@param deps table|nil
---@return nil
function M.run_mqtt_session(cfg, session, deps)
  deps = deps or {}
  local ha = deps.ha or require("laptop_reborn.ha")
  local boot = deps.mqtt_boot or require("laptop_reborn.mqtt_boot")
  local os_module = deps.os or os
  local sleep = deps.sleep or rawget(os_module, "sleep") or function() end
  local computer = deps.computer
  local connect_timeout = tonumber(cfg.MQTT_CONNECT_TIMEOUT) or 30
  local ack_timeout = tonumber(cfg.MQTT_ACK_TIMEOUT) or 75
  local log = deps.log or function(_) end

  local function stopped()
    return session.stop == true
  end

  local function uptime()
    return read_uptime(computer)
  end

  local function run_one(mqtt)
    local connector = deps.connector
    if connector == nil then
      connector = boot.create_connector({
        internet = deps.internet,
        buffer = deps.buffer,
        now = deps.now,
        sleep = sleep,
        should_stop = stopped,
      })
    end

    session.connected = false
    local started = uptime()
    session.reconnect_at = started
    session.ack_pending_since = nil

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
    if cfg.USERNAME ~= nil and cfg.USERNAME ~= "" then
      client_args.username = cfg.USERNAME
      client_args.password = cfg.PASSWORD
    end

    local client = mqtt.client(client_args)
    local loop
    local tick

    -- luamqtt keeps a client registered while reconnect is set, so even a
    -- graceful disconnect would be retried. Remove it from the loop as well.
    local function teardown()
      pcall(client.disconnect, client)
      pcall(client.close_connection, client, "session closed")
      if loop ~= nil then
        pcall(loop.remove, loop, tick)
        pcall(loop.remove, loop, client)
        loop.running = false
      end
      session.connected = false
    end

    client:on({
      connect = function(connack)
        if connack.rc ~= 0 then
          session.connected = false
          session.link = "FAULT"
          return
        end
        session.connected = true
        session.link = "ONLINE"
        session.ack_pending_since = uptime()
        session.reconnect_at = nil
        pcall(ha.publish_availability, client, cfg, true)
        pcall(ha.publish_discovery, client, cfg)
        pcall(ha.publish_all_state, client, cfg, session.view)
      end,
      acknowledge = function()
        session.ack_pending_since = nil
      end,
      message = function(message)
        client:acknowledge(message)
      end,
      close = function()
        session.connected = false
        session.ack_pending_since = nil
        session.reconnect_at = uptime()
        if session.link ~= "FAULT" then
          session.link = "RETRY"
        end
        pcall(ha.publish_link, client, cfg, session.view, false)
      end,
      error = function()
        session.connected = false
        session.ack_pending_since = nil
        session.link = "FAULT"
        session.reconnect_at = uptime()
      end,
    })

    if type(boot.create_ioloop) == "function" then
      loop = boot.create_ioloop(mqtt)
    else
      loop = mqtt.get_ioloop(true, boot.ioloop_options())
    end
    loop:add(client)

    local last_state = uptime()
    local pending_retry_at = 0
    tick = function()
      local at = uptime()
      if stopped() then
        pcall(ha.publish_link, client, cfg, session.view, false)
        pcall(ha.publish_availability, client, cfg, false)
        pcall(client.disconnect, client)
        session.connected = false
        pcall(loop.remove, loop, tick)
        pcall(loop.remove, loop, client)
        return
      end

      -- A silent half-open socket keeps luamqtt "connected" forever because it
      -- never times out a missing PINGRESP. QoS 1 publishes get a PUBACK, so a
      -- connected link with no acknowledgement for too long is dead.
      if session.connected then
        local pending_since = session.ack_pending_since
        if pending_since ~= nil and at - pending_since >= ack_timeout then
          session.link = "RETRY"
          teardown()
          return
        end
      elseif at - (session.reconnect_at or started) >= connect_timeout then
        session.link = "RETRY"
        teardown()
        return
      end

      if session.rediscover and session.connected then
        session.rediscover = false
        local called, published = pcall(ha.publish_discovery, client, cfg)
        if not (called and published) then
          session.rediscover = true
        end
      end

      if next(session.pending) ~= nil and at >= pending_retry_at then
        local batch = {}
        for key in pairs(session.pending) do
          batch[key] = true
        end
        if session.connected and session.ack_pending_since == nil then
          session.ack_pending_since = at
        end
        local called, published = pcall(ha.publish_changed, client, cfg, session.view, batch)
        if called and published then
          for key in pairs(batch) do
            session.pending[key] = nil
          end
        else
          pending_retry_at = at + 2
        end
      end

      if at - last_state >= cfg.STATE_INTERVAL then
        last_state = at
        if session.connected and session.ack_pending_since == nil then
          session.ack_pending_since = at
        end
        local called, published = pcall(ha.publish_all_state, client, cfg, session.view)
        if called and published then
          pcall(ha.publish_link, client, cfg, { link = "ONLINE" }, true)
        end
      end
    end
    loop:add(tick)

    local ran, loop_err = pcall(loop.run_until_clients, loop)
    teardown()
    if not ran then
      error(loop_err, 0)
    end
  end

  local last_ensure_err = nil
  while not stopped() do
    local mqtt = deps.mqtt
    if mqtt == nil then
      -- Show the bootstrap in the UI instead of leaving LINK OFF while the
      -- luamqtt download runs (or stalls) on a fresh computer.
      session.link = "RETRY"
      local ok, result, err = pcall(boot.ensure_luamqtt, cfg, {
        internet = deps.internet,
        filesystem = deps.filesystem,
        io = deps.io,
        os = deps.os,
        now = deps.now,
        sleep = sleep,
        download_timeout = cfg.MQTT_DOWNLOAD_TIMEOUT,
        log = log,
      })
      if ok then
        mqtt = result
        if mqtt ~= nil then
          last_ensure_err = nil
        end
      end
      if mqtt == nil then
        local message = ok and tostring(err) or tostring(result)
        if message ~= last_ensure_err then
          last_ensure_err = message
          log("luamqtt unavailable: " .. message)
        end
        session.link = "RETRY"
        if stopped() then
          return
        end
        sleep(cfg.MQTT_RETRY)
      end
    end

    if mqtt ~= nil and not stopped() then
      local ok, err = pcall(run_one, mqtt)
      if not ok then
        session.connected = false
        session.link = "RETRY"
        log("mqtt session failed: " .. tostring(err))
      end
      if not stopped() then
        sleep(cfg.MQTT_RETRY)
      end
    end
  end
end

---Runs the MQTT session until `session.stop`, restarting it after any error.
---Without this, an exception in the OpenOS thread wrapper calls `os.exit` and
---takes the whole dashboard down with it, so the only recovery would be a
---computer reboot.
---@param cfg table
---@param session table
---@param deps table|nil
---@return nil
function M.supervise_mqtt(cfg, session, deps)
  deps = deps or {}
  local os_module = deps.os or os
  local sleep = deps.sleep or rawget(os_module, "sleep") or function() end
  local retry = tonumber(cfg.MQTT_RETRY) or 10
  local run_session = deps.run_session or M.run_mqtt_session

  while session.stop ~= true do
    local ok = pcall(run_session, cfg, session, deps)
    if session.stop == true then
      return
    end
    if not ok then
      session.connected = false
      session.link = "RETRY"
    end

    -- Sleep in slices so a quit request does not wait for the full retry delay.
    local remaining = retry
    while session.stop ~= true and remaining > 0 do
      local slice = math.min(0.5, remaining)
      remaining = remaining - slice
      sleep(slice)
    end
  end
end

---@param cfg table
---@param deps table|nil
---@return number
function M.run(cfg, deps)
  deps = deps or {}

  local ha = deps.ha or require("laptop_reborn.ha")
  local io_module = deps.io or io
  local function say(text)
    pcall(io_module.write, tostring(text) .. "\n")
  end

  local computer = deps.computer or require("computer")
  local event = deps.event or require("event")
  local component = resolve_component(deps)
  local thread = deps.thread or require("thread")
  local process = require_first(deps, "process", "process")

  if M.has_running_instance(process, coroutine.running()) then
    say("laptop_reborn is already running; refusing to start a second instance")
    return 1
  end

  local reader
  local reader_ok, reader_result, reader_err = pcall(make_reader, cfg, deps, component)
  if reader_ok then
    reader = reader_result
  end
  if reader == nil then
    say(
      "laptop_reborn v"
        .. tostring(cfg.VERSION)
        .. ": no supported capacitor/energy storage: "
        .. tostring(reader_ok and reader_err or reader_result)
    )
    say("Run 'laptop_reborn --diag' to print component discovery details.")
    return 1
  end

  local redstone = deps.redstone or require("laptop_reborn.redstone")
  local reddev = nil
  if cfg.ENABLE_REDSTONE then
    local ok, device = pcall(resolve_redstone, cfg, deps, component)
    if ok then
      reddev = device
    end
  end

  local model_module, model = resolve_model(deps)
  local session = {
    view = nil,
    pending = {},
    rediscover = false,
    stop = false,
    connected = false,
    link = "OFF",
  }

  local now = deps.now or function()
    return read_uptime(computer)
  end
  local last_poll = -math.huge
  local function poll()
    local at = now()
    if at - last_poll < cfg.POLL_INTERVAL then
      return
    end
    last_poll = at
    local ok, status = pcall(reader.pull, reader, true)
    if ok and status == 0 then
      session.view = model_module.update(model, reader.cache)
    else
      session.view = model.record_offline(model)
    end
  end
  poll()

  local display = nil
  local ui = nil
  local gpu = nil

  local function init_display()
    local gpu_component = component and component.gpu
    if gpu_component == nil then
      return nil
    end

    local factory = deps.display_factory
    if factory == nil then
      local ok, module = pcall(require, "laptop_reborn.display")
      if not ok then
        return nil
      end
      factory = module.new
    end
    local display_ok, display_result = pcall(factory, { gpu = gpu_component })
    if not display_ok or display_result == nil then
      return nil
    end

    local layout = deps.layout or require("laptop_reborn.layout")
    local max_w, max_h = 80, 25
    local max_ok, measured_w, measured_h = pcall(gpu_component.maxResolution)
    if max_ok then
      max_w, max_h = measured_w, measured_h
    end
    local target_w, target_h = layout.pick(cfg.SCALE, max_w, max_h)
    pcall(display_result.set_resolution, display_result, target_w, target_h)

    local actual_w, actual_h = target_w, target_h
    local size_ok, sized_w, sized_h = pcall(display_result.size, display_result)
    if size_ok then
      actual_w, actual_h = sized_w, sized_h
    end

    local theme = deps.theme or require("laptop_reborn.theme")
    local palette = theme.PALETTES[cfg.THEME] or theme.PALETTES.dark

    local ui_factory = deps.ui_factory
    if ui_factory == nil then
      local ok, module = pcall(require, "laptop_reborn.ui")
      if not ok then
        pcall(display_result.free, display_result)
        return nil
      end
      ui_factory = module.new
    end
    local ui_ok, ui_result = pcall(ui_factory, display_result, {
      palette = palette,
      show_icons = true,
      version = cfg.VERSION,
    })
    if not ui_ok or ui_result == nil then
      pcall(display_result.free, display_result)
      return nil
    end

    return display_result, ui_result, gpu_component, actual_w, actual_h
  end

  local display_ok, display_result, ui_result, gpu_result = pcall(init_display)
  if display_ok and display_result ~= nil then
    display, ui, gpu = display_result, ui_result, gpu_result
  else
    say("laptop_reborn: no display/GPU; running headless")
  end

  local redstone_enabled = cfg.ENABLE_REDSTONE == true

  local function set_redstone(enabled)
    redstone_enabled = enabled
    if not enabled then
      pcall(redstone.zero, reddev, deps)
    end
  end

  local function handle_action(action)
    if action == "quit" then
      session.stop = true
    elseif action == "refresh" then
      session.rediscover = true
    elseif action == "redstone" then
      set_redstone(not redstone_enabled)
    end
  end

  local handle = nil
  if cfg.ENABLE_MQTT then
    local mqtt_deps = shallow_copy(deps)
    mqtt_deps.computer = computer
    mqtt_deps.now = now
    mqtt_deps.log = say
    local created, thread_handle = pcall(thread.create, function()
      local ok, err = pcall(M.supervise_mqtt, cfg, session, mqtt_deps)
      if not ok then
        session.link = "FAULT"
        say("laptop_reborn: MQTT thread failed: " .. tostring(err))
      end
    end)
    if created then
      handle = thread_handle
    else
      session.link = "FAULT"
      say("laptop_reborn: MQTT thread could not start: " .. tostring(thread_handle))
    end
  else
    session.link = "OFF"
    say("laptop_reborn: MQTT disabled by ENABLE_MQTT=false or -M")
  end

  local previous = nil
  local function queue_changes()
    if cfg.ENABLE_MQTT and session.connected and session.view ~= nil then
      local dirty = M.dirty_keys(previous, session.view, ha)
      for key in pairs(dirty) do
        session.pending[key] = true
      end
    end
    previous = shallow_copy(session.view)
  end

  local function screen_alive()
    if display == nil then
      return false
    end
    if gpu == nil then
      return false
    end
    if methods.get(gpu, "getScreen") ~= nil then
      local ok, address = methods.call(gpu, "getScreen")
      if not ok then
        return false
      end
      return address ~= nil and address ~= ""
    end
    return true
  end

  local function maybe_rebind()
    if display ~= nil and screen_alive() then
      return
    end
    local had_display = display ~= nil
    if display ~= nil then
      pcall(display.free, display)
      if ui ~= nil then
        if type(ui.close) == "function" then
          pcall(ui.close, ui)
        end
        if type(ui.deactivate) == "function" then
          pcall(ui.deactivate, ui)
        end
      end
      display, ui, gpu = nil, nil, nil
    end
    local ok, new_display, new_ui, new_gpu = pcall(init_display)
    if ok and new_display ~= nil then
      display, ui, gpu = new_display, new_ui, new_gpu
    elseif had_display then
      say("display lost; stopping")
      session.stop = true
    end
  end

  local ui_tick = math.max(1, math.floor(tonumber(cfg.UI_TICK) or 1))
  local ticks = 0

  while not session.stop do
    ticks = ticks + 1
    ---@type string|nil
    local name
    local pulled, event_name, _, p2, p3 = pcall(event.pull, cfg.LOOP_INTERVAL)
    if pulled then
      name = event_name
    end

    if name == "interrupted" or name == "interrupt" or name == "shutdown" then
      session.stop = true
    elseif name == "touch" then
      if ui ~= nil and type(ui.handle_click) == "function" then
        local ok, action = pcall(ui.handle_click, ui, p2, p3)
        if ok then
          handle_action(action)
        end
      end
    elseif name == "key_down" then
      local char = tostring(p2 or "")
      if char == "q" or char == "Q" then
        session.stop = true
      elseif char == "r" or char == "R" then
        session.rediscover = true
      elseif char == "t" or char == "T" then
        set_redstone(not redstone_enabled)
      end
    elseif name == "component_removed" or name == "component_added" then
      maybe_rebind()
    end

    if not session.stop then
      poll()
      if session.view ~= nil then
        session.view.link = session.link
        session.view.redstone_enabled = redstone_enabled
      end

      if redstone_enabled and reddev ~= nil then
        local out = redstone.compute(reader.cache, ticks)
        out.battery.side = cfg.REDSTONE_BATTERY_SIDE
        out.load_plus.side = cfg.REDSTONE_LOAD_PLUS_SIDE
        out.load_minus.side = cfg.REDSTONE_LOAD_MINUS_SIDE
        pcall(redstone.apply, reddev, out, deps)
      end

      queue_changes()

      if ui ~= nil and ticks % ui_tick == 0 then
        local history = model_module.history(model)
        local drawn = pcall(ui.render, ui, session.view, history)
        if not drawn then
          say("display lost; stopping")
          session.stop = true
        end
      end
    end
  end

  session.stop = true
  if handle ~= nil then
    local waited, all_done = pcall(thread.waitForAll, { handle }, 2)
    local still_running = true
    if type(handle.status) == "function" then
      local status_ok, status = pcall(handle.status, handle)
      still_running = not (status_ok and status == "dead")
    else
      still_running = not (waited and all_done)
    end
    if still_running then
      pcall(handle.kill, handle)
    end
  end

  pcall(redstone.zero, reddev, deps)
  if display ~= nil then
    pcall(display.free, display)
  end
  if ui ~= nil then
    if type(ui.close) == "function" then
      pcall(ui.close, ui)
    end
    if type(ui.deactivate) == "function" then
      pcall(ui.deactivate, ui)
    end
  end
  if reader ~= nil and type(reader.dispose) == "function" then
    pcall(reader.dispose, reader)
  end

  return 0
end

return M
