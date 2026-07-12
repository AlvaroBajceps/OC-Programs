local os = require("os")
local term = require("term")

function start()
  term.clear()
  os.execute("heating_pump")
end
