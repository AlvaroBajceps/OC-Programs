-- Wraps a single gt_machine (DEHP) component. All component calls are pcall'd.
-- Provides telemetry refresh, state snapshot, and work-allowed toggling.
--
-- Factory: return function(deps) where deps = {address, index}
-- Returns a pump wrapper table.

local component = require("component")

return function(deps)
  local address = deps.address
  local index = deps.index

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

    -- Stored EU / EU capacity. Fall through the two naming conventions.
    pcall_result = { pcall(proxy.getStoredEU, proxy) }
    if not pcall_result[1] or type(pcall_result[2]) ~= "number" then
      pcall_result = { pcall(proxy.getEUStored, proxy) }
    end
    state.stored_eu = (pcall_result[1] and type(pcall_result[2]) == "number") and pcall_result[2] or nil

    pcall_result = { pcall(proxy.getEUCapacity, proxy) }
    if not pcall_result[1] or type(pcall_result[2]) ~= "number" then
      pcall_result = { pcall(proxy.getEUMaxStored, proxy) }
    end
    state.eu_capacity = (pcall_result[1] and type(pcall_result[2]) == "number") and pcall_result[2] or nil

    -- Work progress.
    pcall_result = { pcall(proxy.getWorkProgress, proxy) }
    state.progress = (pcall_result[1] and type(pcall_result[2]) == "number") and pcall_result[2] or nil

    pcall_result = { pcall(proxy.getWorkMaxProgress, proxy) }
    state.max_progress = (pcall_result[1] and type(pcall_result[2]) == "number") and pcall_result[2] or nil

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
