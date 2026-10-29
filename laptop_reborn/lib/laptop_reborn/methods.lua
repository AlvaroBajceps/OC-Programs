-- OpenOS component proxies expose methods as callable tables, not functions.
-- This helper accepts both callable tables (real proxies) and plain proxy
-- functions (test doubles) and never injects an implicit self argument.

local M = {}

---@param value any
---@return boolean
function M.is_callable(value)
  if type(value) == "function" then
    return true
  end
  if type(value) == "table" then
    local meta = getmetatable(value)
    return meta ~= nil and type(meta.__call) == "function"
  end
  return false
end

---@param object table|nil
---@param name string
---@return any|nil
function M.get(object, name)
  if type(object) ~= "table" then
    return nil
  end
  local ok, value = pcall(function()
    return object[name]
  end)
  if ok and M.is_callable(value) then
    return value
  end
  return nil
end

---@param object table|nil
---@param name string
---@return boolean ok
---@return any result
function M.call(object, name, ...)
  if type(object) ~= "table" then
    return false, "not a table"
  end
  local ok, method = pcall(function()
    return object[name]
  end)
  if not ok or not M.is_callable(method) then
    return false, "missing method " .. tostring(name)
  end
  return pcall(method, ...)
end

return M
