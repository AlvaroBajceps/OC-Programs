-- rc.d entry for ab_turbinecontrol.
-- Starts the daemon in an OpenOS background thread so rc can return to booting.

local computer = require("computer")
local filesystem = require("filesystem")
local shell = require("shell")
local thread = require("thread")

local handle = nil

local function daemon_path()
  local ok, path = pcall(shell.resolve, "ab_turbinecontrol")
  if ok and path ~= nil then
    if filesystem.exists(path) then
      return path
    end
    if filesystem.exists(path .. ".lua") then
      return path .. ".lua"
    end
  end
  return "/bin/ab_turbinecontrol.lua"
end

local function alive()
  if handle == nil then
    return false
  end
  if type(handle.status) == "function" then
    local ok, status = pcall(handle.status, handle)
    return ok and status ~= "dead"
  end
  return true
end

function start()
  if alive() then
    return
  end

  local path = daemon_path()
  local created, result = pcall(thread.create, function()
    local chunk, load_err = loadfile(path)
    if not chunk then
      print("ab_turbinecontrol: cannot load " .. path .. ": " .. tostring(load_err))
      return
    end

    local ok, err = pcall(chunk)
    if not ok then
      print("ab_turbinecontrol: " .. tostring(err))
    end
  end)

  if created then
    handle = result
    -- rc may run in a process that exits after start(); detach so the daemon
    -- is not joined and killed with that process.
    if type(handle.detach) == "function" then
      pcall(handle.detach, handle)
    end
  else
    print("ab_turbinecontrol: cannot start daemon thread: " .. tostring(result))
  end
end

function stop()
  computer.pushSignal("ab_turbinecontrol_stop")

  if handle == nil then
    return
  end

  pcall(thread.waitForAll, { handle }, 12)
  if alive() then
    pcall(handle.kill, handle)
  end
  handle = nil
end
