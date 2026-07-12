-- Deep Earth Heating Pump Controller.
-- Lua 5.2, T2 computer + T2 screen, GTNH OpenComputers fork.
--
-- Prerequisites (in-world):
--   * 4 Adapters placed on GregTech Deep Earth Heating Pump controllers,
--     wired to the computer via OC cable.
--   * 2 Adapters on the hot and cold coolant tanks (transposer API),
--     wired to the computer via OC cable.
--   * T2 GPU + T2 Screen (80x25 resolution) attached to the computer.
--   * OC cable connecting all components to the computer.
--
-- Composition root: discovers components, wires modules, owns the event loop.
-- All policy and rendering live in the library modules; this file is plumbing.

local component = require("component")
local computer = require("computer")
local event = require("event")

local config_factory = require("heating_pump.config")
local machine_factory = require("heating_pump.machine")
local tank_factory = require("heating_pump.tank")
local stats_factory = require("heating_pump.stats")
local controller_factory = require("heating_pump.controller")
local display_factory = require("heating_pump.display")

local app = {
  dirty = true,
  shutting_down = false,
}

local config = config_factory()

-- Shared mutable state owned by the composition root.
local tick_timer
local machines, hot_tank, cold_tank
local display

-- ── Component discovery ────────────────────────────────────────────

local function classify_gt_component(address)
  local proxy = component.proxy(address)
  local ok, name = pcall(proxy.getName, proxy)
  if ok and name then
    local lower = name:lower()
    if lower:find("tank") then
      return "tank"
    end
  end
  return "pump"
end

local function classify_tank(tank_wrapper)
  local s = tank_wrapper.get_state()
  if not s.online then
    return "unknown"
  end
  local identifier = ""
  if s.name then
    identifier = s.name:lower()
  elseif s.label then
    identifier = s.label:lower()
  end

  if identifier:find("hot") and not identifier:find("cold") then
    return "hot"
  end
  if identifier:find("cold") or identifier:find("coolant") then
    return "cold"
  end
  return "unknown"
end

-- ── Shutdown / fatal ───────────────────────────────────────────────

local function shutdown()
  if app.shutting_down then
    return
  end
  app.shutting_down = true

  if tick_timer then
    event.cancel(tick_timer)
    tick_timer = nil
  end

  if machines then
    for _, m in ipairs(machines) do
      pcall(m.set_work_allowed, m, false, computer.uptime())
    end
  end

  if display then
    display.free()
  end
end

local function fatal(msg)
  pcall(shutdown)
  print("FATAL: " .. tostring(msg))
  if display and display.get_gpu() then
    local g = display.get_gpu()
    g.setActiveBuffer(0)
    g.setBackground(0x000000)
    g.setForeground(0xFF0000)
    local w, h = display.get_dims()
    g.fill(1, 1, w, h, " ")
    g.set(1, 1, "FATAL: " .. tostring(msg))
  end
  computer.beep(1000, 0.3)
end

-- ── Main ───────────────────────────────────────────────────────────

local function main()
  -- Unified discovery: classify all gt_machine adapters as pumps or tanks.
  local pump_addrs = {}
  local tank_addrs = {}

  for address, kind in component.list() do
    if kind == "gt_machine" then
      local typeof = classify_gt_component(address)
      local proxy = component.proxy(address)
      local _, nm = pcall(proxy.getName, proxy)
      print(string.format("  gt_machine %s → %s (name: %s)", address:sub(1, 8), typeof, tostring(nm)))
      if typeof == "pump" then
        pump_addrs[#pump_addrs + 1] = address
      else
        tank_addrs[#tank_addrs + 1] = address
      end
    end
  end

  -- Backward compat: also discover standalone transposer adapters.
  for address, kind in component.list() do
    if kind == "transposer" then
      tank_addrs[#tank_addrs + 1] = address
      print(string.format("  transposer %s → tank", address:sub(1, 8)))
    end
  end

  if #pump_addrs == 0 then
    fatal("No gt_machine pumps discovered. Check adapter placement and cabling.")
    return
  end

  machines = {}
  for i, addr in ipairs(pump_addrs) do
    local m = machine_factory({ address = addr, index = i, low_eu_threshold = config.PUMP_LOW_EU_THRESHOLD })
    machines[#machines + 1] = m
  end

  if #tank_addrs == 0 then
    fatal("No coolant tanks discovered. Check adapter placement and cabling.")
    return
  end

  print(string.format("Discovered %d pump(s) and %d tank(s).", #pump_addrs, #tank_addrs))

  local tank_wrappers = {}
  for _, addr in ipairs(tank_addrs) do
    local t = tank_factory({ address = addr })
    local s = t.get_state()
    print(
      string.format(
        "  tank %s: online=%s side=%s amount=%s",
        addr:sub(1, 8),
        tostring(s.online),
        tostring(s.side),
        tostring(s.amount)
      )
    )
    tank_wrappers[#tank_wrappers + 1] = t
  end

  for _, t in ipairs(tank_wrappers) do
    local kind = classify_tank(t)
    local s = t.get_state()
    local label = s.name or s.label or s.address:sub(1, 6)
    if kind == "hot" and not hot_tank then
      hot_tank = t
      print(string.format("Hot tank identified: %s", label))
    elseif kind == "cold" and not cold_tank then
      cold_tank = t
      print(string.format("Cold tank identified: %s", label))
    end
  end

  -- Assign unknowns: first unassigned → hot, second → cold.
  for _, t in ipairs(tank_wrappers) do
    if t ~= hot_tank and t ~= cold_tank then
      if not hot_tank then
        hot_tank = t
        print("Assigned unknown tank as hot (first unassigned).")
      elseif not cold_tank then
        cold_tank = t
        print("Assigned unknown tank as cold (second unassigned).")
      end
    end
  end

  if not cold_tank then
    fatal("No cold coolant tank identified. Cold tank is safety-critical — cannot run without it.")
    return
  end

  if not hot_tank then
    print("WARNING: No hot coolant tank identified. Hot demand will be treated as satisfied.")
  end

  local stats = stats_factory({ config = config })

  local controller = controller_factory({
    config = config,
    machines = machines,
    hot_tank = hot_tank,
    cold_tank = cold_tank,
    stats = stats,
    app = app,
    uptime_fn = function()
      return computer.uptime()
    end,
  })

  display = display_factory({
    config = config,
    controller = controller,
    machines = machines,
    hot_tank = hot_tank,
    cold_tank = cold_tank,
    stats = stats,
    app = app,
    uptime_fn = function()
      return computer.uptime()
    end,
  })

  display.setup()

  tick_timer = event.timer(config.TICK_INTERVAL, function()
    controller.tick(computer.uptime())
    app.dirty = true
  end, math.huge)

  controller.tick(computer.uptime())

  while true do
    if app.dirty then
      display.render()
      app.dirty = false
    end
    local ev = { event.pull(0.5) }
    if ev[1] == "interrupted" then
      shutdown()
      return
    end
  end
end

local ok, err = pcall(main)
if not ok then
  fatal(err)
  error(err)
end
