local component = require("component")
local io = require("io")
local shell = require("shell")
local serialization = require("serialization")
local event = require("event")
local os = require("os")
local filesystem = require("filesystem")
local sides      = require("sides")

local unserialize = serialization.unserialize
local serialize = serialization.serialize

--VERSION 1.0.0

---@type ComponentMEInterface[]
local ass_bus_array = {}

---@type ComponentMEInterface
local ass_me_pattern

---@type ComponentMEInterface
local ass_hatch_interface

local PROG_DESCRIPTION="smartass [options]\n"

local PROG_OPTS = {
  help="show help",
}

---@class SmartassConfig
---@field pattern_holder_adr string
---@field ass_fluid_interface_adr string
---@field ass_bus_array_file string

---@type SmartassConfig
local config = {
  pattern_holder_adr="",
  ass_fluid_interface_adr="",
  ass_bus_array_file="",
}

local CONFIG_PATH = "/etc/ab_ass.d/ass.cfg"

local DEBUG = 0

---@param lvl integer
---@param msg string
local function debuglog(lvl, msg)
  if not DEBUG or DEBUG == 0 or DEBUG < lvl then
    return
  end

  event.pull(1, "")
  print(msg)
end

local function read_main_args(...)
  local args, opts = shell.parse(...)

  for op_prog, _ in pairs(PROG_OPTS) do
    local op_prog_letter = op_prog:sub(1,1)

    if opts[op_prog_letter] ~= nil then
      opts[op_prog] = opts[op_prog_letter]
    end
  end

  if opts.help then
    print(PROG_DESCRIPTION)
    for k,v in pairs(PROG_OPTS) do print(k,v) end
    os.exit(0)
  end

  return args, opts
end

---@param str string
local function is_empty(str)
  return (not str) or (str == "")
end

local function init_devices()

  if is_empty(config.ass_bus_array_file) then
    error("config.ass_bus_array_file is invalid")
  end
  if is_empty(config.ass_fluid_interface_adr) then
    error("config.ass_fluid_interface_adr is invalid")
  end
  if is_empty(config.pattern_holder_adr) then
    error("config.pattern_holder_adr is invalid")
  end

  if not filesystem.exists(config.ass_bus_array_file) then
    error("config.ass_bus_array_file file not exist")
  end
  
  local f = io.open(config.ass_bus_array_file, "r")
  if not f then
      error("file IO error")
  end
  local ass_buses = unserialize(f:read("*a"))
  f:close()

  for i, adr in ipairs(ass_buses) do
    table.insert(ass_bus_array, component.proxy(adr))
  end

  local adr = component.get(config.pattern_holder_adr, "fluid_interface") or component.get(config.pattern_holder_adr, "me_interface")
  if not adr then error("cannot find pattern me_interface") end
  ass_me_pattern = component.proxy(adr) --[[@as ComponentMEInterface]]

  adr = component.get(config.ass_fluid_interface_adr, "fluid_interface")
  if not adr then error("cannot find ass fluid me_interface") end
  ass_hatch_interface = component.proxy(adr) --[[@as ComponentMEInterface]]

  if not pcall(component.getPrimary, "redstone") then error("missing redstone component!") end
end

---return first item from array by predictate
---@param array any[]
---@param predictate fun(item: any): boolean
---@return any item
---@return integer index
local function array_any(array, predictate)
  local ret = {}
  for i, item in ipairs(array) do
    if predictate(item) then
      return item, i
    end
  end
  return nil, 0
end

---@param pattern MEPatternStack
---@return boolean craftable
---@return integer? n
local function is_pattern_craftable(pattern)
  local me = ass_bus_array[1] --[[@as ComponentMEInterface]]

  local me_items = me.getItemsInNetwork() --[[@as MEItemStack[] ]]
  local me_fluids = me.getFluidsInNetwork() --[[@as MEFluidStack[] ]]

  local n = 0

  ::drain_loop::
  n = n + 1

  for _, entry in ipairs(pattern.inputs) do
    ---@cast entry MEItemStack|MEFluidStack

    local entry_predictate = function(a) return entry.id == a.id end

    debuglog(2, "Checking for '" .. entry.label .. "'")

    local me_item, me_item_idx = array_any(me_items, entry_predictate)
    local me_fluid, me_fluid_idx = array_any(me_fluids, entry_predictate)
    ---@cast me_item MEItemStack?
    ---@cast me_fluid MEFluidStack?

    if me_item then

      if me_item.size < entry.size then
        debuglog(1, " Not enough stored (me: " .. tostring(me_item.size) .. " vs pat: " .. tostring(entry.size) .. ")")
        if n > 1 then debuglog(1, "  Yet was enough for " .. tostring(n-1)) end
        return false
      end

      debuglog(3," me: " .. tostring(me_item.size) .. " vs pat: " .. tostring(entry.size))
      me_item.size = me_item.size - entry.size

      if me_item.size <= 0 then table.remove(me_items, me_item_idx) end

    elseif me_fluid then

      if me_fluid.amount < entry.amount then
        debuglog(1, " Not enough stored (me: " .. tostring(me_fluid.amount) .. " vs pat: " .. tostring(entry.amount) .. ")")
        if n > 1 then debuglog(1, "  Yet was enough for " .. tostring(n-1)) end
        return false
      end

      debuglog(3," me: " .. tostring(me_fluid.amount) .. " vs pat: " .. tostring(entry.amount))
      me_fluid.amount = me_fluid.amount - entry.amount

      if me_fluid.amount <= 0 then table.remove(me_fluids, me_fluid_idx) end

    else
      debuglog(1, " ME Storage have no '" .. entry.label .. "' but contains other entries! (partial pattern x" .. tostring(n) .. " match )" )
      return false
    end

  end

  os.sleep(0.05)
  if #me_items > 0 or #me_fluids > 0 then
    goto drain_loop
  end

  debuglog(1, " Fulfilled x" .. tostring(n))
  return true, n
end

local function is_me_empty()
  local me = ass_bus_array[1] --[[@as ComponentMEInterface]]

  local me_items = me.getItemsInNetwork() --[[@as MEItemStack[] ]]
  local me_fluids = me.getFluidsInNetwork() --[[@as MEFluidStack[] ]]

  return #me_items + #me_fluids == 0
end

---@param pattern MEPatternStack
local function pattern_limit_to_stack(pattern)
  local max = 0
  local all = {}
  for i, entry in ipairs(pattern.inputs) do
    --only liquids are equipped with amount but liquids are exported loosely
    if not entry.amount then
      max = math.max(max, entry.size or 0)
      table.insert(all, entry.size)
    end
  end

  debuglog(1, "Pattern max is: " .. tostring(max))
  --find divisor to drop under 64
  local divisor = 1
  while max // divisor > 64 do

    local found = false
    local d = divisor + 1

    while d <= max do
      local allDivisible = true
      for i = 1, #all do
        if all[i] % d ~= 0 then
          allDivisible = false
          break
        end
      end

      if allDivisible then
        divisor = d
        found = true
        break
      end
      d = d + 1
    end

    if not found then
      break
    end
  end

  debuglog(1, "Divisor applied: " .. tostring(divisor))
  --apply divisor
  for i, entry in ipairs(pattern.inputs) do
    if entry.size then
      entry.size = entry.size // divisor
    end
    if entry.amount then
      entry.amount = entry.amount // divisor
    end
  end
  for i, entry in ipairs(pattern.outputs) do
    if entry.size then
      entry.size = entry.size // divisor
    end
    if entry.amount then
      entry.amount = entry.amount // divisor
    end
  end

  return divisor
end

---@return boolean craftable
---@return MEPatternStack? pattern
---@return integer? n
local function check_for_craft()
  debuglog(1, "Checking...")

  for slot = 1,36 do
    local pattern = ass_me_pattern.getInterfacePattern(slot)

    if pattern then
      debuglog(1, "Found pattern at slot " .. tostring(slot))
      local craftable, n = is_pattern_craftable(pattern)
      if craftable then
        debuglog(1, "Pattern is craftable!")
        return true, pattern, n
      end
    end

  end
  return false
end

local function clear_ass_bus()
  for i, ass_bus in ipairs(ass_bus_array) do
    ass_bus.setInterfaceConfiguration(1)
  end

  ass_hatch_interface.setFluidInterfaceConfiguration(1)
end

---@param pattern MEPatternStack
local function setup_ass_bus(pattern)
  local ass_bus_idx = 1
  local ass_hatch_idx = 1
  for i, item in ipairs(pattern.inputs) do
    --only liquids are equipped with amount but liquids are exported loosely
    if not item.amount then
      if ass_bus_idx > #ass_bus_array then error("This pattern is not compatible with current ASSLINE! (bus count too low!)") end
      local ass_bus = ass_bus_array[ass_bus_idx]
      ass_bus_idx = ass_bus_idx + 1

      ass_bus.setInterfaceConfiguration(1, {name=item.name, size=item.size, damage=item.damage})
    else
      ass_hatch_interface.setFluidInterfaceConfiguration(ass_hatch_idx, {name=item.name})
      ass_hatch_idx = ass_hatch_idx + 1
    end
  end
end

local function read_config()
  local conf = io.open(CONFIG_PATH, "r")
  if not conf then
    local dir = filesystem.path(CONFIG_PATH)
    if not filesystem.isDirectory(dir) then
      if not filesystem.makeDirectory(dir) then
        error("cannot make dir " .. dir)print("Valid pattern is requested")
      end
    end

    conf = io.open(CONFIG_PATH, "w")
    if not conf then error("Cannot read nor save empty config!") end
    print("No config found. Fill it up in " .. CONFIG_PATH)
    conf:write(serialize(config))
    conf:close()
    return config
  end
  local config_read = unserialize(conf:read("*a"))
  conf:close()
  return config_read or config
end

local function main(...)
  local args, opts = read_main_args(...)

  config = read_config()
  init_devices()
  clear_ass_bus()
  component.redstone.setOutput(sides.top, 0)
  print("Initialized!")

  while(not event.pull(1, "interrupt")) do
    local ok, pattern, n = check_for_craft()
    if ok and pattern then
      local divisor = pattern_limit_to_stack(pattern)
      n = n * divisor

      print("Valid pattern is requested")
      setup_ass_bus(pattern)
      component.redstone.setOutput(sides.top, 255)
      while not is_me_empty() do os.sleep(0.5) end
      print("Craft completed (me_storage empty of items)")

      clear_ass_bus()
      component.redstone.setOutput(sides.top, 0)
    end
  end

end

main(...)