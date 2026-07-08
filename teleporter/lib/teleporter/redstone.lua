-- Bundled-redstone health sensing for the teleporter.
-- One bundled cable (ProjectRed / RedLogic) carries two signals:
--   Black (color 15) - cable-health heartbeat; its presence lets this node
--                      auto-discover which side the cable is on.
--   Red   (color 14) - driven high only while the teleporter entity is
--                      physically at this node.
-- check_health() reports whether the node is safe to teleport from: rs
-- present, cable detected, and at most one node network-wide holds Red high.

local component = require("component")

return function(deps)
  local config = deps.config
  local peers = deps.peers
  local app = deps.app

  local rs = nil
  local rs_side = nil
  local local_red_high = false
  local local_black_high = false

  local function refresh()
    if not rs then
      rs_side = nil
      local_black_high = false
      local_red_high = false
      return
    end
    local new_side = nil
    for side = 0, 5 do
      if rs.getBundledInput(side, config.COLOR_BLACK) > 0 then
        new_side = side
        break
      end
    end
    local new_black = new_side ~= nil
    local new_red = false
    if new_side ~= nil then
      new_red = rs.getBundledInput(new_side, config.COLOR_RED) > 0
    end
    if new_side ~= rs_side or new_red ~= local_red_high or new_black ~= local_black_high then
      rs_side = new_side
      local_black_high = new_black
      local_red_high = new_red
      app.dirty = true
    end
  end

  local function count_red_high()
    local count = 0
    if local_black_high and local_red_high then
      count = count + 1
    end
    for _, p in pairs(peers.all()) do
      if p.online and p.has_tp then
        count = count + 1
      end
    end
    return count
  end

  local function check_health()
    if not rs then
      return true, "Redstone I/O component not detected"
    end
    if not local_black_high then
      return true, "Bundled cable missing (Black health signal not found on any side)"
    end
    local red_count = count_red_high()
    if red_count > 1 then
      return true, red_count .. " nodes report teleporter present (Red conflict)"
    end
    return false, nil
  end

  rs = (component.isAvailable("redstone") and component.redstone) or nil

  return {
    refresh = refresh,
    count_red_high = count_red_high,
    check_health = check_health,
    has_rs = function()
      return rs ~= nil
    end,
    get_side = function()
      return rs_side
    end,
    is_black_high = function()
      return local_black_high
    end,
    is_red_high = function()
      return local_red_high
    end,
  }
end
