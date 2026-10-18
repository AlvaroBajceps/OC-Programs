-- Chunk-loader readiness gate. Each teleporter node has an Adapter touching a
-- Railcraft World Anchor (the chunk loader), exposed as `component.anchor`.
-- An anchor is ready when it is type "world", holds >= 10 ender pearls in its
-- fuel slot, and is not redstone-disabled.
--
-- Fail-safe: when the component is missing or calls error, get_info returns a
-- degenerate table (present false) so a missing loader can never satisfy a
-- readiness gate, mirroring spatial_io.lua.

local component = require("component")

return function()
  local REQUIRED_TYPE = "world"
  local FUEL_ITEM = "minecraft:ender_pearl"
  local MIN_FUEL = 10

  local INVALID = {
    present = false,
    kind = "",
    fuel_name = nil,
    fuel_count = 0,
    disabled = true,
  }

  local function get_info()
    if not component.isAvailable("anchor") then
      return INVALID
    end
    local ok, kind, fuel, disabled = pcall(function()
      return component.anchor.getType(), component.anchor.getFuelSlotContents(), component.anchor.isDisabled()
    end)
    if not ok then
      return INVALID
    end
    local fuel_name = nil
    local fuel_count = 0
    if type(fuel) == "table" then
      fuel_name = fuel.name
      if type(fuel.size) == "number" then
        fuel_count = fuel.size
      end
    end
    return {
      present = true,
      kind = type(kind) == "string" and kind or "",
      fuel_name = type(fuel_name) == "string" and fuel_name or nil,
      fuel_count = fuel_count,
      disabled = disabled == true,
    }
  end

  local function is_ready(info)
    local i = info or get_info()
    return i.present
      and i.kind == REQUIRED_TYPE
      and i.fuel_name == FUEL_ITEM
      and i.fuel_count >= MIN_FUEL
      and not i.disabled
  end

  local function describe_not_ready(info)
    local i = info or get_info()
    if not i.present then
      return "missing"
    end
    if i.kind ~= REQUIRED_TYPE then
      return "wrong type (" .. (i.kind ~= "" and i.kind or "unknown") .. ")"
    end
    if i.disabled then
      return "disabled"
    end
    if i.fuel_name ~= FUEL_ITEM then
      return "no ender pearls in fuel slot"
    end
    return "fuel low (" .. i.fuel_count .. "/" .. MIN_FUEL .. " ender pearls)"
  end

  return {
    get_info = get_info,
    is_ready = is_ready,
    describe_not_ready = describe_not_ready,
    has_component = function()
      return component.isAvailable("anchor")
    end,
  }
end
