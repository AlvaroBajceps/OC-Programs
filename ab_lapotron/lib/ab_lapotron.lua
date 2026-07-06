--AlvaroBajceps 2026
--version 1.2.1

local _component = require("component")
local _ev = require("event")

--#region gt_machine

---@class gt_machine : Component
---@field address string
---@field getSensorInformation fun() : table

--#endregion

local function onDevRm(self, _, uuid)
    if self._dev.address == uuid then
        self._dev_ejected = true
    end
end

local function onDevAdd(self, _, uuid)
    if self._dev.address == uuid then
        self._dev_ejected = false
    end
end

--#region LapotronReader

local _lap_sensinf = {
    stored = 2,
    capacityUsed = 4,
    capacityTotal = 5,
    passiveLoss = 7,
    powerAvgIn_5s = 10,
    powerAvgOut_5s = 11,
    powerAvgIn_5m = 12,
    powerAvgOut_5m = 13,
    powerAvgIn_1h = 14,
    powerAvgOut_1h = 15,
    energyStatusText = 16,
    maintenanceStatus = 17,
}

---@type gt_machine
---@diagnostic disable-next-line: missing-fields
local v_lapotron = { address = "v_lapotron" }
function v_lapotron.getSensorInformation()
    return {
        "§eOperational Data of virtual Laporton:§r",
        "EU Stored: 11,776,185,376 EU",
        "EU Stored: 1.18x10^10 EU",
        "Used Capacity: 60.58%",
        "Total Capacity: 19,440,000,000 EU",
        "Total Capacity: 1.94x10^10 EU",
        "Passive Loss: 112 EU/t",
        "EU IN: 0 EU/t",
        "EU OUT: 32,768 EU/t",
        "Avg EU IN: 119,603 (last 5 seconds)",
        "Avg EU OUT: 116,981 (last 5 seconds)",
        "Avg EU IN: 120,210 (last 5 minutes)",
        "Avg EU OUT: 112,375 (last 5 minutes)",
        "Avg EU IN: 120,210 (last 1 hour)",
        "Avg EU OUT: 112,375 (last 1 hour)",
        "Time to Full: 1.77 days",
        "Maintenance Status: §aWorking perfectly§r",
        "Wireless mode: §cdisabled§r",
        "§4UHV§r Capacitors detected: 0",
        "§5UEV§r Capacitors detected: 0",
        "§1§lUIV§r Capacitors detected: 0",
        "§c§l§nUMV§r Capacitors detected: 0",
        "Total wireless EU: §c0 EU",
        "Total wireless EU: §c0 EU"
    }
end

---@class LapotronReader
local LapotronReader = {
    SENSINF_LEN = 24,
    SENSINF = _lap_sensinf,
    ---@type gt_machine
    _dev = nil,
    _onDevRm = function () end,
    _onDevAdd= function () end,
    _dev_ejected = false,
    ---@type table
    _sensinf_cache = {},
    ---@type table
    v_lapotron = v_lapotron,
    cache = {
        stored = 0,
        capacityUsed = 0,
        capacityTotal = 0,
        passiveLoss = 0,
        powerAvgIn_5s = 0,
        powerAvgIn_5m = 0,
        powerAvgIn_1h = 0,
        powerAvgOut_5s = 0,
        powerAvgOut_5m = 0,
        powerAvgOut_1h = 0,
        energyStatusText = "No data",
        maintenanceStatus = true,
    },
}
LapotronReader.__index = LapotronReader

function LapotronReader.isDeviceValid(dev_uuid)
    if not dev_uuid then
        return nil, "not even string."
    end

    if dev_uuid == "v_lapotron" then return true end

---@diagnostic disable-next-line: missing-parameter
    local dev_uuid_full = _component.get(dev_uuid)

    if not dev_uuid_full or dev_uuid_full == "" then
        return false, ("No device found with UUID '" .. dev_uuid .. "'")
    end

    local dev_proxy = _component.proxy(dev_uuid_full)
    ---@cast dev_proxy gt_machine

    if not dev_proxy.getSensorInformation then
        return false, ("Device '" .. dev_uuid_full .. "' does not have `getSensorInformation()` Probably not lapotronic capacitor...")
    end

    if #dev_proxy.getSensorInformation() ~= LapotronReader.SENSINF_LEN then
        return false, ("Device '" .. dev_uuid_full .. "' does not have expected length in `getSensorInformation()` Probably not lapotronic capacitor...")
    end

    return true
end

---@param dev_uuid string Device UUID
function LapotronReader.new(dev_uuid)
    if not dev_uuid then
        return nil, "not even string."
    end

    if dev_uuid == "v_lapotron" then
        local instance = {
            _dev = v_lapotron,
        }
        setmetatable(instance, LapotronReader)
        return instance
    end

    local status, msg = LapotronReader.isDeviceValid(dev_uuid)

    if not status then
        return nil, msg
    end

    local dev_proxy = _component.proxy(dev_uuid)

    local instance = {
        _dev = dev_proxy,
    }
    setmetatable(instance, LapotronReader)
    instance._onDevRm = function(...) onDevRm(instance, ...) end
    instance._onDevAdd = function(...) onDevAdd(instance, ...) end

    _ev.listen("component_removed", instance._onDevRm)
    _ev.listen("component_added", instance._onDevAdd)

    return instance
end

function LapotronReader:dispose()
    if self._dev ~= v_lapotron then
        _ev.ignore("component_removed", self._onDevRm)
        _ev.ignore("component_added", self._onDevAdd)
    end
    self._sensinf_cache = nil
    self._dev = nil
end

-- Pulls data from lapotron.
---@param readall boolean? if true read all fields into cache
---@return number|number result1 @ status
---@return nil|string result2 @ error message
function LapotronReader:pull(readall)
    if self._dev_ejected then
        return 1, ("Component '" .. self._dev.address .. "' was ejected.")
    end
    self._sensinf_cache = self._dev.getSensorInformation()

    if readall ~= nil and readall then
        self:cacheAll()
    end

    return 0
end

function LapotronReader:cacheAll()
    self.cache.stored = self:getStored()
    self.cache.capacityUsed = self:getCapacityUsed()
    self.cache.capacityTotal = self:getCapacityTotal()
    self.cache.passiveLoss = self:getPassiveLoss()
    self.cache.powerAvgIn_5s = self:getPowerAvgIn_5s()
    self.cache.powerAvgIn_5m = self:getPowerAvgIn_5m()
    self.cache.powerAvgIn_1h = self:getPowerAvgIn_1h()
    self.cache.powerAvgOut_5s = self:getPowerAvgOut_5s()
    self.cache.powerAvgOut_5m = self:getPowerAvgOut_5m()
    self.cache.powerAvgOut_1h = self:getPowerAvgOut_1h()
    self.cache.energyStatusText = self:getEnergyStatusText()
    self.cache.maintenanceStatus = self:getMaintenanceStatus()
end

-- currently stored
function LapotronReader:getStored()
    local data = self._sensinf_cache[self.SENSINF.stored]
    data = string.match(data, "%d+[,%d+]*")
    data = string.gsub(data, ",", "")
    return tonumber(data)
end

-- capacity used in % (0 - 100)
function LapotronReader:getCapacityUsed()
    local data = self._sensinf_cache[self.SENSINF.capacityUsed]
    data = string.match(data, "%d+.%d+")
    return tonumber(data)
end

-- total capacity duh
function LapotronReader:getCapacityTotal()
    local data = self._sensinf_cache[self.SENSINF.capacityTotal]
    data = string.match(data, "%d+[,%d+]*")
    data = string.gsub(data, ",", "")
    return tonumber(data)
end

function LapotronReader:getPassiveLoss()
    local data = self._sensinf_cache[self.SENSINF.passiveLoss]
    data = string.match(data, "%d+")
    return tonumber(data)
end

function LapotronReader:getPowerAvgIn_5s()
    local data = self._sensinf_cache[self.SENSINF.powerAvgIn_5s]
    data = string.match(data, "%d+[,%d+]*")
    data = string.gsub(data, ",", "")
    return tonumber(data)
end

function LapotronReader:getPowerAvgIn_5m()
    local data = self._sensinf_cache[self.SENSINF.powerAvgIn_5m]
    data = string.match(data, "%d+[,%d+]*")
    data = string.gsub(data, ",", "")
    return tonumber(data)
end

function LapotronReader:getPowerAvgIn_1h()
    local data = self._sensinf_cache[self.SENSINF.powerAvgIn_1h]
    data = string.match(data, "%d+[,%d+]*")
    data = string.gsub(data, ",", "")
    return tonumber(data)
end

function LapotronReader:getPowerAvgOut_5s()
    local data = self._sensinf_cache[self.SENSINF.powerAvgOut_5s]
    data = string.match(data, "%d+[,%d+]*")
    data = string.gsub(data, ",", "")
    return tonumber(data)
end

function LapotronReader:getPowerAvgOut_5m()
    local data = self._sensinf_cache[self.SENSINF.powerAvgOut_5m]
    data = string.match(data, "%d+[,%d+]*")
    data = string.gsub(data, ",", "")
    return tonumber(data)
end

function LapotronReader:getPowerAvgOut_1h()
    local data = self._sensinf_cache[self.SENSINF.powerAvgOut_1h]
    data = string.match(data, "%d+[,%d+]*")
    data = string.gsub(data, ",", "")
    return tonumber(data)
end

-- copy paste status from machine
function LapotronReader:getEnergyStatusText()
   return self._sensinf_cache[self.SENSINF.energyStatusText]
end

-- returns true when machine have an issue
function LapotronReader:getMaintenanceStatus()
    local data = self._sensinf_cache[self.SENSINF.maintenanceStatus]
    data = string.sub(
        data,
        ( string.find(data, ":")+2 --[[remove two chars after]] ) or 0
    )
    data = string.gsub(data, "§%w", "")

    return (string.find(data, "Has")) ~= nil
end

--#endregion LapotronReader

return LapotronReader
