-- Wraps a single gt_machine (DEHP) component. All component calls are pcall'd.
-- Provides telemetry refresh, state snapshot, and work-allowed toggling.
--
-- Factory: return function(deps) where deps = {address, index}
-- Returns a pump wrapper table.

local component = require("component")

return function(deps)
  local address = deps.address
  local index = deps.index
  local low_eu_pct = deps.low_eu_pct or 0.20

  local proxy = component.proxy(address)

  local state = {
    index = index,
    address = address,
    online = true,
    name = "?",
    work_allowed = false,
    machine_active = false,
    needs_maintenance = false,
    maintenance_reason = nil,
    stored_eu = nil,
    eu_capacity = nil,
    progress = nil,
    max_progress = nil,
    on_since = nil,
    sensor_lines = {},
    low_energy = false,
  }

  -- Strip Minecraft § color codes (UTF-8 2-byte sequence "\194\167" + letter).
  -- After stripping, check if the remaining text indicates maintenance needed.
  local function _parse_maintenance(lines)
    for i = 1, #lines do
      local cleaned = lines[i]:gsub("\194\167%w?", "")
      if cleaned:find("Maintenance") then
        local lower = cleaned:lower()
        -- "Working fine", "perfect", "No problem" → no maintenance.
        if lower:find("working") or lower:find("perfectly") or lower:find("no problem") then
          return false, nil
        end
        -- Tool names or problem keywords → maintenance needed.
        if
          lower:find("has")
          or lower:find("problem")
          or lower:find("issue")
          or lower:find("wrench")
          or lower:find("screwdriver")
          or lower:find("mallet")
          or lower:find("hammer")
          or lower:find("solder")
          or lower:find("crowbar")
        then
          local colon = cleaned:find(": ")
          local reason = colon and cleaned:sub(colon + 2) or cleaned
          return true, reason
        end
      end
    end
    return false, nil
  end

  local function _strip_codes(s)
    return s:gsub("\194\167%w?", "")
  end

  local function _parse_eu_from_sensor(lines)
    for i = 1, #lines do
      local cleaned = _strip_codes(lines[i] or "")
      local stored_str, cap_str = cleaned:match("Stored Energy:%s*(%d[%d,]*)%s*EU%s*/%s*(%d[%d,]*)%s*EU")
      if stored_str then
        return tonumber(stored_str:gsub(",", "")), tonumber(cap_str:gsub(",", ""))
      end
    end
    return nil, nil
  end

  local function _parse_progress_from_sensor(lines)
    for i = 1, #lines do
      local cleaned = _strip_codes(lines[i] or "")
      local prog_str, max_str = cleaned:match("Progress:%s*(%d[%d,]*)%s*s%s*/%s*(%d[%d,]*)%s*s")
      if prog_str then
        return tonumber(prog_str:gsub(",", "")), tonumber(max_str:gsub(",", ""))
      end
    end
    return nil, nil
  end

  local function refresh()
    local pcall_result

    -- Sensor information.
    pcall_result = { pcall(proxy.getSensorInformation, proxy) }
    if not pcall_result[1] then
      state.online = false
      return
    end
    state.sensor_lines = pcall_result[2] or {}

    -- Maintenance (must run before any offline-flagging of subsequent reads).
    local maint, reason = _parse_maintenance(state.sensor_lines)
    state.needs_maintenance = maint
    state.maintenance_reason = reason

    -- Work allowed.
    pcall_result = { pcall(proxy.isWorkAllowed, proxy) }
    state.work_allowed = pcall_result[1] and pcall_result[2] or false

    -- Machine active.
    pcall_result = { pcall(proxy.isMachineActive, proxy) }
    state.machine_active = pcall_result[1] and pcall_result[2] or false

    -- Name.
    pcall_result = { pcall(proxy.getName, proxy) }
    state.name = (pcall_result[1] and pcall_result[2]) or "?"

    -- Stored EU / EU capacity parsed from sensor lines (direct API methods
    -- return 0 on this machine controller — only getSensorInformation works).
    state.stored_eu, state.eu_capacity = _parse_eu_from_sensor(state.sensor_lines)

    if state.stored_eu and state.eu_capacity and state.eu_capacity > 0 then
      state.low_energy = state.stored_eu / state.eu_capacity < low_eu_pct
    else
      state.low_energy = false
    end

    state.progress, state.max_progress = _parse_progress_from_sensor(state.sensor_lines)

    state.online = true
  end

  local function get_state()
    return {
      index = state.index,
      address = state.address,
      name = state.name,
      online = state.online,
      work_allowed = state.work_allowed,
      machine_active = state.machine_active,
      needs_maintenance = state.needs_maintenance,
      maintenance_reason = state.maintenance_reason,
      stored_eu = state.stored_eu,
      eu_capacity = state.eu_capacity,
      progress = state.progress,
      max_progress = state.max_progress,
      on_since = state.on_since,
      sensor_lines = state.sensor_lines,
      low_energy = state.low_energy,
    }
  end

  local function set_work_allowed(enabled, current_uptime)
    local ok = pcall(proxy.setWorkAllowed, proxy, enabled) -- luacheck: ignore 122
    if ok then
      state.work_allowed = enabled
      if enabled then
        state.on_since = current_uptime
      else
        state.on_since = nil
      end
    end
    return ok
  end

  -- Returns seconds since this pump was last enabled, or 0 if off.
  -- uptime_fn should be a zero-arg function returning the current uptime
  -- (e.g. computer.uptime), injected so machine.lua stays decoupled.
  local function uptime_on(uptime_fn)
    if not state.on_since then
      return 0
    end
    return uptime_fn() - state.on_since
  end

  refresh()

  return {
    refresh = refresh,
    get_state = get_state,
    set_work_allowed = set_work_allowed,
    uptime_on = uptime_on,
  }
end
