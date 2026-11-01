# ab_json

Small deterministic JSON encoder for OpenComputers, used by
`ab_turbinecontrol`.

```lua
local json = require("ab_json")
print(json.encode({ hello = "world", count = 3 }))
-- {"count":3,"hello":"world"}
```

Arrays are tables with a positive `#value`; other tables are objects and must
have string keys. Object keys are sorted for stable output. Non-finite numbers
encode as `null`.

API:

- `json.encode(value)` / `json.json_encode(value)`

No decoder is included; this package covers the encoder needed for MQTT and
Home Assistant discovery payloads.
