local EV = require("event")
local TERM = require("term")
local COM = require("component")
local COMPC = require("computer")
local ev_id = -1

local function termglue_recover(name, uuid, type)
  if name ~= "component_added" or not (type == "screen" or type == "keyboard") then
    return
  end

  local gOk, g = pcall(COM.getPrimary, "gpu")
  local sOk, s = pcall(COM.getPrimary, "screen")
  if not gOk or not sOk then
    return
  end

  g.bind(s.address, false)
  EV.ignore("component_added", termglue_recover)
  print("## Termglue: DISPLAY RECOVERED ##")
  COMPC.beep(2000, 0.4)
end

local function termglue_main()
  COMPC.beep(500, 0.4)
  --instant recover
  termglue_recover("component_added", "uuid", "screen")
  --if failed wait for components
  if not TERM.isAvailable() then
    EV.listen("component_added", termglue_recover)
  end
end


function start()
  if ev_id ~= -1 then print("Termglue already running!") return end
  ev_id = EV.listen("term_unavailable", termglue_main)
  print("Termglue started.")
end

function stop()
  if ev_id == -1 then print("Termglue already stopped!") return end
  EV.cancel(ev_id)
  ev_id = -1
  print("Termglue stopped.")
end