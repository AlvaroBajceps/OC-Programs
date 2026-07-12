-- Deep Earth Heating Pump controller configuration.
-- Single source of truth for thresholds, timing, colors, and screen dimensions.
--
-- Factory module: require once, call the returned function, pass the result
-- to every other heating_pump module that needs constants.

return function()
  return {
    -- Each DEHP produces 3840 L/s hot coolant, consumes 3840 L/s cold coolant.
    PUMP_RATE_L_PER_S = 3840,

    -- Below this cold coolant level (200 kL), emergency shutdown of ALL pumps.
    COLD_EMERGENCY_L = 200000,

    -- Hysteresis: cold coolant must rise above this to EXIT emergency mode.
    COLD_EMERGENCY_RECOVERY_L = 300000,

    -- Below this cold fraction, refuse to enable NEW pumps (caution cap).
    COLD_CAUTION_PCT = 0.25,

    -- Below this stored EU value (flat, not a fraction), a pump is excluded
    -- from the active pool (like maintenance). Running a DEHP with insufficient
    -- energy is useless. DEHP controllers report 17K EU capacity, so 12K leaves
    -- headroom before the machine stalls.
    PUMP_LOW_EU_THRESHOLD = 12000,

    -- When the controller's desired work-allowed state for a pump doesn't
    -- match what isWorkAllowed() reports, re-assert setWorkAllowed on this
    -- interval. Some DEHP controllers accept the call (pcall succeeds) but
    -- don't actually flip the working flag — retrying exposes the mismatch
    -- and eventually pushes the state through.
    RETRY_INTERVAL_S = 5.0,

    -- Hot tank below this fraction → enable another pump.
    HOT_LOW_PCT = 0.30,

    -- Hot tank above this fraction → disable a pump.
    HOT_HIGH_PCT = 0.70,

    -- A pump turned on must stay on at least this long (normal operation).
    MIN_RUNTIME_S = 5.0,

    -- Control-loop period in seconds.
    TICK_INTERVAL = 1.0,

    -- Feedforward: project hot tank level this many seconds ahead.
    FF_PROJECTION_S = 5.0,

    -- Feedforward: minimum |rate| (L/s) to trigger preemptive action (filters noise).
    FF_MIN_RATE_L_S = 500,

    -- Rolling-average window for long-term rate display.
    STATS_WINDOW_S = 60,

    -- Short window for responsive rate display.
    STATS_SHORT_WINDOW_S = 10,

    -- Screen dimensions (T2 screen + GPU required).
    SCR_W = 80,
    SCR_H = 25,

    -- Action history ring size for the dashboard.
    HISTORY_SIZE = 5,

    -- Color palette (0xRRGGBB).
    COLORS = {
      GREEN = 0x00FF00,
      YELLOW = 0xFFFF00,
      RED = 0xFF0000,
      CYAN = 0x00FFFF,
      WHITE = 0xFFFFFF,
      GREY = 0x888888,
      BLUE = 0x4488FF,
      ORANGE = 0xFFAA00,
      BLACK = 0x000000,
      DARK_GREY = 0x444444,
      -- Background colors for dashboard sections.
      BG_TITLE_NORMAL = 0x003300,
      BG_TITLE_EMERGENCY = 0x330000,
      BG_PANEL = 0x0A0A0A,
      BG_ROW_EVEN = 0x080808,
      BG_ROW_ODD = 0x101010,
      -- Bar colors.
      BAR_GREEN = 0x00CC00,
      BAR_YELLOW = 0xCCCC00,
      BAR_RED = 0xCC0000,
      BAR_BLUE = 0x0044CC,
      BAR_EMPTY = 0x222222,
      BAR_COLD = 0x0066CC,
    },
  }
end
