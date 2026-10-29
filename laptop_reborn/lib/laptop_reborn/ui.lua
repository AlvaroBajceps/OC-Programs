-- Graphical dashboard for laptop_reborn. The display object is injected; this
-- module never touches the GPU directly. Every draw is clipped to its panel
-- rect and every string is truncated by display width before it is emitted.

local theme = require("laptop_reborn.theme")
local layout = require("laptop_reborn.layout")
local format = require("laptop_reborn.format")

local M = {}

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
  if r.w >= 2 and r.h >= 2 then
    ui.display.box(r.x, r.y, r.w, r.h, p.border, bg, "single")
    return r.x + 1, r.y + 1, r.w - 2, r.h - 2
  end
  return r.x, r.y, r.w, r.h
end

local function draw_header(ui, r, view)
  local p = ui.p
  ui.display.fill(r.x, r.y, r.w, r.h, " ", p.fg, p.head)
  led(ui, r.x, r.y, p.accent)

  local y = r.y
  local right = r.x + r.w - 1
  local res_text = tostring(ui.w) .. "x" .. tostring(ui.h)
  local res_w = format.width(res_text)
  local res_x = right - res_w + 1

  local link = tostring(view.link or "OFF")
  local badge_w = format.width(link)
  local badge_x = res_x - badge_w - 1
  if badge_x < r.x + 1 then
    badge_x = nil
  end
  local right_limit = (badge_x and badge_x - 1) or (res_x - 1)

  local title_x = r.x + 2
  local avail = right_limit - title_x + 1
  local shown = line(ui, title_x, y, math.max(0, avail), "LAPTOP REBORN", p.fg, p.head)
  local cursor = title_x + shown

  local version = "v" .. tostring(ui.version)
  local vw = format.width(version)
  if cursor + 1 + vw <= right_limit then
    line(ui, cursor + 1, y, vw, version, p.dim, p.head)
    cursor = cursor + 1 + vw
  end

  local online = view.online and true or false
  local seq = num(view.seq) or 0
  local led_color = online and ((seq % 2 == 0) and p.ok or p.accent) or p.bad
  if cursor + 1 <= right_limit then
    led(ui, cursor + 1, y, led_color)
    cursor = cursor + 1
  end

  if badge_x and badge_x > cursor then
    local lc = link_color(p, link)
    ui.display.fill(badge_x, y, badge_w, 1, " ", p.black, lc)
    ui.display.text(badge_x, y, link, p.black, lc)
  end

  if res_x > r.x and res_x <= right then
    line(ui, res_x, y, res_w, res_text, p.dim, p.head)
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

  local content_x = ix
  local content_w = iw
  local battery = theme.COMPILED.battery
  if ui.icons and iw >= battery.w + 1 and ih >= battery.h then
    ui.display.sprite(ix, iy, battery)
    content_x = ix + battery.w + 1
    content_w = iw - battery.w - 1
  else
    led(ui, ix, iy, online and charge_color(p, percent) or p.dim)
    content_x = ix + 2
    content_w = iw - 2
  end
  if content_w < 1 then
    return
  end

  local row = 0
  if ih >= 3 then
    line(ui, content_x, iy + row, content_w, "BATTERY", online and p.accent or p.dim, p.panel)
    row = row + 1
  end

  local percent_text
  if not online then
    percent_text = "OFFLINE"
  elseif percent then
    percent_text = string.format("%d%%", math.floor(percent + 0.5))
  else
    percent_text = "--%"
  end
  if row < ih then
    line(ui, content_x, iy + row, content_w, percent_text, online and charge_color(p, percent) or p.bad, p.panel)
    row = row + 1
  end

  if row < ih then
    local stored_text = "--"
    if stored and capacity then
      stored_text = eu_pair(stored, capacity, content_w)
    elseif stored then
      stored_text = format.eu(stored)
    end
    line(ui, content_x, iy + row, content_w, stored_text, p.dim, p.panel)
    row = row + 1
  end

  if row < ih and capacity then
    line(ui, content_x, iy + row, content_w, "CAP " .. format.eu(capacity), p.dim, p.panel)
    row = row + 1
  end

  if row < ih and num(view.passive_loss) then
    line(ui, content_x, iy + row, content_w, "LOSS " .. format.eut(view.passive_loss), p.dim, p.panel)
  end
end

local function draw_gauge(ui, r, view, history)
  local p = ui.p
  local ix, iy, iw, ih = panel(ui, r, p.panel_hi)
  if iw < 1 or ih < 1 then
    return
  end

  local online = view.online and true or false
  local percent = num(view.percent)
  local color = online and charge_color(p, percent) or p.dim
  local net = num(view.net_kf) or num(view.net_instant) or 0

  local arrow = theme.COMPILED.transfer
  if net > 0 then
    arrow = theme.COMPILED.arrow_up
  elseif net < 0 then
    arrow = theme.COMPILED.arrow_down
  end
  local arrow_w = 0
  if ui.icons and ih >= arrow.h + 1 and iw >= arrow.w + 10 then
    ui.display.sprite(ix + iw - arrow.w, iy, arrow)
    arrow_w = arrow.w + 1
  end
  local content_w = iw - arrow_w
  if content_w < 1 then
    return
  end

  local row = 0
  if ih >= 2 then
    local label_w = line(ui, ix, iy, content_w, "CHARGE", p.dim, p.panel_hi)
    if online and percent then
      local text = string.format("%d%%", math.floor(percent + 0.5))
      line_right(ui, ix + content_w - 1, iy, math.max(0, content_w - label_w - 1), text, color, p.panel_hi)
    end
    row = 1
  end

  local bar_y = iy + row
  if bar_y > iy + ih - 1 then
    return
  end
  ui.display.fill(ix, bar_y, content_w, 1, " ", p.panel, p.panel)
  local filled = 0
  if percent then
    local clamped = math.max(0, math.min(100, percent))
    filled = math.floor(clamped / 100 * content_w + 0.5)
  end
  if filled > 0 then
    ui.display.fill(ix, bar_y, filled, 1, " ", color, color)
  end
  row = row + 1

  if row < ih and content_w >= 10 then
    local seg_w = math.floor(content_w / 10)
    for seg = 1, 10 do
      local sx = ix + (seg - 1) * seg_w
      local on = percent ~= nil and seg <= math.floor(percent / 10 + 0.5)
      led(ui, sx, iy + row, on and color or p.panel)
    end
    row = row + 1
  end

  if row < ih then
    local detail
    if online and num(view.stored) then
      detail = format.eu(view.stored)
      if num(view.capacity_total) then
        detail = eu_pair(view.stored, view.capacity_total, content_w)
      end
    else
      detail = "OFFLINE"
    end
    line(ui, ix, iy + row, content_w, detail, p.dim, p.panel_hi)
    row = row + 1
  end

  if row < ih and num(view.passive_loss) then
    line(ui, ix, iy + row, content_w, "LOSS " .. format.eut(view.passive_loss), p.dim, p.panel_hi)
    row = row + 1
  end

  if ih - row >= 3 then
    local samples = {}
    if type(history) == "table" then
      for index = 1, #history do
        local sample = history[index]
        if type(sample) == "table" and type(sample.percent) == "number" then
          samples[#samples + 1] = sample.percent - 50
        end
      end
    end
    if #samples > 0 then
      line(ui, ix, iy + row, content_w, "CHARGE HISTORY", p.dim, p.panel_hi)
      row = row + 1
      ui.display.spark(ix, iy + row, content_w, ih - row, samples, color, p.dim)
    end
  end
end

local function power_row(ui, ix, y, iw, label, value, color, bg)
  if iw >= 2 then
    led(ui, ix, y, color)
  end
  local label_w = line(ui, ix + 2, y, math.max(0, iw - 2), label, color, bg)
  if label_w > 0 then
    line(ui, ix + 2 + label_w + 1, y, math.max(0, iw - 2 - label_w - 1), value, color, bg)
  end
end

local function draw_power(ui, r, view)
  local p = ui.p
  local ix, iy, iw, ih = panel(ui, r, p.panel)
  if iw < 1 or ih < 1 then
    return
  end

  local net = num(view.net_kf) or num(view.net_instant)
  local net_color = p.dim
  if net then
    if net > 0 then
      net_color = p.ok
    elseif net < 0 then
      net_color = p.bad
    end
  end

  local row = 0
  if ih >= 5 then
    line(ui, ix, iy, iw, "POWER FLOW", p.dim, p.panel)
    row = 1
  end

  local rows = {
    { label = "IN", value = format.eut(view.in_5s), color = p.ok },
    { label = "OUT", value = format.eut(view.out_5s), color = p.bad },
    { label = "NET", value = format.eut(net), color = net_color },
  }
  for _, item in ipairs(rows) do
    if row >= ih then
      break
    end
    power_row(ui, ix, iy + row, iw, item.label, item.value, item.color, p.panel)
    row = row + 1
  end

  if row < ih and (num(view.in_5m) or num(view.out_5m)) then
    line(ui, ix, iy + row, iw, "AVG 5m", p.dim, p.panel)
    row = row + 1
  end
  if row < ih and num(view.in_5m) then
    power_row(ui, ix, iy + row, iw, "IN", format.eut(view.in_5m), p.dim, p.panel)
    row = row + 1
  end
  if row < ih and num(view.out_5m) then
    power_row(ui, ix, iy + row, iw, "OUT", format.eut(view.out_5m), p.dim, p.panel)
    row = row + 1
  end

  if row < ih and (num(view.in_1h) or num(view.out_1h)) then
    line(ui, ix, iy + row, iw, "AVG 1h", p.dim, p.panel)
    row = row + 1
  end
  if row < ih and num(view.in_1h) then
    power_row(ui, ix, iy + row, iw, "IN", format.eut(view.in_1h), p.dim, p.panel)
    row = row + 1
  end
  if row < ih and num(view.out_1h) then
    power_row(ui, ix, iy + row, iw, "OUT", format.eut(view.out_1h), p.dim, p.panel)
  end
end

local function draw_edge(ui, r, view)
  local p = ui.p
  local ix, iy, iw, ih = panel(ui, r, p.panel)
  if iw < 1 or ih < 1 then
    return
  end

  local text = tostring(view.edge_text or "unknown")
  local clock = theme.COMPILED.clock
  if ui.icons and ih >= clock.h and iw >= clock.w + 1 then
    ui.display.sprite(ix, iy, clock)
    local text_x = ix + clock.w + 1
    local text_w = iw - clock.w - 1
    line(ui, text_x, iy, text_w, "EDGE", p.dim, p.panel)
    if ih >= 2 then
      line(ui, text_x, iy + 1, text_w, text, p.fg, p.panel)
    end
    return
  end

  if ih >= 2 then
    line(ui, ix, iy, iw, "EDGE TIME", p.dim, p.panel)
    line(ui, ix, iy + 1, iw, text, p.fg, p.panel)
  else
    line(ui, ix, iy, iw, text, p.fg, p.panel)
  end
end

local function draw_status(ui, r, view)
  local p = ui.p
  local ix, iy, iw, ih = panel(ui, r, p.panel_hi)
  if iw < 1 or ih < 1 then
    return
  end

  local online = view.online and true or false
  local maintenance = view.maintenance
  local maint_text = "MAINT ?"
  local maint_color = p.dim
  if maintenance == true then
    maint_text = "MAINT!"
    maint_color = p.bad
  elseif maintenance == false then
    maint_text = "MAINT OK"
    maint_color = p.ok
  end
  local lapo_text = online and "LAPOTRON ONLINE" or "LAPOTRON OFFLINE"
  local lapo_color = online and p.ok or p.bad
  local rs_text = view.redstone_enabled and "RS ON" or "RS OFF"
  local rs_color = view.redstone_enabled and p.ok or p.dim
  local status_text = tostring(view.status_text or "")
  local link = tostring(view.link or "OFF")

  if ih == 1 then
    local text
    if not online then
      text = format.width(lapo_text) <= iw and lapo_text or "LAPO OFFLINE"
    else
      text = maint_text .. " LAP ON"
      if format.width(text) + 1 + format.width(rs_text) <= iw then
        text = text .. " " .. rs_text
      end
    end
    line(ui, ix, iy, iw, text, online and p.fg or p.bad, p.panel_hi)
    return
  end

  local icon = maintenance == true and theme.COMPILED.warning or theme.COMPILED.wrench
  local icon_color = maintenance == true and p.bad or p.ok
  local text_x = ix
  local text_w = iw
  if ui.icons and ih >= icon.h and iw >= icon.w + 1 then
    ui.display.sprite(ix, iy, icon)
    text_x = ix + icon.w + 1
    text_w = iw - icon.w - 1
  else
    led(ui, ix, iy, icon_color)
    text_x = ix + 2
    text_w = iw - 2
  end
  if text_w < 1 then
    return
  end

  local row = 0
  line(ui, text_x, iy + row, text_w, maint_text, maint_color, p.panel_hi)
  row = row + 1
  if row < ih then
    line(ui, text_x, iy + row, text_w, lapo_text, lapo_color, p.panel_hi)
    row = row + 1
  end
  if row < ih then
    led(ui, text_x, iy + row, rs_color)
    line(ui, text_x + 2, iy + row, math.max(0, text_w - 2), rs_text, rs_color, p.panel_hi)
    row = row + 1
  end
  if row < ih and status_text ~= "" then
    line(ui, text_x, iy + row, text_w, status_text, p.dim, p.panel_hi)
    row = row + 1
  end
  if row < ih then
    line(ui, text_x, iy + row, text_w, "LINK " .. link, link_color(p, link), p.panel_hi)
    row = row + 1
  end
  if row < ih and num(view.capacity_total) then
    line(ui, text_x, iy + row, text_w, "CAP " .. format.eu(view.capacity_total), p.dim, p.panel_hi)
    row = row + 1
  end
  if row < ih then
    line(ui, text_x, iy + row, text_w, "PANEL v" .. ui.version, p.dim, p.panel_hi)
    row = row + 1
  end
  if row < ih then
    line(ui, text_x, iy + row, text_w, "SCALE " .. ui.w .. "x" .. ui.h, p.dim, p.panel_hi)
  end
end

local function draw_spark(ui, r, history)
  local p = ui.p
  local ix, iy, iw, ih = panel(ui, r, p.panel)
  if iw < 1 or ih < 1 then
    return
  end

  local samples = {}
  if type(history) == "table" then
    for index = 1, #history do
      local sample = history[index]
      if type(sample) == "table" then
        samples[#samples + 1] = num(sample.net)
      end
    end
  end

  if ih == 1 then
    local label_w = 0
    if iw >= 10 then
      label_w = line(ui, ix, iy, 4, "HIST", p.dim, p.panel) + 1
    end
    ui.display.spark(ix + label_w, iy, math.max(1, iw - label_w), 1, samples, p.accent, p.dim)
    return
  end

  line(ui, ix, iy, iw, "POWER HISTORY", p.dim, p.panel)
  ui.display.spark(ix, iy + 1, iw, ih - 1, samples, p.accent, p.dim)
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
    local link = tostring(view.link or "OFF")
    local link_text = "LINK " .. link
    local link_w = format.width(link_text)
    local link_x = rs_x - 1 - link_w
    if link_x >= x then
      line(ui, link_x, y, link_w, link_text, link_color(p, link), p.head)
    end
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
    version = tostring(opts.version or "1.0.0"),
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
  draw_edge(self, rects.edge, view)
  draw_status(self, rects.status, view)
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
