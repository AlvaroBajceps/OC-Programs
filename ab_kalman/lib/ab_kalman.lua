--AlvaroBajceps 2026 and gemini
--version 1.0.0

---@class KalmanFilter
local KalmanFilter = {
    Q = 0.0,
    R = 0.0,
    c = 1.0,
    x = 0.0,
    k = 0.0,
}
KalmanFilter.__index = KalmanFilter

function KalmanFilter.new(process_noise, sensor_noise, initial_value)
    local instance = {
        Q = process_noise,
        R = sensor_noise,
        c = 1.0,
        x = initial_value,
        k = 0.0,
    }
    setmetatable(instance, KalmanFilter)
    return instance
end

function KalmanFilter:update(measurement)
    self.c = self.c + self.Q
    self.k = self.c / (self.c + self.R)
    self.x = self.x + self.k * (measurement - self.x)
    self.c = (1 - self.k) * self.c
    return self.x
end

return KalmanFilter