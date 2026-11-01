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

-- Parse a grouped numeric string ("3,798,144" or "3.798.144" -> 3798144).
local function _parse_num(s)
  if not s then
    return nil
  end
  return tonumber((s:gsub("[,%.]", "")))
end

local AMOUNT_UNITS = { L = true, mB = true, X = true }

-- Accept the 2.8 "L" unit and the 2.9 GTNHLib "mB"/"X" units.
local function _parse_amounts(text)
  local amt_str, amt_unit, cap_str, cap_unit = text:match("(%d[%d,.]*)%s*(%a+)%s*(%d[%d,.]*)%s*(%a+)")
  if not amt_str or not AMOUNT_UNITS[amt_unit] or not AMOUNT_UNITS[cap_unit] then
    return nil, nil
  end
  return _parse_num(amt_str), _parse_num(cap_str)
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
  local is_gt_machine = pcall(proxy.getSensorInformation)

  local function _refresh_gt_machine()
    local ok, lines = pcall(proxy.getSensorInformation)
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
      local is_legacy = cleaned:find("Stored Fluid:", 1, true) ~= nil
      local is_modern = cleaned == "GT5U.infodata.digital_tank.stored_fluid"
      if is_legacy or is_modern then
        if lines[i + 1] then
          local fluid_name = _strip_codes(lines[i + 1])
          fluid_name = fluid_name:gsub("^%s+", ""):gsub("%s+$", "")
          if
            #fluid_name > 0
            and fluid_name ~= "GT5U.infodata.digital_tank.stored_fluid.empty"
            and fluid_name:lower() ~= "no fluid"
          then
            state.name = fluid_name
            state.label = fluid_name
          end
        end
        for offset = 1, 3 do
          local line = lines[i + offset]
          if line then
            local amount, capacity = _parse_amounts(_strip_codes(line))
            if amount then
              state.amount = amount
              state.capacity = capacity
              break
            end
          end
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

    local ok, fluid = pcall(proxy.getFluidInTank, state.side, 1)
    if not ok or type(fluid) ~= "table" then
      local ok2, lvl = pcall(proxy.getTankLevel, state.side, 1)
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

    local ok3, cap = pcall(proxy.getTankCapacity, state.side, 1)
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
      local ok, count = pcall(proxy.getTankCount, side_val)
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
