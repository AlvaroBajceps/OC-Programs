-- OpenComputers Internet Card connector for luamqtt.
-- DOC: https://ocdoc.cil.li/component:internet
--
-- Usage:
--   local mqtt = require("ab_luamqtt")
--   local client = ab_luamqtt.client{
--       uri = "broker:1883",
--       clean = true,
--       connector = require("ab_luamqtt.luasocket_oc"),
--   }

-- module table
local luasocket_oc = {}

local component = require("component")
local computer = require("computer")
local os = require("os")

local os_sleep = rawget(os, "sleep") or function() end
local str_sub = string.sub

-- Timeouts (in seconds) used by operations that must make progress.
local CONNECT_TIMEOUT = 10
local WRITE_TIMEOUT = 10

local function now()
	return computer.uptime()
end

local function close_socket(sock)
	if sock then
		pcall(sock.close)
	end
end

-- Open network connection to .host and .port in conn table
-- Store opened socket to conn table
-- Returns true on success, or false and error text on failure
function luasocket_oc.connect(conn)
	if conn.secure then
		return false, "luasocket_oc connector does not support TLS"
	end
	if not component.isAvailable("internet") then
		return false, "no internet card found"
	end

	local card = component.internet

	local enabled_ok, tcp_enabled = pcall(card.isTcpEnabled)
	if enabled_ok and tcp_enabled == false then
		return false, "TCP connections are disabled on the internet card"
	end

	local call_ok, sock, err = pcall(card.connect, conn.host, conn.port)
	if not call_ok then
		return false, "internet.connect failed: " .. tostring(sock)
	end
	if not sock then
		return false, "internet.connect failed: " .. tostring(err)
	end

	-- OC's TCP sockets are non-blocking; wait for the connection to complete.
	local deadline = now() + CONNECT_TIMEOUT
	while true do
		local ok, connected = pcall(sock.finishConnect)
		if not ok then
			close_socket(sock)
			return false, "internet.connect failed: " .. tostring(connected)
		end
		if connected then
			break
		end
		if now() >= deadline then
			close_socket(sock)
			return false, "internet.connect timed out"
		end
		os_sleep(0.05)
	end

	conn.sock = sock
	conn.oc_buffer = ""
	return true
end

-- Shutdown network connection
function luasocket_oc.shutdown(conn)
	if conn.sock then
		close_socket(conn.sock)
		conn.sock = nil
	end
	conn.oc_buffer = nil
end

-- Send data to network connection
-- Sends data[i..j] and returns j (index of the last byte sent) on success
function luasocket_oc.send(conn, data, i, j)
	local sock = conn.sock
	if not sock then
		return nil, "connection is closed"
	end

	i = i or 1
	j = j or #data
	local pos = i
	local deadline = now() + WRITE_TIMEOUT

	while pos <= j do
		local ok, written, err = pcall(sock.write, str_sub(data, pos, j))
		if not ok then
			return nil, tostring(written)
		end
		if type(written) ~= "number" then
			return nil, tostring(err or written)
		end
		if written > 0 then
			pos = pos + written
		elseif now() >= deadline then
			return nil, "internet socket write timed out"
		else
			-- A zero write may mean the send buffer is full, or the
			-- connection has been closed by the card.
			local connected_ok, connected = pcall(sock.finishConnect)
			if not connected_ok or not connected then
				return nil, "connection is closed"
			end
			os_sleep(0.01)
		end
	end

	return j
end

-- Receive given amount of data from network connection
-- Returns exactly `size` bytes on success, or nil and "timeout"/"closed" on failure
function luasocket_oc.receive(conn, size)
	local sock = conn.sock
	if not sock then
		return nil, "closed"
	end
	if not size or size < 1 then
		return ""
	end

	local buffer = conn.oc_buffer or ""
	local timeout = conn.timeout

	while #buffer < size do
		local ok, chunk, err = pcall(sock.read, size - #buffer)
		if not ok then
			return nil, "internet socket read failed: " .. tostring(chunk)
		end
		if chunk == nil then
			if err ~= nil then
				return nil, tostring(err)
			end
			conn.oc_buffer = nil
			return nil, "closed"
		end
		if type(chunk) ~= "string" then
			return nil, tostring(err or chunk)
		end
		if #chunk > 0 then
			buffer = buffer .. chunk
		else
			if err ~= nil and err ~= "timeout" and err ~= "wantread" then
				return nil, tostring(err)
			end
			-- Keep partially received data for the next receive() call.
			conn.oc_buffer = buffer
			if timeout then
				-- Ioloop mode. receive() runs inside luamqtt's receive
				-- coroutine; sleeping here yields a nil packet to the ioloop.
				-- Return timeout and let the ioloop's sleep_function wait.
				return nil, "timeout"
			end
			-- Sync mode: block and wait for the broker to send more data.
			os_sleep(0.05)
		end
	end

	conn.oc_buffer = str_sub(buffer, size + 1)
	return str_sub(buffer, 1, size)
end

-- Store the timeout used to switch between blocking and ioloop operation.
-- OC sockets are always non-blocking; the timeout only affects receive().
function luasocket_oc.settimeout(conn, timeout)
	conn.timeout = timeout
end

-- export module table
return luasocket_oc

-- vim: ts=4 sts=4 sw=4 noet ft=lua
