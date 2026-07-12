-- Wraps a single tank component. Auto-detects whether the component is a
-- gt_machine (SuperTank, read via getSensorInformation) or a transposer
-- (read via getTankCount/getFluidInTank). All component calls are pcall'd.
--
-- Factory: return function(deps) where deps = {address}
-- Returns a tank wrapper table.

local component = require("component")
local sides = require("sides")

-- Strip Minecraft section-sign color codes (UTF-8 "\194\167" + format char).
local function _strip_codes(s)
  return s:gsub("\194\167%w?", "")
end

-- Parse a comma-separated numeric string ("3,798,144" -> 3798144).
local function _parse_num(s)
  if not s then
    return nil
  end
  return tonumber((s:gsub(",", "")))
end

return function(deps)
  local address = deps.address

  local proxy = component.proxy(address)

  local state = {
    address = address,
    side = nil,
    online = false,
    amount = nil,
    capacity = nil,
    name = nil,
    label = nil,
  }

  -- Detect component type: gt_machine exposes getSensorInformation, transposer exposes getTankCount.
  local is_gt_machine = pcall(proxy.getSensorInformation, proxy)

  local function _refresh_gt_machine()
    local ok, lines = pcall(proxy.getSensorInformation, proxy)
    if not ok or type(lines) ~= "table" then
      state.online = false
      state.amount = nil
      state.capacity = nil
      state.name = nil
      state.label = nil
      return
    end

    -- SuperTank sensor output (after color-strip):
    --   [1] "Super Tank"                 (machine name)
    --   [2] "Stored Fluid:"               (label)
    --   [3] "IC2 Coolant"                 (fluid name)
    --   [4] "3,798,144 L 4,000,000 L"     (amount + capacity)
    state.name = nil
    state.label = nil
    state.amount = nil
    state.capacity = nil

    for i = 1, #lines do
      local cleaned = _strip_codes(lines[i] or "")
      if cleaned:find("Stored Fluid:") then
        if lines[i + 1] then
          local fluid_name = _strip_codes(lines[i + 1])
          fluid_name = fluid_name:gsub("^%s+", ""):gsub("%s+$", "")
          if #fluid_name > 0 then
            state.name = fluid_name
            state.label = fluid_name
          end
        end
        if lines[i + 2] then
          local amounts = _strip_codes(lines[i + 2])
          local amt_str, cap_str = amounts:match("(%d[%d,]*)%s*L%s*(%d[%d,]*)%s*L")
          state.amount = _parse_num(amt_str)
          state.capacity = _parse_num(cap_str)
        end
        break
      end
    end

    state.online = true
  end

  local function _refresh_transposer()
    if not state.side then
      state.online = false
      return
    end

    local ok, fluid = pcall(proxy.getFluidInTank, proxy, state.side, 1)
    if not ok or type(fluid) ~= "table" then
      local ok2, lvl = pcall(proxy.getTankLevel, proxy, state.side, 1)
      if ok2 and type(lvl) == "number" then
        state.amount = lvl
      else
        state.online = false
        state.amount = nil
        return
      end
      state.name = nil
      state.label = nil
    else
      state.amount = fluid.amount
      state.name = fluid.name
      state.label = fluid.label
    end

    local ok3, cap = pcall(proxy.getTankCapacity, proxy, state.side, 1)
    if not ok3 or type(cap) ~= "number" or cap <= 0 then
      state.capacity = nil
    else
      state.capacity = cap
    end

    state.online = true
  end

  if not is_gt_machine then
    local SIDE_ORDER = { sides.down, sides.up, sides.north, sides.south, sides.west, sides.east } -- luacheck: ignore 131
    for _, side_val in ipairs(SIDE_ORDER) do
      local ok, count = pcall(proxy.getTankCount, proxy, side_val)
      if ok and type(count) == "number" and count >= 1 then
        state.side = side_val
        state.online = true
        break
      end
    end
  end

  local function refresh()
    if is_gt_machine then
      _refresh_gt_machine()
    else
      _refresh_transposer()
    end
  end

  local function get_state()
    local pct = 0
    if state.capacity and state.capacity > 0 and state.amount then
      pct = state.amount / state.capacity
    elseif state.amount and state.amount > 0 then
      pct = 1.0
    end
    return {
      address = state.address,
      side = state.side,
      online = state.online,
      amount = state.amount,
      capacity = state.capacity,
      name = state.name,
      label = state.label,
      pct = pct,
    }
  end

  refresh()

  return {
    refresh = refresh,
    get_state = get_state,
  }
end
