local os = require("os")
local term = require("term")

-- selene: allow(unused_variable)
function start()
  term.clear()
  os.execute("mqtt_ha")
end
