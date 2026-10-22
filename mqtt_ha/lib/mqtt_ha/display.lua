-- GPU/screen setup and double-buffered drawing primitives.
-- Shared with src/OC-Programs/teleporter/lib/teleporter/display.lua.
-- Owns the gpu proxy, allocated back-buffer, and current resolution. All
-- screens render into the back-buffer; flip() blits it to the visible screen
-- in one bitblt to avoid mid-frame tearing.

local component = require("component")

return function()
  local gpu
  local screen_addr
  local scr_w, scr_h = 80, 25
  local back_buf

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
      gpu.setResolution(math.min(max_w, 80), math.min(max_h, 25))
      scr_w, scr_h = gpu.getResolution()
    end
    back_buf = gpu.allocateBuffer(scr_w, scr_h)
    if not back_buf then
      error("GPU does not have enough VRAM for a back-buffer. Reduce resolution.")
    end
  end

  local function flip()
    gpu.setActiveBuffer(0)
    gpu.bitblt(0, 1, 1, scr_w, scr_h, back_buf, 1, 1)
    gpu.setActiveBuffer(back_buf)
  end

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

  local function draw_text(x, y, text, fg, bg)
    gpu.setBackground(bg or 0x000000)
    gpu.setForeground(fg or 0xFFFFFF)
    gpu.set(x, y, text)
  end

  local function draw_box(x, y, w, h, border_color, bg_color, style)
    if w < 2 or h < 2 then
      gpu.setBackground(bg_color)
      gpu.fill(x, y, w, h, " ")
      return
    end
    local chars = style == "double" and DOUBLE_BOX or SINGLE_BOX
    gpu.setBackground(bg_color)
    gpu.fill(x + 1, y + 1, w - 2, h - 2, " ")
    gpu.setForeground(border_color)
    local horizontal = string.rep(chars.h, w - 2)
    gpu.set(x, y, chars.tl .. horizontal .. chars.tr)
    gpu.set(x, y + h - 1, chars.bl .. horizontal .. chars.br)
    for row = y + 1, y + h - 2 do
      gpu.set(x, row, chars.v)
      gpu.set(x + w - 1, row, chars.v)
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

  local function draw_filled_button(x, y, w, h, text, fg, bg, border_color, style)
    draw_box(x, y, w, h, border_color, bg, style)
    gpu.setBackground(bg)
    gpu.setForeground(fg)
    local tlen = #text
    local tx = x + math.floor((w - tlen) / 2)
    if tx < x + 1 then
      tx = x + 1
    end
    gpu.set(tx, y + math.floor(h / 2), text)
  end

  return {
    setup = setup,
    flip = flip,
    draw_box = draw_box,
    draw_text = draw_text,
    draw_text_centered = draw_text_centered,
    draw_filled_button = draw_filled_button,
    get_gpu = function()
      return gpu
    end,
    get_screen_addr = function()
      return screen_addr
    end,
    get_dims = function()
      return scr_w, scr_h
    end,
    get_back_buffer = function()
      return back_buf
    end,
    set_active_buffer = function(b)
      gpu.setActiveBuffer(b)
    end,
    free = function()
      if gpu and back_buf then
        gpu.setActiveBuffer(0)
        gpu.freeBuffer(back_buf)
      end
    end,
  }
end
