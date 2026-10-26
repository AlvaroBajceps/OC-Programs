---@param component table
---@param cfg table
---@return table
local function build(component, cfg)
  local M = {}

  local function list(kind)
    local ok, listed = pcall(component.list, kind, true)
    if not ok then
      return nil, tostring(listed)
    end
    local found = {}
    if type(listed) == "function" then
      while true do
        local address = listed()
        if not address then
          break
        end
        found[#found + 1] = tostring(address)
      end
    elseif type(listed) == "table" then
      for address in pairs(listed) do
        found[#found + 1] = tostring(address)
      end
    else
      return nil, "component list unavailable"
    end
    return found
  end

  ---@return table
  function M.read()
    local info = {
      present = false,
      known = false,
      disabled = nil,
      kind = nil,
      fuel_ticks = nil,
      fuel_count = 0,
      fuel_name = nil,
      address = nil,
      count = 0,
      ambiguous = false,
      error = nil,
    }

    local ok, found, list_err = pcall(list, "anchor")
    if not ok or type(found) ~= "table" then
      info.error = ok and tostring(list_err) or tostring(found)
      return info
    end
    info.count = #found

    local selected
    if cfg.ANCHOR_ADDRESS then
      for _, address in ipairs(found) do
        if address == cfg.ANCHOR_ADDRESS then
          selected = address
        end
      end
      if not selected then
        info.error = "configured anchor not found"
        return info
      end
    elseif #found == 0 then
      return info
    elseif #found == 1 then
      selected = found[1]
    else
      info.ambiguous = true
      info.error = "multiple anchors found: " .. tostring(#found)
      return info
    end

    info.address = selected
    local proxy_ok, proxy = pcall(component.proxy, selected)
    if not proxy_ok or type(proxy) ~= "table" then
      info.error = "anchor proxy failed"
      return info
    end

    local type_ok, kind = pcall(proxy.getType)
    if type_ok then
      info.kind = tostring(kind)
    end

    local disabled_ok, disabled = pcall(proxy.isDisabled)
    if disabled_ok then
      info.known = true
      info.disabled = disabled == true
    else
      info.error = "anchor probe failed"
    end

    local fuel_ok, fuel = pcall(proxy.getFuel)
    if fuel_ok and type(fuel) == "number" then
      info.fuel_ticks = fuel
    end

    local slot_ok, stack = pcall(proxy.getFuelSlotContents)
    if slot_ok and type(stack) == "table" then
      info.fuel_count = stack.size or 0
      info.fuel_name = stack.name
    end

    info.present = true
    return info
  end

  return M
end

return build
