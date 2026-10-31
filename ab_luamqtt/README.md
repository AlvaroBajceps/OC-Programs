# ab_luamqtt - Pure-lua MQTT v3.1.1 and v5.0 client

[![License](http://img.shields.io/badge/Licence-MIT-brightgreen.svg)](https://github.com/xHasKx/luamqtt/blob/master/LICENSE)

> **This is a redistribution.** This directory contains a copy of
> [luamqtt](https://github.com/xHasKx/luamqtt), imported from upstream commit
> `14ad9be4c327972be68726d3c796c781eb4cc542` and redistributed as part of the
> [OC-Programs](https://github.com/AlvaroBajceps/OC-Programs) OPPM repository.
> Upstream authorship and the MIT license apply; see [LICENSE](LICENSE).

MQTT ( [http://mqtt.org/](http://mqtt.org/) ) client library for Lua.
**MQTT** is a popular network communication protocol working by **"publish/subscribe"** model.

This library is written in **pure-lua** to provide maximum portability.

# Features

* Full MQTT v3.1.1 client-side support
* Full MQTT v5.0 client-side support
* Several long-living MQTT clients in one script thanks to ioloop

# Documentation

See [https://xhaskx.github.io/luamqtt/](https://xhaskx.github.io/luamqtt/)

# Forum

See [flespi forum thread](https://forum.flespi.com/d/97-luamqtt-mqtt-client-written-in-pure-lua)

# Source Code (Original)

[https://github.com/xHasKx/luamqtt](https://github.com/xHasKx/luamqtt)

# Dependencies

The only main dependency is a [**luasocket**](https://luarocks.org/modules/luasocket/luasocket) to establishing TCP connection to the MQTT broker. Install it like this:

```sh
luarocks install luasocket
```

On Lua 5.1 it also depends on [**LuaBitOp**](http://bitop.luajit.org/) (**bit**) library to perform bitwise operations.
It's not listed in package dependencies, please install it manually like this:

```sh
luarocks install luabitop
```

# Lua versions

It's tested to work on Debian 9 GNU/Linux with Lua versions:

* Lua 5.1 and above (**i.e. any modern Lua version**)
* LuaJIT 2.0.0 ... LuaJIT 2.1.0 beta3
* It may also work on other Lua versions without any guarantees

# Connectors

Connector is a network connection layer for luamqtt. There are two standard connectors included:

* [`luasocket`](luasocket.lua)
* [`luasocket_oc`](luasocket_oc.lua) - OpenComputers Internet Card connector

The `luasocket` or `luasocket_ssl` connector will be used by default, if not specified, according `secure=true/false` option per MQTT client.

In simple terms, connector is a set of functions to establish a network stream (TCP connection usually) and send/receive data through it.
Every MQTT client instance may have their own connector.

And it's very simple to implement your own connector to make luamqtt works in your environment.

# Bugs & contributing

Please [file a GitHub issue](https://github.com/xHasKx/luamqtt/issues) if you found any bug.

And of course, any contribution are welcome!

# MQTT version

Currently supported is:

* [MQTT v3.1.1 protocol](http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/errata01/os/mqtt-v3.1.1-errata01-os-complete.html) version.
* [MQTT v5.0 protocol](http://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html) version.

Both protocols has full control packets support.

# LICENSE

Standard MIT License, see LICENSE file for full text
