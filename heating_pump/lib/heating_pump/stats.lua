-- Sliding-window rate tracker for hot/cold tank fill rates.
-- Maintains a ring buffer of samples and computes net-rate deltas over
-- long (60s) and short (10s) windows.
--
-- Factory: return function(deps) where deps = {config}
-- Returns a stats tracker.

return function(deps)
  local config = deps.config

  local max_samples = math.ceil(config.STATS_WINDOW_S / config.TICK_INTERVAL) + 2
  local short_cutoff = config.STATS_SHORT_WINDOW_S

  local samples = {} -- {t, hot_amount, cold_amount, active_pumps}
  local head = 0

  local function sample(t, hot_amount, cold_amount, active_pumps)
    head = head + 1
    samples[head] = {
      t = t,
      hot_amount = hot_amount,
      cold_amount = cold_amount,
      active_pumps = active_pumps,
    }
    -- Evict oldest entries beyond the ring cap.
    local cutoff = head - max_samples
    for i = 1, cutoff do
      samples[i] = nil
    end
  end

  local function _rate_over_window(now, oldest_i)
    local oldest = samples[oldest_i]
    if not oldest then
      return 0, 0
    end
    local dt = now - oldest.t
    if dt <= 0 then
      return 0, 0
    end
    local hot_rate = 0
    local cold_rate = 0
    if samples[head].hot_amount and oldest.hot_amount then
      hot_rate = (samples[head].hot_amount - oldest.hot_amount) / dt
    end
    if samples[head].cold_amount and oldest.cold_amount then
      cold_rate = (samples[head].cold_amount - oldest.cold_amount) / dt
    end
    return hot_rate, cold_rate
  end

  local function _find_oldest_for_window(now, window_s)
    if head < 2 then
      return nil
    end
    local target = now - window_s
    local oldest_i = 1
    for i = 2, head do
      if samples[i].t <= target then
        oldest_i = i
      else
        break
      end
    end
    return oldest_i
  end

  local function rates()
    if head < 2 then
      return 0, 0, 0, 0, 0
    end

    local now = samples[head].t

    local oldest_long = _find_oldest_for_window(now, config.STATS_WINDOW_S)
    local hot_long, cold_long = _rate_over_window(now, oldest_long or 1)

    local oldest_short = _find_oldest_for_window(now, short_cutoff)
    local hot_short, cold_short = _rate_over_window(now, oldest_short or 1)

    local active = samples[head].active_pumps or 0

    return hot_long, hot_short, cold_long, cold_short, active
  end

  return {
    sample = sample,
    rates = rates,
  }
end
