-- AE2 stored-power telemetry with a mock fallback.
-- Reads the real me_controller.getStoredPower() when an Adapter touches a
-- controller; otherwise returns a conservative constant so the countdown
-- logic can still run end-to-end on a bench setup without AE2 connected.

local component = require("component")

return function()
  return {
    get_power = function()
      if component.isAvailable("me_controller") then
        local ok, val = pcall(function()
          return component.me_controller.getStoredPower()
        end)
        if ok and type(val) == "number" then
          return val
        end
      end
      return 2000000
    end,
  }
end
