---@param deps table|nil
---@return table
local function build(deps)
  deps = deps or {}
  local io = deps.io or io
  local os = deps.os or os

  local MODES = { on = true, off = true, keep_state = true }

  ---@param mode any
  ---@return string|nil
  local function normalize_mode(mode)
    if type(mode) ~= "string" then
      return nil
    end
    local trimmed = mode:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if MODES[trimmed] then
      return trimmed
    end
    return nil
  end

  ---@param mode string|nil
  ---@return string
  local function next_mode(mode)
    if mode == "off" then
      return "on"
    elseif mode == "on" then
      return "keep_state"
    end
    return "off"
  end

  ---@param text string|nil
  ---@return table|nil, string|nil
  local function parse(text)
    if type(text) ~= "string" then
      return nil, "invalid state"
    end
    local mode = nil
    for line in text:gmatch("[^\r\n]+") do
      local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if key == "boot_mode" then
        mode = normalize_mode(value)
      end
    end
    if not mode then
      return nil, "invalid state"
    end
    return { boot_mode = mode }, nil
  end

  ---@param state table
  ---@return string
  local function serialize(state)
    local mode = "keep_state"
    if type(state) == "table" then
      local normalized = normalize_mode(state.boot_mode)
      if normalized then
        mode = normalized
      end
    end
    return "boot_mode=" .. mode .. "\n"
  end

  ---@param path string
  ---@return table|nil, string|nil
  local function load(path)
    local ok, file, open_err = pcall(io.open, path, "r")
    if not ok or not file then
      local reason = tostring(file or open_err or "")
      if reason:match("[Nn]o such file") or reason:match("[Nn]ot found") then
        return nil, nil
      end
      return nil, reason ~= "" and reason or "read failed"
    end
    local read_ok, text = pcall(file.read, file, "*a")
    pcall(file.close, file)
    if not read_ok then
      return nil, tostring(text)
    end
    return parse(text)
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
  local function save(path, state)
    local text = serialize(state)
    if type(os.rename) ~= "function" then
      return write_file(path, text)
    end

    local temp = path .. ".tmp"
    local written, write_err = write_file(temp, text)
    if not written then
      local direct_ok, direct_err = write_file(path, text)
      pcall(os.remove, temp)
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
      pcall(os.remove, temp)
      return true, nil
    end
    return false, tostring(called and rename_err or renamed) .. "; " .. tostring(direct_err)
  end

  ---@param mode string|nil
  ---@param anchor_info table|nil
  ---@param cfg table
  ---@return table
  local function resolve_boot(mode, anchor_info, cfg)
    if mode == "on" then
      return { enabled = true, source = "mode" }
    elseif mode == "off" then
      return { enabled = false, source = "mode" }
    end
    if type(anchor_info) == "table" and anchor_info.known then
      return { enabled = not anchor_info.disabled, source = "anchor" }
    end
    return { enabled = cfg.KEEP_STATE_FALLBACK_ENABLED == true, source = "fallback" }
  end

  return {
    normalize_mode = normalize_mode,
    next_mode = next_mode,
    parse = parse,
    serialize = serialize,
    load = load,
    save = save,
    resolve_boot = resolve_boot,
  }
end

return build
