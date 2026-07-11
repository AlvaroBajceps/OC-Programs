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
      if s.online and not s.needs_maintenance then
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

    -- 3a. Hysteresis adjustment.
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
      if s.online and not s.needs_maintenance then
        eligible[#eligible + 1] = m
      end
    end

    -- Maintenance / offline pumps: always off.
    for _, m in ipairs(machines) do
      local s = m.get_state()
      if s.work_allowed and (not s.online or s.needs_maintenance) then
        m.set_work_allowed(false, current_uptime)
      end
    end

    -- 3c. Reconcile desired vs actual.
    for i, m in ipairs(eligible) do
      local s = m.get_state()
      local should_be_on = i <= state.desired_active

      if should_be_on and not s.work_allowed then
        -- Enable this pump.
        m.set_work_allowed(true, current_uptime)
        state.last_action = string.format("Enabled pump %d (hot %.0f%%)", s.index, hot_pct * 100)
        state.last_action_time = current_uptime
        _push_history(state.last_action)
      elseif not should_be_on and s.work_allowed then
        -- Disable, but respect min-runtime.
        local runtime = s.on_since and (current_uptime - s.on_since) or 9999
        if runtime >= config.MIN_RUNTIME_S then
          m.set_work_allowed(false, current_uptime)
          state.last_action = string.format("Disabled pump %d (hot %.0f%%)", s.index, hot_pct * 100)
          state.last_action_time = current_uptime
          _push_history(state.last_action)
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
      emergency_cold_amount = config.COLD_EMERGENCY_L,
      history = history,
    }
  end

  return {
    tick = tick,
    snapshot = snapshot,
  }
end
