-- Publishes "dupa" to the MQTT topic "mars" once, then disconnects.
-- Requires luamqtt and the OpenComputers Internet Card.
-- Edit BROKER and run the program.

local mqtt = require("ab_luamqtt")
local ioloop = require("ab_luamqtt.ioloop")

local BROKER = "192.168.1.10:1883" -- change to your MQTT broker
local TOPIC = "mars"
local PAYLOAD = "dupa"

local published = false
local failure

local client = mqtt.client{
	uri = BROKER,
	clean = true,
	connector = require("ab_luamqtt.luasocket_oc"),
}

client:on{
	connect = function(connack)
		if connack.rc ~= 0 then
			failure = "connection refused: " .. connack:reason_string()
			return
		end

		local ok, err = client:publish{
			topic = TOPIC,
			payload = PAYLOAD,
			qos = 1,
			callback = function()
				print(("published %q to topic %q"):format(PAYLOAD, TOPIC))
				published = true
				client:disconnect()
			end,
		}
		if not ok then
			failure = "publish failed: " .. tostring(err)
		end
	end,

	error = function(err)
		failure = tostring(err)
	end,
}

-- Use a small timeout and os.sleep, because luamqtt's default ioloop sleep
-- function comes from the luasocket module, which OpenComputers does not have.
local loop = ioloop.create{
	timeout = 0.05,
	sleep_function = os.sleep,
}
loop:add(client)

local started, err = client:start_connecting()
if not started then
	loop:remove(client)
	error("connect failed: " .. tostring(err))
end

loop:run_until_clients()

if not published then
	error(failure or "connection was closed before the message was acknowledged")
end
