local os = require("os")
local term = require("term")

function start()
  os.execute("oppm update all")
  term.clear()
  os.execute("heating_pump")
end
