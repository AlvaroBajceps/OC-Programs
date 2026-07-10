-- AE2 stored-power telemetry, plus spatial-cell stocking gate for receiver-side
-- warp validation. When no me_controller/me_interface is reachable, power
-- reports 0 (fail-safe: missing telemetry must never satisfy the threshold).
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
      return 0
    end,

    request_stock_item = function()
      if not component.isAvailable("me_interface") or not component.isAvailable("database") then
        return false
      end
      -- setInterfaceConfiguration always returns true in the GTNH OC driver,
      -- even when the database slot is empty (it silently clears the interface
      -- slot). Pre-validate the database to avoid false success.
      local db_ok, db_item = pcall(function()
        return component.database.get(config.STOCK_DB_INDEX)
      end)
      if not db_ok or db_item == nil then
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

    verify_stock_item = function()
      if not component.isAvailable("me_interface") then
        return false
      end
      local ok, res = pcall(function()
        return component.me_interface.getInterfaceConfiguration(config.STOCK_SLOT)
      end)
      if not ok or type(res) ~= "table" then
        return false
      end
      return res.name ~= nil
    end,

    clear_stock_item = function()
      if not component.isAvailable("me_interface") then
        return
      end
      pcall(function()
        component.me_interface.setInterfaceConfiguration(config.STOCK_SLOT)
      end)
    end,
  }
end
