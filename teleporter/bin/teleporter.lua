-- AE2 Spatial Teleportation Safety System (mock).
-- Lua 5.2, T2 computer + T2 screen, GTNH OpenComputers fork.
--
-- Prerequisites (in-world):
--   * Network Card in a card slot of each computer
--   * All computers connected via OC cable (same wired segment)
--   * T2 Screen + Keyboard attached
--   * Optional: an Adapter touching an me_controller for real AE power telemetry

local component = require("component")
local computer = require("computer")
local event = require("event")
local serialization = require("serialization")

-- ---------------------------------------------------------------------------
-- Protocol constants
-- ---------------------------------------------------------------------------

local PORT = 4200

local HEARTBEAT_INTERVAL = 60
local OFFLINE_TIMEOUT = 150
local COOLDOWN_DURATION = 15
local COUNTDOWN_DURATION = 10
local AE_POWER_REQUIRED = 900000
local MAX_NAME_LEN = 16
local NAME_FILE = "/home/.teleporter_name"

local SYNC_HANG_TIMEOUT = 5
local DEST_HANG_TIMEOUT = 5
local POWER_STALE_SEC = 3

local OUTCOME = {
  CONFIRMED = "ok",
  USER_CANCEL = "user",
  REFUSED = "refused",
  NO_RESPONSE = "noresp",
  SRC_POWER = "srcpwr",
  DST_POWER = "dstpwr",
  LOST_SYNC = "lostsync",
  DEST_UNREACHABLE = "destgone",
  NETWORK_CANCEL = "netcancel",
}

-- Short single-char tags for payload efficiency.
local MT = {
  HELLO = "h",
  BYE = "b",
  HB = "! ",
  PING = "? ",
  PONG = "= ",
  TP_REQ = "R",
  TP_ACK = "A",
  TP_SYNC = "S",
  TP_PWR = "P",
  TP_ABORT = "X",
  TP_DONE = "D",
  TP_COOL = "C",
  RENAME = "N",
}

-- ---------------------------------------------------------------------------
-- Globals / state
-- ---------------------------------------------------------------------------

-- Seeds differ per machine (uptime is unique).
math.randomseed(math.floor(computer.uptime() * 1000))

local MY_ADDR = computer.address()
local MY_NAME = "Node-" .. MY_ADDR:sub(1, 6)

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

local function persist_name()
  local ok, f = pcall(io.open, NAME_FILE, "w")
  if ok and f then
    f:write(MY_NAME)
    f:close()
  end
end

-- Peer table: { [addr] = { name: string, last_beat: number, online: bool } }
local peers = {}

-- FSM states: IDLE | REQUESTING | COUNTDOWN_LOCAL | COUNTDOWN_REMOTE | COOLDOWN
local APP_STATE = "IDLE"
local selected_peer = nil
local tp_seq = 0
local tp_active_seq = nil
local tp_active_src = nil
local tp_active_dest = nil
local tp_countdown_remaining = 0
local tp_src_power_ok = false
local tp_src_power_val = 0
local tp_dest_power_ok = false
local tp_dest_power_val = 0
local tp_dest_power_ts = 0
local tp_outcome = nil
local tp_outcome_reason = nil
local tp_outcome_seq = nil
local cooldown_remaining = 0
local cooldown_total = COOLDOWN_DURATION
local cooldown_authority = false
local force_redraw = true

local rename_mode = false
local rename_buffer = ""

local gpu
local screen_addr
local scr_w, scr_h = 80, 25
local back_buf = nil

local hit_regions = {}

local countdown_timer = nil
local cooldown_timer = nil
local sync_hang_timer = nil
local dest_hang_timer = nil

-- Infinite repeating timers (tracked for cancellation on shutdown)
local hb_timer = nil
local refresh_timer = nil
local discover_timer = nil

-- One-shot timers that may still be live at shutdown
local request_timeout_timer = nil
local remote_cooldown_timer = nil

-- Event listener IDs (tracked for explicit removal on shutdown)
local modem_listener = nil
local touch_listener = nil
local key_listener = nil

-- Shutdown guard: prevents re-entrant cleanup and post-shutdown resource creation
local shutting_down = false

-- ---------------------------------------------------------------------------
-- Serialization helpers (modem only transports basic types)
-- ---------------------------------------------------------------------------

local function pack(tbl)
  return serialization.serialize(tbl)
end

local function unpack_msg(payload)
  local ok, result = pcall(serialization.unserialize, payload)
  if ok and type(result) == "table" then
    return result
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Modem setup
-- ---------------------------------------------------------------------------

local function setup_modem()
  if not component.isAvailable("modem") then
    error("No modem (network card) found. Insert a Network Card and retry.")
  end
  local m = component.modem
  if not m.isWired() then
    error("Modem is not wired. Use a wired Network Card.")
  end
  m.open(PORT)
  return m
end

local modem = setup_modem()

-- ---------------------------------------------------------------------------
-- GPU / Screen setup
-- ---------------------------------------------------------------------------

local function setup_screen()
  if not component.isAvailable("gpu") or not component.isAvailable("screen") then
    error("No GPU or screen found. Attach a T2 screen and GPU.")
  end
  gpu = component.gpu
  local scr = component.screen
  screen_addr = scr.address
  scr.turnOn()
  gpu.bind(screen_addr, false)
  local max_w, max_h = gpu.maxResolution()
  scr_w, scr_h = gpu.getResolution()
  if scr_w < 60 or scr_h < 20 then
    gpu.setResolution(math.min(max_w, 80), math.min(max_h, 25))
    scr_w, scr_h = gpu.getResolution()
  end
  back_buf = gpu.allocateBuffer(scr_w, scr_h)
  if not back_buf then
    error("GPU does not have enough VRAM for a back-buffer. Reduce resolution.")
  end
end

setup_screen()

-- ---------------------------------------------------------------------------
-- Double-buffered flip: copy back-buffer to screen
-- ---------------------------------------------------------------------------

local function flip()
  gpu.setActiveBuffer(0)
  gpu.bitblt(0, 1, 1, scr_w, scr_h, back_buf, 1, 1)
  gpu.setActiveBuffer(back_buf)
end

-- ---------------------------------------------------------------------------
-- AE2 power query (mock fallback if no me_controller present)
-- ---------------------------------------------------------------------------

local function get_ae_power()
  if component.isAvailable("me_controller") then
    local ok, val = pcall(function()
      return component.me_controller.getStoredPower()
    end)
    if ok and type(val) == "number" then
      return val
    end
  end
  return 2000000
end

-- ---------------------------------------------------------------------------
-- Message send
-- ---------------------------------------------------------------------------

local function send_msg(tbl, target)
  local payload = pack(tbl)
  if not payload then
    return
  end
  if target then
    modem.send(target, PORT, payload)
  else
    modem.broadcast(PORT, payload)
  end
end

-- ---------------------------------------------------------------------------
-- Peer tracking
-- ---------------------------------------------------------------------------

local function peer_beat(addr, name)
  if addr == MY_ADDR then
    return
  end
  if name then
    name = name:sub(1, MAX_NAME_LEN)
  end
  if not peers[addr] then
    peers[addr] = {
      name = name or ("Node-" .. addr:sub(1, 6)),
      last_beat = computer.uptime(),
      online = true,
    }
    force_redraw = true
  else
    peers[addr].last_beat = computer.uptime()
    peers[addr].online = true
    if name and name ~= peers[addr].name then
      peers[addr].name = name
      force_redraw = true
    end
  end
end

local function peer_rename(addr, name)
  if addr == MY_ADDR then
    return
  end
  if peers[addr] and name then
    peers[addr].name = name:sub(1, MAX_NAME_LEN)
    force_redraw = true
  end
end

local function refresh_peer_status()
  local now = computer.uptime()
  local changed = false
  for _, p in pairs(peers) do
    local alive = (now - p.last_beat) < OFFLINE_TIMEOUT
    if p.online ~= alive then
      p.online = alive
      changed = true
    end
  end
  if changed then
    force_redraw = true
  end
  if selected_peer and peers[selected_peer] and not peers[selected_peer].online then
    selected_peer = nil
    force_redraw = true
  end
end

local function all_peers_sorted()
  local t = {}
  for addr, p in pairs(peers) do
    t[#t + 1] = { addr = addr, name = p.name, online = p.online }
  end
  table.sort(t, function(a, b)
    return a.name < b.name
  end)
  return t
end

-- ---------------------------------------------------------------------------
-- Discovery & heartbeat
-- ---------------------------------------------------------------------------

local function random_delay(min_sec, max_sec)
  return min_sec + math.random() * (max_sec - min_sec)
end

local function discover()
  send_msg({ t = MT.HELLO, s = MY_ADDR, n = MY_NAME })
  send_msg({ t = MT.PING, s = MY_ADDR, d = "*" })
end

local function heartbeat()
  send_msg({ t = MT.HB, s = MY_ADDR, n = MY_NAME, ts = computer.uptime() })
end

local function broadcast_rename()
  persist_name()
  send_msg({ t = MT.RENAME, s = MY_ADDR, n = MY_NAME })
end

-- ---------------------------------------------------------------------------
-- Teleport protocol: state machine
-- ---------------------------------------------------------------------------

local function next_seq()
  tp_seq = tp_seq + 1
  return MY_ADDR .. ":" .. tp_seq
end

local function cancel_countdown_timers()
  if countdown_timer then
    event.cancel(countdown_timer)
    countdown_timer = nil
  end
  if sync_hang_timer then
    event.cancel(sync_hang_timer)
    sync_hang_timer = nil
  end
  if dest_hang_timer then
    event.cancel(dest_hang_timer)
    dest_hang_timer = nil
  end
  if remote_cooldown_timer then
    event.cancel(remote_cooldown_timer)
    remote_cooldown_timer = nil
  end
end

local function reset_tp_state()
  tp_active_seq = nil
  tp_active_src = nil
  tp_active_dest = nil
  tp_countdown_remaining = 0
  tp_src_power_ok = false
  tp_src_power_val = 0
  tp_dest_power_ok = false
  tp_dest_power_val = 0
  tp_dest_power_ts = 0
end

local function start_cooldown(outcome_code, reason, seq, is_authority, initial_rem, initial_total)
  if shutting_down then
    return
  end
  cancel_countdown_timers()
  APP_STATE = "COOLDOWN"
  cooldown_remaining = initial_rem or COOLDOWN_DURATION
  cooldown_total = initial_total or COOLDOWN_DURATION
  if cooldown_remaining < 0 then
    cooldown_remaining = 0
  end
  cooldown_authority = is_authority
  tp_outcome = outcome_code
  tp_outcome_reason = reason
  tp_outcome_seq = seq
  reset_tp_state()
  if cooldown_timer then
    event.cancel(cooldown_timer)
  end
  local ticks_needed = cooldown_remaining
  if ticks_needed < 1 then
    ticks_needed = 1
  end
  cooldown_timer = event.timer(1, function()
    cooldown_remaining = cooldown_remaining - 1
    if is_authority and seq then
      send_msg({
        t = MT.TP_COOL,
        s = MY_ADDR,
        id = seq,
        rem = cooldown_remaining,
        total = cooldown_total,
        oc = outcome_code,
        why = reason,
      })
    end
    force_redraw = true
    if cooldown_remaining <= 0 then
      APP_STATE = "IDLE"
      cooldown_remaining = 0
      cooldown_timer = nil
      cooldown_authority = false
      tp_outcome = nil
      tp_outcome_reason = nil
      tp_outcome_seq = nil
      force_redraw = true
    end
  end, ticks_needed)
  force_redraw = true
end

local function abort_teleport(outcome_code, reason, broadcast, is_authority)
  if shutting_down then
    return
  end
  local seq = tp_active_seq
  if broadcast and seq then
    send_msg({
      t = MT.TP_ABORT,
      s = MY_ADDR,
      id = seq,
      oc = outcome_code,
      why = reason,
    })
  end
  start_cooldown(outcome_code, reason, seq, is_authority)
  selected_peer = nil
end

local function complete_teleport()
  if shutting_down then
    return
  end
  local seq = tp_active_seq
  send_msg({
    t = MT.TP_DONE,
    s = MY_ADDR,
    id = seq,
    oc = OUTCOME.CONFIRMED,
    why = "Teleportation confirmed",
  })
  start_cooldown(OUTCOME.CONFIRMED, "Teleportation confirmed", seq, true)
  selected_peer = nil
end

local function reset_sync_hang(seq)
  if sync_hang_timer then
    event.cancel(sync_hang_timer)
  end
  sync_hang_timer = event.timer(SYNC_HANG_TIMEOUT, function()
    sync_hang_timer = nil
    if shutting_down then
      return
    end
    if APP_STATE == "COUNTDOWN_REMOTE" and tp_active_seq == seq then
      abort_teleport(
        OUTCOME.LOST_SYNC,
        "Initiator stopped broadcasting (no TP_SYNC for " .. SYNC_HANG_TIMEOUT .. "s)",
        false,
        false
      )
    end
  end, 1)
end

local function reset_dest_hang(seq)
  if dest_hang_timer then
    event.cancel(dest_hang_timer)
  end
  dest_hang_timer = event.timer(DEST_HANG_TIMEOUT, function()
    dest_hang_timer = nil
    if shutting_down then
      return
    end
    if APP_STATE == "COUNTDOWN_LOCAL" and tp_active_seq == seq then
      abort_teleport(
        OUTCOME.DEST_UNREACHABLE,
        "Destination stopped responding (no TP_PWR for " .. DEST_HANG_TIMEOUT .. "s)",
        true,
        true
      )
    end
  end, 1)
end

local function broadcast_tp_sync(seq, rem, total)
  local src_power = get_ae_power()
  tp_src_power_val = src_power
  tp_src_power_ok = src_power >= AE_POWER_REQUIRED
  send_msg({
    t = MT.TP_SYNC,
    s = MY_ADDR,
    id = seq,
    rem = rem,
    total = total,
    d = tp_active_dest,
    sp = src_power,
    sok = tp_src_power_ok,
  })
end

local function broadcast_tp_pwr(seq)
  local dest_power = get_ae_power()
  tp_dest_power_val = dest_power
  tp_dest_power_ok = dest_power >= AE_POWER_REQUIRED
  tp_dest_power_ts = computer.uptime()
  send_msg({
    t = MT.TP_PWR,
    s = MY_ADDR,
    id = seq,
    pwr = dest_power,
    ok = tp_dest_power_ok,
  })
end

local function start_countdown(src, dest, seq, dest_power_ok, dest_power_val, is_local)
  if shutting_down then
    return
  end
  tp_active_seq = seq
  tp_active_src = src
  tp_active_dest = dest
  tp_countdown_remaining = COUNTDOWN_DURATION
  tp_dest_power_ok = dest_power_ok
  tp_dest_power_val = dest_power_val
  tp_dest_power_ts = computer.uptime()
  APP_STATE = is_local and "COUNTDOWN_LOCAL" or "COUNTDOWN_REMOTE"

  if is_local then
    tp_src_power_val = get_ae_power()
    tp_src_power_ok = tp_src_power_val >= AE_POWER_REQUIRED
    broadcast_tp_sync(seq, tp_countdown_remaining, COUNTDOWN_DURATION)
    reset_dest_hang(seq)
    if countdown_timer then
      event.cancel(countdown_timer)
    end
    countdown_timer = event.timer(1, function()
      local our_power = get_ae_power()
      tp_src_power_val = our_power
      tp_src_power_ok = our_power >= AE_POWER_REQUIRED
      if not tp_src_power_ok then
        countdown_timer = nil
        abort_teleport(OUTCOME.SRC_POWER, "Source power dropped below threshold", true, true)
        return
      end
      tp_countdown_remaining = tp_countdown_remaining - 1
      if tp_countdown_remaining > 0 then
        broadcast_tp_sync(seq, tp_countdown_remaining, COUNTDOWN_DURATION)
      end
      force_redraw = true
      if tp_countdown_remaining <= 0 then
        countdown_timer = nil
        complete_teleport()
      end
    end, COUNTDOWN_DURATION)
  else
    tp_src_power_val = 0
    tp_src_power_ok = false
    reset_sync_hang(seq)
  end
  force_redraw = true
end

local function request_teleport(dest_addr)
  if shutting_down then
    return
  end
  if APP_STATE ~= "IDLE" or not peers[dest_addr] or not peers[dest_addr].online or dest_addr == MY_ADDR then
    return
  end
  local seq = next_seq()
  tp_active_seq = seq
  tp_active_src = MY_ADDR
  tp_active_dest = dest_addr
  selected_peer = dest_addr
  APP_STATE = "REQUESTING"
  force_redraw = true

  send_msg({ t = MT.TP_REQ, s = MY_ADDR, d = dest_addr, id = seq }, dest_addr)

  if request_timeout_timer then
    event.cancel(request_timeout_timer)
  end
  request_timeout_timer = event.timer(5, function()
    request_timeout_timer = nil
    if shutting_down then
      return
    end
    if APP_STATE == "REQUESTING" and tp_active_seq == seq then
      abort_teleport(OUTCOME.NO_RESPONSE, "Destination did not respond", true, true)
    end
  end, 1)
end

-- ---------------------------------------------------------------------------
-- Incoming message handler
-- ---------------------------------------------------------------------------

local function handle_message(_, port, payload)
  if port ~= PORT then
    return
  end
  local msg = unpack_msg(payload)
  if not msg or not msg.t then
    return
  end

  local src = msg.s
  if src == MY_ADDR then
    return
  end

  if msg.t == MT.HELLO then
    event.timer(random_delay(1, 5), function()
      send_msg({ t = MT.PONG, s = MY_ADDR, n = MY_NAME, d = src }, src)
    end, 1)
    peer_beat(src, msg.n)
    return
  end
  if msg.t == MT.HB then
    peer_beat(src, msg.n)
    return
  end
  if msg.t == MT.BYE then
    if peers[src] then
      peers[src].online = false
      force_redraw = true
    end
    return
  end
  if msg.t == MT.PING then
    if msg.d == "*" or msg.d == MY_ADDR then
      event.timer(random_delay(1, 5), function()
        send_msg({ t = MT.PONG, s = MY_ADDR, n = MY_NAME, d = src }, src)
      end, 1)
    end
    return
  end
  if msg.t == MT.PONG then
    peer_beat(src, msg.n)
    return
  end
  if msg.t == MT.RENAME then
    peer_rename(src, msg.n)
    return
  end

  if msg.t == MT.TP_REQ then
    if APP_STATE ~= "IDLE" or rename_mode then
      send_msg({ t = MT.TP_ACK, s = MY_ADDR, d = src, id = msg.id, ok = false, pwr = 0 }, src)
      return
    end
    local our_power = get_ae_power()
    local power_ok = our_power >= AE_POWER_REQUIRED
    send_msg({
      t = MT.TP_ACK,
      s = MY_ADDR,
      d = src,
      id = msg.id,
      ok = power_ok,
      pwr = our_power,
    }, src)
    if power_ok then
      start_countdown(src, MY_ADDR, msg.id, true, our_power, false)
    end
    return
  end

  if msg.t == MT.TP_ACK then
    if APP_STATE ~= "REQUESTING" or msg.id ~= tp_active_seq then
      return
    end
    if not msg.ok then
      abort_teleport(OUTCOME.REFUSED, "Destination refused or insufficient power", true, true)
      return
    end
    start_countdown(MY_ADDR, src, msg.id, true, msg.pwr or 0, true)
    return
  end

  if msg.t == MT.TP_SYNC then
    local is_dest = (msg.d == MY_ADDR)
    if msg.id ~= tp_active_seq and APP_STATE == "IDLE" then
      tp_active_seq = msg.id
      tp_active_src = src
      tp_active_dest = msg.d
      tp_countdown_remaining = msg.rem or 0
      tp_src_power_val = msg.sp or 0
      tp_src_power_ok = msg.sok == true
      tp_dest_power_ok = false
      tp_dest_power_val = 0
      tp_dest_power_ts = 0
      APP_STATE = "COUNTDOWN_REMOTE"
      force_redraw = true
    elseif msg.id == tp_active_seq and APP_STATE == "COUNTDOWN_REMOTE" then
      tp_countdown_remaining = msg.rem or tp_countdown_remaining
      tp_src_power_val = msg.sp or tp_src_power_val
      tp_src_power_ok = msg.sok == true
      force_redraw = true
    else
      return
    end
    reset_sync_hang(msg.id)
    if is_dest then
      broadcast_tp_pwr(msg.id)
    end
    return
  end

  if msg.t == MT.TP_PWR then
    if msg.id ~= tp_active_seq then
      return
    end
    tp_dest_power_val = msg.pwr or 0
    tp_dest_power_ok = msg.ok == true
    tp_dest_power_ts = computer.uptime()
    force_redraw = true
    if APP_STATE == "COUNTDOWN_LOCAL" then
      reset_dest_hang(msg.id)
      if not tp_dest_power_ok then
        abort_teleport(OUTCOME.DST_POWER, "Destination power dropped below threshold", true, true)
      end
    end
    return
  end

  if msg.t == MT.TP_ABORT then
    local why = msg.why or "Cancelled by another peer"
    local outcome_code = msg.oc or OUTCOME.NETWORK_CANCEL
    if tp_active_seq and msg.id == tp_active_seq then
      local was_initiator = (APP_STATE == "COUNTDOWN_LOCAL" or APP_STATE == "REQUESTING")
      abort_teleport(outcome_code, why, false, was_initiator)
    elseif APP_STATE == "IDLE" then
      start_cooldown(outcome_code, why, msg.id, false)
    end
    return
  end

  if msg.t == MT.TP_DONE then
    local relevant = (APP_STATE == "COUNTDOWN_REMOTE" and msg.id == tp_active_seq) or APP_STATE == "IDLE"
    if relevant then
      start_cooldown(msg.oc or OUTCOME.CONFIRMED, msg.why or "Teleportation confirmed", msg.id, false)
    end
    return
  end

  if msg.t == MT.TP_COOL then
    local incoming_seq = msg.id
    local incoming_rem = msg.rem or COOLDOWN_DURATION
    local incoming_total = msg.total or COOLDOWN_DURATION
    local incoming_outcome = msg.oc or OUTCOME.CONFIRMED
    local incoming_why = msg.why or ""
    if APP_STATE == "COOLDOWN" and incoming_seq == tp_outcome_seq then
      local changed = false
      if incoming_outcome ~= tp_outcome then
        tp_outcome = incoming_outcome
        changed = true
      end
      if incoming_why ~= tp_outcome_reason then
        tp_outcome_reason = incoming_why
        changed = true
      end
      if incoming_rem < cooldown_remaining then
        cooldown_remaining = incoming_rem
        cooldown_total = incoming_total
        changed = true
      end
      if changed then
        force_redraw = true
      end
    elseif APP_STATE == "IDLE" or (APP_STATE == "COOLDOWN" and incoming_seq ~= tp_outcome_seq) then
      start_cooldown(incoming_outcome, incoming_why, incoming_seq, false, incoming_rem, incoming_total)
    end
    return
  end
end

-- ---------------------------------------------------------------------------
-- UI: drawing helpers
-- ---------------------------------------------------------------------------

local function draw_box(x, y, w, h, border_color, bg_color)
  gpu.setBackground(bg_color)
  gpu.setForeground(border_color)
  for col = x, x + w - 1 do
    gpu.set(col, y, "\226\148\128")
    gpu.set(col, y + h - 1, "\226\148\128")
  end
  for row = y + 1, y + h - 2 do
    gpu.set(x, row, "\226\148\130")
    gpu.set(x + w - 1, row, "\226\148\130")
  end
  gpu.set(x, y, "\226\148\140")
  gpu.set(x + w - 1, y, "\226\148\144")
  gpu.set(x, y + h - 1, "\226\148\148")
  gpu.set(x + w - 1, y + h - 1, "\226\148\152")
  gpu.setBackground(bg_color)
  for row = y + 1, y + h - 2 do
    for col = x + 1, x + w - 2 do
      gpu.set(col, row, " ")
    end
  end
end

local function draw_text_centered(x, y, w, text, fg, bg)
  gpu.setBackground(bg or 0x000000)
  gpu.setForeground(fg or 0xFFFFFF)
  local start_x = x + math.floor((w - #text) / 2)
  if start_x < 1 then
    start_x = 1
  end
  gpu.set(start_x, y, text)
end

local function draw_filled_button(x, y, w, h, text, fg, bg, border_color)
  draw_box(x, y, w, h, border_color, bg)
  gpu.setBackground(bg)
  gpu.setForeground(fg)
  local tlen = #text
  local tx = x + math.floor((w - tlen) / 2)
  if tx < x + 1 then
    tx = x + 1
  end
  gpu.set(tx, y + math.floor(h / 2), text)
end

-- ---------------------------------------------------------------------------
-- UI: normal screen (peer list + action button)
-- ---------------------------------------------------------------------------

local function render_normal()
  hit_regions = {}
  gpu.setBackground(0x000000)
  gpu.fill(1, 1, scr_w, scr_h, " ")

  gpu.setBackground(0x1A1A2E)
  gpu.setForeground(0x00BFFF)
  gpu.fill(1, 1, scr_w, 1, " ")
  draw_text_centered(1, 1, scr_w, " AE2 Spatial Teleporter ", 0x00BFFF, 0x1A1A2E)

  local rename_label = MY_NAME .. "  \226\156\142"
  local rename_label_w = #rename_label
  local rename_x = scr_w - rename_label_w - 1
  gpu.setBackground(0x1A1A2E)
  gpu.setForeground(0x00FF88)
  gpu.set(rename_x, 1, rename_label)
  hit_regions[#hit_regions + 1] = {
    type = "rename",
    x1 = rename_x,
    y1 = 1,
    x2 = scr_w,
    y2 = 1,
  }

  gpu.setBackground(0x333366)
  gpu.fill(1, 2, scr_w, 1, " ")
  gpu.setBackground(0x000000)

  local sorted = all_peers_sorted()
  local list_y = 3
  local box_w = 22
  local box_h = 5
  local gap = 2
  local margin = 2
  local max_cols = math.floor((scr_w - margin) / (box_w + gap))
  if max_cols < 1 then
    max_cols = 1
  end

  if #sorted == 0 then
    gpu.setForeground(0x888888)
    draw_text_centered(1, list_y + 3, scr_w, "Searching for peers on the network...", 0x888888, 0x000000)
  else
    for i, peer in ipairs(sorted) do
      local col = (i - 1) % max_cols
      local row = math.floor((i - 1) / max_cols)
      local bx = margin + col * (box_w + gap)
      local by = list_y + row * (box_h + gap)
      if by + box_h - 1 <= list_y + 14 then
        local is_sel = (selected_peer == peer.addr)
        local border_color
        local bg_color
        local name_fg
        local status_fg
        if peer.online then
          if is_sel then
            border_color = 0x00DD00
            bg_color = 0x003300
            name_fg = 0x00FF00
            status_fg = 0x00FF00
          else
            border_color = 0x008800
            bg_color = 0x000000
            name_fg = 0xCCFFCC
            status_fg = 0x00AA00
          end
        else
          border_color = 0x444444
          bg_color = 0x000000
          name_fg = 0x666666
          status_fg = 0x555555
        end
        draw_box(bx, by, box_w, box_h, border_color, bg_color)
        gpu.setBackground(bg_color)
        gpu.setForeground(name_fg)
        draw_text_centered(bx, by + 1, box_w, peer.name, name_fg, bg_color)
        gpu.setForeground(status_fg)
        draw_text_centered(bx, by + 2, box_w, peer.online and " LIVE " or "OFFLINE", status_fg, bg_color)
        if peer.addr == MY_ADDR then
          gpu.setForeground(0x888888)
          draw_text_centered(bx, by + 3, box_w, "(you)", 0x888888, bg_color)
        end
        hit_regions[#hit_regions + 1] = {
          type = "peer",
          addr = peer.addr,
          x1 = bx,
          y1 = by,
          x2 = bx + box_w - 1,
          y2 = by + box_h - 1,
          online = peer.online,
        }
      end
    end
  end

  local status_y = scr_h - 6
  gpu.setBackground(0x0A0A0A)
  gpu.fill(1, status_y, scr_w, 3, " ")

  local our_power = get_ae_power()
  local power_ok = our_power >= AE_POWER_REQUIRED
  local power_color = power_ok and 0x00FF00 or 0xFF4444
  gpu.setBackground(0x0A0A0A)
  gpu.setForeground(0x888888)
  gpu.set(2, status_y, "Power:")
  gpu.setForeground(power_color)
  gpu.set(10, status_y, string.format("%.1fM AE / %.1fM AE req", our_power / 1000000, AE_POWER_REQUIRED / 1000000))
  gpu.set(scr_w - 5, status_y, power_ok and " OK " or " LOW")

  local live_count = 0
  local offline_count = 0
  for _, p in pairs(peers) do
    if p.online then
      live_count = live_count + 1
    else
      offline_count = offline_count + 1
    end
  end
  gpu.setForeground(0x888888)
  gpu.set(2, status_y + 1, string.format("Peers: %d live / %d offline", live_count, offline_count))

  local state_text = "Ready"
  if #sorted == 0 then
    state_text = "Discovering..."
  elseif selected_peer then
    local sel = peers[selected_peer]
    state_text = "Selected: " .. (sel and sel.name or "?")
  end
  gpu.setForeground(0x00FF00)
  gpu.set(2, status_y + 2, "Status: " .. state_text)

  local btn_y = scr_h - 2
  local btn_h = 3
  local btn_text = " REQUEST TELEPORTER "
  local btn_w = #btn_text + 4
  local btn_x = math.floor((scr_w - btn_w) / 2)
  local btn_enabled = (selected_peer ~= nil and peers[selected_peer] and peers[selected_peer].online)
  local btn_fg = btn_enabled and 0x000000 or 0x666666
  local btn_bg = btn_enabled and 0x00DD00 or 0x222222
  local btn_border = btn_enabled and 0x00FF00 or 0x444444
  draw_filled_button(btn_x, btn_y - btn_h + 1, btn_w, btn_h, btn_text, btn_fg, btn_bg, btn_border)
  if btn_enabled then
    hit_regions[#hit_regions + 1] = {
      type = "button",
      action = "request",
      x1 = btn_x,
      y1 = btn_y - btn_h + 1,
      x2 = btn_x + btn_w - 1,
      y2 = btn_y,
    }
  end
end

-- ---------------------------------------------------------------------------
-- UI: requesting screen
-- ---------------------------------------------------------------------------

local function render_requesting()
  hit_regions = {}
  gpu.setBackground(0x000000)
  gpu.fill(1, 1, scr_w, scr_h, " ")

  gpu.setBackground(0x002200)
  gpu.setForeground(0x00FF00)
  gpu.fill(1, 1, scr_w, 1, " ")
  draw_text_centered(1, 1, scr_w, " REQUESTING TELEPORT... ", 0x00FF00, 0x002200)

  local dest_name = tp_active_dest and peers[tp_active_dest] and peers[tp_active_dest].name or "unknown"
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  draw_text_centered(1, 5, scr_w, "Destination: " .. dest_name, 0xFFFFFF, 0x000000)
  gpu.setForeground(0x888888)
  draw_text_centered(1, 7, scr_w, "Awaiting destination confirmation...", 0x888888, 0x000000)
  draw_text_centered(1, 8, scr_w, "Checking power availability...", 0x888888, 0x000000)

  local cancel_y = scr_h - 3
  local cancel_w = 20
  local cancel_x = math.floor((scr_w - cancel_w) / 2)
  draw_filled_button(cancel_x, cancel_y, cancel_w, 3, "  CANCEL  ", 0xFFFFFF, 0xAA0000, 0xFF4444)
  hit_regions[#hit_regions + 1] = {
    type = "button",
    action = "cancel",
    x1 = cancel_x,
    y1 = cancel_y,
    x2 = cancel_x + cancel_w - 1,
    y2 = cancel_y + 2,
  }
end

-- ---------------------------------------------------------------------------
-- UI: countdown screen
-- ---------------------------------------------------------------------------

local function render_countdown()
  hit_regions = {}
  gpu.setBackground(0x1A0000)
  gpu.fill(1, 1, scr_w, scr_h, " ")

  gpu.setBackground(0x330000)
  gpu.setForeground(0xFF4444)
  gpu.fill(1, 1, scr_w, 1, " ")
  draw_text_centered(1, 1, scr_w, " WARNING: TELEPORTATION IN PROGRESS ", 0xFF4444, 0x330000)

  local src_name = MY_NAME
  if tp_active_src and peers[tp_active_src] then
    src_name = peers[tp_active_src].name
  end
  local dest_name = ""
  if tp_active_dest and peers[tp_active_dest] then
    dest_name = peers[tp_active_dest].name
  elseif tp_active_dest == MY_ADDR then
    dest_name = MY_NAME
  end
  gpu.setBackground(0x1A0000)
  gpu.setForeground(0xFFAA00)
  draw_text_centered(1, 3, scr_w, src_name .. "  \226\150\182  " .. dest_name, 0xFFAA00, 0x1A0000)

  local bar_x = math.floor(scr_w / 2) - 15
  local bar_y = 7
  gpu.setBackground(0x330000)
  gpu.fill(bar_x, bar_y, 30, 3, " ")

  local pct = tp_countdown_remaining / COUNTDOWN_DURATION
  local fill_w = math.floor(30 * pct)
  if fill_w > 0 then
    gpu.setBackground(pct > 0.3 and 0xFF0000 or 0xFF4400)
    gpu.fill(bar_x, bar_y, fill_w, 3, " ")
  end

  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  draw_text_centered(1, bar_y + 1, scr_w, "COUNTDOWN: " .. tp_countdown_remaining, 0xFFFFFF, 0x000000)

  gpu.setForeground(0xFF2222)
  gpu.setBackground(0x1A0000)
  draw_text_centered(1, 6, scr_w, tostring(tp_countdown_remaining), 0xFF2222, 0x1A0000)

  local dest_stale = tp_dest_power_ts == 0 or (computer.uptime() - tp_dest_power_ts) > POWER_STALE_SEC
  gpu.setForeground(0xAAAAAA)
  gpu.setBackground(0x1A0000)
  draw_text_centered(
    1,
    12,
    scr_w,
    string.format(
      "Source Power: %s %.1fM AE (%s)",
      tp_src_power_ok and "\226\156\148" or "\226\156\150",
      tp_src_power_val / 1000000,
      tp_src_power_ok and "OK" or "INSUFFICIENT"
    ),
    tp_src_power_ok and 0x00FF00 or 0xFF4444,
    0x1A0000
  )
  draw_text_centered(
    1,
    13,
    scr_w,
    string.format(
      "Dest Power:   %s %.1fM AE (%s%s)",
      tp_dest_power_ok and "\226\156\148" or "\226\156\150",
      tp_dest_power_val / 1000000,
      tp_dest_power_ok and "OK" or "INSUFFICIENT",
      dest_stale and " - STALE" or ""
    ),
    tp_dest_power_ok and 0x00FF00 or 0xFF4444,
    0x1A0000
  )
  draw_text_centered(1, 14, scr_w, "Dest Confirmed: \226\156\148", 0x00FF00, 0x1A0000)

  local cancel_y = scr_h - 3
  local cancel_w = 20
  local cancel_x = math.floor((scr_w - cancel_w) / 2)
  draw_filled_button(cancel_x, cancel_y, cancel_w, 3, "  CANCEL  ", 0xFFFFFF, 0xAA0000, 0xFF4444)
  hit_regions[#hit_regions + 1] = {
    type = "button",
    action = "cancel",
    x1 = cancel_x,
    y1 = cancel_y,
    x2 = cancel_x + cancel_w - 1,
    y2 = cancel_y + 2,
  }
  gpu.setForeground(0x888888)
  gpu.setBackground(0x1A0000)
  draw_text_centered(1, scr_h, scr_w, "Press CANCEL on any network computer to abort", 0x888888, 0x1A0000)
end

-- ---------------------------------------------------------------------------
-- UI: rename screen (on-screen keyboard modal)
-- ---------------------------------------------------------------------------

local function render_rename()
  hit_regions = {}
  gpu.setBackground(0x000000)
  gpu.fill(1, 1, scr_w, scr_h, " ")

  local field_w = 50
  local field_x = math.floor((scr_w - field_w) / 2)
  local field_y = 2
  draw_box(field_x, field_y, field_w, 3, 0x00BFFF, 0x000000)
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  local display = rename_buffer
  if #rename_buffer < MAX_NAME_LEN then
    display = display .. "_"
  end
  gpu.set(field_x + 1, field_y + 1, display)
  gpu.setForeground(0x888888)
  gpu.set(field_x + field_w - 6, field_y + 1, string.format("%2d/%d", #rename_buffer, MAX_NAME_LEN))

  local key_w = 5
  local key_h = 3
  local gap = 1
  local kb_y = 6
  local rows = {
    "1234567890",
    "QWERTYUIOP",
    "ASDFGHJKL",
    "ZXCVBNM",
  }
  for r, row in ipairs(rows) do
    local row_w = #row * key_w + (#row - 1) * gap
    local row_x = math.floor((scr_w - row_w) / 2)
    local y = kb_y + (r - 1) * (key_h + gap)
    for i = 1, #row do
      local ch = row:sub(i, i)
      local x = row_x + (i - 1) * (key_w + gap)
      draw_filled_button(x, y, key_w, key_h, " " .. ch .. " ", 0xFFFFFF, 0x222266, 0x444488)
      hit_regions[#hit_regions + 1] = {
        type = "kb_key",
        char = ch,
        x1 = x,
        y1 = y,
        x2 = x + key_w - 1,
        y2 = y + key_h - 1,
      }
    end
  end

  local spec_y = kb_y + 4 * (key_h + gap)
  local space_w = 15
  local bs_w = 9
  local sym_w = 5
  local cancel_w = 11
  local enter_w = 15
  local total_spec = space_w + gap + bs_w + gap + sym_w + gap + sym_w + gap + cancel_w + gap + enter_w
  local spec_x = math.floor((scr_w - total_spec) / 2)
  local cx = spec_x
  draw_filled_button(cx, spec_y, space_w, key_h, "  SPACE  ", 0xFFFFFF, 0x444488, 0x6666AA)
  hit_regions[#hit_regions + 1] = {
    type = "kb_space",
    x1 = cx,
    y1 = spec_y,
    x2 = cx + space_w - 1,
    y2 = spec_y + key_h - 1,
  }
  cx = cx + space_w + gap
  draw_filled_button(cx, spec_y, bs_w, key_h, " BKSP ", 0xFFFFFF, 0xAA3333, 0xFF4444)
  hit_regions[#hit_regions + 1] = {
    type = "kb_back",
    x1 = cx,
    y1 = spec_y,
    x2 = cx + bs_w - 1,
    y2 = spec_y + key_h - 1,
  }
  cx = cx + bs_w + gap
  draw_filled_button(cx, spec_y, sym_w, key_h, " _ ", 0xFFFFFF, 0x222266, 0x444488)
  hit_regions[#hit_regions + 1] = {
    type = "kb_key",
    char = "_",
    x1 = cx,
    y1 = spec_y,
    x2 = cx + sym_w - 1,
    y2 = spec_y + key_h - 1,
  }
  cx = cx + sym_w + gap
  draw_filled_button(cx, spec_y, sym_w, key_h, " - ", 0xFFFFFF, 0x222266, 0x444488)
  hit_regions[#hit_regions + 1] = {
    type = "kb_key",
    char = "-",
    x1 = cx,
    y1 = spec_y,
    x2 = cx + sym_w - 1,
    y2 = spec_y + key_h - 1,
  }
  cx = cx + sym_w + gap
  draw_filled_button(cx, spec_y, cancel_w, key_h, " CANCEL ", 0xFFFFFF, 0xAA0000, 0xFF4444)
  hit_regions[#hit_regions + 1] = {
    type = "kb_cancel",
    x1 = cx,
    y1 = spec_y,
    x2 = cx + cancel_w - 1,
    y2 = spec_y + key_h - 1,
  }
  cx = cx + cancel_w + gap
  local can_commit = #rename_buffer > 0
  draw_filled_button(
    cx,
    spec_y,
    enter_w,
    key_h,
    " ENTER ",
    can_commit and 0x000000 or 0x666666,
    can_commit and 0x00AA00 or 0x222222,
    can_commit and 0x00FF00 or 0x444444
  )
  if can_commit then
    hit_regions[#hit_regions + 1] = {
      type = "kb_enter",
      x1 = cx,
      y1 = spec_y,
      x2 = cx + enter_w - 1,
      y2 = spec_y + key_h - 1,
    }
  end
end

-- ---------------------------------------------------------------------------
-- UI: outcome / cooldown screen
-- ---------------------------------------------------------------------------

local function outcome_label(code)
  if code == OUTCOME.CONFIRMED then
    return "TELEPORT CONFIRMED", 0x00FF66, 0x003311
  end
  if code == OUTCOME.USER_CANCEL then
    return "TELEPORT CANCELED", 0xFFAA00, 0x332200
  end
  return "TELEPORT FAILED", 0xFF4444, 0x330000
end

local function render_cooldown()
  hit_regions = {}
  gpu.setBackground(0x000000)
  gpu.fill(1, 1, scr_w, scr_h, " ")

  local label, label_fg, banner_bg = outcome_label(tp_outcome)
  gpu.setBackground(banner_bg)
  gpu.setForeground(label_fg)
  gpu.fill(1, 1, scr_w, 3, " ")
  draw_text_centered(1, 2, scr_w, " " .. label .. " ", label_fg, banner_bg)

  gpu.setBackground(0x000000)
  gpu.setForeground(0xCCCCCC)
  local reason = tp_outcome_reason or ""
  if #reason > scr_w - 4 then
    reason = reason:sub(1, scr_w - 7) .. "..."
  end
  draw_text_centered(1, 5, scr_w, reason, 0xCCCCCC, 0x000000)

  local src_name = ""
  if tp_outcome_seq then
    local src_addr = tp_outcome_seq:match("^([^:]+):")
    if src_addr and peers[src_addr] then
      src_name = peers[src_addr].name
    elseif src_addr == MY_ADDR then
      src_name = MY_NAME
    end
  end
  if src_name ~= "" then
    gpu.setForeground(0x888888)
    draw_text_centered(1, 7, scr_w, "Sequence origin: " .. src_name, 0x888888, 0x000000)
  end

  local bar_w = math.min(60, scr_w - 8)
  local bar_x = math.floor((scr_w - bar_w) / 2)
  local bar_y = 11
  gpu.setBackground(0x222222)
  gpu.fill(bar_x, bar_y, bar_w, 3, " ")
  local pct = cooldown_total > 0 and (cooldown_remaining / cooldown_total) or 0
  local fill_w = math.floor(bar_w * pct)
  if fill_w > 0 then
    gpu.setBackground(label_fg)
    gpu.fill(bar_x, bar_y, fill_w, 3, " ")
  end
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  draw_text_centered(1, bar_y + 1, scr_w, "COOLDOWN  " .. cooldown_remaining .. "s", 0xFFFFFF, 0x000000)

  gpu.setForeground(0x666666)
  local sync_state = cooldown_authority and "BROADCASTING" or "SYNCED"
  draw_text_centered(1, bar_y + 5, scr_w, "timer: " .. sync_state, 0x666666, 0x000000)

  gpu.setForeground(0x555555)
  draw_text_centered(1, scr_h, scr_w, "All network computers are locked until cooldown ends", 0x555555, 0x000000)
end

-- ---------------------------------------------------------------------------
-- Hit-testing and input handling
-- ---------------------------------------------------------------------------

local function find_hit_region(x, y)
  for _, r in ipairs(hit_regions) do
    if x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2 then
      return r
    end
  end
  return nil
end

local function on_touch(_, _, x, y)
  local region = find_hit_region(x, y)
  if not region then
    return
  end
  if rename_mode then
    if region.type == "kb_key" and #rename_buffer < MAX_NAME_LEN then
      rename_buffer = rename_buffer .. region.char
      force_redraw = true
      return
    end
    if region.type == "kb_space" and #rename_buffer < MAX_NAME_LEN then
      rename_buffer = rename_buffer .. " "
      force_redraw = true
      return
    end
    if region.type == "kb_back" and #rename_buffer > 0 then
      rename_buffer = rename_buffer:sub(1, -2)
      force_redraw = true
      return
    end
    if region.type == "kb_cancel" then
      rename_mode = false
      rename_buffer = ""
      force_redraw = true
      return
    end
    if region.type == "kb_enter" and #rename_buffer > 0 then
      MY_NAME = rename_buffer
      broadcast_rename()
      rename_mode = false
      rename_buffer = ""
      force_redraw = true
      return
    end
    return
  end
  if region.type == "rename" then
    if APP_STATE == "IDLE" then
      rename_mode = true
      rename_buffer = MY_NAME
      force_redraw = true
    end
    return
  end
  if region.type == "peer" then
    if region.online and APP_STATE == "IDLE" then
      selected_peer = region.addr
      force_redraw = true
    end
  elseif region.type == "button" then
    if region.action == "request" and selected_peer and APP_STATE == "IDLE" then
      request_teleport(selected_peer)
    elseif region.action == "cancel" then
      if APP_STATE == "REQUESTING" or APP_STATE == "COUNTDOWN_LOCAL" or APP_STATE == "COUNTDOWN_REMOTE" then
        local is_auth = (APP_STATE == "REQUESTING" or APP_STATE == "COUNTDOWN_LOCAL")
        abort_teleport(OUTCOME.USER_CANCEL, "Cancelled by user", true, is_auth)
      end
    end
  end
end

local function on_key(_, _, _, char, code)
  if not rename_mode then
    return
  end

  if code == 28 then
    if #rename_buffer > 0 then
      MY_NAME = rename_buffer
      broadcast_rename()
    end
    rename_mode = false
    rename_buffer = ""
    force_redraw = true
    return
  end

  -- Escape: cancel rename
  if code == 1 then
    rename_mode = false
    rename_buffer = ""
    force_redraw = true
    return
  end

  if code == 14 then
    rename_buffer = rename_buffer:sub(1, -2)
    force_redraw = true
    return
  end

  if char and char >= 32 and char <= 126 and #rename_buffer < MAX_NAME_LEN then
    rename_buffer = rename_buffer .. string.char(char)
    force_redraw = true
  end
end

-- ---------------------------------------------------------------------------
-- Graceful shutdown: stops all timers, removes listeners, releases hardware
-- ---------------------------------------------------------------------------

local function shutdown()
  if shutting_down then
    return
  end
  shutting_down = true

  if hb_timer then
    event.cancel(hb_timer)
  end
  if refresh_timer then
    event.cancel(refresh_timer)
  end
  if discover_timer then
    event.cancel(discover_timer)
  end
  if countdown_timer then
    event.cancel(countdown_timer)
  end
  if cooldown_timer then
    event.cancel(cooldown_timer)
  end
  if sync_hang_timer then
    event.cancel(sync_hang_timer)
  end
  if dest_hang_timer then
    event.cancel(dest_hang_timer)
  end
  if request_timeout_timer then
    event.cancel(request_timeout_timer)
  end
  if remote_cooldown_timer then
    event.cancel(remote_cooldown_timer)
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

  if modem then
    pcall(send_msg, { t = MT.BYE, s = MY_ADDR, n = MY_NAME })
    modem.close(PORT)
  end

  if gpu and back_buf then
    gpu.setActiveBuffer(0)
    gpu.freeBuffer(back_buf)
  end
end

-- ---------------------------------------------------------------------------
-- Main event loop
-- ---------------------------------------------------------------------------

local function main()
  modem_listener = event.listen("modem_message", function(_, _, remote_addr, port, _, payload)
    handle_message(remote_addr, port, payload)
  end)

  touch_listener = event.listen("touch", on_touch)
  key_listener = event.listen("key_down", on_key)

  hb_timer = event.timer(HEARTBEAT_INTERVAL, heartbeat, math.huge)
  refresh_timer = event.timer(1, refresh_peer_status, math.huge)

  discover()
  discover_timer = event.timer(60, discover, math.huge)

  force_redraw = true

  while true do
    if force_redraw then
      gpu.setActiveBuffer(back_buf)
      if rename_mode then
        render_rename()
      elseif APP_STATE == "IDLE" then
        render_normal()
      elseif APP_STATE == "REQUESTING" then
        render_requesting()
      elseif APP_STATE == "COUNTDOWN_LOCAL" or APP_STATE == "COUNTDOWN_REMOTE" then
        render_countdown()
      elseif APP_STATE == "COOLDOWN" then
        render_cooldown()
      end
      flip()
      force_redraw = false
    end
    local ev = { event.pull(0.5) }
    if ev[1] == "interrupted" then
      pcall(shutdown)
      return
    end
  end
end

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------

local function fatal(msg)
  pcall(shutdown)
  if gpu and screen_addr then
    gpu.setActiveBuffer(0)
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFF0000)
    gpu.fill(1, 1, scr_w, scr_h, " ")
    gpu.set(1, 1, "FATAL: " .. tostring(msg))
  end
  computer.beep(1000, 0.3)
end

local ok, err = pcall(main)
if not ok then
  fatal(err)
  error(err)
end
