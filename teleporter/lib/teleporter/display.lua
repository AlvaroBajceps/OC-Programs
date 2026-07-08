-- GPU/screen setup and double-buffered drawing primitives.
-- Owns the gpu proxy, allocated back-buffer, and current resolution. All
-- teleporter UI screens render into the back-buffer; flip() blits it to the
-- visible screen in one bitblt to avoid mid-frame tearing.

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

  local function draw_box(x, y, w, h, border_color, bg_color)
    gpu.setBackground(bg_color)
    gpu.setForeground(border_color)
    for col = x, x + w - 1 do
      gpu.set(col, y, "\226\148\128")
      gpu.set(col, y + h - 1, "\226\148\128")
    end
    for row = y + 1, y + h - 2 do
      gpu.set(x, row, "\226\148\130")
      gpu.set(x + w - 1, row, "\226\148\130")
    end
    gpu.set(x, y, "\226\148\140")
    gpu.set(x + w - 1, y, "\226\148\144")
    gpu.set(x, y + h - 1, "\226\148\148")
    gpu.set(x + w - 1, y + h - 1, "\226\148\152")
    gpu.setBackground(bg_color)
    for row = y + 1, y + h - 2 do
      for col = x + 1, x + w - 2 do
        gpu.set(col, row, " ")
      end
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

  local function draw_filled_button(x, y, w, h, text, fg, bg, border_color)
    draw_box(x, y, w, h, border_color, bg)
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
