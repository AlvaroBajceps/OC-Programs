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
    -- The GTNH OC driver reports requiredEnergy divided by 10 and reports -1
    -- when the spatial setup is invalid. Apply a safety margin: the 12.5
    -- coefficient embeds the x10 correction (12.5 * raw == 1.25 * true) for a
    -- 25% buffer, plus a 1M AE floor. canTrigger stays the authoritative
    -- readiness gate; this value drives the displayed/forwarded "energy needed".
    local raw_req = type(info.requiredEnergy) == "number" and info.requiredEnergy or -1
    return {
      availableEnergy = type(info.availableEnergy) == "number" and info.availableEnergy or 0,
      maxEnergy = type(info.maxEnergy) == "number" and info.maxEnergy or 0,
      requiredEnergy = raw_req >= 0 and (1000000 + 12.5 * raw_req) or -1,
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
