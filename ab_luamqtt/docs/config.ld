-- usage:
-- execute `ldoc .` in this docs directory

file = {"../lib/ab_luamqtt/init.lua", "../lib/ab_luamqtt/const.lua", "../lib/ab_luamqtt/client.lua", "../lib/ab_luamqtt/ioloop.lua", "../lib/ab_luamqtt/protocol.lua"}
project = "ab_luamqtt"
package = "ab_luamqtt"
dir = "."

description = "ab_luamqtt - Pure-lua MQTT v3.1.1 and v5.0 client"

full_description = "Source code: https://github.com/xHasKx/luamqtt"

examples = {
	"../examples/opencomputers-publish.lua",
}

topics = {"../README.md", "../LICENSE"}

format = "markdown"
plain = true
