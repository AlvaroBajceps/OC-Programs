-- Double-buffered 80x25 dashboard renderer for the heating pump controller.
-- Owns the GPU proxy, back-buffer, and all drawing primitives. Uses the same
-- UTF-8 box-drawing runes as the teleporter display for visual consistency.
--
-- Factory: return function(deps) where deps = {config, controller, machines,
--   hot_tank, cold_tank, stats, app}
-- Returns display with setup(), render(), free().

local component = require("component")

-- Box-drawing runes (UTF-8 3-byte sequences).
local H = "\226\148\128" -- horizontal
local V = "\226\148\130" -- vertical
local TL = "\226\148\140" -- top-left corner
local TR = "\226\148\144" -- top-right corner
local BL = "\226\148\148" -- bottom-left corner
local BR = "\226\148\152" -- bottom-right corner

return function(deps)
  local config = deps.config
  local controller = deps.controller
  local machines = deps.machines
  local hot_tank = deps.hot_tank
  local cold_tank = deps.cold_tank
  local stats = deps.stats
  local gpu
  local screen_addr
  local scr_w, scr_h = config.SCR_W, config.SCR_H
  local back_buf

  local COL = config.COLORS

  -- ── Number formatting ────────────────────────────────────────────

  local function fmt_i(n)
    if not n then
      return "—"
    end
    local s = tostring(math.floor(n))
    return s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  end

  local function fmt_k(n)
    if not n then
      return "—"
    end
    if n >= 1000000 then
      return string.format("%.1fM", n / 1000000)
    elseif n >= 1000 then
      return string.format("%.0fK", n / 1000)
    end
    return fmt_i(n)
  end

  local function fmt_pct(pct)
    if not pct then
      return "—%"
    end
    return string.format("%.0f%%", pct * 100)
  end

  local function fmt_rate(r)
    if r == nil then
      return "—"
    end
    local abs_r = math.abs(r)
    local sign
    if r > 0.5 then
      sign = "+"
    elseif r < -0.5 then
      sign = "-"
    else
      sign = " "
    end
    return sign .. fmt_k(abs_r) .. "L/s"
  end

  local function fmt_dur(seconds)
    if not seconds or seconds <= 0 then
      return "—"
    end
    seconds = math.floor(seconds)
    if seconds >= 3600 then
      local h = math.floor(seconds / 3600)
      local m = math.floor((seconds % 3600) / 60)
      return string.format("%dh %dm", h, m)
    elseif seconds >= 60 then
      local m = math.floor(seconds / 60)
      local s = seconds % 60
      return string.format("%dm %ds", m, s)
    end
    return string.format("%ds", seconds)
  end

  local function fmt_dur_short(seconds)
    if not seconds then
      return "—"
    end
    if seconds <= 0 then
      return "—"
    end
    return string.format("%ds", math.floor(seconds))
  end

  -- ── Drawing primitives ───────────────────────────────────────────

  local function draw_box(x, y, w, h, border_color, bg_color)
    gpu.setBackground(bg_color)
    gpu.setForeground(border_color)
    for col = x, x + w - 1 do
      gpu.set(col, y, H)
      gpu.set(col, y + h - 1, H)
    end
    for row = y + 1, y + h - 2 do
      gpu.set(x, row, V)
      gpu.set(x + w - 1, row, V)
    end
    gpu.set(x, y, TL)
    gpu.set(x + w - 1, y, TR)
    gpu.set(x, y + h - 1, BL)
    gpu.set(x + w - 1, y + h - 1, BR)
    gpu.setBackground(bg_color)
    for row = y + 1, y + h - 2 do
      for col = x + 1, x + w - 2 do
        gpu.set(col, row, " ")
      end
    end
  end

  local function draw_fill(x, y, w, h, fg, bg, char)
    gpu.setBackground(bg or COL.BLACK)
    gpu.setForeground(fg or COL.WHITE)
    local ch = char or " "
    for row = y, y + h - 1 do
      for col = x, x + w - 1 do
        gpu.set(col, row, ch)
      end
    end
  end

  local function draw_text(x, y, text, fg, bg)
    gpu.setBackground(bg or COL.BLACK)
    gpu.setForeground(fg or COL.WHITE)
    gpu.set(x, y, text)
  end

  local function draw_text_center(x, y, w, text, fg, bg)
    gpu.setBackground(bg or COL.BLACK)
    gpu.setForeground(fg or COL.WHITE)
    local start_x = x + math.floor((w - #text) / 2)
    if start_x < 1 then
      start_x = 1
    end
    gpu.set(start_x, y, text)
  end

  local function draw_text_right(x, y, w, text, fg, bg)
    gpu.setBackground(bg or COL.BLACK)
    gpu.setForeground(fg or COL.WHITE)
    local start_x = x + w - #text
    if start_x < 1 then
      start_x = 1
    end
    gpu.set(start_x, y, text)
  end

  local function draw_bar(x, y, w, pct, fill_color, empty_color, bg_color)
    bg_color = bg_color or COL.BLACK
    empty_color = empty_color or COL.BAR_EMPTY
    local filled = math.floor(w * pct + 0.5)
    if filled > w then
      filled = w
    end
    if filled < 0 then
      filled = 0
    end

    gpu.setBackground(bg_color)
    gpu.setForeground(fill_color or COL.GREEN)
    local fill_str = string.rep("#", filled)
    gpu.set(x, y, fill_str)

    if filled < w then
      gpu.setForeground(empty_color)
      local empty_str = string.rep(".", w - filled)
      gpu.set(x + filled, y, empty_str)
    end
  end

  -- ── Dashboard render ─────────────────────────────────────────────

  local function _count_maint()
    local n = 0
    for _, m in ipairs(machines) do
      local s = m.get_state()
      if s.needs_maintenance then
        n = n + 1
      end
    end
    return n
  end

  local function _count_low_eu()
    local n = 0
    for _, m in ipairs(machines) do
      local s = m.get_state()
      if s.low_energy then
        n = n + 1
      end
    end
    return n
  end

  local function _count_retry()
    local n = 0
    for _, m in ipairs(machines) do
      local s = m.get_state()
      if s.retry_pending then
        n = n + 1
      end
    end
    return n
  end

  local function render()
    gpu.setActiveBuffer(back_buf)
    gpu.setBackground(COL.BLACK)
    gpu.fill(1, 1, scr_w, scr_h, " ")

    local cs = controller.snapshot()
    local hot = hot_tank.get_state()
    local cold = cold_tank.get_state()
    local hot_long, hot_short, cold_long, cold_short, active_pumps = stats.rates()

    local is_emergency = cs.mode == "EMERGENCY"
    local mode_color = is_emergency and COL.RED or COL.GREEN
    local mode_bg = is_emergency and COL.BG_TITLE_EMERGENCY or COL.BG_TITLE_NORMAL

    -- ── Row 1: Title bar ──
    draw_fill(1, 1, scr_w, 1, COL.WHITE, mode_bg)
    local title = "DEEP EARTH HEATING PUMP CONTROLLER"
    draw_text_center(1, 1, scr_w, title, COL.WHITE, mode_bg)

    -- ── Row 2: blank ──

    -- ── Rows 3-5: Hot coolant tank panel ──
    local hot_box_y = 3
    local hot_box_w = 38
    draw_box(1, hot_box_y, hot_box_w, 3, COL.GREY, COL.BG_PANEL)

    local hot_label = hot.name or hot.label or "HOT COOLANT"
    draw_text(2, hot_box_y, " HOT COOLANT: " .. hot_label, COL.WHITE, COL.BG_PANEL)

    local hot_pct_text = fmt_pct(hot.pct)
    draw_text_right(1, hot_box_y, hot_box_w, hot_pct_text .. " ", COL.WHITE, COL.BG_PANEL)

    -- Hot bar
    local hot_bar_color
    if hot.pct >= 0.90 then
      hot_bar_color = COL.BAR_RED
    elseif hot.pct >= 0.70 then
      hot_bar_color = COL.BAR_YELLOW
    else
      hot_bar_color = COL.BAR_GREEN
    end
    draw_bar(2, hot_box_y + 1, hot_box_w - 2, math.min(hot.pct, 1.0), hot_bar_color, COL.BAR_EMPTY, COL.BG_PANEL)

    -- Hot amount line
    local hot_amt_text = fmt_i(hot.amount) .. " / " .. fmt_i(hot.capacity) .. " L"
    draw_text(2, hot_box_y + 2, hot_amt_text, COL.WHITE, COL.BG_PANEL)

    local hot_rate_text = "Net " .. fmt_rate(hot_long)
    local hot_rate_color
    if hot_long > 5 then
      hot_rate_color = COL.GREEN
    elseif hot_long < -5 then
      hot_rate_color = COL.RED
    else
      hot_rate_color = COL.GREY
    end
    draw_text_right(1, hot_box_y + 2, hot_box_w, hot_rate_text .. "  ", hot_rate_color, COL.BG_PANEL)

    -- ── Rows 3-5 right side: Cold coolant tank panel ──
    local cold_box_x = 41
    local cold_box_w = 40
    local cold_box_y = 3
    draw_box(cold_box_x, cold_box_y, cold_box_w, 3, COL.GREY, COL.BG_PANEL)

    local cold_label = cold.name or cold.label or "COLD COOLANT"
    draw_text(cold_box_x + 1, cold_box_y, " COLD COOLANT: " .. cold_label, COL.CYAN, COL.BG_PANEL)

    local cold_pct_text = fmt_pct(cold.pct)
    draw_text_right(cold_box_x, cold_box_y, cold_box_w, cold_pct_text .. " ", COL.CYAN, COL.BG_PANEL)

    -- Cold bar with emergency floor marker
    local cold_bar_color
    if cold.pct < config.COLD_CAUTION_PCT then
      cold_bar_color = COL.BAR_RED
    elseif cold.amount and cold.amount < config.COLD_EMERGENCY_RECOVERY_L then
      cold_bar_color = COL.BAR_YELLOW
    else
      cold_bar_color = COL.BAR_BLUE
    end
    draw_bar(
      cold_box_x + 1,
      cold_box_y + 1,
      cold_box_w - 2,
      math.min(cold.pct, 1.0),
      cold_bar_color,
      COL.BAR_EMPTY,
      COL.BG_PANEL
    )

    -- Emergency floor marker on the bar
    if cold.capacity and cold.capacity > 0 then
      local emerg_pct = config.COLD_EMERGENCY_L / cold.capacity
      local emerg_x = cold_box_x + 1 + math.floor((cold_box_w - 2) * emerg_pct)
      if emerg_x >= cold_box_x + 1 and emerg_x <= cold_box_x + cold_box_w - 2 then
        gpu.setBackground(COL.BG_PANEL)
        gpu.setForeground(COL.RED)
        gpu.set(emerg_x, cold_box_y + 1, "!")
      end
    end

    -- Cold amount line
    local cold_amt_text = fmt_i(cold.amount) .. " / " .. fmt_i(cold.capacity) .. " L"
    draw_text(cold_box_x + 1, cold_box_y + 2, cold_amt_text, COL.CYAN, COL.BG_PANEL)

    local cold_rate_text = "Net " .. fmt_rate(cold_long)
    local cold_rate_color
    if cold_long > 5 then
      cold_rate_color = COL.GREEN
    elseif cold_long < -5 then
      cold_rate_color = COL.RED
    else
      cold_rate_color = COL.GREY
    end
    draw_text_right(cold_box_x, cold_box_y + 2, cold_box_w, cold_rate_text .. "  ", cold_rate_color, COL.BG_PANEL)

    -- Emergency indicator for cold tank.
    if is_emergency or (cold.amount and cold.amount < config.COLD_EMERGENCY_RECOVERY_L) then
      draw_text(41, 6, "  EMERGENCY FLOOR: " .. fmt_i(config.COLD_EMERGENCY_L) .. " L", COL.RED, COL.BLACK)
    end

    -- ── Row 7: Rates summary ──
    local gross_prod = active_pumps * config.PUMP_RATE_L_PER_S
    local hot_prod_text = string.format("Produced: %sL/s  ", fmt_k(gross_prod))
    local hot_cons_text = string.format("Hot net: %sL/s", fmt_rate(hot_short):gsub("^[+ ]", ""))
    draw_text(2, 7, hot_prod_text .. hot_cons_text, COL.WHITE, COL.BLACK)

    local cold_cons_text = string.format("  Cold consumed: %sL/s  ", fmt_k(gross_prod))
    local cold_net_text = string.format("Cold net: %sL/s", fmt_rate(cold_short):gsub("^[+ ]", ""))
    draw_text(41, 7, cold_cons_text .. cold_net_text, COL.CYAN, COL.BLACK)

    -- ── Row 8: separator ──
    gpu.setBackground(COL.BLACK)
    gpu.setForeground(COL.GREY)
    local sep_line = string.rep(H, scr_w)
    gpu.set(1, 8, sep_line)
    draw_text_center(1, 8, scr_w, "—— PUMPS ——", COL.GREY, COL.BLACK)

    -- ── Row 9: Pump table header ──
    draw_text(2, 9, "#  STATUS     RUNTIME   MAINTENANCE         EU            PROGRESS", COL.GREY, COL.BLACK)

    -- ── Rows 10-13: Pump rows (up to 4, render all discovered) ──
    local pump_row_y = 10
    for _, m in ipairs(machines) do
      if pump_row_y > 13 then
        break
      end
      local s = m.get_state()
      local row_bg = (s.index % 2 == 0) and COL.BG_ROW_EVEN or COL.BG_ROW_ODD

      draw_fill(1, pump_row_y, scr_w, 1, COL.WHITE, row_bg)

      -- Pump index
      draw_text(1, pump_row_y, string.format("%-2d", s.index), COL.WHITE, row_bg)

      -- Status indicator
      local status_char, status_color
      if not s.online then
        status_char = "?"
        status_color = COL.YELLOW
      elseif s.needs_maintenance then
        status_char = "X"
        status_color = COL.RED
      elseif s.low_energy then
        status_char = "!"
        status_color = COL.YELLOW
      elseif s.retry_pending then
        status_char = "~"
        status_color = COL.YELLOW
      elseif s.work_allowed and s.machine_active then
        status_char = "O"
        status_color = COL.GREEN
      elseif s.work_allowed then
        status_char = "o"
        status_color = COL.GREEN
      else
        status_char = "o"
        status_color = COL.GREY
      end

      local status_text
      if not s.online then
        status_text = "OFFLINE"
      elseif s.needs_maintenance then
        status_text = "MAINT"
      elseif s.low_energy then
        status_text = "LOW EU"
      elseif s.retry_pending then
        status_text = "RETRY"
      elseif s.work_allowed then
        status_text = "ON"
      else
        status_text = "OFF"
      end
      draw_text(4, pump_row_y, status_char .. " " .. status_text, status_color, row_bg)

      -- Runtime
      local runtime
      if s.on_since then
        runtime = deps.uptime_fn() - s.on_since
      else
        runtime = 0
      end
      draw_text(15, pump_row_y, fmt_dur_short(runtime), COL.WHITE, row_bg)

      -- Maintenance
      local maint_text, maint_color
      if not s.online then
        maint_text = "N/A"
        maint_color = COL.YELLOW
      elseif s.needs_maintenance then
        local reason = s.maintenance_reason or "?"
        if #reason > 20 then
          reason = reason:sub(1, 19) .. ">"
        end
        maint_text = reason
        maint_color = COL.RED
      else
        maint_text = "OK"
        maint_color = COL.GREEN
      end
      draw_text(27, pump_row_y, maint_text, maint_color, row_bg)

      -- EU
      local eu_text
      if not s.stored_eu or not s.eu_capacity then
        eu_text = "—"
      else
        eu_text = fmt_k(s.stored_eu) .. "/" .. fmt_k(s.eu_capacity)
      end
      draw_text(49, pump_row_y, eu_text, COL.GREY, row_bg)

      -- Progress
      local progress_text
      if not s.progress or not s.max_progress or s.max_progress <= 0 then
        progress_text = "—"
      else
        local prog_pct = s.progress / s.max_progress
        local prog_bar_w = 10
        local filled = math.floor(prog_bar_w * prog_pct + 0.5)
        progress_text = string.rep("#", filled)
          .. string.rep(".", prog_bar_w - filled)
          .. " "
          .. string.format("%.0f%%", prog_pct * 100)
      end
      draw_text(65, pump_row_y, progress_text, COL.GREY, row_bg)

      pump_row_y = pump_row_y + 1
    end

    -- Fill remaining pump rows (up to row 13) with blanks
    while pump_row_y <= 13 do
      draw_fill(1, pump_row_y, scr_w, 1, COL.WHITE, COL.BG_ROW_EVEN)
      pump_row_y = pump_row_y + 1
    end

    -- ── Row 14: separator ──
    gpu.setBackground(COL.BLACK)
    gpu.setForeground(COL.GREY)
    gpu.set(1, 14, sep_line)
    draw_text_center(1, 14, scr_w, "—— SYSTEM ——", COL.GREY, COL.BLACK)

    -- ── Row 15: System status line ──
    local mode_dot = is_emergency and "!" or "*"
    local mode_text =
      string.format("State: %s %-8s  Active: %d/%d healthy", mode_dot, cs.mode, active_pumps, cs.healthy_count)
    if _count_maint() > 0 then
      mode_text = mode_text .. string.format("  (%d maint)", _count_maint())
    end
    if _count_low_eu() > 0 then
      mode_text = mode_text .. string.format("  (%d low EU)", _count_low_eu())
    end
    if _count_retry() > 0 then
      mode_text = mode_text .. string.format("  (%d retry)", _count_retry())
    end
    draw_text(2, 15, mode_text, mode_color, COL.BLACK)

    -- Uptime on the right
    local uptime = deps.uptime_fn()
    draw_text_right(1, 15, scr_w, "Uptime: " .. fmt_dur(uptime) .. "  ", COL.GREY, COL.BLACK)

    -- ── Row 16: Desired / percentages ──
    local desired_text = string.format(
      "Desired: %d pumps (%sL/s gross)    Hot: %s    Cold: %s",
      cs.desired_active,
      fmt_k(cs.desired_active * config.PUMP_RATE_L_PER_S),
      fmt_pct(hot.pct),
      fmt_pct(cold.pct)
    )
    draw_text(2, 16, desired_text, COL.WHITE, COL.BLACK)

    -- ── Row 17: Last action ──
    local age_str = ""
    if cs.last_action_time then
      local age = uptime - cs.last_action_time
      age_str = "   " .. fmt_dur_short(age) .. " ago"
    end
    draw_text(2, 17, "Last: " .. (cs.last_action or "") .. age_str, COL.WHITE, COL.BLACK)

    -- ── Rows 18-20: Action history ──
    local hist_y = 18
    for i = 1, math.min(3, #cs.history) do
      local h = cs.history[i]
      if h then
        if #h > 78 then
          h = h:sub(1, 77) .. ">"
        end
        draw_text(2, hist_y, h, COL.DARK_GREY, COL.BLACK)
      end
      hist_y = hist_y + 1
    end

    -- ── Row 23: blank ──

    -- ── Row 24: Footer ──
    draw_text(2, 24, "heating_pump v1.0", COL.DARK_GREY, COL.BLACK)
    draw_text_right(1, 24, scr_w, "[Ctrl+C] stop  ", COL.DARK_GREY, COL.BLACK)

    -- Flip back-buffer to visible screen.
    gpu.setActiveBuffer(0)
    gpu.bitblt(0, 1, 1, scr_w, scr_h, back_buf, 1, 1)
    gpu.setActiveBuffer(back_buf)
  end

  -- ── Setup / teardown ─────────────────────────────────────────────

  local function setup()
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
      gpu.setResolution(math.min(max_w, config.SCR_W), math.min(max_h, config.SCR_H))
      scr_w, scr_h = gpu.getResolution()
    end
    back_buf = gpu.allocateBuffer(scr_w, scr_h)
    if not back_buf then
      error("GPU does not have enough VRAM for a back-buffer. Reduce resolution.")
    end
  end

  local function free()
    if gpu and back_buf then
      gpu.setActiveBuffer(0)
      gpu.freeBuffer(back_buf)
    end
  end

  return {
    setup = setup,
    render = render,
    free = free,
    get_gpu = function()
      return gpu
    end,
    get_screen_addr = function()
      return screen_addr
    end,
    get_dims = function()
      return scr_w, scr_h
    end,
  }
end
