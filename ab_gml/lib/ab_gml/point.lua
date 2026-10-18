---Point stores x,y coordinates, as simple as that.
---@class Point
---@field x number
---@field y number
local point = {}
point.__index = point

---Create new point instance
---@param x number
---@param y number
function point.new(x,y)
    checkArg(1, x, "number")
    checkArg(2, y, "number")
    local self = setmetatable({x = x, y = y}, point)
    return self
end

--cpp style ctor
setmetatable(point, { __call = function(self, ...) return self.new(...) end } )


function point:unpack()
    return self.x, self.y
end

function point.__add(a,b)
    if getmetatable(b) == point then
        return point.new(a.x + b.x, a.y + b.y)
    end
    return point.new(a.x + b, a.y + b)
end

function point.__sub(a,b)
    if getmetatable(b) == point then
        return point.new(a.x - b.x, a.y - b.y)
    end
    return point.new(a.x - b, a.y - b)
end

function point.__div(a,b)
    if getmetatable(b) == point then
        return point.new(a.x / b.x, a.y / b.y)
    end
    return point.new(a.x / b, a.y / b)
end

function point.__mul(a,b)
    if getmetatable(b) == point then
        return point.new(a.x * b.x, a.y * b.y)
    end
    return point.new(a.x * b, a.y * b)
end

function point.__tostring(a)
    return string.format("x:%f y:%f", a.x, a.y)
end

return point