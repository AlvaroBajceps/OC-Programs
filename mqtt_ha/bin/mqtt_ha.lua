-- MQTT <-> Home Assistant industrial control panel for OpenComputers (Lua 5.3).
--
-- Exposes two controls:
--   light.<node>_lamp              "Panel Lamp"    (bidirectional ON/OFF)
--   select.<node>_restart_mode     "Restart Mode"  (off/on/keep_state at boot)
-- and one diagnostic entity:
--   binary_sensor.<node>_link      "Broker Link"   (ONLINE/OFFLINE)
--
-- Press Space/Enter (or click the breaker/lamp) on the OC screen to toggle.
-- Press M (or click the footer hint) to cycle the restart mode. The mode and
-- the last lamp value are persisted to /etc/mqtt_ha.state so the panel
-- restores itself on restart. HA commands update the same state. Ctrl+C (or Q)
-- publishes offline and exits.
--
-- Prerequisites: Internet Card, keyboard component for shortcuts (every control
-- is also clickable), Mosquitto at 172.16.69.4:1883 reachable from the GTNH
-- container, ip:172.16.69.4 allowed in OpenComputers.cfg, and HA's MQTT
-- integration pointed at the same broker. The mqtt_ha package installs its
-- renderer as mqtt_ha.display; without it the program falls back to a compact
-- built-in panel. luamqtt is downloaded into /lib/mqtt on first run, pinned to
-- the commit below. See src/OC-Programs/mqtt_ha/README.md.

local M = {}

M.CONFIG = {
  broker = "172.16.69.4",
  port = 1883,
  username = "",
  password = "",
  discovery_prefix = "homeassistant",
  keep_alive = 30,
  state_interval = 30,
  reconnect = 5,
  mqtt_dir = "/lib/mqtt",
  state_file = "/etc/mqtt_ha.state",
  restart_mode = "keep_state",
  device_name = "GTNH Industrial Panel",
  version = "2.2.1",
}

M.MQTT_COMMIT = "14ad9be4c327972be68726d3c796c781eb4cc542"
M.MQTT_FILES = {
  "init.lua",
  "const.lua",
  "client.lua",
  "ioloop.lua",
  "protocol.lua",
  "protocol4.lua",
  "protocol5.lua",
  "tools.lua",
  "bitwrap.lua",
  "bit53.lua",
}
M.MQTT_RAW = "https://raw.githubusercontent.com/xHasKx/luamqtt/" .. M.MQTT_COMMIT .. "/mqtt/"

local function json_escape(value)
  return (
    value:gsub('[%z\1-\31\\"]', function(char)
      if char == '"' then
        return '\\"'
      elseif char == "\\" then
        return "\\\\"
      elseif char == "\b" then
        return "\\b"
      elseif char == "\f" then
        return "\\f"
      elseif char == "\n" then
        return "\\n"
      elseif char == "\r" then
        return "\\r"
      elseif char == "\t" then
        return "\\t"
      end
      return string.format("\\u%04x", char:byte())
    end)
  )
end

---@param value any
---@return string
function M.json_encode(value)
  local kind = type(value)
  if kind == "nil" then
    return "null"
  elseif kind == "boolean" then
    return value and "true" or "false"
  elseif kind == "number" then
    if value == math.floor(value) then
      return string.format("%d", value)
    end
    return string.format("%.14g", value)
  elseif kind == "string" then
    return '"' .. json_escape(value) .. '"'
  elseif kind ~= "table" then
    error("cannot JSON-encode " .. kind)
  end

  if #value > 0 then
    local items = {}
    for index = 1, #value do
      items[index] = M.json_encode(value[index])
    end
    return "[" .. table.concat(items, ",") .. "]"
  end

  local items = {}
  for key, item in pairs(value) do
    if type(key) ~= "string" then
      error("JSON object keys must be strings")
    end
    items[#items + 1] = '"' .. json_escape(key) .. '":' .. M.json_encode(item)
  end
  table.sort(items)
  return "{" .. table.concat(items, ",") .. "}"
end

---@param computer table
---@return table
function M.make_config(computer)
  local address = computer.address():gsub("[^%w]", ""):lower()
  local node = "oc_" .. address:sub(1, 8)
  local base = "gtnh/oc/" .. node

  return {
    broker = M.CONFIG.broker,
    port = M.CONFIG.port,
    username = M.CONFIG.username,
    password = M.CONFIG.password,
    client_id = node,
    base_topic = base,
    availability_topic = base .. "/availability",
    lamp_command_topic = base .. "/lamp/set",
    lamp_state_topic = base .. "/lamp/state",
    link_state_topic = base .. "/link/state",
    restart_command_topic = base .. "/restart_mode/set",
    restart_state_topic = base .. "/restart_mode/state",
    state_file = M.CONFIG.state_file,
    discovery_prefix = M.CONFIG.discovery_prefix,
    keep_alive = M.CONFIG.keep_alive,
    state_interval = M.CONFIG.state_interval,
    reconnect = M.CONFIG.reconnect,
    mqtt_dir = M.CONFIG.mqtt_dir,
    version = M.CONFIG.version,
    device = {
      identifiers = { node },
      name = M.CONFIG.device_name .. " " .. node,
      manufacturer = "OpenComputers / GTNH",
      model = "Industrial HMI",
      sw_version = M.CONFIG.version,
    },
    origin = {
      name = "oc_gtnh mqtt_ha",
      sw_version = M.CONFIG.version,
    },
  }
end

---@param cfg table
---@return table
function M.build_lamp_discovery(cfg)
  local unique_id = cfg.client_id .. "_lamp"
  return {
    name = "Panel Lamp",
    unique_id = unique_id,
    default_entity_id = "light." .. unique_id,
    icon = "mdi:ceiling-light",
    schema = "basic",
    command_topic = cfg.lamp_command_topic,
    state_topic = cfg.lamp_state_topic,
    availability_topic = cfg.availability_topic,
    payload_on = "ON",
    payload_off = "OFF",
    optimistic = false,
    qos = 1,
    retain = false,
    device = cfg.device,
    origin = cfg.origin,
  }
end

---@param cfg table
---@return table
function M.build_link_discovery(cfg)
  local unique_id = cfg.client_id .. "_link"
  return {
    name = "Broker Link",
    unique_id = unique_id,
    default_entity_id = "binary_sensor." .. unique_id,
    icon = "mdi:lan-connect",
    device_class = "connectivity",
    entity_category = "diagnostic",
    state_topic = cfg.link_state_topic,
    payload_on = "ONLINE",
    payload_off = "OFFLINE",
    availability_topic = cfg.availability_topic,
    qos = 1,
    device = cfg.device,
    origin = cfg.origin,
  }
end

---@param cfg table
---@return table
function M.build_restart_mode_discovery(cfg)
  return {
    name = "Restart Mode",
    unique_id = cfg.client_id .. "_restart_mode",
    default_entity_id = "select." .. cfg.client_id .. "_restart_mode",
    icon = "mdi:restart",
    command_topic = cfg.restart_command_topic,
    state_topic = cfg.restart_state_topic,
    options = { "off", "on", "keep_state" },
    entity_category = "config",
    qos = 1,
    retain = false,
    availability_topic = cfg.availability_topic,
    device = cfg.device,
    origin = cfg.origin,
  }
end

---@param cfg table
---@return string[]
function M.stale_discovery_topics(cfg)
  local prefix = cfg.discovery_prefix .. "/"
  return {
    prefix .. "switch/" .. cfg.client_id .. "_button/config",
    prefix .. "button/" .. cfg.client_id .. "_toggle/config",
    prefix .. "light/" .. cfg.client_id .. "_bulb/config",
  }
end

---@param cfg table
---@return string[]
function M.stale_state_topics(cfg)
  return {
    cfg.base_topic .. "/button/state",
    cfg.base_topic .. "/bulb/state",
  }
end

---@param value any
---@return string|nil
function M.normalize_restart_mode(value)
  if type(value) ~= "string" then
    return nil
  end
  local mode = value:gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if mode == "off" or mode == "on" or mode == "keep_state" then
    return mode
  end
  return nil
end

---@param mode string|nil
---@return string
function M.next_restart_mode(mode)
  local normalized = M.normalize_restart_mode(mode)
  if normalized == "off" then
    return "on"
  elseif normalized == "on" then
    return "keep_state"
  elseif normalized == "keep_state" then
    return "off"
  end
  return "off"
end

---@param info table|nil
---@return string|nil
function M.process_identity(info)
  if type(info) ~= "table" then
    return nil
  end
  if info.command == "lua" then
    return nil
  end
  local command = info.command
  local path = info.path
  if command == nil and path == nil then
    return nil
  end
  return tostring(command or "") .. "\0" .. tostring(path or "")
end

---@param process table|nil
---@param current thread
---@return boolean
function M.has_running_instance(process, current)
  if not process or not process.list or not process.info then
    return false
  end
  local ok, this = pcall(process.info, current)
  if not ok or not this then
    return false
  end
  local this_id = M.process_identity(this)
  if not this_id then
    return false
  end
  for thread in pairs(process.list) do
    if thread ~= current then
      local info_ok, info = pcall(process.info, thread)
      if info_ok and info and M.process_identity(info) == this_id then
        return true
      end
    end
  end
  return false
end

---@param char string|number|nil
---@return string|nil
function M.key_char(char)
  if type(char) == "string" then
    return char:lower()
  end
  if type(char) == "number" and char >= 32 and char <= 126 then
    return string.char(char):lower()
  end
  return nil
end

---@param lamp boolean|nil
---@param restart_mode string|nil
---@return table
function M.new_state(lamp, restart_mode)
  return {
    lamp = lamp == true,
    restart_mode = M.normalize_restart_mode(restart_mode) or M.CONFIG.restart_mode,
  }
end

---@param saved table|nil
---@return table
function M.boot_state(saved)
  saved = saved or {}
  local mode = M.normalize_restart_mode(saved.restart_mode) or M.CONFIG.restart_mode
  local lamp = false
  if mode == "on" then
    lamp = true
  elseif mode == "keep_state" then
    lamp = saved.has_lamp == true and saved.lamp == true
  end
  return M.new_state(lamp, mode)
end

---@param text string|nil
---@return table
function M.parse_persisted(text)
  local result = { restart_mode = nil, lamp = false, has_lamp = false }
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if key then
      key = key:lower()
      if key == "restart_mode" then
        local mode = M.normalize_restart_mode(value)
        if mode then
          result.restart_mode = mode
        end
      elseif key == "lamp" or key == "last_lamp" then
        local normalized = value:lower()
        local lamp
        if normalized == "on" or normalized == "1" or normalized == "true" then
          lamp = true
        elseif normalized == "off" or normalized == "0" or normalized == "false" then
          lamp = false
        end
        if lamp ~= nil then
          result.lamp = lamp
          result.has_lamp = true
        end
      end
    end
  end
  return result
end

---@param state table
---@return string
function M.serialize_state(state)
  local mode = M.normalize_restart_mode(state.restart_mode) or M.CONFIG.restart_mode
  return "# restart_mode=off|on|keep_state; last_lamp is used only by keep_state\n"
    .. "restart_mode="
    .. mode
    .. "\nlast_lamp="
    .. (state.lamp and "on" or "off")
    .. "\n"
end

---@param path string
---@return string|nil, string|nil
local function read_file(path)
  local ok, file, open_err = pcall(io.open, path, "r")
  if not ok or not file then
    local reason = tostring(file or open_err or "")
    if reason:match("[Nn]o such file") or reason:match("[Nn]ot found") then
      return nil, nil
    end
    return nil, reason ~= "" and reason or nil
  end
  local read_ok, text = pcall(file.read, file, "*a")
  file:close()
  if not read_ok then
    return nil, tostring(text)
  end
  return text, nil
end

---@param path string
---@return table|nil, string|nil
function M.load_persisted(path)
  local text, err = read_file(path)
  if not text or #text == 0 then
    local temp_text, temp_err = read_file(path .. ".tmp")
    if temp_text and #temp_text > 0 then
      text, err = temp_text, nil
    elseif not err then
      err = temp_err
    end
  end
  if not text then
    return nil, err
  end
  return M.parse_persisted(text), nil
end

---@param path string
---@param text string
---@return boolean, string|nil
local function write_file(path, text)
  local ok, file, open_err = pcall(io.open, path, "w")
  if not ok or not file then
    return false, tostring(file or open_err)
  end
  local write_ok, write_result, write_err = pcall(file.write, file, text)
  if not write_ok or not write_result then
    pcall(file.close, file)
    return false, tostring(write_ok and (write_err or "write failed") or write_result)
  end
  local flush_ok, flush_result, flush_err = pcall(file.flush, file)
  local close_ok, close_result, close_err = pcall(file.close, file)
  if not flush_ok or not flush_result then
    return false, tostring(flush_ok and (flush_err or "flush failed") or flush_result)
  end
  if not close_ok then
    return false, tostring(close_result)
  end
  if close_result == nil and close_err then
    return false, tostring(close_err)
  end
  return true, nil
end

---@param path string
---@param state table
---@return boolean, string|nil
function M.save_persisted(path, state)
  local text = M.serialize_state(state)
  if type(os.rename) ~= "function" then
    return write_file(path, text)
  end

  local temp = path .. ".tmp"
  local written, write_err = write_file(temp, text)
  if not written then
    local direct_ok, direct_err = write_file(path, text)
    os.remove(temp)
    if direct_ok then
      return true, nil
    end
    return false, tostring(write_err) .. "; " .. tostring(direct_err)
  end
  local called, renamed, rename_err = pcall(os.rename, temp, path)
  if called and renamed then
    return true, nil
  end
  local direct_ok, direct_err = write_file(path, text)
  if direct_ok then
    os.remove(temp)
    return true, nil
  end
  return false, tostring(called and rename_err or renamed) .. "; " .. tostring(direct_err)
end

---@param cfg table
---@param topic string
---@param payload string|nil
---@return table|nil
function M.parse_command(cfg, topic, payload)
  payload = (payload or ""):gsub("%s+$", "")
  local clean_topic = (topic or ""):gsub("%s+$", "")
  if clean_topic == cfg.lamp_command_topic then
    if payload == "ON" then
      return { name = "lamp", value = true }
    elseif payload == "OFF" then
      return { name = "lamp", value = false }
    end
  elseif clean_topic == cfg.restart_command_topic then
    local mode = M.normalize_restart_mode(payload)
    if mode then
      return { name = "restart_mode", value = mode }
    end
  end
  return nil
end

---@param state table
---@param command table
---@return string|nil, boolean|string|nil
function M.apply_command(state, command)
  if command.name == "lamp" then
    state.lamp = command.value
    return "lamp", state.lamp
  elseif command.name == "restart_mode" then
    state.restart_mode = M.normalize_restart_mode(command.value) or state.restart_mode
    return "restart_mode", state.restart_mode
  end
  return nil, nil
end

---@param client table
---@param cfg table
---@param online boolean
---@return number|boolean|nil, string|nil
function M.publish_availability(client, cfg, online)
  return client:publish({
    topic = cfg.availability_topic,
    payload = online and "online" or "offline",
    qos = 1,
    retain = true,
  })
end

---@param client table
---@param cfg table
---@param state table
---@return number|boolean|nil, string|nil
function M.publish_state(client, cfg, state)
  return client:publish({
    topic = cfg.lamp_state_topic,
    payload = state.lamp and "ON" or "OFF",
    qos = 1,
    retain = true,
  })
end

---@param client table
---@param cfg table
---@param state table
---@return number|boolean|nil, string|nil
function M.publish_restart_state(client, cfg, state)
  return client:publish({
    topic = cfg.restart_state_topic,
    payload = M.normalize_restart_mode(state.restart_mode) or M.CONFIG.restart_mode,
    qos = 1,
    retain = true,
  })
end

---@param client table
---@param cfg table
---@param online boolean
---@return number|boolean|nil, string|nil
function M.publish_link_state(client, cfg, online)
  return client:publish({
    topic = cfg.link_state_topic,
    payload = online and "ONLINE" or "OFFLINE",
    qos = 1,
    retain = true,
  })
end

---@param client table
---@param cfg table
---@param state table
---@param online boolean
---@return boolean|nil, string|nil
function M.publish_all_state(client, cfg, state, online)
  local ok, err = M.publish_state(client, cfg, state)
  if not ok then
    return false, err
  end
  ok, err = M.publish_restart_state(client, cfg, state)
  if not ok then
    return false, err
  end
  ok, err = M.publish_link_state(client, cfg, online)
  if not ok then
    return false, err
  end
  return true
end

---@param client table
---@param cfg table
---@return boolean|nil, string|nil
function M.publish_discovery(client, cfg)
  local stale = M.stale_discovery_topics(cfg)
  for _, topic in ipairs(M.stale_state_topics(cfg)) do
    stale[#stale + 1] = topic
  end
  for _, topic in ipairs(stale) do
    local ok, err = client:publish({ topic = topic, payload = "", qos = 1, retain = true })
    if not ok then
      return false, err
    end
  end

  local entries = {
    { component = "light", object_id = cfg.client_id .. "_lamp", payload = M.build_lamp_discovery(cfg) },
    { component = "binary_sensor", object_id = cfg.client_id .. "_link", payload = M.build_link_discovery(cfg) },
    {
      component = "select",
      object_id = cfg.client_id .. "_restart_mode",
      payload = M.build_restart_mode_discovery(cfg),
    },
  }
  for _, entry in ipairs(entries) do
    local topic = cfg.discovery_prefix .. "/" .. entry.component .. "/" .. entry.object_id .. "/config"
    local ok, err = client:publish({
      topic = topic,
      payload = M.json_encode(entry.payload),
      qos = 1,
      retain = true,
    })
    if not ok then
      return false, err
    end
  end
  return true
end

local THEME = {
  bg = 0x0B0F14,
  panel = 0x121A22,
  panel_hi = 0x1B2631,
  border = 0x33465A,
  header = 0x0E141A,
  footer = 0x0E141A,
  text = 0xC7D6E5,
  muted = 0x6C8299,
  amber = 0xFFB000,
  green = 0x35D07F,
  red = 0xFF4D4D,
  cyan = 0x35C7D6,
  steel = 0x8FA3B8,
  black = 0x000000,
  lamp_on = 0xFFD24A,
  lamp_hi = 0xFFF3B0,
  lamp_off = 0x2A3138,
  lamp_off_hi = 0x414B55,
  glow_on = 0x7A5200,
  glow_off = 0x1C2026,
  socket = 0x6B7B8C,
}

M.THEME = THEME

local LAMP_SPRITE = {
  "...GGGGGG...",
  ".GGYYYYYYGG.",
  "GYYYHHHHYYYG",
  "GYYHHHHHHYYG",
  "GYYHHHHHHYYG",
  "GYYYHHHHYYYG",
  ".GGYYYYYYGG.",
  "...GGGGGG...",
  "....BBBB....",
}

local LAMP_MINI = {
  "..GGGG..",
  ".GYYYYG.",
  "GYHHHHYG",
  ".GYYYYG.",
  "..BBBB..",
}

local LOG_COLORS = {
  HA = THEME.cyan,
  OC = THEME.amber,
  SYS = THEME.muted,
  ERR = THEME.red,
}

local function clip(text, width)
  text = tostring(text or "")
  if width <= 0 then
    return ""
  end
  if #text <= width then
    return text
  end
  if width <= 3 then
    return text:sub(1, width)
  end
  return text:sub(1, width - 3) .. "..."
end

local function fmt_uptime(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local secs = seconds % 60
  return string.format("%02d:%02d:%02d", hours, minutes, secs)
end

local function timestamp()
  local ok, value = pcall(os.date, "%H:%M:%S")
  if ok and value then
    return value
  end
  return "--:--:--"
end

local function status_color(status)
  if status == "ONLINE" then
    return THEME.green
  elseif status == "RETRY" or status == "LINKING" then
    return THEME.amber
  elseif status == "FAULT" then
    return THEME.red
  end
  return THEME.muted
end

local function lamp_palette(on)
  if on then
    return { G = THEME.glow_on, Y = THEME.lamp_on, H = THEME.lamp_hi, B = THEME.socket }
  end
  return { G = THEME.glow_off, Y = THEME.lamp_off, H = THEME.lamp_off_hi, B = THEME.socket }
end

local function choose_sprite(interior_w, interior_h)
  if interior_h >= 9 and interior_w >= 12 then
    local scale = 1
    if interior_h >= 20 and interior_w >= 24 then
      scale = 2
    end
    if interior_h >= 29 and interior_w >= 36 then
      scale = 3
    end
    return LAMP_SPRITE, scale
  end
  if interior_h >= 5 and interior_w >= 8 then
    local scale = 1
    if interior_h >= 10 and interior_w >= 16 then
      scale = 2
    end
    return LAMP_MINI, scale
  end
  return nil, 1
end

local function draw_sprite(gpu, sprite, x, y, scale, palette)
  for row = 1, #sprite do
    local line = sprite[row]
    local col = 1
    while col <= #line do
      local key = line:sub(col, col)
      local color = palette[key]
      if color then
        local run = 1
        while col + run <= #line and line:sub(col + run, col + run) == key do
          run = run + 1
        end
        gpu.setBackground(color)
        gpu.fill(x + (col - 1) * scale, y + (row - 1) * scale, run * scale, scale, " ")
        col = col + run
      else
        col = col + 1
      end
    end
  end
end

local function log_line(entry)
  return string.format("%s %-3s %s", entry.time or "--:--:--", entry.source or "SYS", entry.text or "")
end

---@param deps table|nil
---@return table|nil, string|nil
function M.create_ui(deps)
  deps = deps or {}
  local term = deps.term or require("term")
  local event = deps.event or require("event")
  local keyboard = deps.keyboard or require("keyboard")
  local display = deps.display
  local gpu = display and display.get_gpu() or deps.gpu
  if not gpu then
    if term.isAvailable and not term.isAvailable() then
      return nil, "no screen"
    end
    gpu = term.gpu and term.gpu() or nil
  end
  if not gpu then
    return nil, "no gpu"
  end

  local width, height
  if display then
    width, height = display.get_dims()
  else
    width, height = gpu.getResolution()
  end

  local owner = coroutine.running()
  local process = deps.process
  local process_ok = process ~= nil
  if not process_ok then
    process_ok = pcall(function()
      process = require("process")
    end)
  end
  local function owner_alive()
    if not process_ok or not process or not process.list then
      return true
    end
    return process.list[owner] ~= nil
  end

  local ui = {
    display = display,
    gpu = gpu,
    term = term,
    w = width,
    h = height,
    node = deps.node or "",
    screen = display and display.get_screen_addr() or (term.screen and term.screen() or nil),
    on_toggle = deps.on_toggle or function() end,
    on_cycle_mode = deps.on_cycle_mode or function() end,
    on_rediscover = deps.on_rediscover or function() end,
    on_quit = deps.on_quit or function() end,
    hit_regions = {},
    active = true,
  }
  ui.minimal = not display or width < 50 or height < 18
  ui.old_bg, ui.old_bg_palette = gpu.getBackground()
  ui.old_fg, ui.old_fg_palette = gpu.getForeground()
  ui.old_blink = term.getCursorBlink and term.getCursorBlink() or nil
  if term.setCursorBlink then
    term.setCursorBlink(false)
  end

  local function text(x, y, value, fg, bg)
    gpu.setBackground(bg or THEME.bg)
    gpu.setForeground(fg or THEME.text)
    gpu.set(x, y, value)
  end

  local function led(x, y, color)
    gpu.setBackground(color)
    gpu.fill(x, y, 2, 1, " ")
  end

  local function panel(x, y, w, h, title)
    display.draw_box(x, y, w, h, THEME.border, THEME.panel, "double")
    if title and w > 6 then
      local caption = " " .. clip(title, w - 6) .. " "
      gpu.setBackground(THEME.panel)
      gpu.setForeground(THEME.amber)
      gpu.set(x + 2, y, caption)
    end
  end

  local function heavy_button(x, y, w, h, caption, fg, bg, border)
    display.draw_box(x, y, w, h, border, bg, "double")
    text(x + math.floor((w - #caption) / 2), y + math.floor(h / 2), caption, fg, bg)
  end

  local function add_hit(kind, x1, y1, x2, y2)
    ui.hit_regions[#ui.hit_regions + 1] = { kind = kind, x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
  end

  function ui:draw_lamp(x, y, w, h, view)
    local sprite, scale = choose_sprite(w - 2, h - 2)
    if not sprite then
      return
    end
    local inner_x, inner_y = x + 1, y + 1
    local inner_w, inner_h = w - 2, h - 2
    local sprite_w = #sprite[1] * scale
    local sprite_h = #sprite * scale
    local badge_h = inner_h >= sprite_h + 2 and 1 or 0
    local sx = inner_x + math.floor((inner_w - sprite_w) / 2)
    local sy = inner_y + math.floor((inner_h - sprite_h - badge_h) / 2)
    draw_sprite(gpu, sprite, sx, sy, scale, lamp_palette(view.lamp))
    if badge_h > 0 then
      local badge = view.lamp and "   ON   " or "  OFF  "
      local bx = inner_x + math.floor((inner_w - #badge) / 2)
      local by = inner_y + inner_h - 1
      gpu.setBackground(view.lamp and THEME.green or THEME.panel_hi)
      gpu.setForeground(view.lamp and THEME.black or THEME.text)
      gpu.set(bx, by, badge)
    end
    local segments = math.max(1, math.min(8, math.floor((h - 4) / 2)))
    for index = 1, segments do
      gpu.setBackground(view.lamp and THEME.green or THEME.panel_hi)
      gpu.fill(x + w - 4, y + 2 + (index - 1) * 2, 2, 1, " ")
    end
    gpu.setBackground(THEME.panel)
    gpu.setForeground(THEME.text)
  end

  function ui:draw_telemetry(x, y, w, h, view)
    local rows = {
      { "BROKER", view.broker or "--", THEME.text },
      { "STATUS", view.status or "--", status_color(view.status) },
      { "LAMP", view.lamp and "ON" or "OFF", view.lamp and THEME.green or THEME.muted },
      { "RESTART", view.restart_mode or "--", THEME.text },
      { "UPTIME", fmt_uptime(view.uptime), THEME.text },
      { "RX / TX", string.format("%d / %d", view.rx or 0, view.tx or 0), THEME.text },
      { "LAST", view.last or "--", THEME.text },
      { "ERROR", view.error or "--", view.error and THEME.red or THEME.muted },
      { "TOPIC", view.topic or "--", THEME.muted },
      { "KEEPALIVE", tostring(view.keepalive or "--") .. "s", THEME.text },
    }
    local visible = h - 2
    local value_x = x + math.min(14, math.max(10, math.floor(w * 0.34)))
    local value_w = w - (value_x - x) - 2
    for index = 1, math.min(visible, #rows) do
      local row = rows[index]
      text(x + 2, y + index, row[1], THEME.muted, THEME.panel)
      text(value_x, y + index, clip(row[2], value_w), row[3], THEME.panel)
    end
  end

  function ui:draw_log(x, y, w, h, view)
    local visible = h - 2
    local logs = view.logs or {}
    if #logs == 0 then
      text(x + 2, y + 1, "no events yet", THEME.muted, THEME.panel)
      return
    end
    local first = math.max(1, #logs - visible + 1)
    for index = 1, math.min(visible, #logs) do
      local entry = logs[first + index - 1]
      if entry then
        text(x + 2, y + index, clip(log_line(entry), w - 4), LOG_COLORS[entry.source] or THEME.muted, THEME.panel)
      end
    end
  end

  function ui:render_display(view)
    local w, h = self.w, self.h
    gpu.setBackground(THEME.bg)
    gpu.fill(1, 1, w, h, " ")
    display.draw_box(1, 1, w, h, THEME.border, THEME.bg, "double")

    local header_h = h >= 32 and 3 or 2
    gpu.setBackground(THEME.header)
    gpu.fill(2, 2, w - 2, header_h, " ")
    gpu.setForeground(THEME.amber)
    gpu.set(3, 2, "▓▓")
    text(6, 2, "GTNH", THEME.text, THEME.header)
    text(11, 2, "// INDUSTRIAL CONTROL", THEME.muted, THEME.header)

    local status_x = w - 18
    if status_x > 40 then
      text(status_x, 2, "LINK", THEME.muted, THEME.header)
      local link_color = THEME.amber
      if view.connected then
        link_color = THEME.green
      elseif view.status == "FAULT" then
        link_color = THEME.red
      end
      led(status_x + 5, 2, link_color)
      text(status_x + 8, 2, "ACT", THEME.muted, THEME.header)
      local active = view.last_activity and view.uptime and (view.uptime - view.last_activity) < 5
      led(status_x + 12, 2, active and THEME.green or THEME.steel)
    end

    text(3, 3, "NODE " .. tostring(self.node), THEME.text, THEME.header)
    local version = "v" .. tostring(M.CONFIG.version) .. "  //  MQTT 3.1.1"
    text(w - #version - 3, 3, version, THEME.muted, THEME.header)

    if header_h >= 3 then
      gpu.setBackground(THEME.header)
      gpu.setForeground(THEME.amber)
      gpu.set(2, 4, string.rep("▌ ", math.floor((w - 2) / 2)))
    end
    text(2, 2 + header_h, string.rep("─", w - 2), THEME.border, THEME.bg)

    local content_top = 2 + header_h + 1
    local content_bottom = h - 3
    local content_h = content_bottom - content_top + 1
    local content_w = w - 2
    local left_w = math.floor((content_w - 1) * 0.44)
    local right_w = content_w - 1 - left_w
    local right_x = 2 + left_w + 1

    local lamp_h = math.max(11, math.floor(content_h * 0.62))
    lamp_h = math.min(lamp_h, 26)
    if lamp_h > content_h - 5 then
      lamp_h = content_h - 5
    end
    local breaker_h = content_h - lamp_h - 1

    panel(2, content_top, left_w, lamp_h, "OUTPUT LAMP")
    self:draw_lamp(2, content_top, left_w, lamp_h, view)
    add_hit("toggle", 2, content_top, 2 + left_w - 1, content_top + lamp_h - 1)

    local breaker_y = content_top + lamp_h + 1
    panel(2, breaker_y, left_w, breaker_h, "BREAKER // " .. tostring(view.restart_mode or "--"):upper())
    local button_h = math.min(5, breaker_h - 3)
    if button_h < 1 then
      button_h = 1
    end
    if button_h % 2 == 0 then
      button_h = button_h - 1
    end
    if button_h < 1 then
      button_h = 1
    end
    local interior_h = breaker_h - 2
    local button_y = breaker_y + 1 + math.max(0, math.floor((interior_h - button_h) / 2))
    local button_w = left_w - 4
    local caption = view.lamp and "   ON   " or "   OFF  "
    local button_bg = view.lamp and THEME.green or THEME.panel_hi
    local button_fg = view.lamp and THEME.black or THEME.text
    heavy_button(
      4,
      button_y,
      button_w,
      button_h,
      caption,
      button_fg,
      button_bg,
      view.lamp and THEME.green or THEME.border
    )
    add_hit("toggle", 4, button_y, 4 + button_w - 1, button_y + button_h - 1)
    if breaker_h >= 6 then
      text(5, breaker_y + breaker_h - 2, "CLICK / SPACE", THEME.muted, THEME.panel)
    end

    local telemetry_h = math.min(14, math.max(10, math.floor(content_h * 0.55)))
    local log_h = content_h - telemetry_h - 1
    panel(right_x, content_top, right_w, telemetry_h, "TELEMETRY")
    self:draw_telemetry(right_x, content_top, right_w, telemetry_h, view)
    panel(right_x, content_top + telemetry_h + 1, right_w, log_h, "EVENT LOG")
    self:draw_log(right_x, content_top + telemetry_h + 1, right_w, log_h, view)

    gpu.setBackground(THEME.footer)
    gpu.fill(2, h - 1, w - 2, 1, " ")
    local hint = "[SPACE] TOGGLE   [M] MODE   [R] REDISCOVER   [Q/^C] QUIT"
    text(3, h - 1, hint, THEME.muted, THEME.footer)
    local footer_version = "GTNH // OC-MQTT  v" .. tostring(M.CONFIG.version)
    if #hint + #footer_version + 4 <= w - 2 then
      text(w - #footer_version - 2, h - 1, footer_version, THEME.muted, THEME.footer)
    end
    local mode_pos = hint:find("%[M%]")
    if mode_pos then
      add_hit("cycle_mode", 3 + mode_pos - 1, h - 1, 3 + mode_pos + 2, h - 1)
    end
    local rediscover_pos = hint:find("%[R%]")
    if rediscover_pos then
      add_hit("rediscover", 3 + rediscover_pos - 1, h - 1, 3 + rediscover_pos + 2, h - 1)
    end
    local quit_pos = hint:find("%[Q%]")
    if quit_pos then
      add_hit("quit", 3 + quit_pos - 1, h - 1, 3 + quit_pos + 2, h - 1)
    end
  end

  function ui:render_compact(view)
    local w, h = self.w, self.h
    gpu.setBackground(THEME.bg)
    gpu.fill(1, 1, w, h, " ")
    display.draw_box(1, 1, w, h, THEME.border, THEME.bg, "double")

    gpu.setBackground(THEME.header)
    gpu.fill(2, 2, w - 2, 2, " ")
    gpu.setForeground(THEME.amber)
    gpu.set(3, 2, "▓▓")
    text(6, 2, "GTNH", THEME.text, THEME.header)
    text(11, 2, "// INDUSTRIAL", THEME.muted, THEME.header)
    local status = string.format("LINK %s   LAMP %s", tostring(view.status), view.lamp and "ON" or "OFF")
    text(3, 3, clip(status, w - 4), view.connected and THEME.text or THEME.muted, THEME.header)
    text(2, 4, string.rep("─", w - 2), THEME.border, THEME.bg)

    local content_top = 5
    local content_h = (h - 3) - content_top + 1
    local lamp_h = math.max(7, math.floor(content_h * 0.55))
    local breaker_h = content_h - lamp_h - 1
    if breaker_h < 3 then
      lamp_h = math.max(7, content_h - 4)
      breaker_h = content_h - lamp_h - 1
    end

    panel(2, content_top, w - 2, lamp_h, "OUTPUT LAMP")
    self:draw_lamp(2, content_top, w - 2, lamp_h, view)
    add_hit("toggle", 2, content_top, w - 1, content_top + lamp_h - 1)

    if breaker_h >= 3 then
      local breaker_y = content_top + lamp_h + 1
      panel(2, breaker_y, w - 2, breaker_h, "BREAKER // " .. tostring(view.restart_mode or "--"):upper())
      local button_h = math.max(1, breaker_h - 2)
      if button_h % 2 == 0 then
        button_h = button_h - 1
      end
      if button_h < 1 then
        button_h = 1
      end
      local button_w = w - 6
      local caption = view.lamp and "   ON   " or "   OFF  "
      heavy_button(
        4,
        breaker_y + 1,
        button_w,
        button_h,
        caption,
        view.lamp and THEME.black or THEME.text,
        view.lamp and THEME.green or THEME.panel_hi,
        view.lamp and THEME.green or THEME.border
      )
      add_hit("toggle", 4, breaker_y + 1, 4 + button_w - 1, breaker_y + button_h)
    end

    gpu.setBackground(THEME.footer)
    gpu.fill(2, h - 1, w - 2, 1, " ")
    local hint = "[SPACE] TOGGLE  [M] MODE  [Q/^C] QUIT"
    text(3, h - 1, hint, THEME.muted, THEME.footer)
    local mode_pos = hint:find("%[M%]")
    if mode_pos then
      add_hit("cycle_mode", 3 + mode_pos - 1, h - 1, 3 + mode_pos + 2, h - 1)
    end
    local quit_pos = hint:find("%[Q%]")
    if quit_pos then
      add_hit("quit", 3 + quit_pos - 1, h - 1, 3 + quit_pos + 2, h - 1)
    end
  end

  function ui:render_minimal(view)
    local w, h = self.w, self.h
    gpu.setBackground(THEME.bg)
    gpu.fill(1, 1, w, h, " ")
    gpu.setForeground(THEME.amber)
    gpu.set(2, 2, clip("GTNH // INDUSTRIAL CONTROL", w - 3))
    text(2, 4, clip("LAMP  " .. (view.lamp and "ON" or "OFF"), w - 3), THEME.text)
    text(2, 5, clip("LINK  " .. tostring(view.status), w - 3), THEME.text)
    if h >= 9 then
      text(2, 6, clip("MODE  " .. tostring(view.restart_mode or "--"), w - 3), THEME.text)
    end
    if h >= 10 then
      text(2, 7, clip("UP    " .. fmt_uptime(view.uptime), w - 3), THEME.muted)
    end
    local label = view.lamp and "  TURN OFF  " or "  TURN ON  "
    local button_x = math.max(1, math.floor((w - #label) / 2) + 1)
    local button_y = math.min(math.max(1, h - 2), 8)
    gpu.setBackground(view.lamp and THEME.green or THEME.panel_hi)
    gpu.setForeground(view.lamp and THEME.black or THEME.text)
    gpu.set(button_x, button_y, label)
    self.button_x = button_x
    self.button_y = button_y
    self.button_w = #label
    if h >= button_y + 2 then
      local hint = "[SPACE] TOGGLE  [M] MODE  [Q/^C] QUIT"
      text(2, button_y + 2, clip(hint, w - 3), THEME.muted)
      if #hint <= w - 3 then
        local mode_pos = hint:find("%[M%]")
        if mode_pos then
          add_hit("cycle_mode", 2 + mode_pos - 1, button_y + 2, 2 + mode_pos + 1, button_y + 2)
        end
        local quit_pos = hint:find("%[Q%]")
        if quit_pos then
          add_hit("quit", 2 + quit_pos - 1, button_y + 2, 2 + quit_pos + 1, button_y + 2)
        end
      end
    end
  end

  function ui:render(view)
    view = view or {}
    self.hit_regions = {}
    if self.display then
      self.w, self.h = self.display.get_dims()
      self.display.set_active_buffer(self.display.get_back_buffer())
    else
      self.w, self.h = self.gpu.getResolution()
    end
    self.minimal = not self.display or self.w < 50 or self.h < 18
    if self.minimal then
      self:render_minimal(view)
    elseif self.w >= 70 and self.h >= 24 then
      self:render_display(view)
    else
      self:render_compact(view)
    end
    if self.display then
      self.display.flip()
    end
    return true
  end

  function ui:input_active()
    if not self.active or not owner_alive() then
      return false
    end
    if not self.display then
      return true
    end
    local ok, active = pcall(function()
      return self.gpu.getActiveBuffer()
    end)
    if not ok then
      return true
    end
    return active == self.display.get_back_buffer()
  end

  function ui:handle_touch(x, y)
    for index = #self.hit_regions, 1, -1 do
      local region = self.hit_regions[index]
      if x >= region.x1 and x <= region.x2 and y >= region.y1 and y <= region.y2 then
        if region.kind == "toggle" then
          self:on_toggle()
        elseif region.kind == "cycle_mode" then
          self:on_cycle_mode()
        elseif region.kind == "rediscover" then
          self:on_rediscover()
        elseif region.kind == "quit" then
          self:on_quit()
        end
        return true
      end
    end
    if self.minimal and self.button_x then
      if x >= self.button_x and x < self.button_x + self.button_w and y >= self.button_y and y <= self.button_y + 1 then
        self:on_toggle()
        return true
      end
    end
    return false
  end

  function ui:handle_key(code, char)
    if code == keyboard.keys.space or code == keyboard.keys.enter then
      self:on_toggle()
      return true
    end
    if code == keyboard.keys.c and keyboard.isControlDown and keyboard.isControlDown() then
      self:on_quit()
      return true
    end
    local key = M.key_char(char)
    if not key and type(code) == "number" then
      if code == keyboard.keys.m then
        key = "m"
      elseif code == keyboard.keys.r then
        key = "r"
      elseif code == keyboard.keys.q then
        key = "q"
      end
    end
    if key == "m" then
      self:on_cycle_mode()
      return true
    elseif key == "r" then
      self:on_rediscover()
      return true
    elseif key == "q" then
      self:on_quit()
      return true
    end
    return false
  end

  function ui:deactivate()
    self.active = false
    if self.unlisten then
      self.unlisten()
      self.unlisten = nil
    end
  end

  function ui:close()
    self:deactivate()
    if self.display then
      local current = self.display.get_gpu()
      self.display.free()
      current.setActiveBuffer(0)
      current.setBackground(self.old_bg, self.old_bg_palette)
      current.setForeground(self.old_fg, self.old_fg_palette)
      local w, h = self.display.get_dims()
      current.fill(1, 1, w, h, " ")
    else
      self.gpu.setBackground(self.old_bg, self.old_bg_palette)
      self.gpu.setForeground(self.old_fg, self.old_fg_palette)
      self.gpu.fill(1, 1, self.w, self.h, " ")
    end
    if self.old_blink ~= nil and self.term.setCursorBlink then
      self.term.setCursorBlink(self.old_blink)
    end
    if self.term.setCursor then
      self.term.setCursor(1, 1)
    end
  end

  local function on_touch(_, address, x, y)
    if not owner_alive() then
      if event.ignore then
        pcall(event.ignore, "touch", on_touch)
      end
      return
    end
    if not ui:input_active() then
      return
    end
    if ui.screen and address ~= ui.screen then
      return
    end
    pcall(ui.handle_touch, ui, x, y)
  end

  local function on_key_down(_, _, char, code)
    if not owner_alive() then
      if event.ignore then
        pcall(event.ignore, "key_down", on_key_down)
      end
      return
    end
    if not ui:input_active() then
      return
    end
    pcall(ui.handle_key, ui, code, char)
  end

  if deps.listen ~= false then
    event.listen("touch", on_touch)
    event.listen("key_down", on_key_down)
    ui.unlisten = function()
      if event.ignore then
        pcall(event.ignore, "touch", on_touch)
        pcall(event.ignore, "key_down", on_key_down)
      end
    end
  end

  return ui
end

---@param deps table|nil
---@return table
function M.create_connector(deps)
  deps = deps or {}
  local internet = deps.internet or require("internet")
  local buffer = deps.buffer or require("buffer")
  local sleep = deps.sleep or os.sleep
  local now = deps.now or require("computer").uptime
  local connect_timeout = deps.connect_timeout or 10
  local should_stop = deps.should_stop
  local connector = {}

  function connector.connect(conn)
    local stream, err = internet.socket(conn.host, conn.port)
    if not stream then
      return false, err or "internet.socket failed"
    end

    local deadline = now() + connect_timeout
    while true do
      if should_stop and should_stop() then
        stream:close()
        return false, "stopped"
      end
      local ok, connected = pcall(stream.socket.finishConnect)
      if not ok then
        stream:close()
        return false, tostring(connected)
      end
      if connected then
        break
      end
      if now() >= deadline then
        stream:close()
        return false, "TCP connect timeout"
      end
      sleep(0.05)
    end

    local sock = buffer.new("rwb", stream)
    sock:setvbuf("no")
    conn.sock = sock
    return true
  end

  function connector.shutdown(conn)
    if conn.sock then
      conn.sock:close()
      conn.sock = nil
    end
  end

  function connector.send(conn, data, index)
    local ok, err = conn.sock:write(data:sub(index))
    if not ok then
      return nil, tostring(err)
    end
    return #data
  end

  function connector.receive(conn, size)
    local ok, data, err = pcall(conn.sock.read, conn.sock, size)
    if not ok then
      local message = tostring(data)
      if message:match("timeout$") then
        return nil, "timeout"
      elseif message:match("wantread$") then
        return nil, "wantread"
      end
      return nil, message
    end
    if data == nil and err == nil then
      return nil, "closed"
    end
    return data, err
  end

  function connector.settimeout(conn, timeout)
    if conn.sock then
      conn.sock:setTimeout(timeout or math.huge)
    end
  end

  return connector
end

---@param internet table
---@param url string
---@param path string
---@return boolean, string|nil
function M.download(internet, url, path)
  local ok, handle = pcall(internet.request, url)
  if not ok then
    return false, tostring(handle)
  end

  local mt = getmetatable(handle)
  if mt and mt.__index and mt.__index.response then
    local ok_code, code = pcall(mt.__index.response)
    if ok_code and code and code ~= 200 then
      return false, "HTTP " .. tostring(code)
    end
  end

  local file, open_err = io.open(path, "w")
  if not file then
    return false, tostring(open_err)
  end
  local ok_write, write_err = pcall(function()
    for chunk in handle do
      file:write(chunk)
    end
  end)
  file:close()
  if not ok_write then
    os.remove(path)
    return false, tostring(write_err)
  end
  return true, nil
end

---@param cfg table
---@param deps table|nil
---@return table
function M.ensure_luamqtt(cfg, deps)
  deps = deps or {}
  local root = cfg.mqtt_dir:match("^(.*)/[^/]+$") or cfg.mqtt_dir
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

  local ok, mqtt = pcall(require, "mqtt")
  if ok then
    return mqtt
  end

  local internet = deps.internet or require("internet")
  local filesystem = deps.filesystem or require("filesystem")
  local directory = cfg.mqtt_dir
  if not filesystem.exists(directory) then
    local made, mkdir_err = filesystem.mkdir(directory)
    if not made and not filesystem.exists(directory) then
      error("cannot create " .. directory .. ": " .. tostring(mkdir_err))
    end
  end

  print("Installing luamqtt into " .. directory)
  for _, name in ipairs(M.MQTT_FILES) do
    local target = directory .. "/" .. name
    local present = filesystem.exists(target)
    local size = present and filesystem.size(target) or 0
    if not present or size == 0 then
      local downloaded, err = M.download(internet, M.MQTT_RAW .. name, target)
      if not downloaded then
        error("download failed for " .. name .. ": " .. tostring(err))
      end
      print("  " .. name)
    end
  end

  for key in pairs(package.loaded) do
    if key == "mqtt" or key:match("^mqtt%.") then
      package.loaded[key] = nil
    end
  end
  return require("mqtt")
end

---@param deps table|nil
---@return table|nil, string|nil
function M.ensure_display(deps)
  deps = deps or {}
  if deps.display then
    return deps.display
  end
  package.path = "/lib/?.lua;/lib/?/init.lua;./?.lua;./?/init.lua;" .. package.path
  local ok, factory = pcall(require, "mqtt_ha.display")
  if not ok or type(factory) ~= "function" then
    return nil, "display library not found; reinstall the mqtt_ha package"
  end
  local display = factory()
  display.setup()
  return display
end

---@return table
function M.ioloop_options()
  return { sleep_function = os.sleep, sleep = 0.05, timeout = 0.05 }
end

---@param deps table|nil
---@return nil
function M.main(deps)
  deps = deps or {}
  local computer = deps.computer or require("computer")
  local event = deps.event or require("event")
  local component = deps.component or require("component")

  local process_ok, process = pcall(require, "process")
  if process_ok and M.has_running_instance(process, coroutine.running()) then
    print("mqtt_ha is already running; refusing to start a second instance")
    print("Stop the existing instance with Q / Ctrl+C or reboot this computer.")
    pcall(computer.beep, 1000, 0.4)
    return
  end

  if not component.isAvailable("internet") then
    error("no internet card found; insert one and retry")
  end

  local cfg = M.make_config(computer)
  local stop_requested = false
  local rediscover_requested = false
  local auto_save = false
  local persist = function() end
  local owner_thread = coroutine.running()
  local function owner_alive()
    if not process_ok or not process or not process.list then
      return true
    end
    return process.list[owner_thread] ~= nil
  end
  local on_interrupted
  on_interrupted = function()
    if not owner_alive() then
      if event.ignore then
        pcall(event.ignore, "interrupted", on_interrupted)
      end
      return
    end
    stop_requested = true
    if auto_save then
      pcall(persist)
    end
  end
  event.listen("interrupted", on_interrupted)

  local mqtt = M.ensure_luamqtt(cfg, deps)

  local display = nil
  local display_ok, display_result, display_err = pcall(M.ensure_display, deps)
  if display_ok then
    display = display_result
  end
  if not display then
    print("Display unavailable: " .. tostring(display_ok and display_err or display_result))
  end

  local saved, load_err
  for attempt = 1, 3 do
    saved, load_err = M.load_persisted(cfg.state_file)
    if not load_err then
      break
    end
    if attempt < 3 then
      os.sleep(0.2)
    end
  end
  auto_save = not load_err
  local state = M.boot_state(saved)
  local save_ok, save_err = true, nil
  if not load_err then
    save_ok, save_err = M.save_persisted(cfg.state_file, state)
  end
  local boot_warnings = {}
  if load_err then
    boot_warnings[#boot_warnings + 1] = "state load failed: " .. tostring(load_err)
  end
  if not save_ok then
    boot_warnings[#boot_warnings + 1] = "state save failed: " .. tostring(save_err)
  end

  local connected = false
  local status = "LINKING"
  local last_error = nil
  local last_event = "--"
  local last_activity = computer.uptime()
  local logs = {}
  local rx_count = 0
  local tx_count = 0
  local ui = nil
  local ui_dirty = true
  local publish_dirty = false
  local last_draw = 0

  local function add_log(source, text)
    logs[#logs + 1] = { time = timestamp(), source = source, text = text }
    if #logs > 32 then
      table.remove(logs, 1)
    end
    ui_dirty = true
  end

  add_log("SYS", "restart mode " .. state.restart_mode)
  add_log("SYS", "boot lamp " .. (state.lamp and "on" or "off"))
  if saved and saved.has_lamp and saved.lamp ~= state.lamp then
    add_log("SYS", "restart mode forced lamp " .. (state.lamp and "on" or "off"))
  end
  for _, warning in ipairs(boot_warnings) do
    add_log("ERR", warning)
  end

  persist = function()
    local ok, err = M.save_persisted(cfg.state_file, state)
    if ok then
      auto_save = true
    else
      last_error = "state save failed: " .. tostring(err)
      add_log("ERR", "state save failed")
    end
    return ok, err
  end

  local function notify(message)
    if not ui then
      print(message)
    end
  end

  local function current_view()
    return {
      lamp = state.lamp,
      restart_mode = state.restart_mode,
      connected = connected,
      status = status,
      error = last_error,
      uptime = computer.uptime(),
      last_activity = last_activity,
      rx = rx_count,
      tx = tx_count,
      last = last_event,
      logs = logs,
      broker = cfg.broker .. ":" .. cfg.port,
      topic = cfg.base_topic,
      keepalive = cfg.keep_alive,
      version = M.CONFIG.version,
    }
  end

  local function toggle()
    state.lamp = not state.lamp
    persist()
    last_event = "OC -> " .. (state.lamp and "ON" or "OFF")
    add_log("OC", "lamp " .. (state.lamp and "on" or "off"))
    ui_dirty = true
    publish_dirty = true
  end

  local function cycle_restart_mode()
    state.restart_mode = M.next_restart_mode(state.restart_mode)
    persist()
    last_event = "OC -> RESTART " .. state.restart_mode
    add_log("OC", "restart mode " .. state.restart_mode)
    ui_dirty = true
    publish_dirty = true
  end

  local function rediscover()
    rediscover_requested = true
  end

  local function quit()
    stop_requested = true
  end

  local ui_ok, ui_result = pcall(M.create_ui, {
    display = display,
    node = cfg.client_id,
    on_toggle = toggle,
    on_cycle_mode = cycle_restart_mode,
    on_rediscover = rediscover,
    on_quit = quit,
    term = deps.term,
    gpu = deps.gpu,
    event = deps.event,
    keyboard = deps.keyboard,
  })
  if not ui_ok then
    print("UI unavailable: " .. tostring(ui_result))
    ui = nil
    if display then
      pcall(display.free)
    end
  elseif not ui_result then
    print("No screen/GPU found; running headless")
    ui = nil
  else
    ui = ui_result
    local drawn = pcall(ui.render, ui, current_view())
    if not drawn then
      pcall(ui.deactivate, ui)
      ui = nil
      if display then
        pcall(display.free)
      end
      stop_requested = true
      print("display lost; stopping")
    end
  end

  local connector_deps = {}
  for key, value in pairs(deps) do
    connector_deps[key] = value
  end
  connector_deps.should_stop = function()
    return stop_requested
  end
  local connector = M.create_connector(connector_deps)

  local client_args = {
    uri = cfg.broker .. ":" .. cfg.port,
    id = cfg.client_id,
    clean = true,
    version = mqtt.v311,
    keep_alive = cfg.keep_alive,
    reconnect = cfg.reconnect,
    will = {
      topic = cfg.availability_topic,
      payload = "offline",
      qos = 1,
      retain = true,
    },
    connector = connector,
  }
  if cfg.username ~= "" then
    client_args.username = cfg.username
    client_args.password = cfg.password
  end

  local client = mqtt.client(client_args)
  client:on({
    connect = function(connack)
      if connack.rc ~= 0 then
        connected = false
        status = "FAULT"
        last_error = "CONNACK " .. tostring(connack.rc) .. ": " .. tostring(connack:reason_string())
        add_log("ERR", "connect refused")
        notify(last_error)
        return
      end
      connected = true
      status = "ONLINE"
      last_error = nil
      last_activity = computer.uptime()
      publish_dirty = false
      add_log("SYS", "link online")

      local subscribed, subscribe_err = client:subscribe({ topic = cfg.base_topic .. "/+/set", qos = 1 })
      if not subscribed then
        add_log("ERR", "subscribe failed")
        last_error = tostring(subscribe_err)
      end

      local ok, err = M.publish_availability(client, cfg, true)
      if ok then
        tx_count = tx_count + 1
      else
        last_error = tostring(err)
      end
      ok, err = M.publish_discovery(client, cfg)
      if ok then
        tx_count = tx_count + 1
        add_log("SYS", "discovery published")
      else
        last_error = tostring(err)
        add_log("ERR", "discovery failed")
      end
      ok, err = M.publish_all_state(client, cfg, state, true)
      if ok then
        tx_count = tx_count + 3
      else
        last_error = tostring(err)
        add_log("ERR", "state publish failed")
      end
      notify("MQTT connected: " .. cfg.broker .. ":" .. cfg.port)
      ui_dirty = true
    end,
    message = function(msg)
      client:acknowledge(msg)
      rx_count = rx_count + 1
      last_activity = computer.uptime()
      if msg.retain then
        add_log("SYS", "ignored retained command")
        ui_dirty = true
        return
      end
      local command = M.parse_command(cfg, msg.topic, msg.payload)
      if not command then
        add_log("ERR", "unexpected topic")
        ui_dirty = true
        return
      end
      local which, value = M.apply_command(state, command)
      if which then
        persist()
        if which == "lamp" then
          last_event = "HA -> " .. (value and "ON" or "OFF")
          add_log("HA", "lamp " .. (value and "on" or "off"))
          local ok, err = M.publish_state(client, cfg, state)
          if ok then
            tx_count = tx_count + 1
          else
            last_error = tostring(err)
            status = "FAULT"
            publish_dirty = true
            add_log("ERR", "state publish failed")
          end
          notify(string.format("%s -> %s", which, value and "ON" or "OFF"))
        else
          last_event = "HA -> RESTART " .. tostring(value)
          add_log("HA", "restart mode " .. tostring(value))
          local ok, err = M.publish_restart_state(client, cfg, state)
          if ok then
            tx_count = tx_count + 1
          else
            last_error = tostring(err)
            status = "FAULT"
            publish_dirty = true
            add_log("ERR", "state publish failed")
          end
          notify(string.format("%s -> %s", which, tostring(value)))
        end
        ui_dirty = true
      end
    end,
    error = function(err)
      last_error = tostring(err)
      status = "FAULT"
      add_log("ERR", "mqtt error")
      notify("MQTT error: " .. tostring(err))
      ui_dirty = true
    end,
    close = function(conn)
      connected = false
      if status ~= "FAULT" then
        status = "RETRY"
      end
      local reason = conn and conn.close_reason and tostring(conn.close_reason) or "closed"
      add_log("SYS", "link down: " .. reason)
      ui_dirty = true
    end,
  })

  local loop = mqtt.get_ioloop(true, M.ioloop_options())
  loop:add(client)

  local last_state = 0
  local tick
  tick = function()
    if stop_requested then
      if auto_save then
        persist()
      end
      if connected then
        pcall(M.publish_link_state, client, cfg, false)
        pcall(M.publish_availability, client, cfg, false)
        pcall(function()
          client:disconnect()
        end)
        connected = false
      end
      loop:remove(tick)
      loop:remove(client)
      return
    end

    if publish_dirty and connected then
      local lamp_ok, lamp_err = M.publish_state(client, cfg, state)
      if lamp_ok then
        tx_count = tx_count + 1
      end
      local mode_ok, mode_err = M.publish_restart_state(client, cfg, state)
      if mode_ok then
        tx_count = tx_count + 1
      end
      if lamp_ok and mode_ok then
        publish_dirty = false
        last_activity = computer.uptime()
      else
        last_error = tostring(lamp_ok and mode_err or lamp_err)
        status = "FAULT"
        add_log("ERR", "state publish failed")
      end
      ui_dirty = true
    end

    if rediscover_requested then
      rediscover_requested = false
      if connected then
        local ok, err = M.publish_discovery(client, cfg)
        if ok then
          tx_count = tx_count + 1
          add_log("SYS", "discovery republished")
        else
          last_error = tostring(err)
          add_log("ERR", "discovery failed")
        end
      end
      ui_dirty = true
    end

    local now = computer.uptime()
    if now - last_state >= cfg.state_interval then
      last_state = now
      if auto_save then
        persist()
      end
      if connected then
        local ok, err = M.publish_all_state(client, cfg, state, true)
        if ok then
          tx_count = tx_count + 3
        else
          last_error = tostring(err)
        end
        ui_dirty = true
      end
    end

    if ui and (ui_dirty or now - last_draw >= 1) then
      ui_dirty = false
      last_draw = now
      local drawn = pcall(ui.render, ui, current_view())
      if not drawn then
        pcall(ui.deactivate, ui)
        ui = nil
        if display then
          pcall(display.free)
        end
        stop_requested = true
        print("display lost; stopping")
      end
    end
  end
  loop:add(tick)

  if not ui then
    print("MQTT HA panel running headless; press Ctrl+C to stop")
  end
  loop:run_until_clients()
  if event.ignore then
    pcall(event.ignore, "interrupted", on_interrupted)
  end
  if ui then
    pcall(ui.close, ui)
  end
  print("MQTT HA panel stopped")
  os.exit(0)
end

if not MQTT_HA_NO_AUTORUN then
  M.main()
end

return M
