local POINT = require("ab_gml.point")

local anchor = {
    LT = "left top",
    LC = "left center",
    LB = "left bottom",
    CT = "center top",
    CC = "center center",
    CB = "center bottom",
    RT = "right top",
    RC = "right center",
    RB = "right bottom",
}
anchor.__index = anchor

function anchor.new(x, y, w, h)
    local self = setmetatable({}, anchor)

    -- Define spatial markers
    local x_left   = x
    local x_center = x + math.floor(w / 2)
    local x_right  = x + w

    local y_top    = y
    local y_center = y + math.floor(h / 2)
    local y_bottom = y + h

    -- Precompute the 9 points using xy mixing naming convention
    self.points = {
        [anchor.LT] = POINT(x_left, y_top),
        [anchor.LC] = POINT(x_left, y_center),
        [anchor.LB] = POINT(x_left, y_bottom),

        [anchor.CT] = POINT(x_center, y_top),
        [anchor.CC] = POINT(x_center, y_center),
        [anchor.CB] = POINT(x_center, y_bottom),

        [anchor.RT] = POINT(x_right, y_top),
        [anchor.RC] = POINT(x_right, y_center),
        [anchor.RB] = POINT(x_right, y_bottom),
    }

    return self
end

-- Get a point by its string layout name
function anchor:get(name)
    return self.points[name]
end

return anchor