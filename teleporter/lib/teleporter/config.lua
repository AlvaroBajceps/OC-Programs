-- Teleporter configuration: protocol constants, timing, and node identity.
-- Single source of truth for magic numbers and the mutable display name,
-- which is persisted to disk so a rename survives reboots.
--
-- Factory module: require once, call the returned function, pass the result
-- to every other teleporter module that needs constants or identity.

local computer = require("computer")

return function()
  -- Per-process RNG seed; uptime is unique per machine so two nodes on the
  -- same wired segment don't collide on discovery backoff.
  math.randomseed(math.floor(computer.uptime() * 1000))

  local MAX_NAME_LEN = 16
  local NAME_FILE = "/home/.teleporter_name"

  local MY_ADDR = computer.address()
  local MY_NAME = "Node-" .. MY_ADDR:sub(1, 6)

  local function persist_name()
    local ok, f = pcall(io.open, NAME_FILE, "w")
    if ok and f then
      f:write(MY_NAME)
      f:close()
    end
  end

  local function load_name_from_disk()
    local ok, f = pcall(io.open, NAME_FILE, "r")
    if ok and f then
      local content = f:read("*a")
      f:close()
      if content and #content > 0 then
        MY_NAME = content:sub(1, MAX_NAME_LEN)
      end
    end
  end

  load_name_from_disk()

  return {
    PORT = 4200,
    HEARTBEAT_INTERVAL = 60,
    OFFLINE_TIMEOUT = 150,
    COOLDOWN_DURATION = 15,
    COUNTDOWN_DURATION = 10,
    AE_POWER_REQUIRED = 900000,
    MAX_NAME_LEN = MAX_NAME_LEN,
    NAME_FILE = NAME_FILE,
    SYNC_HANG_TIMEOUT = 5,
    DEST_HANG_TIMEOUT = 5,
    POWER_STALE_SEC = 3,
    CONFIRM_TIMEOUT = 10,
    RECOVERY_DURATION = 3,
    -- OC bundled-redstone color bit indices (ProjectRed / RedLogic compatible,
    -- match OpenOS colors.red / colors.black). Inlined to avoid a require for
    -- just two constants.
    COLOR_RED = 14,
    COLOR_BLACK = 15,
    OUTCOME = {
      CONFIRMED = "ok",
      USER_CANCEL = "user",
      REFUSED = "refused",
      NO_RESPONSE = "noresp",
      SRC_POWER = "srcpwr",
      DST_POWER = "dstpwr",
      LOST_SYNC = "lostsync",
      DEST_UNREACHABLE = "destgone",
      NETWORK_CANCEL = "netcancel",
      HW_FAULT = "hwfault",
      NO_CHAMBER = "nochamber",
      CHAMBER_LOST = "chamberlost",
    },
    -- Short single-char tags for payload efficiency on the wire.
    MT = {
      HELLO = "h",
      BYE = "b",
      HB = "! ",
      PONG = "= ",
      TP_REQ = "R",
      TP_ACK = "A",
      TP_SYNC = "S",
      TP_PWR = "P",
      TP_ABORT = "X",
      TP_DONE = "D",
      TP_COOL = "C",
      TP_SUMMON = "M",
      TP_FIRE = "F",
      RENAME = "N",
    },
    MY_ADDR = MY_ADDR,
    get_name = function()
      return MY_NAME
    end,
    set_name = function(name)
      MY_NAME = name:sub(1, MAX_NAME_LEN)
      persist_name()
    end,
  }
end
