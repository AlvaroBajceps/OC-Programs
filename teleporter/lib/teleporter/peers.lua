-- Peer directory: tracks every other teleporter node seen on the wire.
-- Each peer record holds { name, last_beat, online, modem_addr, has_tp,
-- healthy }. Also owns the currently-selected destination (selected_peer)
-- since both the UI (click to select) and the protocol (clear on abort)
-- mutate it.

local computer = require("computer")

return function(deps)
  local config = deps.config
  local app = deps.app

  local peers = {}
  local selected_peer = nil

  local function beat(addr, name, modem_addr, has_tp, healthy)
    if addr == config.MY_ADDR then
      return
    end
    if name then
      name = name:sub(1, config.MAX_NAME_LEN)
    end
    local new_healthy = healthy ~= false
    if not peers[addr] then
      peers[addr] = {
        name = name or ("Node-" .. addr:sub(1, 6)),
        last_beat = computer.uptime(),
        online = true,
        modem_addr = modem_addr,
        has_tp = has_tp == true,
        healthy = new_healthy,
      }
      app.dirty = true
    else
      peers[addr].last_beat = computer.uptime()
      peers[addr].online = true
      if modem_addr then
        peers[addr].modem_addr = modem_addr
      end
      if name and name ~= peers[addr].name then
        peers[addr].name = name
        app.dirty = true
      end
      local new_tp = has_tp == true
      if peers[addr].has_tp ~= new_tp then
        peers[addr].has_tp = new_tp
        app.dirty = true
      end
      if peers[addr].healthy ~= new_healthy then
        peers[addr].healthy = new_healthy
        app.dirty = true
      end
    end
  end

  local function rename(addr, name)
    if addr == config.MY_ADDR then
      return
    end
    if peers[addr] and name then
      peers[addr].name = name:sub(1, config.MAX_NAME_LEN)
      app.dirty = true
    end
  end

  local function refresh_status()
    local now = computer.uptime()
    local changed = false
    for _, p in pairs(peers) do
      local alive = (now - p.last_beat) < config.OFFLINE_TIMEOUT
      if p.online ~= alive then
        p.online = alive
        changed = true
      end
    end
    if changed then
      app.dirty = true
    end
    if selected_peer and peers[selected_peer] and not peers[selected_peer].online then
      selected_peer = nil
      app.dirty = true
    end
  end

  local function all_sorted()
    local t = {}
    for addr, p in pairs(peers) do
      t[#t + 1] = { addr = addr, name = p.name, online = p.online, healthy = p.healthy }
    end
    table.sort(t, function(a, b)
      return a.name < b.name
    end)
    return t
  end

  return {
    beat = beat,
    rename = rename,
    refresh_status = refresh_status,
    all_sorted = all_sorted,
    get = function(addr)
      return peers[addr]
    end,
    all = function()
      return peers
    end,
    get_selected = function()
      return selected_peer
    end,
    set_selected = function(addr)
      selected_peer = addr
      app.dirty = true
    end,
    clear_selected = function()
      selected_peer = nil
      app.dirty = true
    end,
    is_selected = function(addr)
      return selected_peer == addr
    end,
    mark_offline = function(addr)
      if peers[addr] then
        peers[addr].online = false
        if peers[addr].has_tp then
          peers[addr].has_tp = false
        end
        app.dirty = true
      end
    end,
  }
end
