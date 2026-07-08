-- Wired-modem transport for the teleporter protocol.
-- Owns the modem proxy; encodes outgoing messages via util.pack and sends
-- them either unicast (target addr given) or broadcast.

local component = require("component")

return function(deps)
  local config = deps.config
  local util = deps.util
  local modem

  return {
    setup = function()
      if not component.isAvailable("modem") then
        error("No modem (network card) found. Insert a Network Card and retry.")
      end
      local m = component.modem
      if not m.isWired() then
        error("Modem is not wired. Use a wired Network Card.")
      end
      m.open(config.PORT)
      modem = m
      return m
    end,
    send = function(tbl, target)
      local payload = util.pack(tbl)
      if not payload then
        return
      end
      if target then
        modem.send(target, config.PORT, payload)
      else
        modem.broadcast(config.PORT, payload)
      end
    end,
    close = function()
      if modem then
        modem.close(config.PORT)
      end
    end,
  }
end
