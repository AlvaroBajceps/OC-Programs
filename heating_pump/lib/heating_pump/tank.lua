-- Wraps a single transposer adapter reading a fluid tank. Auto-probes sides
-- 0..5 to find the tank side. All component calls are pcall'd.
--
-- Factory: return function(deps) where deps = {address}
-- Returns a tank wrapper table.

local component = require("component")
local sides = require("sides")

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

  local SIDE_ORDER = { sides.down, sides.up, sides.north, sides.south, sides.west, sides.east } -- luacheck: ignore 131

  -- Auto-probe: find the first side with at least one fluid tank.
  for _, side_val in ipairs(SIDE_ORDER) do
    local ok, count = pcall(proxy.getTankCount, proxy, side_val)
    if ok and type(count) == "number" and count >= 1 then
      state.side = side_val
      state.online = true
      break
    end
  end

  local function refresh()
    if not state.side then
      state.online = false
      return
    end

    -- Read fluid information.
    local ok, fluid = pcall(proxy.getFluidInTank, proxy, state.side, 1)
    if not ok or type(fluid) ~= "table" then
      -- Fallback: try getTankLevel for amount.
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

    -- Read capacity.
    local ok3, cap = pcall(proxy.getTankCapacity, proxy, state.side, 1)
    if not ok3 or type(cap) ~= "number" or cap <= 0 then
      -- Tank exists but capacity read failed — treat as online with nil capacity.
      -- The controller will be conservative (pct = 0 for cold tank).
      state.capacity = nil
    else
      state.capacity = cap
    end

    state.online = true
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
