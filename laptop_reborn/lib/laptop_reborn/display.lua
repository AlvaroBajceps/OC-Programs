-- Double-buffered drawing surface for laptop_reborn. The GPU is injected; no
-- component is bound at require time. Every primitive clips to the current
-- resolution so a malformed rect can never throw from gpu.set/fill.

local methods = require("laptop_reborn.methods")

local M = {}

local SINGLE_BOX = {
  h = "\226\148\128",
  v = "\226\148\130",
  tl = "\226\148\140",
  tr = "\226\148\144",
  bl = "\226\148\148",
  br = "\226\148\152",
}

local DOUBLE_BOX = {
  h = "\226\149\144",
  v = "\226\149\145",
  tl = "\226\149\148",
  tr = "\226\149\151",
  bl = "\226\149\154",
  br = "\226\149\157",
}

local function cp_len(s)
  return utf8.len(s) or #s
end

local function cp_sub(s, from, to)
  local len = cp_len(s)
  from = math.max(1, from or 1)
  to = math.min(len, to or len)
  if from > to then
    return ""
  end
  local index = 0
  local start_byte = nil
  local end_byte = #s
  for i = 1, #s do
    local byte = s:byte(i)
    if byte < 0x80 or byte >= 0xC0 then
      index = index + 1
      if index == from then
        start_byte = i
      end
      if index == to + 1 then
        end_byte = i - 1
        break
      end
    end
  end
  if not start_byte then
    return ""
  end
  return s:sub(start_byte, end_byte)
end

local function fallback_trunc(s, width)
  if width <= 0 then
    return ""
  end
  if cp_len(s) <= width then
    return s
  end
  if width >= 4 then
    return cp_sub(s, 1, width - 2) .. ".."
  end
  return cp_sub(s, 1, width)
end

---@param deps table
---@return table
function M.new(deps)
  deps = deps or {}
  local gpu = deps.gpu
  if not gpu then
    error("laptop_reborn.display requires deps.gpu")
  end

  local format_cache = nil
  local format_mod = deps.format

  local function get_format()
    if format_mod then
      return format_mod
    end
    if format_cache == nil then
      local ok, mod = pcall(require, "laptop_reborn.format")
      format_cache = ok and mod or false
    end
    return format_cache or nil
  end

  local function trunc(text, width)
    local fmt = get_format()
    if fmt and type(fmt.trunc) == "function" then
      return fmt.trunc(text, width)
    end
    return fallback_trunc(text, width)
  end

  local function read_resolution()
    local ok, w, h = pcall(gpu.getResolution)
    if ok and type(w) == "number" and type(h) == "number" then
      return w, h
    end
    return 80, 25
  end

  local function read_max()
    local ok, w, h = pcall(gpu.maxResolution)
    if ok and type(w) == "number" and type(h) == "number" then
      return w, h
    end
    return read_resolution()
  end

  local scr_w, scr_h = read_resolution()
  local orig_w, orig_h = nil, nil
  local back_buf = nil

  local function clamp_rect(x, y, w, h)
    x = math.floor(tonumber(x) or 1)
    y = math.floor(tonumber(y) or 1)
    w = math.floor(tonumber(w) or 0)
    h = math.floor(tonumber(h) or 0)
    if w < 1 or h < 1 then
      return nil
    end
    local x1 = math.max(1, x)
    local y1 = math.max(1, y)
    local x2 = math.min(scr_w, x + w - 1)
    local y2 = math.min(scr_h, y + h - 1)
    if x2 < x1 or y2 < y1 then
      return nil
    end
    return x1, y1, x2 - x1 + 1, y2 - y1 + 1
  end

  local function clip_text(x, y, text)
    if y < 1 or y > scr_h then
      return nil
    end
    if x > scr_w then
      return nil
    end
    local draw_x = math.max(1, x)
    local avail = scr_w - draw_x + 1
    if avail < 1 then
      return nil
    end
    local body = text
    if x < 1 then
      body = cp_sub(text, 2 - x, cp_len(text))
    end
    body = trunc(body, avail)
    if body == "" then
      return nil
    end
    return draw_x, body
  end

  local display = {}

  function display.set_resolution(w, h)
    local current_w, current_h = read_resolution()
    if not orig_w then
      orig_w, orig_h = current_w, current_h
    end
    local max_w, max_h = read_max()
    local target_w = math.max(1, math.floor(tonumber(w) or current_w))
    local target_h = math.max(1, math.floor(tonumber(h) or current_h))
    target_w = math.min(target_w, max_w)
    target_h = math.min(target_h, max_h)
    pcall(gpu.setResolution, target_w, target_h)
    scr_w, scr_h = read_resolution()
    if back_buf then
      pcall(gpu.freeBuffer, back_buf)
      back_buf = nil
    end
    if methods.get(gpu, "allocateBuffer") ~= nil then
      local ok, buf = methods.call(gpu, "allocateBuffer", scr_w, scr_h)
      if ok and buf then
        back_buf = buf
        pcall(gpu.setActiveBuffer, back_buf)
      end
    end
    return scr_w, scr_h
  end

  function display.size()
    return scr_w, scr_h
  end

  function display.clear(bg)
    gpu.setBackground(bg or 0x000000)
    gpu.fill(1, 1, scr_w, scr_h, " ")
  end

  function display.text(x, y, text, fg, bg)
    x = math.floor(tonumber(x) or 1)
    y = math.floor(tonumber(y) or 1)
    local draw_x, body = clip_text(x, y, tostring(text or ""))
    if not draw_x then
      return
    end
    gpu.setBackground(bg or 0x000000)
    gpu.setForeground(fg or 0xFFFFFF)
    gpu.set(draw_x, y, body)
  end

  function display.fill(x, y, w, h, ch, fg, bg)
    local cx, cy, cw, chh = clamp_rect(x, y, w, h)
    if not cx then
      return
    end
    gpu.setBackground(bg or 0x000000)
    gpu.setForeground(fg or 0xFFFFFF)
    gpu.fill(cx, cy, cw, chh, ch or " ")
  end

  function display.box(x, y, w, h, border, bg, style)
    local cx, cy, cw, ch = clamp_rect(x, y, w, h)
    if not cx then
      return
    end
    if cw < 2 or ch < 2 then
      gpu.setBackground(bg or 0x000000)
      gpu.fill(cx, cy, cw, ch, " ")
      return
    end
    local chars = style == "double" and DOUBLE_BOX or SINGLE_BOX
    gpu.setBackground(bg or 0x000000)
    gpu.fill(cx + 1, cy + 1, cw - 2, ch - 2, " ")
    gpu.setForeground(border or 0xFFFFFF)
    local horizontal = string.rep(chars.h, cw - 2)
    gpu.set(cx, cy, chars.tl .. horizontal .. chars.tr)
    gpu.set(cx, cy + ch - 1, chars.bl .. horizontal .. chars.br)
    for row = cy + 1, cy + ch - 2 do
      gpu.set(cx, row, chars.v)
      gpu.set(cx + cw - 1, row, chars.v)
    end
  end

  function display.sprite(x, y, compiled)
    if not compiled or not compiled.runs then
      return
    end
    x = math.floor(tonumber(x) or 1)
    y = math.floor(tonumber(y) or 1)
    for _, run in ipairs(compiled.runs) do
      local cx, cy, cw, ch = clamp_rect(x + run.x - 1, y + run.y - 1, run.w, run.h)
      if cx then
        gpu.setBackground(run.color)
        gpu.fill(cx, cy, cw, ch, " ")
      end
    end
  end

  function display.spark(x, y, w, h, samples, fg, dim)
    x = math.floor(tonumber(x) or 1)
    y = math.floor(tonumber(y) or 1)
    w = math.floor(tonumber(w) or 0)
    h = math.floor(tonumber(h) or 0)
    if w < 1 or h < 1 then
      return
    end
    local y1 = math.max(1, y)
    local y2 = math.min(scr_h, y + h - 1)
    if y2 < y1 then
      return
    end
    local x1 = math.max(1, x)
    local x2 = math.min(scr_w, x + w - 1)
    if x2 < x1 then
      return
    end
    local list = samples or {}
    local base = math.max(0, #list - w)
    local max_abs = 0
    for index = base + 1, #list do
      local value = list[index]
      if type(value) == "number" and math.abs(value) > max_abs then
        max_abs = math.abs(value)
      end
    end
    if max_abs <= 0 then
      return
    end
    local bar_area = y2 - y1 + 1
    local pos_color = fg or 0xFFFFFF
    local neg_color = dim or pos_color
    for px = x1, x2 do
      local value = list[base + (px - x) + 1]
      if type(value) == "number" and value ~= 0 then
        local bar = math.floor(math.abs(value) / max_abs * bar_area + 0.5)
        if bar < 1 then
          bar = 1
        end
        if bar > bar_area then
          bar = bar_area
        end
        gpu.setBackground(value > 0 and pos_color or neg_color)
        gpu.fill(px, y2 - bar + 1, 1, bar, " ")
      end
    end
  end

  function display.flip()
    if not back_buf then
      return
    end
    gpu.setActiveBuffer(0)
    gpu.bitblt(0, 1, 1, scr_w, scr_h, back_buf, 1, 1)
    gpu.setActiveBuffer(back_buf)
  end

  function display.free()
    if back_buf then
      pcall(gpu.setActiveBuffer, 0)
      pcall(gpu.freeBuffer, back_buf)
      back_buf = nil
    end
    if orig_w and orig_h then
      pcall(gpu.setResolution, orig_w, orig_h)
      scr_w, scr_h = read_resolution()
      orig_w, orig_h = nil, nil
    end
  end

  return display
end

return M
