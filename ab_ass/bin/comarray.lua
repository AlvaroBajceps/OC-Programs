local IO = require("io")
local SHELL = require("shell")
local SERIALIZATION = require("serialization")
local EVENT = require("event")

local unserialize = SERIALIZATION.unserialize
local serialize = SERIALIZATION.serialize

--VERSION 1.0.0

local DEBUG = 1

local PROG_DESCRIPTION="comarray [options] <arg1>\narg1 - the file to write to\n"

local PROG_OPTS = {
  help="show help",
  append="append to component list",
}

local function read_main_args(...)
  local args, opts = SHELL.parse(...)

  for op_prog, _ in pairs(PROG_OPTS) do
    local op_prog_letter = op_prog:sub(1,1)

    if opts[op_prog_letter] ~= nil then
      opts[op_prog] = opts[op_prog_letter]
    end
  end

  return args, opts  
end

local function main(...)
  local args, opts = read_main_args(...)

  if opts.help then
    print(PROG_DESCRIPTION)
    for k,v in pairs(PROG_OPTS) do print(k,v) end
    return
  end

  if DEBUG then
    for k,v in pairs(opts) do print(k,v) end
    for k,v in pairs(args) do print(k,v) end
  end

  local file 

  if not file then file=SHELL.getWorkingDirectory().."/com.luat" end

  local comlist = {}

  if opts.append then
    local f = IO.open(file, "r")
    if not f then
        error("file IO error")
    end
    comlist = unserialize(f:read("*a"))
    f:close()
  end

  local com_add = function(evname, address, type) table.insert(comlist, address) print(evname, address, type) end
  EVENT.listen("component_added", com_add)

  print("Awaiting for componend_added events...")

  while(not EVENT.pull(0.5, "interrupt")) do end

  print("There is " .. tostring(#comlist) .. " component/s!")

  print("Saving results...")

  EVENT.ignore("component_added", com_add)

  local f = IO.open(file, "w")
  if not f then
    error("file IO error")
  end
  f:write(serialize(comlist))
  f:close()

end

main(...)