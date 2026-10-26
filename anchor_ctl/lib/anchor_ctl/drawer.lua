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
      count = 0,
      capacity = 0,
      item_count = 0,
      item_name = nil,
      pearls = 0,
      is_pearls = true,
      percent = 0,
      slots = 0,
      address = nil,
      ambiguous = false,
      error = nil,
    }

    local ok, found, list_err = pcall(list, "drawer")
    if not ok or type(found) ~= "table" then
      info.error = ok and tostring(list_err) or tostring(found)
      return info
    end
    info.count = #found

    local selected
    if cfg.DRAWER_ADDRESS then
      for _, address in ipairs(found) do
        if address == cfg.DRAWER_ADDRESS then
          selected = address
        end
      end
      if not selected then
        info.error = "configured drawer not found"
        return info
      end
    elseif #found == 0 then
      return info
    elseif #found == 1 then
      selected = found[1]
    else
      info.ambiguous = true
      info.error = "multiple drawers found: " .. tostring(#found)
      return info
    end

    info.address = selected
    local proxy_ok, proxy = pcall(component.proxy, selected)
    if not proxy_ok or type(proxy) ~= "table" then
      info.error = "drawer proxy failed"
      return info
    end

    local count_ok, drawer_count = pcall(proxy.getDrawerCount)
    if not count_ok or type(drawer_count) ~= "number" or drawer_count < 1 then
      info.error = "drawer count unavailable"
      return info
    end
    info.count = drawer_count

    local slot_list = {}
    if drawer_count > 1 then
      for slot = 1, drawer_count do
        slot_list[#slot_list + 1] = slot
      end
    else
      local slot = cfg.DRAWER_SLOT or 1
      if slot < 1 or slot > drawer_count then
        info.error = "drawer slot out of range"
        info.slots = 0
        return info
      end
      slot_list[1] = slot
    end

    local total = 0
    local capacity = 0
    local item_name = nil
    local is_pearls = true
    local read_error = nil

    for _, slot in ipairs(slot_list) do
      local c_ok, c = pcall(proxy.getItemCount, slot)
      local cap_ok, cap = pcall(proxy.getMaxCapacity, slot)
      local n_ok, name = pcall(proxy.getItemName, slot)
      if not c_ok or not cap_ok then
        read_error = "drawer slot read failed"
      else
        local count = type(c) == "number" and c or 0
        local slot_cap = type(cap) == "number" and cap or 0
        total = total + count
        capacity = capacity + slot_cap
        if n_ok and name ~= nil and name ~= "" then
          if item_name == nil then
            item_name = tostring(name)
          end
          if not cfg.PEARL_ITEM_NAMES[tostring(name)] then
            is_pearls = false
          end
        end
      end
    end

    info.slots = #slot_list
    info.item_count = total
    info.capacity = capacity
    info.item_name = item_name
    info.is_pearls = is_pearls
    info.pearls = is_pearls and total or 0
    if capacity > 0 then
      info.percent = math.floor(total / capacity * 1000 + 0.5) / 10
    end
    info.error = read_error
    info.present = true
    return info
  end

  return M
end

return build
