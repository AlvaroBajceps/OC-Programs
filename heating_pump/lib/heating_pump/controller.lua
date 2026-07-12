-- The core control brain: hot/cold coolant balancing, emergency shutdown,
-- maintenance gating, min-runtime enforcement, and hysteresis deadband.
--
-- Factory: return function(deps) where deps = {config, machines, hot_tank,
--   cold_tank, stats, app}
-- Returns a controller with tick() and snapshot().

return function(deps)
  local config = deps.config
  local machines = deps.machines
  local hot_tank = deps.hot_tank
  local cold_tank = deps.cold_tank
  local stats = deps.stats

  local state = {
    mode = "NORMAL", -- "NORMAL" | "EMERGENCY"
    desired_active = 0,
    last_action = "Initializing",
    last_action_time = nil,
    projected_hot_pct = nil,
    retry_next_at = {}, -- pump index → uptime when next setWorkAllowed attempt is allowed
  }
  local history = {}

  local function _push_history(action)
    table.insert(history, 1, action)
    if #history > config.HISTORY_SIZE then
      history[#history] = nil
    end
  end

  local function _count_active_healthy()
    local count = 0
    for _, m in ipairs(machines) do
      local s = m.get_state()
      if s.online and not s.needs_maintenance and s.work_allowed then
        count = count + 1
      end
    end
    return count
  end

  local function _count_healthy()
    local count = 0
    for _, m in ipairs(machines) do
      local s = m.get_state()
      if s.online and not s.needs_maintenance and not s.low_energy then
        count = count + 1
      end
    end
    return count
  end

  local function _count_total()
    return #machines
  end

  local function _enter_emergency(reason)
    state.mode = "EMERGENCY"
    state.last_action = reason
    state.last_action_time = deps.uptime_fn and deps.uptime_fn() or 0
    _push_history(reason)

    -- Force ALL pumps off immediately, ignoring min-runtime.
    local now = deps.uptime_fn and deps.uptime_fn() or 0
    for _, m in ipairs(machines) do
      local s = m.get_state()
      if s.work_allowed then
        m.set_work_allowed(false, now)
      end
    end
    state.desired_active = 0
  end

  local function tick(current_uptime)
    -- 1. Refresh all data sources.
    for _, m in ipairs(machines) do
      m.refresh()
    end
    hot_tank.refresh()
    cold_tank.refresh()

    local hot = hot_tank.get_state()
    local cold = cold_tank.get_state()
    local active_healthy = _count_active_healthy()

    stats.sample(current_uptime, hot.amount, cold.amount, active_healthy)

    -- 2. Emergency check: cold tank offline or below floor.
    if state.mode == "EMERGENCY" then
      if cold.online and cold.amount and cold.amount >= config.COLD_EMERGENCY_RECOVERY_L then
        state.mode = "NORMAL"
        local msg =
          string.format("Emergency cleared (cold %d L >= recovery %d L)", cold.amount, config.COLD_EMERGENCY_RECOVERY_L)
        state.last_action = msg
        state.last_action_time = current_uptime
        _push_history(msg)
      else
        -- Stay in emergency — ensure all pumps off.
        for _, m in ipairs(machines) do
          local s = m.get_state()
          if s.work_allowed then
            m.set_work_allowed(false, current_uptime)
          end
        end
        return
      end
    end

    -- Fresh emergency detection.
    if not cold.online or cold.amount == nil then
      _enter_emergency("EMERGENCY: cold tank offline — failsafe shutdown (all pumps off)")
      return
    end
    if cold.amount < config.COLD_EMERGENCY_L then
      _enter_emergency(
        string.format(
          "EMERGENCY: cold coolant < floor (%d L < %d L) — all pumps off",
          cold.amount,
          config.COLD_EMERGENCY_L
        )
      )
      return
    end

    -- 3. Normal control.
    local healthy_count = _count_healthy()
    if healthy_count == 0 then
      -- No healthy pumps available — disable everything.
      for _, m in ipairs(machines) do
        local s = m.get_state()
        if s.work_allowed then
          m.set_work_allowed(false, current_uptime)
        end
      end
      state.desired_active = 0
      state.last_action = "No healthy pumps available"
      state.last_action_time = current_uptime
      return
    end

    -- Compute hot/cold percentages with conservative guards.
    local hot_pct
    if not hot.online or not hot.amount or not hot.capacity or hot.capacity <= 0 then
      -- Hot tank unreadable: treat as full so we don't over-produce.
      hot_pct = 1.0
    else
      hot_pct = hot.amount / hot.capacity
    end

    local cold_pct
    if not cold.capacity or cold.capacity <= 0 then
      cold_pct = 0
    else
      cold_pct = (cold.amount or 0) / cold.capacity
    end

    -- Get rates from stats for feedforward projection.
    local _, hot_short = stats.rates()

    -- Project hot tank level for feedforward.
    if hot.capacity and hot.capacity > 0 and hot_short ~= 0 then
      state.projected_hot_pct = hot_pct + (hot_short * config.FF_PROJECTION_S / hot.capacity)
    else
      state.projected_hot_pct = hot_pct
    end

    -- 3a. Hysteresis + feedforward adjustment.
    local prev_desired = state.desired_active

    if hot_pct < config.HOT_LOW_PCT and state.desired_active < healthy_count then
      -- Cold caution check: if cold is low, cap the increase.
      if cold_pct < config.COLD_CAUTION_PCT then
        state.last_action =
          string.format("Cold coolant low (%.0f%%) — holding at %d pumps", cold_pct * 100, state.desired_active)
        state.last_action_time = current_uptime
        _push_history(state.last_action)
      else
        state.desired_active = state.desired_active + 1
        state.last_action =
          string.format("Hot coolant low (%.0f%%) — enabling pump (desired %d)", hot_pct * 100, state.desired_active)
        state.last_action_time = current_uptime
        _push_history(state.last_action)
      end
    elseif hot_pct > config.HOT_HIGH_PCT and state.desired_active > 0 then
      state.desired_active = state.desired_active - 1
      state.last_action =
        string.format("Hot coolant high (%.0f%%) — disabling pump (desired %d)", hot_pct * 100, state.desired_active)
      state.last_action_time = current_uptime
      _push_history(state.last_action)
    elseif
      state.projected_hot_pct < config.HOT_LOW_PCT
      and math.abs(hot_short) > config.FF_MIN_RATE_L_S
      and state.desired_active < healthy_count
    then
      if cold_pct < config.COLD_CAUTION_PCT then
        state.last_action = string.format(
          "FF: hot draining (%.0f L/s) but cold low (%.0f%%) — holding",
          math.abs(hot_short),
          cold_pct * 100
        )
        state.last_action_time = current_uptime
        _push_history(state.last_action)
      else
        state.desired_active = state.desired_active + 1
        state.last_action = string.format(
          "FF: hot draining (%.0f L/s, projected %.0f%%) — enabling pump (%d)",
          math.abs(hot_short),
          state.projected_hot_pct * 100,
          state.desired_active
        )
        state.last_action_time = current_uptime
        _push_history(state.last_action)
      end
    elseif
      state.projected_hot_pct > config.HOT_HIGH_PCT
      and math.abs(hot_short) > config.FF_MIN_RATE_L_S
      and state.desired_active > 0
    then
      state.desired_active = state.desired_active - 1
      state.last_action = string.format(
        "FF: hot filling (%.0f L/s, projected %.0f%%) — disabling pump (%d)",
        math.abs(hot_short),
        state.projected_hot_pct * 100,
        state.desired_active
      )
      state.last_action_time = current_uptime
      _push_history(state.last_action)
    end

    -- Extra safety: if cold is below caution AND we weren't decreasing,
    -- defer any increase that was already queued.
    if cold_pct < config.COLD_CAUTION_PCT and state.desired_active > prev_desired then
      state.desired_active = prev_desired
      if not state.last_action:find("holding at") then
        state.last_action =
          string.format("Cold coolant low (%.0f%%) — holding at %d pumps", cold_pct * 100, state.desired_active)
        state.last_action_time = current_uptime
        _push_history(state.last_action)
      end
    end

    -- 3b. Build ordered list of eligible (healthy + online) pumps.
    local eligible = {}
    for _, m in ipairs(machines) do
      local s = m.get_state()
      if s.online and not s.needs_maintenance and not s.low_energy then
        eligible[#eligible + 1] = m
      end
    end

    local function _eligible_rank(target)
      for j, em in ipairs(eligible) do
        if em == target then
          return j
        end
      end
      return nil
    end

    -- 3c. Reconcile desired vs actual for EVERY pump. Some DEHP controllers
    -- accept setWorkAllowed (pcall ok) but never flip isWorkAllowed — retry
    -- on RETRY_INTERVAL_S boundaries so the mismatch is visible and the call
    -- eventually takes effect.
    for _, m in ipairs(machines) do
      local s = m.get_state()
      local idx = s.index

      local rank = _eligible_rank(m)
      local should_be_on = rank ~= nil and rank <= state.desired_active
      local enforce_min_runtime = rank ~= nil

      local mismatched = should_be_on ~= s.work_allowed
      if not mismatched then
        m.set_retry_status(false, nil)
        state.retry_next_at[idx] = nil
      else
        local next_allowed = state.retry_next_at[idx]
        -- First attempt for a freshly-detected mismatch is immediate;
        -- subsequent attempts are throttled by RETRY_INTERVAL_S.
        local can_retry = next_allowed == nil or current_uptime >= next_allowed

        local min_runtime_locked = false
        if enforce_min_runtime and not should_be_on and s.on_since then
          local runtime = current_uptime - s.on_since
          if runtime < config.MIN_RUNTIME_S then
            min_runtime_locked = true
          end
        end

        if min_runtime_locked then
          -- Intentional hold — don't mark retry_pending.
          m.set_retry_status(false, nil)
        elseif can_retry then
          m.set_work_allowed(should_be_on, current_uptime)
          state.retry_next_at[idx] = current_uptime + config.RETRY_INTERVAL_S
          local verb = should_be_on and "Enabled" or "Disabled"
          state.last_action = string.format("%s pump %d (hot %.0f%%)", verb, idx, hot_pct * 100)
          state.last_action_time = current_uptime
          _push_history(state.last_action)
          -- Optimistically clear retry_pending; the next tick's refresh
          -- will re-flag if isWorkAllowed() still disagrees.
          m.set_retry_status(false, nil)
        else
          m.set_retry_status(true, next_allowed)
        end
      end
    end
  end

  local function snapshot()
    return {
      mode = state.mode,
      desired_active = state.desired_active,
      healthy_count = _count_healthy(),
      total_count = _count_total(),
      last_action = state.last_action,
      last_action_time = state.last_action_time,
      projected_hot_pct = state.projected_hot_pct,
      emergency_cold_amount = config.COLD_EMERGENCY_L,
      history = history,
    }
  end

  return {
    tick = tick,
    snapshot = snapshot,
  }
end
