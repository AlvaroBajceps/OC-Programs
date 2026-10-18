local COMPUTER = require("computer")

local luaVer = tonumber(string.match(COMPUTER.getArchitecture(), "^Lua (%d+%.%d+)$"))

if luaVer and luaVer >= 5.3 then
    if rawget(_G, "bit32") then
        return false
    end
    _G.bit32 = require("bit32")
    return true
end

return false