-- AE2 Spatial Teleportation Safety System.
-- Lua 5.2, T2 computer + T2 screen, GTNH OpenComputers fork.
--
-- Prerequisites (in-world):
--   * Network Card in a card slot of each computer
--   * All computers connected via OC cable (same wired segment)
--   * T2 Screen + Keyboard attached
--   * Redstone I/O block adjacent to the computer (or a Redstone Card in a
--     slot). T2 card required for bundled I/O.
--   * Exactly one bundled cable (ProjectRed / RedLogic) on any side of the
--     Redstone I/O. The cable must carry two signals:
--       Black (color 15) - permanently driven high by an external source;
--                         used as a cable-health heartbeat and lets each
--                         node auto-discover which side the cable is on.
--       Red   (color 14) - driven high only while the teleporter entity is
--                         physically at this node. Exactly one node on the
--                         network may hold Red high at any time; that node
--                         is the only one allowed to initiate a teleport.
--   * An Adapter touching an AE2 Spatial IO Port, on every node. Exposed as
--     component.spatial_io; provides energy/readiness telemetry (canTrigger,
--     availableEnergy, requiredEnergy, hasInputCell) and the trigger() call
--     that compacts (sender) or plays back (receiver) the warp chamber.
--   * An me_interface + database (upgrade) on every node: the receiver places
--     a stocking request so the AE2 network routes the spatial storage cell
--     (ejected by the sender's trigger) into its interface, feeding its
--     spatial IO port. Sender/bystander nodes defensively clear their own
--     interface during a warp.
--
-- Composition root: wires the lib/teleporter/* modules together, owns the
-- bin-level timers/listeners, and runs the render/event loop. All policy and
-- rendering live in the library modules; this file is plumbing only.

local computer = require("computer")
local event = require("event")

local config_factory = require("teleporter.config")
local util_factory = require("teleporter.util")
local ae2_factory = require("teleporter.ae2")
local spatial_io_factory = require("teleporter.spatial_io")
local peers_factory = require("teleporter.peers")
local redstone_factory = require("teleporter.redstone")
local display_factory = require("teleporter.display")
local modem_factory = require("teleporter.modem")
local protocol_factory = require("teleporter.protocol")
local ui_factory = require("teleporter.ui")

-- Cross-cutting flags shared across modules: the redraw dirty flag, the
-- shutdown guard, and rename_mode (which gates incoming TP_REQ handling).
local app = {
  dirty = true,
  shutting_down = false,
  rename_mode = false,
}

local config = config_factory()
local util = util_factory()
local ae2 = ae2_factory({ config = config })
local spatial_io = spatial_io_factory()
local peers = peers_factory({ config = config, app = app })
local redstone = redstone_factory({ config = config, peers = peers, app = app })
local display = display_factory()
local modem = modem_factory({ config = config, util = util })

display.setup()
modem.setup()

local protocol = protocol_factory({
  config = config,
  util = util,
  modem = modem,
  ae2 = ae2,
  spatial_io = spatial_io,
  redstone = redstone,
  peers = peers,
  app = app,
})
local ui = ui_factory({
  config = config,
  display = display,
  peers = peers,
  spatial_io = spatial_io,
  redstone = redstone,
  protocol = protocol,
  app = app,
})

local hb_timer, refresh_timer, discover_timer
local modem_listener, touch_listener, key_listener, redstone_listener

local function shutdown()
  if app.shutting_down then
    return
  end
  app.shutting_down = true

  protocol.cancel_all_timers()
  if hb_timer then
    event.cancel(hb_timer)
  end
  if refresh_timer then
    event.cancel(refresh_timer)
  end
  if discover_timer then
    event.cancel(discover_timer)
  end

  if modem_listener then
    event.cancel(modem_listener)
  end
  if touch_listener then
    event.cancel(touch_listener)
  end
  if key_listener then
    event.cancel(key_listener)
  end
  if redstone_listener then
    event.cancel(redstone_listener)
  end

  pcall(modem.send, { t = config.MT.BYE, s = config.MY_ADDR, n = config.get_name() })
  modem.close()
  display.free()
end

local function fatal(msg)
  pcall(shutdown)
  local gpu = display.get_gpu()
  local screen_addr = display.get_screen_addr()
  if gpu and screen_addr then
    gpu.setActiveBuffer(0)
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFF0000)
    local scr_w, scr_h = display.get_dims()
    gpu.fill(1, 1, scr_w, scr_h, " ")
    gpu.set(1, 1, "FATAL: " .. tostring(msg))
  end
  computer.beep(1000, 0.3)
end

local function main()
  local function refresh_redstone()
    local prev_red = redstone.is_red_high()
    redstone.refresh()
    if redstone.is_red_high() ~= prev_red then
      protocol.heartbeat()
    end
    protocol.check_receiver_confirm()
  end

  modem_listener = event.listen("modem_message", function(_, _, remote_addr, port, _, payload)
    protocol.handle_message(remote_addr, port, payload)
  end)
  touch_listener = event.listen("touch", ui.on_touch)
  key_listener = event.listen("key_down", ui.on_key)
  redstone_listener = event.listen("redstone_changed", refresh_redstone)

  hb_timer = event.timer(config.HEARTBEAT_INTERVAL, protocol.heartbeat, math.huge)
  local power_refresh_tick = 0
  refresh_timer = event.timer(1, function()
    refresh_redstone()
    peers.refresh_status()
    power_refresh_tick = power_refresh_tick + 1
    if power_refresh_tick >= 5 then
      power_refresh_tick = 0
      app.dirty = true
    end
  end, math.huge)

  refresh_redstone()
  protocol.discover()
  discover_timer = event.timer(60, protocol.discover, math.huge)

  app.dirty = true

  while true do
    if app.dirty then
      ui.render()
      app.dirty = false
    end
    local ev = { event.pull(0.5) }
    if ev[1] == "interrupted" then
      pcall(shutdown)
      return
    end
    protocol.abort_if_unhealthy()
    protocol.check_receiver_confirm()
  end
end

local ok, err = pcall(main)
if not ok then
  fatal(err)
  error(err)
end
