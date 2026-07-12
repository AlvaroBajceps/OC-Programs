-- Spatial IO port telemetry and trigger control. Each teleporter node has an
-- Adapter touching an AE2 Spatial IO Port, exposed as `component.spatial_io`.
-- getInformation() reports the port's own energy buffer, the ready gate
-- (canTrigger), setup validity (efficiency/requiredEnergy == -1 = unhealthy),
-- and whether a spatial storage cell is loaded (hasInputCell).
--
-- Fail-safe: when the component is missing or calls error, get_info returns a
-- degenerate table (zero energy, canTrigger false, efficiency -1) so a missing
-- port can never satisfy a readiness gate.

local component = require("component")

return function()
  local INVALID = {
    availableEnergy = 0,
    maxEnergy = 0,
    requiredEnergy = -1,
    canTrigger = false,
    efficiency = -1,
    hasInputCell = false,
  }

  local function get_info()
    if not component.isAvailable("spatial_io") then
      return INVALID
    end
    local ok, info = pcall(function()
      return component.spatial_io.getInformation()
    end)
    if not ok or type(info) ~= "table" then
      return INVALID
    end
    return {
      availableEnergy = type(info.availableEnergy) == "number" and info.availableEnergy or 0,
      maxEnergy = type(info.maxEnergy) == "number" and info.maxEnergy or 0,
      -- requiredEnergy/efficiency read -1 when the spatial setup is invalid;
      -- the upstream driver also divides requiredEnergy by 10, so the read
      -- value is compared as-is (canTrigger is the authoritative gate).
      requiredEnergy = type(info.requiredEnergy) == "number" and info.requiredEnergy or -1,
      canTrigger = info.canTrigger == true,
      efficiency = type(info.efficiency) == "number" and info.efficiency or -1,
      hasInputCell = info.hasInputCell == true,
    }
  end

  return {
    get_info = get_info,
    can_trigger = function()
      local info = get_info()
      return info.canTrigger and info.efficiency ~= -1
    end,
    has_input_cell = function()
      return get_info().hasInputCell
    end,
    is_chamber_valid = function()
      if not component.isAvailable("spatial_io") then
        return false
      end
      return get_info().efficiency ~= -1
    end,
    has_component = function()
      return component.isAvailable("spatial_io")
    end,
    trigger = function()
      if not component.isAvailable("spatial_io") then
        return false
      end
      local ok = pcall(function()
        component.spatial_io.trigger()
      end)
      return ok
    end,
    get_energy = function()
      local info = get_info()
      return info.availableEnergy, info.maxEnergy, info.requiredEnergy
    end,
  }
end
