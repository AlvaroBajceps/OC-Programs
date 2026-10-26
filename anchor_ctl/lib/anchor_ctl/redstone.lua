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

  local function find_proxy()
    if proxy ~= nil then
      return proxy
    end
    for _, address in ipairs(addresses()) do
      local p_ok, p = pcall(component.proxy, address)
      if p_ok and type(p) == "table" then
        proxy = p
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

  function M.available()
    return find_proxy() ~= nil
  end

  ---@param enabled boolean
  ---@return boolean, number|string|nil
  function M.set_enabled(enabled)
    local p = find_proxy()
    if not p then
      return false, "redstone card missing"
    end
    local level = M.level_for(enabled)
    local ok, err = pcall(p.setOutput, cfg.REDSTONE_SIDE, level)
    if not ok then
      proxy = nil
      return false, tostring(err)
    end
    return true, level
  end

  ---@return number|nil
  function M.get_level()
    local p = find_proxy()
    if not p then
      return nil
    end
    local ok, level = pcall(p.getOutput, cfg.REDSTONE_SIDE)
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
