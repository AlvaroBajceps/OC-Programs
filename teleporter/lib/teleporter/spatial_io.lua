-- Spatial IO port telemetry and trigger control. Each teleporter node has an
-- Adapter touching an AE2 Spatial IO Port, exposed as `component.spatial_io`.
-- getInformation() reports the port's own energy buffer, the ready gate
-- (canTrigger), setup validity (efficiency/requiredEnergy == -1 = unhealthy),
-- and whether a spatial storage cell is loaded (hasInputCell).
--
-- The driver's canTrigger folds in a live energy test (a simulated
-- extractAEPower of the spatial cost), but it only becomes true once a spatial
-- cell sits in the port's input slot -- never the case on the receiver before
-- the sender fires. Readiness is therefore also gated on an explicit energy
-- comparison (is_energy_ok: availableEnergy >= requiredEnergy), the only energy
-- signal the receiver can evaluate during the countdown.
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
    -- The driver reports the nominal spatial cost, but GTNH's PowerRatios
    -- UsageMultiplier (=10) scales the energy actually drawn, so the true cost
    -- is 10x the reported value. requiredEnergy = 1M + 12.5 * raw embeds that
    -- x10 correction (12.5 * raw == 1.25 * true) for a 25% buffer, plus a 1M AE
    -- floor; -1 is preserved for invalid setups. The result is the threshold
    -- is_energy_ok compares against and the value shown in the UI.
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

  -- The port's grid must hold the energy the transition will draw. Comparing
  -- the raw availableEnergy against the (already x10-corrected, 25%-buffered)
  -- requiredEnergy keeps the readiness gate consistent with the numbers shown
  -- in the UI. A missing/invalid port reports requiredEnergy = -1, so it can
  -- never pass.
  local function is_energy_ok(info)
    return info.requiredEnergy >= 0 and info.availableEnergy >= info.requiredEnergy
  end

  return {
    get_info = get_info,
    is_energy_ok = is_energy_ok,
    can_trigger = function()
      local info = get_info()
      return info.canTrigger and info.efficiency ~= -1 and is_energy_ok(info)
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
