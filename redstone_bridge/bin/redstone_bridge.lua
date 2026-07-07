-- Bundled redstone <-> network bridge for an OpenComputers daemon.
-- Surfaces every attached bundled-redstone cable on a network port, lets
-- remote computers/servers read and write each individual color, and
-- broadcasts change events as they happen. Identifies itself by a
-- human-readable name so peers can discover it without tracking UUIDs.
--
-- Prerequisites (in-world):
--   * Computer (or server) running OpenOS — install via `oppm install redstone_bridge`.
--   * T2 Redstone Card  (bundled I/O requires T2; T1 is vanilla analog only)
--   * Network Card      (wired or wireless) in an expansion slot
--   * Adjacent bundled cable (ProjectRed / RedLogic) on the side(s) you
--     want to bridge. The card polls all 6 sides at startup and marks a
--     side as "active" once it sees any non-zero input or any
--     `redstone_changed` event for it.
--   * Autostart on boot: `rc redstone_bridge enable` (or `rc redstone_bridge start`
--     for one-shot). Requires the rc.d script shipped with this package.
--
-- Persistence:
--   The human-readable name lives in the EEPROM data slot (`eeprom.setData` /
--   `getData`, 256 B max). Default "rsbridge"; settable remotely via the
--   "rename" command. Survives reboots. Every OC computer has an EEPROM, so
--   this works on a regular OpenOS machine — not only on a microcontroller.
--
-- Network protocol (Lua varargs; first payload arg is the string command):
--   Discovery port 99:
--     "iam"          NAME, computer.address, modem.address            (broadcast)
--     "beat"         NAME, computer.address                           (every 10s)
--     "discover"|"who"                                                            (request)
--     "rename"       newName                                                    (request)
--   Service port 100:
--     "read"         side[, color]                                                (request)
--     "write"        side, color, value                                          (request)
--     "list"                                                                       (request)
--     "changed"      side, color, oldValue, newValue                (broadcast on change;
--                     color is -1 for non-bundled changes)
--
-- Replies reuse the command name as the first payload arg so the caller can
-- correlate. Errors come back as `("error", reason)`.
--
-- A minified MCU EEPROM build of this same protocol lives at
-- src/redstone_bridge_eeprom.lua in the parent workspace, for the
-- flash-to-microcontroller deployment path (no filesystem, no rc.d).

local component = require("component")
local computer = require("computer")

-- Numeric side values 0..5 are the canonical OC side enum (sides.bottom=0,
-- top=1, back=2, front=3, right=4, left=5). Inlined to keep the daemon
-- self-contained; `require("sides")` works too on OpenOS if you prefer names.
local SIDES = { [0] = "bottom", [1] = "top", [2] = "back", [3] = "front", [4] = "right", [5] = "left" }

local DISCOVERY_PORT = 99
local SERVICE_PORT = 100
local PULL_TIMEOUT = 0.5
local HEARTBEAT_INTERVAL = 10

local redstoneAddress = component.list("redstone")()
if not redstoneAddress then
  error("redstone bridge: no redstone component — install a redstone card")
end
local modemAddress = component.list("modem")()
if not modemAddress then
  error("redstone bridge: no modem component — install a network card")
end

---@type redstone
local redstone = component.proxy(redstoneAddress)
---@type modem
local modem = component.proxy(modemAddress)

local eepromAddress = component.list("eeprom")()
local eeprom = nil
if eepromAddress then
  eeprom = component.proxy(eepromAddress)
end

local snapshot = {}
local activeSides = { [0] = false, [1] = false, [2] = false, [3] = false, [4] = false, [5] = false }

local function refreshSnapshot(side)
  local colors = {}
  local anyNonZero = false
  for color = 0, 15 do
    local value = redstone.getBundledInput(side, color)
    colors[color] = value
    if value ~= 0 then
      anyNonZero = true
    end
  end
  snapshot[side] = colors
  if anyNonZero then
    activeSides[side] = true
  end
end

for side = 0, 5 do
  refreshSnapshot(side)
end

local NAME = "rsbridge"
if eeprom and eeprom.getData then
  local stored = eeprom.getData()
  -- getData returns the empty string when nothing has been stored; treat
  -- any non-empty content as the persistent name.
  if type(stored) == "string" and #stored > 0 then
    NAME = stored
  end
end

local function saveName()
  if eeprom and eeprom.setData then
    pcall(eeprom.setData, NAME)
  end
end

modem.open(DISCOVERY_PORT)
modem.open(SERVICE_PORT)

-- Compact CSV form for the "read" reply side payload: "color=value,...".
local function serializeSideSnapshot(side)
  local parts = {}
  local colors = snapshot[side] or {}
  for color = 0, 15 do
    local value = colors[color]
    if value then
      parts[#parts + 1] = tostring(color) .. "=" .. tostring(value)
    end
  end
  return table.concat(parts, ",")
end

local function handleCommand(remoteAddr, port, ...)
  local cmd = ...
  if type(cmd) ~= "string" then
    return
  end

  if cmd == "rename" then
    local newName = select(2, ...)
    if type(newName) ~= "string" or #newName == 0 or #newName > 256 then
      modem.send(remoteAddr, port, "error", "rename: name must be 1..256 chars")
      return
    end
    NAME = newName
    saveName()
    modem.send(remoteAddr, port, "renamed", NAME)
    return
  end

  if cmd == "who" or cmd == "discover" then
    modem.send(remoteAddr, port, "iam", NAME, computer.address(), modemAddress)
    return
  end

  if cmd == "list" then
    local parts = {}
    for side = 0, 5 do
      if activeSides[side] then
        parts[#parts + 1] = SIDES[side] .. ":" .. serializeSideSnapshot(side)
      end
    end
    modem.send(remoteAddr, port, "list", table.concat(parts, "|"))
    return
  end

  if cmd == "read" then
    local side = tonumber((select(2, ...)))
    if not side or side < 0 or side > 5 then
      modem.send(remoteAddr, port, "error", "read: invalid side")
      return
    end
    local color = tonumber((select(3, ...)))
    if color then
      if color < 0 or color > 15 then
        modem.send(remoteAddr, port, "error", "read: invalid color")
        return
      end
      local value = redstone.getBundledInput(side, color)
      snapshot[side] = snapshot[side] or {}
      snapshot[side][color] = value
      modem.send(remoteAddr, port, "read", side, color, value)
    else
      refreshSnapshot(side)
      modem.send(remoteAddr, port, "read", side, serializeSideSnapshot(side))
    end
    return
  end

  if cmd == "write" then
    local side = tonumber((select(2, ...)))
    local color = tonumber((select(3, ...)))
    local value = tonumber((select(4, ...)))
    if not side or not color or not value or color < 0 or color > 15 or side < 0 or side > 5 then
      modem.send(remoteAddr, port, "error", "write: expected side,color,value (0..5, 0..15, integer)")
      return
    end
    local oldValue = redstone.setBundledOutput(side, color, value)
    snapshot[side] = snapshot[side] or {}
    snapshot[side][color] = value
    -- Output writes do not emit `redstone_changed` on our own address; we
    -- broadcast the change so any other listener stays in sync.
    modem.broadcast(SERVICE_PORT, "changed", side, color, oldValue, value)
    modem.send(remoteAddr, port, "wrote", side, color, oldValue)
    return
  end

  modem.send(remoteAddr, port, "error", "unknown command: " .. tostring(cmd))
end

modem.broadcast(DISCOVERY_PORT, "iam", NAME, computer.address(), modemAddress)

local lastHeartbeat = computer.uptime()
-- modem_message payload max parts = 8 (default maxNetworkPacketParts).
-- p1..p4 are the header (localAddr, remoteAddr, port, Distance), p5..p12 are
-- the up-to-8 payload args. redstone_changed uses p1=addr, p2..p5 per the
-- signal signature, so we over-declare and reuse the slots per event type.
while true do
  local ok, name, _, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12 = pcall(computer.pullSignal, PULL_TIMEOUT)
  if ok then
    if name == "modem_message" then
      local remoteAddr, port = p2, p3
      if remoteAddr and port then
        local cmdOk, err = pcall(handleCommand, remoteAddr, port, p5, p6, p7, p8, p9, p10, p11, p12)
        if not cmdOk then
          pcall(modem.send, remoteAddr, port, "error", tostring(err))
        end
      end
    elseif name == "redstone_changed" then
      -- p1=rsAddress, p2=side, p3=oldValue, p4=newValue, p5=color (nil for unbundled)
      local side, oldValue, newValue, color = p2, p3, p4, p5
      if type(side) == "number" then
        activeSides[side] = true
        if type(color) == "number" then
          snapshot[side] = snapshot[side] or {}
          snapshot[side][color] = newValue
          modem.broadcast(SERVICE_PORT, "changed", side, color, oldValue, newValue)
        else
          -- Vanilla (non-bundled) change. Forward with color = -1 marker so
          -- listeners can still respond to side-level analog changes.
          modem.broadcast(SERVICE_PORT, "changed", side, -1, oldValue, newValue)
        end
      end
    end
  end

  if computer.uptime() - lastHeartbeat >= HEARTBEAT_INTERVAL then
    lastHeartbeat = computer.uptime()
    pcall(modem.broadcast, DISCOVERY_PORT, "beat", NAME, computer.address())
  end
end
