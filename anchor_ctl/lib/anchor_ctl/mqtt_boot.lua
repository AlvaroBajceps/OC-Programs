-- luamqtt bootstrap and socket connector shared by the anchor_ctl daemon.
-- The pinned commit and file list match src/OC-Programs/mqtt_ha/bin/mqtt_ha.lua
-- so every OC program in this workspace installs an identical luamqtt copy.
local M = {}

M.MQTT_COMMIT = "14ad9be4c327972be68726d3c796c781eb4cc542"
M.MQTT_FILES = {
  "init.lua",
  "const.lua",
  "client.lua",
  "ioloop.lua",
  "protocol.lua",
  "protocol4.lua",
  "protocol5.lua",
  "tools.lua",
  "bitwrap.lua",
  "bit53.lua",
}
M.MQTT_RAW = "https://raw.githubusercontent.com/xHasKx/luamqtt/" .. M.MQTT_COMMIT .. "/mqtt/"

local install_announced = false
local repair_attempted = false

---@param internet table
---@param url string
---@param path string
---@param io table
---@param os table
---@return boolean, string|nil
function M.download(internet, url, path, io, os)
  local ok, handle = pcall(internet.request, url)
  if not ok then
    return false, tostring(handle)
  end

  local mt = getmetatable(handle)
  local index = mt and mt.__index
  if type(index) == "table" and type(index.response) == "function" then
    local ok_code, code = pcall(index.response)
    if ok_code and type(code) == "number" and code ~= 200 then
      return false, "HTTP " .. tostring(code)
    end
  end

  -- Download to a sibling temp file and rename, so a hard kill cannot leave a
  -- truncated module that the next run would treat as already installed.
  local target = path
  if type(os.rename) == "function" then
    target = path .. ".tmp"
  end

  local file, open_err = io.open(target, "w")
  if not file then
    return false, tostring(open_err)
  end
  local ok_write, write_err = pcall(function()
    for chunk in handle do
      local wrote, reason = file:write(chunk)
      if not wrote then
        error(reason or "write failed", 0)
      end
    end
  end)
  if ok_write and type(file.flush) == "function" then
    local flush_ok, flush_result, flush_err = pcall(file.flush, file)
    if not flush_ok or not flush_result then
      ok_write = false
      write_err = flush_ok and (flush_err or "flush failed") or flush_result
    end
  end
  local close_ok, close_result, close_err = pcall(file.close, file)
  local close_failed = not close_ok or close_result == false or (close_result == nil and close_err ~= nil)
  if ok_write and close_failed then
    ok_write = false
    write_err = close_ok and (close_err or "close failed") or close_result
  end
  if not ok_write then
    pcall(os.remove, target)
    return false, tostring(write_err)
  end
  if target ~= path then
    local called, renamed, rename_err = pcall(os.rename, target, path)
    if not called or not renamed then
      pcall(os.remove, target)
      return false, tostring(called and (rename_err or "rename failed") or renamed)
    end
  end
  return true, nil
end

---@param cfg table
---@param deps table|nil
---@return table|nil mqtt
---@return string|nil err
function M.ensure_luamqtt(cfg, deps)
  deps = deps or {}
  local internet = deps.internet or require("internet")
  local filesystem = deps.filesystem or require("filesystem")
  local io = deps.io or io
  local os = deps.os or os
  ---@type fun(level: string, message: string)
  local log = deps.log or function() end

  local root = cfg.MQTT_DIR:match("^(.*)/[^/]+$") or cfg.MQTT_DIR
  local marker = root .. "/?.lua"
  local cached_ok, cached = pcall(require, "mqtt")
  if cached_ok then
    return cached, nil
  end
  if not package.path:find(marker, 1, true) then
    package.path = marker .. ";" .. root .. "/?/init.lua;" .. package.path
  end

  if not filesystem.exists(cfg.MQTT_DIR) then
    local made, mkdir_err = filesystem.makeDirectory(cfg.MQTT_DIR)
    if not made and not filesystem.exists(cfg.MQTT_DIR) then
      return nil, "cannot create " .. cfg.MQTT_DIR .. ": " .. tostring(mkdir_err)
    end
  end

  local needs_download = false
  for _, name in ipairs(M.MQTT_FILES) do
    local target = cfg.MQTT_DIR .. "/" .. name
    local present = filesystem.exists(target)
    local size = present and filesystem.size(target) or 0
    if not present or size == 0 then
      needs_download = true
      break
    end
  end
  if needs_download and not install_announced then
    install_announced = true
    log("info", "installing luamqtt into " .. cfg.MQTT_DIR)
  end

  for _, name in ipairs(M.MQTT_FILES) do
    local target = cfg.MQTT_DIR .. "/" .. name
    local present = filesystem.exists(target)
    local size = present and filesystem.size(target) or 0
    if not present or size == 0 then
      local downloaded, err = M.download(internet, M.MQTT_RAW .. name, target, io, os)
      if not downloaded then
        return nil, "download failed for " .. name .. ": " .. tostring(err)
      end
      log("info", "installed " .. name)
    end
  end

  for key in pairs(package.loaded) do
    if key == "mqtt" or key:match("^mqtt%.") then
      package.loaded[key] = nil
    end
  end

  local ok, mqtt = pcall(require, "mqtt")
  if not ok then
    if not repair_attempted then
      repair_attempted = true
      for _, name in ipairs(M.MQTT_FILES) do
        pcall(os.remove, cfg.MQTT_DIR .. "/" .. name)
      end
      return nil, "mqtt load failed; cached files removed for one repair attempt: " .. tostring(mqtt)
    end
    return nil, tostring(mqtt)
  end
  repair_attempted = false
  return mqtt, nil
end

---@param deps table|nil
---@return table connector
function M.create_connector(deps)
  deps = deps or {}
  local internet = deps.internet or require("internet")
  local buffer = deps.buffer or require("buffer")
  local sleep = deps.sleep or rawget(os, "sleep") or function() end
  local now = deps.now or require("computer").uptime
  local connect_timeout = deps.connect_timeout or 10
  local should_stop = deps.should_stop
  local connector = {}

  function connector.connect(conn)
    local stream, err = internet.socket(conn.host, conn.port)
    if not stream then
      return false, err or "internet.socket failed"
    end

    local deadline = now() + connect_timeout
    while true do
      if should_stop and should_stop() then
        stream:close()
        return false, "stopped"
      end
      local ok, connected = pcall(stream.socket.finishConnect)
      if not ok then
        stream:close()
        return false, tostring(connected)
      end
      if connected then
        break
      end
      if now() >= deadline then
        stream:close()
        return false, "TCP connect timeout"
      end
      sleep(0.05)
    end

    local sock = buffer.new("rwb", stream)
    sock:setvbuf("no")
    conn.sock = sock
    return true
  end

  function connector.shutdown(conn)
    if conn.sock then
      conn.sock:close()
      conn.sock = nil
    end
  end

  function connector.send(conn, data, index)
    local ok, err = conn.sock:write(data:sub(index))
    if not ok then
      return nil, tostring(err)
    end
    return #data
  end

  function connector.receive(conn, size)
    local ok, data, err = pcall(conn.sock.read, conn.sock, size)
    if not ok then
      local message = tostring(data)
      if message:match("timeout$") then
        return nil, "timeout"
      elseif message:match("wantread$") then
        return nil, "wantread"
      end
      return nil, message
    end
    if data == nil and err == nil then
      return nil, "closed"
    end
    return data, err
  end

  function connector.settimeout(conn, timeout)
    if conn.sock then
      conn.sock:setTimeout(timeout or math.huge)
    end
  end

  return connector
end

---@return table
function M.ioloop_options()
  local sleep = rawget(os, "sleep")
  if type(sleep) ~= "function" then
    sleep = function() end
  end
  return { sleep_function = sleep, sleep = 0.05, timeout = 0.05 }
end

return M
