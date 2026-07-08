-- Teleport protocol state machine and wire-message handling.
-- Drives the full lifecycle: peer discovery (HELLO/HB/PONG/BYE), name
-- propagation (RENAME), and the teleport handshake (TP_REQ -> TP_ACK ->
-- TP_SYNC/TP_PWR countdown -> TP_DONE/TP_ABORT -> TP_COOL cooldown).
-- Owns all FSM state and every protocol-internal timer; exposes a snapshot
-- of that state for the UI to render, plus entry points for user actions
-- (request_teleport, abort_user_cancel) and periodic tasks (discover,
-- heartbeat).

local computer = require("computer")
local event = require("event")

return function(deps)
  local config = deps.config
  local util = deps.util
  local modem = deps.modem
  local ae2 = deps.ae2
  local redstone = deps.redstone
  local peers = deps.peers
  local app = deps.app

  local MT = config.MT
  local OUTCOME = config.OUTCOME

  -- FSM states: IDLE | REQUESTING | COUNTDOWN_LOCAL | COUNTDOWN_REMOTE | COOLDOWN
  local APP_STATE = "IDLE"

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
  local cooldown_total = config.COOLDOWN_DURATION
  local cooldown_authority = false

  local countdown_timer = nil
  local cooldown_timer = nil
  local sync_hang_timer = nil
  local dest_hang_timer = nil
  local request_timeout_timer = nil
  local remote_cooldown_timer = nil

  local function next_seq()
    tp_seq = tp_seq + 1
    return config.MY_ADDR .. ":" .. tp_seq
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

  local abort_teleport

  local function start_cooldown(outcome_code, reason, seq, is_authority, initial_rem, initial_total)
    if app.shutting_down then
      return
    end
    cancel_countdown_timers()
    APP_STATE = "COOLDOWN"
    cooldown_remaining = initial_rem or config.COOLDOWN_DURATION
    cooldown_total = initial_total or config.COOLDOWN_DURATION
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
        modem.send({
          t = MT.TP_COOL,
          s = config.MY_ADDR,
          id = seq,
          rem = cooldown_remaining,
          total = cooldown_total,
          oc = outcome_code,
          why = reason,
        })
      end
      app.dirty = true
      if cooldown_remaining <= 0 then
        APP_STATE = "IDLE"
        cooldown_remaining = 0
        cooldown_timer = nil
        cooldown_authority = false
        tp_outcome = nil
        tp_outcome_reason = nil
        tp_outcome_seq = nil
        app.dirty = true
      end
    end, ticks_needed)
    app.dirty = true
  end

  abort_teleport = function(outcome_code, reason, broadcast, is_authority)
    if app.shutting_down then
      return
    end
    local seq = tp_active_seq
    if broadcast and seq then
      modem.send({
        t = MT.TP_ABORT,
        s = config.MY_ADDR,
        id = seq,
        oc = outcome_code,
        why = reason,
      })
    end
    start_cooldown(outcome_code, reason, seq, is_authority)
    peers.clear_selected()
  end

  local function complete_teleport()
    if app.shutting_down then
      return
    end
    local seq = tp_active_seq
    modem.send({
      t = MT.TP_DONE,
      s = config.MY_ADDR,
      id = seq,
      oc = OUTCOME.CONFIRMED,
      why = "Warp completed",
    })
    start_cooldown(OUTCOME.CONFIRMED, "Warp completed", seq, true)
    peers.clear_selected()
  end

  local function reset_sync_hang(seq)
    if sync_hang_timer then
      event.cancel(sync_hang_timer)
    end
    sync_hang_timer = event.timer(config.SYNC_HANG_TIMEOUT, function()
      sync_hang_timer = nil
      if app.shutting_down then
        return
      end
      if APP_STATE == "COUNTDOWN_REMOTE" and tp_active_seq == seq then
        abort_teleport(
          OUTCOME.LOST_SYNC,
          "Initiator stopped broadcasting (no TP_SYNC for " .. config.SYNC_HANG_TIMEOUT .. "s)",
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
    dest_hang_timer = event.timer(config.DEST_HANG_TIMEOUT, function()
      dest_hang_timer = nil
      if app.shutting_down then
        return
      end
      if APP_STATE == "COUNTDOWN_LOCAL" and tp_active_seq == seq then
        abort_teleport(
          OUTCOME.DEST_UNREACHABLE,
          "Destination stopped responding (no TP_PWR for " .. config.DEST_HANG_TIMEOUT .. "s)",
          true,
          true
        )
      end
    end, 1)
  end

  local function broadcast_tp_sync(seq, rem, total)
    local src_power = ae2.get_power()
    tp_src_power_val = src_power
    tp_src_power_ok = src_power >= config.AE_POWER_REQUIRED
    modem.send({
      t = MT.TP_SYNC,
      s = config.MY_ADDR,
      id = seq,
      rem = rem,
      total = total,
      d = tp_active_dest,
      sp = src_power,
      sok = tp_src_power_ok,
    })
  end

  local function broadcast_tp_pwr(seq)
    local dest_power = ae2.get_power()
    tp_dest_power_val = dest_power
    tp_dest_power_ok = dest_power >= config.AE_POWER_REQUIRED
    tp_dest_power_ts = computer.uptime()
    modem.send({
      t = MT.TP_PWR,
      s = config.MY_ADDR,
      id = seq,
      pwr = dest_power,
      ok = tp_dest_power_ok,
    })
  end

  local function start_countdown(src, dest, seq, dest_power_ok, dest_power_val, is_local)
    if app.shutting_down then
      return
    end
    tp_active_seq = seq
    tp_active_src = src
    tp_active_dest = dest
    tp_countdown_remaining = config.COUNTDOWN_DURATION
    tp_dest_power_ok = dest_power_ok
    tp_dest_power_val = dest_power_val
    tp_dest_power_ts = computer.uptime()
    APP_STATE = is_local and "COUNTDOWN_LOCAL" or "COUNTDOWN_REMOTE"

    if is_local then
      tp_src_power_val = ae2.get_power()
      tp_src_power_ok = tp_src_power_val >= config.AE_POWER_REQUIRED
      broadcast_tp_sync(seq, tp_countdown_remaining, config.COUNTDOWN_DURATION)
      reset_dest_hang(seq)
      if countdown_timer then
        event.cancel(countdown_timer)
      end
      countdown_timer = event.timer(1, function()
        local our_power = ae2.get_power()
        tp_src_power_val = our_power
        tp_src_power_ok = our_power >= config.AE_POWER_REQUIRED
        if not tp_src_power_ok then
          countdown_timer = nil
          abort_teleport(OUTCOME.SRC_POWER, "Source power dropped below threshold", true, true)
          return
        end
        tp_countdown_remaining = tp_countdown_remaining - 1
        if tp_countdown_remaining > 0 then
          broadcast_tp_sync(seq, tp_countdown_remaining, config.COUNTDOWN_DURATION)
        end
        app.dirty = true
        if tp_countdown_remaining <= 0 then
          countdown_timer = nil
          complete_teleport()
        end
      end, config.COUNTDOWN_DURATION)
    else
      tp_src_power_val = 0
      tp_src_power_ok = false
      reset_sync_hang(seq)
    end
    app.dirty = true
  end

  local function request_teleport(dest_addr)
    if app.shutting_down then
      return
    end
    if
      APP_STATE ~= "IDLE"
      or not peers.get(dest_addr)
      or not peers.get(dest_addr).online
      or dest_addr == config.MY_ADDR
    then
      return
    end
    local seq = next_seq()
    tp_active_seq = seq
    tp_active_src = config.MY_ADDR
    tp_active_dest = dest_addr
    peers.set_selected(dest_addr)
    APP_STATE = "REQUESTING"
    app.dirty = true

    local peer = peers.get(dest_addr)
    local modem_target = peer and peer.modem_addr or dest_addr
    modem.send({ t = MT.TP_REQ, s = config.MY_ADDR, d = dest_addr, id = seq }, modem_target)

    if request_timeout_timer then
      event.cancel(request_timeout_timer)
    end
    request_timeout_timer = event.timer(5, function()
      request_timeout_timer = nil
      if app.shutting_down then
        return
      end
      if APP_STATE == "REQUESTING" and tp_active_seq == seq then
        abort_teleport(OUTCOME.NO_RESPONSE, "Destination did not respond", true, true)
      end
    end, 1)
  end

  local function abort_if_unhealthy()
    if APP_STATE ~= "COUNTDOWN_LOCAL" and APP_STATE ~= "COUNTDOWN_REMOTE" and APP_STATE ~= "REQUESTING" then
      return
    end
    local unhealthy, reason = redstone.check_health()
    if not unhealthy then
      return
    end
    -- Only the source and destination may abort; an observer that happens to
    -- have its own hardware fault must not broadcast TP_ABORT and kill an
    -- unrelated teleport between two other nodes.
    if APP_STATE == "COUNTDOWN_REMOTE" and tp_active_dest ~= config.MY_ADDR then
      return
    end
    local full_reason = "Hardware fault: " .. (reason or "unknown")
    local is_initiator = (APP_STATE == "COUNTDOWN_LOCAL" or APP_STATE == "REQUESTING")
    abort_teleport(OUTCOME.HW_FAULT, full_reason, true, is_initiator)
  end

  local function handle_message(remote_addr, port, payload)
    if port ~= config.PORT then
      return
    end
    local msg = util.unpack_msg(payload)
    if not msg or not msg.t then
      return
    end

    local src = msg.s
    if src == config.MY_ADDR then
      return
    end

    if msg.t == MT.HELLO then
      event.timer(util.random_delay(1, 5), function()
        local unhealthy = redstone.check_health()
        modem.send({
          t = MT.PONG,
          s = config.MY_ADDR,
          n = config.get_name(),
          d = src,
          rh = redstone.is_red_high(),
          hl = not unhealthy,
        }, remote_addr)
      end, 1)
      peers.beat(src, msg.n, remote_addr, msg.rh, msg.hl)
      return
    end
    if msg.t == MT.HB then
      peers.beat(src, msg.n, remote_addr, msg.rh, msg.hl)
      return
    end
    if msg.t == MT.BYE then
      peers.mark_offline(src)
      return
    end
    if msg.t == MT.PONG then
      peers.beat(src, msg.n, remote_addr, msg.rh, msg.hl)
      return
    end
    if msg.t == MT.RENAME then
      peers.rename(src, msg.n)
      return
    end

    if msg.t == MT.TP_REQ then
      if APP_STATE ~= "IDLE" or app.rename_mode then
        modem.send({ t = MT.TP_ACK, s = config.MY_ADDR, d = src, id = msg.id, ok = false, pwr = 0 }, remote_addr)
        return
      end
      local unhealthy, reason = redstone.check_health()
      if unhealthy then
        modem.send({
          t = MT.TP_ACK,
          s = config.MY_ADDR,
          d = src,
          id = msg.id,
          ok = false,
          pwr = 0,
          oc = OUTCOME.HW_FAULT,
          why = "Destination hardware fault: " .. (reason or "unknown"),
        }, remote_addr)
        return
      end
      local our_power = ae2.get_power()
      local power_ok = our_power >= config.AE_POWER_REQUIRED
      modem.send({
        t = MT.TP_ACK,
        s = config.MY_ADDR,
        d = src,
        id = msg.id,
        ok = power_ok,
        pwr = our_power,
      }, remote_addr)
      if power_ok then
        start_countdown(src, config.MY_ADDR, msg.id, true, our_power, false)
      end
      return
    end

    if msg.t == MT.TP_ACK then
      if APP_STATE ~= "REQUESTING" or msg.id ~= tp_active_seq then
        return
      end
      if not msg.ok then
        local outcome_code = msg.oc or OUTCOME.REFUSED
        local why = msg.why or "Destination refused or insufficient power"
        abort_teleport(outcome_code, why, true, true)
        return
      end
      start_countdown(config.MY_ADDR, src, msg.id, true, msg.pwr or 0, true)
      return
    end

    if msg.t == MT.TP_SYNC then
      local is_dest = (msg.d == config.MY_ADDR)
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
        app.dirty = true
      elseif msg.id == tp_active_seq and APP_STATE == "COUNTDOWN_REMOTE" then
        tp_countdown_remaining = msg.rem or tp_countdown_remaining
        tp_src_power_val = msg.sp or tp_src_power_val
        tp_src_power_ok = msg.sok == true
        app.dirty = true
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
      app.dirty = true
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
      local incoming_rem = msg.rem or config.COOLDOWN_DURATION
      local incoming_total = msg.total or config.COOLDOWN_DURATION
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
          app.dirty = true
        end
      elseif APP_STATE == "IDLE" or (APP_STATE == "COOLDOWN" and incoming_seq ~= tp_outcome_seq) then
        start_cooldown(incoming_outcome, incoming_why, incoming_seq, false, incoming_rem, incoming_total)
      end
      return
    end
  end

  local function discover()
    local unhealthy = redstone.check_health()
    modem.send({
      t = MT.HELLO,
      s = config.MY_ADDR,
      n = config.get_name(),
      rh = redstone.is_red_high(),
      hl = not unhealthy,
    })
  end

  local function heartbeat()
    local unhealthy = redstone.check_health()
    modem.send({
      t = MT.HB,
      s = config.MY_ADDR,
      n = config.get_name(),
      ts = computer.uptime(),
      rh = redstone.is_red_high(),
      hl = not unhealthy,
    })
  end

  local function broadcast_rename()
    modem.send({ t = MT.RENAME, s = config.MY_ADDR, n = config.get_name() })
  end

  local function abort_user_cancel()
    local is_auth = (APP_STATE == "REQUESTING" or APP_STATE == "COUNTDOWN_LOCAL")
    abort_teleport(OUTCOME.USER_CANCEL, "Cancelled by " .. config.get_name(), true, is_auth)
  end

  local function snapshot()
    return {
      state = APP_STATE,
      tp_active_seq = tp_active_seq,
      tp_active_src = tp_active_src,
      tp_active_dest = tp_active_dest,
      tp_countdown_remaining = tp_countdown_remaining,
      tp_src_power_ok = tp_src_power_ok,
      tp_src_power_val = tp_src_power_val,
      tp_dest_power_ok = tp_dest_power_ok,
      tp_dest_power_val = tp_dest_power_val,
      tp_dest_power_ts = tp_dest_power_ts,
      tp_outcome = tp_outcome,
      tp_outcome_reason = tp_outcome_reason,
      tp_outcome_seq = tp_outcome_seq,
      cooldown_remaining = cooldown_remaining,
      cooldown_total = cooldown_total,
      cooldown_authority = cooldown_authority,
    }
  end

  local function cancel_all_timers()
    cancel_countdown_timers()
    if cooldown_timer then
      event.cancel(cooldown_timer)
      cooldown_timer = nil
    end
    if request_timeout_timer then
      event.cancel(request_timeout_timer)
      request_timeout_timer = nil
    end
  end

  return {
    handle_message = handle_message,
    request_teleport = request_teleport,
    abort_user_cancel = abort_user_cancel,
    abort_if_unhealthy = abort_if_unhealthy,
    discover = discover,
    heartbeat = heartbeat,
    broadcast_rename = broadcast_rename,
    snapshot = snapshot,
    cancel_all_timers = cancel_all_timers,
  }
end
