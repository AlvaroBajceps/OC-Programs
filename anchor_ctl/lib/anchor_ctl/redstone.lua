---@param component table
---@param cfg table
---@return table
local function build(component, cfg)
  local M = {}
  local proxy = nil

  local function addresses()
    local ok, listed = pcall(component.list, "redstone", true)
    if not ok then
      return {}
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
    end
    return found
  end

  local function slot_of(address)
    if type(component.slot) ~= "function" then
      return nil
    end
    local ok, slot = pcall(component.slot, address)
    if not ok then
      return nil
    end
    return tonumber(slot)
  end

  local function proxy_for(address)
    local ok, p = pcall(component.proxy, address)
    if ok and type(p) == "table" then
      return p
    end
    return nil
  end

  local function find_by_address(found, wanted)
    local exact = nil
    local prefix = nil
    local prefix_count = 0
    for _, address in ipairs(found) do
      if address == wanted then
        exact = address
      elseif address:sub(1, #wanted) == wanted then
        prefix = address
        prefix_count = prefix_count + 1
      end
    end
    if exact then
      return exact
    end
    if prefix_count == 1 then
      return prefix
    end
    return nil
  end

  local function find_proxy()
    if proxy ~= nil then
      return proxy
    end
    local found = addresses()

    if cfg.REDSTONE_ADDRESS ~= nil and cfg.REDSTONE_ADDRESS ~= "" then
      local selected = find_by_address(found, tostring(cfg.REDSTONE_ADDRESS))
      if selected then
        proxy = proxy_for(selected)
      end
      return proxy
    end

    -- Sides are absolute on an external Redstone I/O block, so prefer a
    -- component outside the case (slot -1) over the in-case card.
    for _, address in ipairs(found) do
      local slot = slot_of(address)
      if slot ~= nil and slot < 0 then
        proxy = proxy_for(address)
        if proxy then
          return proxy
        end
      end
    end

    for _, address in ipairs(found) do
      proxy = proxy_for(address)
      if proxy then
        return proxy
      end
    end

    local primary_ok, primary = pcall(function()
      return component.redstone
    end)
    if primary_ok and type(primary) == "table" then
      proxy = primary
      return proxy
    end
    return nil
  end

  local function configured_sides()
    local configured = cfg.REDSTONE_SIDES
    if type(configured) == "number" then
      return { configured }
    end
    if type(configured) ~= "table" then
      return { 0 }
    end
    local sides = {}
    for _, side in ipairs(configured) do
      if type(side) == "number" then
        sides[#sides + 1] = side
      end
    end
    if #sides == 0 then
      return { 0 }
    end
    return sides
  end

  function M.available()
    return find_proxy() ~= nil
  end

  ---@param enabled boolean
  ---@return boolean, number|string|nil
  function M.set_enabled(enabled)
    local p = find_proxy()
    if not p then
      return false, "redstone component missing"
    end
    local level = M.level_for(enabled)
    for _, side in ipairs(configured_sides()) do
      local ok, err = pcall(p.setOutput, side, level)
      if not ok then
        proxy = nil
        return false, tostring(err)
      end
    end
    return true, level
  end

  ---@return number|nil
  function M.get_level()
    local p = find_proxy()
    if not p then
      return nil
    end
    local ok, level = pcall(p.getOutput, configured_sides()[1])
    if ok and type(level) == "number" then
      return level
    end
    proxy = nil
    return nil
  end

  ---@param enabled boolean
  ---@return number
  function M.level_for(enabled)
    if enabled then
      return cfg.ENABLED_LEVEL
    end
    return cfg.DISABLED_LEVEL
  end

  return M
end

return build
