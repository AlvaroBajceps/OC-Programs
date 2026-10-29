-- CLI entry point for laptop_reborn. Parses flags, merges an optional config
-- override file, and hands the effective config to app.run.

local M = {}

M.VERSION = "1.1.0"

local SCALES = {
  ["1x"] = true,
  ["2x"] = true,
  max = true,
  auto = true,
}

local function first_value(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if value ~= nil then
      return value
    end
  end
  return nil
end

---@return string
function M.help()
  return table.concat({
    "Laptop Reborn v" .. M.VERSION,
    "-h, --help          show help",
    "-r, --redstone      enable redstone mirror",
    "-R, --no-redstone   disable redstone mirror",
    "-V, --virtual       use the virtual lapotron device",
    "-c, --config=[path] use config override at path",
    "-S, --reset-cfg     write a fresh config and exit",
    "-s, --save-cfg      write the effective config and exit",
    "-M, --no-mqtt       disable MQTT/Home Assistant telemetry",
    "-x, --scale=[mode]  1x | 2x | max | auto",
    "--version           print the version",
    "--diag              print component discovery diagnostics",
  }, "\n")
end

local function clear_module_cache()
  for key in pairs(package.loaded) do
    if key == "laptop_reborn" or key:match("^laptop_reborn%.") then
      package.loaded[key] = nil
    end
  end
end

---@param deps table|nil
---@return number
function M.diagnose(deps)
  deps = deps or {}
  local io_module = deps.io or io
  local function say(text)
    pcall(io_module.write, tostring(text) .. "\n")
  end

  local methods = deps.methods or require("laptop_reborn.methods")
  local component = deps.component
  local candidates = { package.loaded.component }
  for _, candidate in ipairs(candidates) do
    if methods.get(component, "list") == nil and methods.get(candidate, "list") ~= nil then
      component = candidate
    end
  end
  if methods.get(component, "list") == nil then
    local ok, loaded = pcall(require, "component")
    if ok and type(loaded) == "table" then
      component = loaded
    end
  end

  say("Laptop Reborn v" .. M.VERSION)
  say("component API: " .. type(component) .. ", list=" .. type(component and component.list))
  if methods.get(component, "list") == nil then
    say("component.list is unavailable from this program")
    return 1
  end

  local ok, listed = pcall(component.list)
  if not ok then
    say("component.list failed: " .. tostring(listed))
    return 1
  end

  local entries = {}
  if type(listed) == "table" then
    for address, kind in pairs(listed) do
      entries[#entries + 1] = { address, kind }
    end
  elseif type(listed) == "function" then
    while true do
      local address, kind = listed()
      if address == nil then
        break
      end
      entries[#entries + 1] = { address, kind }
    end
  end
  table.sort(entries, function(a, b)
    return tostring(a[1]) < tostring(b[1])
  end)

  local matched = 0
  local function report(entry)
    local address, kind = entry[1], entry[2]
    local proxy_ok, proxy = pcall(component.proxy, address)
    local name = "?"
    if proxy_ok and type(proxy) == "table" and methods.get(proxy, "getName") ~= nil then
      local name_ok, value = methods.call(proxy, "getName")
      if name_ok and value ~= nil then
        name = tostring(value)
      end
    end
    say(string.format("%s  %s  %s", tostring(address), tostring(kind), name))
  end

  for _, entry in ipairs(entries) do
    local kind = tostring(entry[2] or "")
    local proxy_ok, proxy = pcall(component.proxy, entry[1])
    local name = ""
    if proxy_ok and type(proxy) == "table" and methods.get(proxy, "getName") ~= nil then
      local name_ok, value = methods.call(proxy, "getName")
      if name_ok and value ~= nil then
        name = tostring(value):lower()
      end
    end
    if kind == "gt_machine" or name:find("capacitor", 1, true) or name:find("lapotron", 1, true) then
      report(entry)
      matched = matched + 1
    end
  end

  if matched == 0 then
    say("no gt_machine/capacitor component matched; listing all components:")
    for _, entry in ipairs(entries) do
      report(entry)
    end
  end
  return 0
end

local function write_config(path, cfg, deps)
  local serialization = deps.serialization or require("serialization")
  local io_module = deps.io or io
  local os_module = deps.os or os

  local data = serialization.serialize(cfg, true)
  local target = path
  if type(os_module.rename) == "function" then
    target = path .. ".tmp"
  end

  local file, open_err = io_module.open(target, "w")
  if not file then
    return false, tostring(open_err)
  end

  local ok, wrote, write_err = pcall(file.write, file, data)
  local close_ok, close_result, close_err = pcall(file.close, file)
  if not ok or wrote == nil or not close_ok or close_result == false then
    pcall(os_module.remove, target)
    return false, tostring(write_err or close_err or "write failed")
  end

  if target ~= path then
    local renamed, rename_err = pcall(os_module.rename, target, path)
    if not renamed then
      pcall(os_module.remove, target)
      return false, tostring(rename_err)
    end
  end

  return true
end

---@param argv table|nil
---@param deps table|nil
---@return number
function M.main(argv, deps)
  argv = argv or {}
  deps = deps or {}
  clear_module_cache()

  local shell = deps.shell or require("shell")
  local computer = deps.computer or require("computer")
  local io_module = deps.io or io

  local function say(text)
    pcall(io_module.write, tostring(text) .. "\n")
  end

  local args, opts = shell.parse(table.unpack(argv))

  if opts.h or opts.help then
    say(M.help())
    return 0
  end
  if opts.version then
    say("Laptop Reborn v" .. M.VERSION)
    return 0
  end
  if opts.diag then
    return M.diagnose(deps)
  end

  local config = deps.config or require("laptop_reborn.config")
  local app = deps.app or require("laptop_reborn.app")

  if opts.virtual then
    opts.V = true
  end
  if opts["reset-cfg"] then
    opts.S = true
  end
  if opts["save-cfg"] then
    opts.s = true
  end
  if opts.redstone then
    opts.r = true
  end
  if opts["no-redstone"] then
    opts.R = true
  end
  if opts["no-mqtt"] then
    opts.M = true
  end

  if opts.S and opts.s then
    say("Cannot reset and save at the same time.")
    return 1
  end

  local path = first_value(opts.config, opts.c, args.config, args.c)
  local address = "unknown"
  if type(computer.address) == "function" then
    local ok, value = pcall(computer.address)
    if ok and value ~= nil then
      address = value
    end
  end

  local defaults = config.build(address)
  path = path or defaults.CONFIG_PATH

  local overrides = nil
  if not opts.S then
    local ok, result = pcall(config.load_override, path, {
      filesystem = deps.filesystem,
      io = deps.io,
      loadfile = deps.loadfile,
    })
    if ok and type(result) == "table" then
      overrides = result
    end
  end

  local cfg = config.build(address, overrides or {})

  if opts.V then
    cfg.DEV_LAPOTRON = "v_lapotron"
  end
  if opts.r then
    cfg.ENABLE_REDSTONE = true
  elseif opts.R then
    cfg.ENABLE_REDSTONE = false
  end
  if opts.M then
    cfg.ENABLE_MQTT = false
  end

  local scale = first_value(opts.x, opts.scale, args.x, args.scale)
  if scale ~= nil then
    if not SCALES[scale] then
      say("Invalid scale '" .. tostring(scale) .. "'. Use 1x, 2x, max, or auto.")
      return 1
    end
    cfg.SCALE = scale
  end

  if opts.S then
    local ok, err = write_config(path, cfg, deps)
    if not ok then
      say("Config reset failed: " .. tostring(err))
      return 1
    end
    say("Config written to " .. path)
    return 0
  end

  if opts.s then
    local ok, err = write_config(path, cfg, deps)
    if not ok then
      say("Config save failed: " .. tostring(err))
      return 1
    end
    say("Config written to " .. path)
    return 0
  end

  return app.run(cfg, deps)
end

-- selene: allow(global_usage)
if rawget(_G, "LAPTOP_REBORN_NO_AUTORUN") ~= true then
  -- selene: allow(undefined_variable)
  return M.main({ ... })
end

return M
