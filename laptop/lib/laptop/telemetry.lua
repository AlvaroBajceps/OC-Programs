-- MQTT supervisor shared with laptop_reborn: discovery, state publishing, ack
-- timeout detection, and session restart. Every external facility is injected.

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

local function get_method(object, name)
  if type(object) ~= "table" then
    return nil
  end
  local ok, value = pcall(function()
    return object[name]
  end)
  if not ok then
    return nil
  end
  if type(value) == "function" then
    return value
  end
  if type(value) == "table" then
    local meta = getmetatable(value)
    if meta ~= nil and type(meta.__call) == "function" then
      return value
    end
  end
  return nil
end

local function read_uptime(computer)
  local uptime = get_method(computer, "uptime")
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
  local ha = ha_module or require("laptop.ha")
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
  local ha = deps.ha or require("laptop.ha")
  local boot = deps.mqtt_boot or require("laptop.mqtt_boot")
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
          local reason = tostring(connack.rc)
          local ok, text = pcall(function()
            return connack:reason_string()
          end)
          if ok and text ~= nil then
            reason = reason .. " " .. tostring(text)
          end
          session.last_error = "CONNACK " .. reason
          log("mqtt connect refused: " .. session.last_error)
          return
        end
        session.connected = true
        session.link = "ONLINE"
        session.last_error = nil
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
      close = function(conn)
        session.connected = false
        session.ack_pending_since = nil
        session.reconnect_at = uptime()
        if session.link ~= "FAULT" then
          session.link = "RETRY"
        end
        local reason = conn and conn.close_reason and tostring(conn.close_reason) or nil
        if reason ~= nil and reason ~= "" then
          session.last_error = "closed: " .. reason
          log("mqtt link down: " .. reason)
        end
        pcall(ha.publish_link, client, cfg, session.view, false)
      end,
      error = function(err)
        session.connected = false
        session.ack_pending_since = nil
        session.link = "RETRY"
        session.reconnect_at = uptime()
        session.last_error = tostring(err)
        log("mqtt error: " .. session.last_error)
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

return M
