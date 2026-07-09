-- AE2 stored-power telemetry with a mock fallback, plus ink-sac stocking
-- gate for receiver-side warp validation.
-- me_controller and me_interface both inherit getStoredPower/getMaxStoredPower
-- from CommonNetworkAPI; stocking requires me_interface + database components.

local component = require("component")

return function(deps)
  local config = deps.config

  local function find_ae2_component()
    if component.isAvailable("me_controller") then
      return component.me_controller
    end
    if component.isAvailable("me_interface") then
      return component.me_interface
    end
    return nil
  end

  return {
    get_power = function()
      local proxy = find_ae2_component()
      if proxy then
        local ok, val = pcall(function()
          return proxy.getStoredPower()
        end)
        if ok and type(val) == "number" then
          return val
        end
      end
      return 2000000
    end,

    request_ink_sac = function()
      if not component.isAvailable("me_interface") or not component.isAvailable("database") then
        return false
      end
      local ok, res = pcall(function()
        return component.me_interface.setInterfaceConfiguration(
          config.STOCK_SLOT,
          component.database.address,
          config.STOCK_DB_INDEX,
          1
        )
      end)
      return ok and res == true
    end,

    verify_ink_sac = function()
      if not component.isAvailable("me_interface") then
        return false
      end
      local ok, res = pcall(function()
        return component.me_interface.getInterfaceConfiguration(config.STOCK_SLOT)
      end)
      if not ok or type(res) ~= "table" then
        return false
      end
      return res ~= nil
    end,

    clear_ink_sac = function()
      if not component.isAvailable("me_interface") then
        return
      end
      pcall(function()
        component.me_interface.setInterfaceConfiguration(config.STOCK_SLOT)
      end)
    end,
  }
end
