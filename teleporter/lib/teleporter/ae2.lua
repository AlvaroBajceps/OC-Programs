-- Spatial-cell stocking gate for the receiver side of a warp. The receiver
-- places a stocking request on its me_interface so the AE2 network routes the
-- spatial storage cell (ejected by the sender's spatial IO port trigger) into
-- this interface, which then feeds the receiver's spatial IO port. Stocking
-- requires me_interface + database components; power/readiness telemetry lives
-- in spatial_io.lua. clear_stock_item is also called on sender/bystander nodes
-- to defensively clear any stray stocking request during a warp.

local component = require("component")

return function(deps)
  local config = deps.config

  return {
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
