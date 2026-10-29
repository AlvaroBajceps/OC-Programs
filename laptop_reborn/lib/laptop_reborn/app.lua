-- Orchestrates the lapotron reader, redstone mirror, MQTT telemetry thread, and
-- the graphical UI. Every external facility is injected so the loop is testable
-- without an OpenComputers runtime.

local M = {}

local DIFF_FIELDS = {
  { key = "charge", field = "percent" },
  { key = "stored", field = "stored" },
  { key = "capacity", field = "capacity_total" },
  { key = "power_in", field = "in_5s" },
  { key = "power_out", field = "out_5s" },
  { key = "power_net", field = "net_instant" },
  { key = "edge_time", field = "seconds_to_edge" },
  { key = "status", field = "status_text" },
  { key = "maintenance", field = "maintenance" },
  { key = "lapotron_online", field = "online" },
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

local function make_reader(cfg, deps)
  local factory = deps.lapotron_factory
  if factory == nil then
    local adapter = deps.lapotron or require("laptop_reborn.lapotron")
    return adapter.open(cfg, {
      component = deps.component,
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
      if proxy_ok and type(proxy) == "table" and type(proxy.setOutput) == "function" then
        return proxy
      end
    end
    return nil
  end
  if type(component.redstone) == "table" and type(component.redstone.setOutput) == "function" then
    return component.redstone
  end
  return nil
end

local function resolve_model(deps)
  local model_module = deps.model or require("laptop_reborn.model")
  local instance = model_module.new({ kf_factory = deps.kf_factory })
  return model_module, instance
end

local function read_uptime(computer)
  if computer and type(computer.uptime) == "function" then
    local ok, value = pcall(computer.uptime)
    if ok and type(value) == "number" then
      return value
    end
  end
  return 0
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

  local function stopped()
    return session.stop == true
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
    client:on({
      connect = function(connack)
        if connack.rc ~= 0 then
          session.connected = false
          session.link = "FAULT"
          return
        end
        session.connected = true
        session.link = "ONLINE"
        pcall(ha.publish_availability, client, cfg, true)
        pcall(ha.publish_discovery, client, cfg)
        pcall(ha.publish_all_state, client, cfg, session.view)
      end,
      message = function(message)
        client:acknowledge(message)
      end,
      close = function()
        session.connected = false
        if session.link ~= "FAULT" then
          session.link = "RETRY"
        end
        pcall(ha.publish_link, client, cfg, session.view, false)
      end,
      error = function()
        session.connected = false
        session.link = "FAULT"
      end,
    })

    local loop = mqtt.get_ioloop(true, boot.ioloop_options())
    loop:add(client)

    local last_state = read_uptime(computer)
    local tick
    tick = function()
      if stopped() then
        pcall(ha.publish_link, client, cfg, session.view, false)
        pcall(ha.publish_availability, client, cfg, false)
        pcall(client.disconnect, client)
        session.connected = false
        pcall(loop.remove, loop, tick)
        pcall(loop.remove, loop, client)
        return
      end

      if session.rediscover then
        session.rediscover = false
        pcall(ha.publish_discovery, client, cfg)
      end

      if next(session.pending) ~= nil then
        local batch = {}
        for key in pairs(session.pending) do
          batch[key] = true
        end
        pcall(ha.publish_changed, client, cfg, session.view, batch)
        for key in pairs(batch) do
          session.pending[key] = nil
        end
      end

      local at = read_uptime(computer)
      if at - last_state >= cfg.STATE_INTERVAL then
        last_state = at
        pcall(ha.publish_all_state, client, cfg, session.view)
        pcall(ha.publish_link, client, cfg, { link = "ONLINE" }, true)
      end
    end
    loop:add(tick)

    loop:run_until_clients()
  end

  while not stopped() do
    local mqtt = deps.mqtt
    if mqtt == nil then
      local ok, result = pcall(boot.ensure_luamqtt, cfg, {
        internet = deps.internet,
        filesystem = deps.filesystem,
        io = deps.io,
        os = deps.os,
      })
      if ok then
        mqtt = result
      end
      if mqtt == nil then
        session.link = "RETRY"
        if stopped() then
          return
        end
        sleep(cfg.MQTT_RETRY)
      end
    end

    if mqtt ~= nil and not stopped() then
      local ok = pcall(run_one, mqtt)
      if not ok then
        session.link = "RETRY"
      end
      if not stopped() then
        sleep(cfg.MQTT_RETRY)
      end
    end
  end
end

---@param cfg table
---@param deps table|nil
---@return number
function M.run(cfg, deps)
  deps = deps or {}

  local io_module = deps.io or io
  local function say(text)
    pcall(io_module.write, tostring(text) .. "\n")
  end

  local computer = deps.computer or require("computer")
  local event = deps.event or require("event")
  local component = deps.component
  if component == nil then
    local ok, loaded = pcall(require, "component")
    if ok then
      component = loaded
    end
  end
  local thread = deps.thread or require("thread")
  local process = require_first(deps, "process", "process")

  if M.has_running_instance(process, coroutine.running()) then
    say("laptop_reborn is already running; refusing to start a second instance")
    return 1
  end

  local reader
  local reader_ok, reader_result, reader_err = pcall(make_reader, cfg, deps)
  if reader_ok then
    reader = reader_result
  end
  if reader == nil then
    say("laptop_reborn: no supported capacitor/energy storage: " .. tostring(reader_ok and reader_err or reader_result))
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
      session.view = model_module.update(model, reader.cache, model.provider)
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
    local created, thread_handle = pcall(thread.create, function()
      M.run_mqtt_session(cfg, session, mqtt_deps)
    end)
    if created then
      handle = thread_handle
    end
  else
    session.link = "OFF"
  end

  local previous = nil
  local function queue_changes()
    if cfg.ENABLE_MQTT and session.connected and session.view ~= nil then
      for _, entry in ipairs(DIFF_FIELDS) do
        if previous == nil or previous[entry.field] ~= session.view[entry.field] then
          session.pending[entry.key] = true
        end
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
    if type(gpu.getScreen) == "function" then
      local ok, address = pcall(gpu.getScreen)
      if ok then
        return address ~= nil and address ~= ""
      end
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
