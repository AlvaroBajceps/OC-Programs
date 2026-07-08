-- Serialization and small math helpers shared across the teleporter protocol.
-- The modem transport only carries primitive types, so every wire message is a
-- serialized Lua table; these helpers are the single encode/decode seam.

local serialization = require("serialization")

return function()
  return {
    pack = function(tbl)
      return serialization.serialize(tbl)
    end,
    unpack_msg = function(payload)
      local ok, result = pcall(serialization.unserialize, payload)
      if ok and type(result) == "table" then
        return result
      end
      return nil
    end,
    random_delay = function(min_sec, max_sec)
      return min_sec + math.random() * (max_sec - min_sec)
    end,
  }
end
