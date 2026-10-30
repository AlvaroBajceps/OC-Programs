-- Graphical dashboard for laptop_reborn. The display object is injected; this
-- module never touches the GPU directly. Every draw is clipped to its panel
-- rect and every string is truncated by display width before it is emitted.

local theme = require("laptop_reborn.theme")
local layout = require("laptop_reborn.layout")
local format = require("laptop_reborn.format")

local M = {}

local BOX_H = "\226\148\128"
local BOX_V = "\226\148\130"
local BOX_BOTTOM = "\226\148\180"
local RANGE_SIGN = "\194\177"

local HINTS = {
  { name = "quit", key = "Q", label = "quit" },
  { name = "refresh", key = "R", label = "refresh" },
  { name = "redstone", key = "T", label = "redstone" },
}

local function num(value)
  if type(value) == "number" and value == value then
    return value
  end
  return nil
end

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local function hint_width(def)
  return format.width(def.key) + 1 + format.width(def.label)
end

local function build_regions(footer)
  local regions = {}
  local x = footer.x
  local right = footer.x + footer.w - 1
  for _, def in ipairs(HINTS) do
    if x > right then
      break
    end
    local w = hint_width(def)
    regions[#regions + 1] = {
      name = def.name,
      x = x,
      y = footer.y,
      w = math.min(w, right - x + 1),
      h = footer.h,
    }
    x = x + w + 1
  end
  return regions
end

local function read_size(display)
  local ok, w, h = pcall(display.size)
  if ok and type(w) == "number" and type(h) == "number" and w >= 1 and h >= 1 then
    return math.floor(w), math.floor(h)
  end
  return 80, 25
end

local function charge_color(p, percent)
  if percent == nil then
    return p.dim
  end
  if percent > 50 then
    return p.ok
  elseif percent >= 20 then
    return p.warn
  end
  return p.bad
end

local function link_color(p, link)
  if link == "ONLINE" then
    return p.ok
  elseif link == "RETRY" then
    return p.warn
  elseif link == "OFFLINE" then
    return p.bad
  end
  return p.dim
end

local STATE_COLORS = {
  CHARGING = "ok",
  DISCHARGING = "accent",
  IDLE = "dim",
  FULL = "ok",
  EMPTY = "bad",
  MAINTENANCE = "warn",
  OFFLINE = "bad",
  UNKNOWN = "bad",
}

local function state_color(p, state)
  local key = STATE_COLORS[state]
  return key and p[key] or p.bad
end

local function percent_text(percent)
  if percent == nil then
    return "--%"
  end
  return string.format("%d%%", math.floor(clamp(percent, 0, 100) + 0.5))
end

local function signed_eut(value)
  if value == nil then
    return "unknown"
  end
  if value > 0 then
    return "+" .. format.eut(value)
  end
  return format.eut(value)
end

local function signed_percent(value)
  if value == nil then
    return ""
  end
  return string.format("%+.1f%%", value)
end

local function history_window(history)
  if type(history) ~= "table" or #history == 0 then
    return nil
  end
  local pmin, pmax, nmin, nmax
  local has_pos, has_neg = false, false
  for index = 1, #history do
    local sample = history[index]
    if type(sample) == "table" then
      local percent = num(sample.percent)
      if percent then
        pmin = pmin and math.min(pmin, percent) or percent
        pmax = pmax and math.max(pmax, percent) or percent
      end
      local net = num(sample.net)
      if net then
        nmin = nmin and math.min(nmin, net) or net
        nmax = nmax and math.max(nmax, net) or net
        if net > 0 then
          has_pos = true
        elseif net < 0 then
          has_neg = true
        end
      end
    end
  end
  if not pmin or not nmin then
    return nil
  end
  return { count = #history, pmin = pmin, pmax = pmax, nmin = nmin, nmax = nmax, has_pos = has_pos, has_neg = has_neg }
end

local function eut_span(a, b, max_width)
  local fa, fb = format.eut(a), format.eut(b)
  local la, ua = fa:match("^(.-) (%S+)$")
  local lb, ub = fb:match("^(.-) (%S+)$")
  if la and lb and ua == ub then
    local full = la .. " .. " .. lb .. " " .. ua
    if max_width == nil or format.width(full) <= max_width then
      return full
    end
    local short = string.format("%.0f .. %.0f %s", tonumber(la) or a, tonumber(lb) or b, ua)
    if format.width(short) <= max_width then
      return short
    end
    local compact = string.format("%.0f..%.0f %s", tonumber(la) or a, tonumber(lb) or b, ua)
    if format.width(compact) <= max_width then
      return compact
    end
    local tight = string.format("%.0f-%.0f %s", tonumber(la) or a, tonumber(lb) or b, ua)
    if format.width(tight) <= max_width then
      return tight
    end
    return full
  end
  return fa .. " .. " .. fb
end

local function percent_span(a, b, max_width)
  local full = string.format("%.1f .. %.1f%%", a, b)
  if max_width == nil or format.width(full) <= max_width then
    return full
  end
  return string.format("%.1f-%.1f%%", a, b)
end

local function line(ui, x, y, maxw, text, fg, bg)
  if maxw < 1 then
    return 0
  end
  local body = format.trunc(text == nil and "" or tostring(text), maxw)
  if body == "" then
    return 0
  end
  ui.display.text(x, y, body, fg, bg)
  return format.width(body)
end

local function line_right(ui, right, y, maxw, text, fg, bg)
  if maxw < 1 then
    return 0
  end
  local body = format.trunc(text == nil and "" or tostring(text), maxw)
  local body_w = format.width(body)
  if body_w == 0 then
    return 0
  end
  ui.display.text(right - body_w + 1, y, body, fg, bg)
  return body_w
end

local function led(ui, x, y, color)
  ui.display.fill(x, y, 1, 1, " ", color, color)
end

local function bar(ui, x, y, w, percent, color, bg)
  if w < 1 then
    return
  end
  ui.display.fill(x, y, w, 1, " ", bg, bg)
  local filled = 0
  if percent ~= nil then
    filled = math.floor(clamp(percent, 0, 100) / 100 * w + 0.5)
  end
  if filled > 0 then
    ui.display.fill(x, y, filled, 1, " ", color, color)
  end
end

local function eu_pair(a, b, max_width)
  local left, left_unit = format.eu(a):match("^(.-) (%a+EU)$")
  local right, right_unit = format.eu(b):match("^(.-) (%a+EU)$")
  if left and right and left_unit == right_unit then
    local full = left .. "/" .. right .. " " .. left_unit
    if max_width == nil or format.width(full) <= max_width then
      return full
    end
    local short_left = string.format("%.1f", tonumber(left) or 0)
    local short_right = string.format("%.1f", tonumber(right) or 0)
    local short = short_left .. "/" .. short_right .. " " .. left_unit
    if format.width(short) <= max_width then
      return short
    end
    local suffix = left_unit:sub(1, 1)
    return short_left .. suffix .. "/" .. short_right .. suffix
  end
  return format.eu(a) .. "/" .. format.eu(b)
end

local function panel(ui, r, bg)
  local p = ui.p
  ui.display.fill(r.x, r.y, r.w, r.h, " ", p.fg, bg)
  if r.w >= 3 and r.h >= 3 then
    ui.display.box(r.x, r.y, r.w, r.h, p.border, bg, "single")
    return r.x + 1, r.y + 1, r.w - 2, r.h - 2
  end
  return r.x, r.y, r.w, r.h
end

local function separator(ui, x, y, w, bg)
  if w < 1 then
    return
  end
  line(ui, x, y, w, string.rep(BOX_H, w), ui.p.border, bg)
end

local function draw_header(ui, r, view)
  local p = ui.p
  ui.display.fill(r.x, r.y, r.w, r.h, " ", p.fg, p.head)

  local y = r.y
  local right = r.x + r.w - 1
  local status = tostring(view.status or (view.online and "Unknown" or "Offline"))
  local state = status:upper()
  local sc = state_color(p, state)
  led(ui, r.x, y, sc)

  local res_text = tostring(ui.w) .. "x" .. tostring(ui.h)
  local res_w = format.width(res_text)
  local res_x = right - res_w + 1

  local badge_text = state
  local badge_w = format.width(badge_text) + 2
  local badge_x = res_x - badge_w - 1
  if badge_x - (r.x + 2) < format.width("LAPTOP REBORN") then
    badge_x = res_x - badge_w
  end
  if badge_x < r.x + 2 or badge_w > r.w - 2 then
    badge_x = nil
  end
  local right_limit = (badge_x and badge_x - 1) or (res_x - 1)

  local title_x = r.x + 2
  local shown = line(ui, title_x, y, math.max(0, right_limit - title_x + 1), "LAPTOP REBORN", p.fg, p.head)
  local cursor = title_x + shown

  local version = "v" .. tostring(ui.version)
  local vw = format.width(version)
  if cursor + 1 + vw <= right_limit then
    line(ui, cursor + 1, y, vw, version, p.dim, p.head)
    cursor = cursor + 1 + vw
  end

  if res_x > r.x then
    line(ui, res_x, y, res_w, res_text, p.dim, p.head)
  end

  if badge_x then
    ui.display.fill(badge_x, y, badge_w, 1, " ", p.black, sc)
    ui.display.text(badge_x + 1, y, badge_text, p.black, sc)
  end
end

local function draw_battery(ui, r, view)
  local p = ui.p
  local ix, iy, iw, ih = panel(ui, r, p.panel)
  if iw < 1 or ih < 1 then
    return
  end

  local online = view.online and true or false
  local percent = num(view.percent)
  local stored = num(view.stored)
  local capacity = num(view.capacity_total)
  local net = num(view.net_instant)
  local color = online and charge_color(p, percent) or p.dim

  local content_x = ix
  local content_w = iw
  local sprite = theme.COMPILED.battery
  if ui.icons and iw >= sprite.w + 16 and ih >= sprite.h then
    ui.display.sprite(ix, iy, sprite)
    content_x = ix + sprite.w + 1
    content_w = iw - sprite.w - 1
  end
  if content_w < 1 then
    return
  end

  local pct_text
  if not online then
    pct_text = "OFFLINE"
  else
    pct_text = percent_text(percent)
  end
  local pct_w = format.width(pct_text)

  local row = 0
  if content_w >= 7 + 2 + pct_w then
    local title_w = line(ui, content_x, iy, content_w, "BATTERY", online and p.accent or p.dim, p.panel)
    line_right(ui, content_x + content_w - 1, iy, content_w - title_w - 1, pct_text, color, p.panel)
    row = 1
  else
    local combo = "BATTERY " .. pct_text
    if format.width(combo) <= content_w then
      line(ui, content_x, iy, content_w, combo, online and p.accent or p.dim, p.panel)
      row = 1
    else
      line(ui, content_x, iy, content_w, "BATTERY", online and p.accent or p.dim, p.panel)
      row = 1
      if row < ih then
        line(ui, content_x, iy + row, content_w, pct_text, color, p.panel)
        row = row + 1
      end
    end
  end

  if row < ih then
    bar(ui, content_x, iy + row, content_w, online and percent or nil, color, p.panel)
    row = row + 1
  end

  if row < ih then
    local stored_text = "--"
    if online and stored and capacity then
      stored_text = eu_pair(stored, capacity, content_w)
    elseif online and stored then
      stored_text = format.eu(stored)
    end
    line(ui, content_x, iy + row, content_w, stored_text, p.dim, p.panel)
    row = row + 1
  end

  if row < ih and online and num(view.passive_loss) then
    line(ui, content_x, iy + row, content_w, "LOSS " .. format.eut(view.passive_loss), p.dim, p.panel)
    row = row + 1
  end

  if row < ih and online and stored and capacity then
    local to_edge
    if percent and percent >= 99.5 then
      to_edge = "full"
    elseif percent and percent <= 0.5 then
      to_edge = "empty"
    elseif net and net < 0 then
      to_edge = format.eu(stored) .. " to empty"
    else
      to_edge = format.eu(math.max(0, capacity - stored)) .. " to full"
    end
    line(ui, content_x, iy + row, content_w, to_edge, p.dim, p.panel)
  end
end

local function percent_samples(history)
  local samples = {}
  if type(history) == "table" then
    for index = 1, #history do
      local sample = history[index]
      if type(sample) == "table" and type(sample.percent) == "number" then
        samples[#samples + 1] = sample.percent
      end
    end
  end
  return samples
end

local function draw_gauge(ui, r, view, history)
  local p = ui.p
  local ix, iy, iw, ih = panel(ui, r, p.panel_hi)
  if iw < 1 or ih < 1 then
    return
  end

  local samples = percent_samples(history)
  local online = view.online and true or false
  local color = online and charge_color(p, num(view.percent)) or p.dim
  local delta = #samples >= 2 and (samples[#samples] - samples[1]) or nil
  local delta_text = delta and signed_percent(delta) or nil
  local title = ih <= 1 and "TREND" or "CHARGE TREND"

  local title_w = line(ui, ix, iy, iw, title, p.dim, p.panel_hi)
  if delta_text and iw >= title_w + 1 + format.width(delta_text) then
    line_right(ui, ix + iw - 1, iy, iw - title_w - 1, delta_text, color, p.panel_hi)
  end

  if ih <= 1 then
    return
  end
  if #samples < 2 then
    line(ui, ix, iy + 1, iw, "no history", p.dim, p.panel_hi)
    return
  end

  local minimum, maximum = samples[1], samples[1]
  for index = 2, #samples do
    local value = samples[index]
    if value < minimum then
      minimum = value
    end
    if value > maximum then
      maximum = value
    end
  end

  local top = clamp(maximum + 0.25, 0, 100)
  local bottom = clamp(minimum - 0.25, 0, 100)
  if top - bottom < 0.5 then
    local mid = (top + bottom) / 2
    top = mid + 0.25
    bottom = mid - 0.25
    if top > 100 then
      local excess = top - 100
      top = 100
      bottom = bottom - excess
    end
    if bottom < 0 then
      local excess = -bottom
      bottom = 0
      top = top + excess
    end
  end

  local decimals = (top - bottom < 2) and 1 or 0
  local top_text = string.format("%." .. decimals .. "f%%", top)
  local bottom_text = string.format("%." .. decimals .. "f%%", bottom)

  if ih < 4 then
    local bottom_plain = string.format("%." .. decimals .. "f", bottom)
    line(ui, ix, iy + 1, iw, bottom_plain .. "-" .. top_text, p.dim, p.panel_hi)
    return
  end

  local label_w = math.max(format.width(top_text), format.width(bottom_text))
  local chart_x = ix + label_w + 2
  local chart_w = iw - label_w - 2
  local top_row = iy + 1
  local bottom_row = iy + ih - 1
  local rows = bottom_row - top_row + 1

  line(ui, ix, top_row, label_w, top_text, p.dim, p.panel_hi)
  line(ui, ix, bottom_row, label_w, bottom_text, p.dim, p.panel_hi)
  if label_w < iw then
    for row = top_row, bottom_row do
      local glyph = row == bottom_row and BOX_BOTTOM or BOX_V
      line(ui, ix + label_w, row, 1, glyph, p.border, p.panel_hi)
    end
  end

  if chart_w < 1 then
    return
  end

  local count = math.min(chart_w, #samples)
  for column = 1, count do
    local index
    if count > 1 then
      index = math.floor((column - 1) * (#samples - 1) / (count - 1)) + 1
    else
      index = #samples
    end
    local fraction = (clamp(samples[index], bottom, top) - bottom) / (top - bottom)
    local row = bottom_row - math.floor(fraction * (rows - 1) + 0.5)
    ui.display.fill(chart_x + column - 1, row, 1, bottom_row - row + 1, " ", color, color)
  end
end

local function mini_bar(ui, x, y, w, amount, maxv, color, bg)
  if w < 1 then
    return
  end
  ui.display.fill(x, y, w, 1, " ", bg, bg)
  local fraction = 0
  if amount ~= nil and maxv and maxv > 0 then
    fraction = clamp(math.abs(amount) / maxv, 0, 1)
  end
  local filled = math.floor(fraction * w + 0.5)
  if filled > 0 then
    ui.display.fill(x, y, filled, 1, " ", color, color)
  end
end

local function power_row(ui, x, y, w, label, amount, color, bg, maxv)
  local show_led = w >= 16
  if show_led then
    led(ui, x, y, color)
  end
  local text_x = x + (show_led and 2 or 0)
  local avail = w - (show_led and 2 or 0)
  if avail < 1 then
    return
  end
  local bar_w = 0
  if w >= 22 then
    bar_w = math.max(4, math.min(8, math.floor(w * 0.3)))
  end
  local label_w = line(ui, text_x, y, avail, label, color, bg)
  if label_w < 1 then
    return
  end
  local value_x = text_x + label_w + 1
  local value_right = x + w - 1 - (bar_w > 0 and (bar_w + 1) or 0)
  local value_w = value_right - value_x + 1
  if value_w >= 1 then
    line(ui, value_x, y, value_w, format.eut(amount), color, bg)
  end
  if bar_w > 0 then
    mini_bar(ui, x + w - bar_w, y, bar_w, amount, maxv, color, bg)
  end
end

local function net_row(ui, x, y, w, amount, color, bg)
  ui.display.fill(x, y, w, 1, " ", bg, bg)
  if w < 3 then
    line(ui, x, y, w, "NET", ui.p.fg, bg)
    return
  end
  if w < 20 then
    local label_w = line(ui, x, y, w, "NET", ui.p.fg, bg)
    line_right(ui, x + w - 1, y, w - label_w - 1, signed_eut(amount), color, bg)
    return
  end
  local label_w = line(ui, x + 1, y, w - 2, "NET", ui.p.fg, bg)
  if label_w < 1 then
    return
  end
  line_right(ui, x + w - 2, y, w - label_w - 3, signed_eut(amount), color, bg)
end

local function avg_row(ui, x, y, w, label, amount, bg)
  local p = ui.p
  if w < 1 then
    return
  end
  if w < 18 then
    label = label:gsub("AVG ", "")
  end
  local color = p.dim
  if amount ~= nil then
    if amount > 0 then
      color = p.ok
    elseif amount < 0 then
      color = p.bad
    end
  end
  local label_w = line(ui, x, y, math.min(w, 6), label, p.dim, bg)
  if label_w < 1 then
    return
  end
  line_right(ui, x + w - 1, y, w - label_w - 1, signed_eut(amount), color, bg)
end

local function draw_power(ui, r, view)
  local p = ui.p
  local ix, iy, iw, ih = panel(ui, r, p.panel)
  if iw < 1 or ih < 1 then
    return
  end

  local net = num(view.net_instant)
  local net_color = p.dim
  if net then
    if net > 0 then
      net_color = p.ok
    elseif net < 0 then
      net_color = p.bad
    end
  end
  local in_value = num(view.in_5s)
  local out_value = num(view.out_5s)
  local maxv = math.max(in_value or 0, out_value or 0, 1)

  local row = 0
  if ih >= 5 then
    line(ui, ix, iy, iw, "POWER FLOW", p.dim, p.panel)
    row = 1
  end
  if row < ih then
    power_row(ui, ix, iy + row, iw, "IN", in_value, p.ok, p.panel, maxv)
    row = row + 1
  end
  if row < ih then
    power_row(ui, ix, iy + row, iw, "OUT", out_value, p.bad, p.panel, maxv)
    row = row + 1
  end
  if row < ih then
    net_row(ui, ix, iy + row, iw, net, net_color, p.panel_hi)
    row = row + 1
  end
  if row < ih and ih - row >= 2 then
    separator(ui, ix, iy + row, iw, p.panel)
    row = row + 1
  end
  if row < ih and iw >= 14 then
    avg_row(ui, ix, iy + row, iw, "AVG 5m", num(view.net_5m), p.panel)
    row = row + 1
  end
  if row < ih and iw >= 14 then
    avg_row(ui, ix, iy + row, iw, "AVG 1h", num(view.net_1h), p.panel)
  end
end

local function draw_edge(ui, r, view)
  local p = ui.p
  local ix, iy, iw, ih = panel(ui, r, p.panel)
  if iw < 1 or ih < 1 then
    return
  end

  local text = tostring(view.edge_text or "unknown")
  if ih == 1 then
    line(ui, ix, iy, iw, text, p.fg, p.panel)
    return
  end

  line(ui, ix, iy, iw, "TIME TO EDGE", p.dim, p.panel)
  line(ui, ix, iy + 1, iw, text, p.fg, p.panel)
  if ih >= 3 then
    local rate = num(view.net_5m) or num(view.net_instant)
    line(ui, ix, iy + 2, iw, "at " .. signed_eut(rate) .. " (5m)", p.dim, p.panel)
  end
end

local function draw_status(ui, r, view, history)
  local p = ui.p
  local ix, iy, iw, ih = panel(ui, r, p.panel_hi)
  if iw < 1 or ih < 1 then
    return
  end

  local online = view.online and true or false
  local maintenance = view.maintenance
  local state = tostring(view.status or (online and "Unknown" or "Offline")):upper()
  local sc = state_color(p, state)

  local maint_text, maint_color
  if maintenance == true then
    maint_text, maint_color = "MAINT!", p.bad
  elseif maintenance == false then
    maint_text, maint_color = "MAINT OK", p.ok
  else
    maint_text, maint_color = "MAINT ?", p.dim
  end
  local lapo_text = online and "LAPOTRON ONLINE" or "LAPOTRON OFFLINE"
  local lapo_color = online and p.ok or p.bad
  local link = tostring(view.link or "OFF")
  local rs_text = view.redstone_enabled and "RS ON" or "RS OFF"
  local rs_color = view.redstone_enabled and p.ok or p.dim
  local status_text = tostring(view.status_text or "")
  local mqtt_error = tostring(view.mqtt_error or "")

  if ih == 1 then
    local text
    if not online then
      text = "LAPOTRON OFFLINE"
    else
      text = maint_text .. " LAP ON"
    end
    line(ui, ix, iy, iw, text, online and p.fg or p.bad, p.panel_hi)
    return
  end

  if ih == 2 then
    line(ui, ix, iy, iw, maint_text, maint_color, p.panel_hi)
    line(ui, ix, iy + 1, iw, lapo_text, lapo_color, p.panel_hi)
    return
  end

  led(ui, ix, iy, sc)
  line(ui, ix + 2, iy, iw - 2, state, sc, p.panel_hi)
  local row = 1

  if row < ih then
    line(ui, ix, iy + row, iw, maint_text, maint_color, p.panel_hi)
    row = row + 1
  end

  if row < ih then
    line(ui, ix, iy + row, iw, lapo_text, lapo_color, p.panel_hi)
    row = row + 1
  end
  if row < ih then
    line(ui, ix, iy + row, iw, "LINK " .. link, link_color(p, link), p.panel_hi)
    row = row + 1
  end
  if row < ih and mqtt_error ~= "" then
    line(ui, ix, iy + row, iw, "MQTT " .. mqtt_error, p.bad, p.panel_hi)
    row = row + 1
  end
  if row < ih then
    led(ui, ix, iy + row, rs_color)
    line(ui, ix + 2, iy + row, iw - 2, rs_text, rs_color, p.panel_hi)
    row = row + 1
  end
  if row < ih then
    separator(ui, ix, iy + row, iw, p.panel_hi)
    row = row + 1
  end
  if row < ih then
    line(ui, ix, iy + row, iw, "GT SENSOR", p.dim, p.panel_hi)
    row = row + 1
  end

  if row < ih and status_text ~= "" then
    local label, value = status_text:match("^(.-):%s*(.*)$")
    if label and label ~= "" then
      line(ui, ix, iy + row, iw, label, p.fg, p.panel_hi)
      row = row + 1
    else
      value = status_text
    end
    if row < ih then
      local lines = format.wrap(value, iw, ih - row)
      for index = 1, #lines do
        line(ui, ix, iy + row + index - 1, iw, lines[index], p.fg, p.panel_hi)
      end
      row = row + #lines
    end
  end

  local window = history_window(history)
  if window and ih - row >= 5 then
    separator(ui, ix, iy + row, iw, p.panel_hi)
    row = row + 1
    line(ui, ix, iy + row, iw, "WINDOW " .. tostring(window.count) .. "s", p.dim, p.panel_hi)
    row = row + 1
    local charge = "CHARGE " .. percent_span(window.pmin, window.pmax, iw - 7)
    line(ui, ix, iy + row, iw, charge, p.fg, p.panel_hi)
    row = row + 1
    local net = "NET " .. eut_span(window.nmin, window.nmax, iw - 4)
    line(ui, ix, iy + row, iw, net, p.fg, p.panel_hi)
  end
end

local function net_samples(history)
  local samples = {}
  if type(history) == "table" then
    for index = 1, #history do
      local sample = history[index]
      if type(sample) == "table" then
        samples[#samples + 1] = num(sample.net)
      end
    end
  end
  return samples
end

local function draw_spark(ui, r, history)
  local p = ui.p
  local ix, iy, iw, ih = panel(ui, r, p.panel)
  if iw < 1 or ih < 1 then
    return
  end

  local samples = net_samples(history)
  local max_abs = 0
  local min_value, max_value = nil, nil
  local has_pos, has_neg = false, false
  for index = 1, #samples do
    local value = samples[index]
    if value ~= nil then
      if math.abs(value) > max_abs then
        max_abs = math.abs(value)
      end
      if min_value == nil or value < min_value then
        min_value = value
      end
      if max_value == nil or value > max_value then
        max_value = value
      end
      if value > 0 then
        has_pos = true
      elseif value < 0 then
        has_neg = true
      end
    end
  end

  if ih == 1 then
    local label = iw >= 13 and "POWER HISTORY" or (iw >= 4 and "HIST" or "")
    local label_w = 0
    if label ~= "" then
      label_w = line(ui, ix, iy, math.min(iw, format.width(label)), label, p.dim, p.panel)
    end
    local gap = label_w > 0 and 1 or 0
    local remaining = iw - label_w - gap
    if min_value and max_value and remaining >= 1 then
      local span = eut_span(min_value, max_value, remaining)
      if format.width(span) <= remaining then
        line_right(ui, ix + iw - 1, iy, remaining, span, p.dim, p.panel)
      end
    end
    return
  end

  local title = "POWER HISTORY"
  local title_w = line(ui, ix, iy, iw, title, p.dim, p.panel)
  local range_width = iw - title_w - 1
  local range_text = nil
  if max_abs > 0 and range_width >= 1 then
    if has_pos and has_neg then
      range_text = RANGE_SIGN .. format.eut(max_abs)
    else
      range_text = eut_span(min_value, max_value, range_width)
    end
  end
  if range_text and format.width(range_text) <= range_width then
    line_right(ui, ix + iw - 1, iy, range_width, range_text, p.dim, p.panel)
  end

  if ih <= 3 then
    ui.display.spark(ix, iy + 1, iw, ih - 1, samples, p.ok, p.bad)
    return
  end

  local top = iy + 1
  local bottom = iy + ih - 1
  local rows = ih - 1
  local mixed = has_pos and has_neg
  local baseline
  if mixed then
    baseline = top + math.floor(rows / 2)
  elseif has_pos then
    baseline = bottom
  else
    baseline = top
  end
  separator(ui, ix, baseline, iw, p.panel)

  local count = math.min(iw, #samples)
  ui.display.spark(ix, baseline, iw, 1, samples, p.border, p.border)
  if max_abs <= 0 or not min_value or not max_value then
    return
  end

  local low, high = min_value, max_value
  if not mixed then
    if low == high then
      low = low - 0.5
      high = high + 0.5
    end
  end
  local span = high - low

  for column = 1, count do
    local index
    if count > 1 then
      index = math.floor((column - 1) * (#samples - 1) / (count - 1)) + 1
    else
      index = #samples
    end
    local value = samples[index]
    if value ~= nil and value ~= 0 then
      if mixed then
        local fraction = math.abs(value) / max_abs
        if value > 0 then
          local extent = baseline - top
          local height = math.max(1, math.floor(fraction * extent + 0.5))
          local y0 = math.max(top, baseline - height)
          ui.display.fill(ix + column - 1, y0, 1, baseline - y0 + 1, " ", p.ok, p.ok)
        else
          local extent = bottom - baseline
          local height = math.max(1, math.floor(fraction * extent + 0.5))
          local y1 = math.min(bottom, baseline + height)
          ui.display.fill(ix + column - 1, baseline + 1, 1, y1 - baseline, " ", p.bad, p.bad)
        end
      elseif has_pos then
        local fraction = (value - low) / span
        local row = bottom - math.floor(fraction * (rows - 1) + 0.5)
        ui.display.fill(ix + column - 1, row, 1, bottom - row + 1, " ", p.ok, p.ok)
      else
        local fraction = (high - value) / span
        local row = math.max(top + 1, top + math.floor(fraction * (rows - 1) + 0.5))
        ui.display.fill(ix + column - 1, top + 1, 1, row - top, " ", p.bad, p.bad)
      end
    end
  end
end

local function draw_footer(ui, r, view)
  local p = ui.p
  ui.display.fill(r.x, r.y, r.w, r.h, " ", p.fg, p.head)
  local y = r.y
  local right = r.x + r.w - 1
  local x = r.x

  for _, def in ipairs(HINTS) do
    if x > right then
      break
    end
    local w = hint_width(def)
    local maxw = math.min(w, right - x + 1)
    line(ui, x, y, maxw, def.key .. " " .. def.label, p.dim, p.head)
    line(ui, x, y, 1, def.key, p.accent, p.head)
    x = x + w + 1
  end

  local rs_badge = "RS " .. (view.redstone_enabled and "ON" or "OFF")
  local rs_color = view.redstone_enabled and p.ok or p.dim
  local rs_w = format.width(rs_badge)
  local rs_x = right - rs_w + 1
  if rs_x >= x then
    ui.display.fill(rs_x, y, rs_w, 1, " ", p.black, rs_color)
    ui.display.text(rs_x, y, rs_badge, p.black, rs_color)
  end
end

local UI = {}
UI.__index = UI

---@param display table
---@param opts table|nil
---@return table
function M.new(display, opts)
  opts = opts or {}
  local self = setmetatable({
    display = display,
    p = opts.palette or theme.PALETTES.dark,
    icons = opts.show_icons ~= false,
    version = tostring(opts.version or "1.2.4"),
    w = 0,
    h = 0,
    regions = {},
  }, UI)

  local w, h = read_size(display)
  self.w = w
  self.h = h
  local rects = layout.layout(w, h)
  self.regions = build_regions(rects.footer)
  return self
end

---@param view table|nil
---@param history table|nil
function UI:render(view, history)
  if type(view) ~= "table" then
    view = {}
  end
  local w, h = read_size(self.display)
  self.w = w
  self.h = h
  local rects = layout.layout(w, h)

  self.display.clear(self.p.bg)
  draw_header(self, rects.header, view)
  draw_battery(self, rects.battery, view)
  draw_gauge(self, rects.gauge, view, history)
  draw_power(self, rects.power, view)
  local edge = rects.edge
  local divider = rects.edge.y == rects.status.y and rects.edge.x + rects.edge.w == rects.status.x
  if divider and rects.edge.w > 1 then
    edge = { x = rects.edge.x, y = rects.edge.y, w = rects.edge.w - 1, h = rects.edge.h }
  else
    divider = false
  end
  draw_edge(self, edge, view)
  local status = rects.status
  if divider and rects.status.w > 15 then
    status = { x = rects.status.x + 1, y = rects.status.y, w = rects.status.w - 1, h = rects.status.h }
  end
  draw_status(self, status, view, history)
  if divider then
    line(self, rects.status.x - 1, rects.edge.y, 1, BOX_V, self.p.dim, self.p.panel)
  end
  draw_spark(self, rects.spark, history)
  draw_footer(self, rects.footer, view)
  self.regions = build_regions(rects.footer)
  self.display.flip()
end

---@return table
function UI:hit_regions()
  return self.regions
end

---@param x number
---@param y number
---@return string|nil
function UI:handle_click(x, y)
  local px = tonumber(x)
  local py = tonumber(y)
  if not px or not py then
    return nil
  end
  px = math.floor(px)
  py = math.floor(py)
  for _, region in ipairs(self.regions) do
    if px >= region.x and px < region.x + region.w and py >= region.y and py < region.y + region.h then
      return region.name
    end
  end
  return nil
end

return M
