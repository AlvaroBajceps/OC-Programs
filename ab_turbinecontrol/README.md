# ab_turbinecontrol

Headless MQTT / Home Assistant controller for four GregTech turbine sets behind
one [`redstone_bridge`](../redstone_bridge) daemon. No screen or GUI is used.

The daemon polls the bridge with `event.pull` for its `changed` broadcasts.
OpenOS does not dispatch `event.listen` handlers registered inside a
`thread.create` thread, so the daemon's loop, discovery, and list queries all
use the thread-safe pull path. MQTT runs in a detached OpenOS thread so broker
outages do not stop redstone processing, and the main loop keeps listening for
modem and command signals while it waits for a bridge reply.

## Install

```text
oppm install ab_turbinecontrol
rc ab_turbinecontrol enable
reboot
```

`ab_luamqtt` and `ab_json` are installed automatically. The daemon needs a
network card for `redstone_bridge` and an Internet Card for MQTT. The bridge
itself must already be running on a computer or microcontroller with a T2
redstone card and a network card:

The HA node is `oc_<address>_turbines`, not the laptop's `oc_<address>`, so the
turbine device is separate from the laptop device in Home Assistant.

```text
oppm install redstone_bridge
rc redstone_bridge enable
```

## Wiring

The redbridge is assumed to face south, so its sides map to:

| Controller cable | Redbridge side | OC side |
|---|---|---:|
| Red | East | 5 (`left`) |
| Lime | North | 2 (`back`) |
| Light Blue | Top | 1 (`top`) |
| Yellow | West | 4 (`right`) |

Inside every controller's bundled cable:

| Signal | Color | Direction |
|---|---|---|
| `EStop` pulse | Grey (7) | write |
| `EStop` latched/critical | Grey (7) | read |
| `Status` (ON = stopped) | Red (14) | read |
| `Reset` pulse | Cyan (9) | write |
| Down `Flow` | Orange (1) | read |
| Down `FlowBoost` | Magenta (2) | read |
| Down `Maintenance` | White (0) | read |
| Up `Flow` | Light Blue (3) | read |
| Up `FlowBoost` | Yellow (4) | read |
| Up `Maintenance` | Black (15) | read |

EStop/Reset pulses use bundled output value `255`, then `0`.

## Configuration

The optional override file is `/etc/ab_turbinecontrol.config.lua`. It must return a
table; keys merge over the packaged defaults.

```lua
-- /etc/ab_turbinecontrol.config.lua
return {
  BROKER_HOST = "172.16.69.4",
  BROKER_PORT = 1883,
  USERNAME = "",
  PASSWORD = "",
  DISCOVERY_PREFIX = "homeassistant",
  BASE_TOPIC = "gtnh/turbines",
  DEVICE_NAME = "GTNH Turbines",
  NODE_SUFFIX = "_turbines",
  ENABLE_MQTT = true,
  KEEP_ALIVE = 30,
  STATE_INTERVAL = 60,
  PUBLISH_INTERVAL = 1,
  IOLOOP_TIMEOUT = 0.5,
  IOLOOP_SLEEP = 0.25,
  PUBLISH_BATCH = 2,
  RESYNC_INTERVAL = 30,
  COMMAND_QUEUE_MAX = 16,
  MQTT_RETRY = 10,
  MQTT_CONNECT_TIMEOUT = 30,
  PULSE_SECONDS = 0.2,
  FULL_POWER = 255,
  LOG_FILE = "/etc/ab_turbinecontrol.log",
}
```

If you override `node`, keep it different from the laptop's `oc_<address>` node;
the default `NODE_SUFFIX = "_turbines"` already does this.

## Sharing the computer with the laptop

One OpenComputers computer is one cooperative Lua VM, and every MQTT socket
read/write and `modem.send` is a normal component call serviced at most once per
server tick. Keep the combined call rate low when the laptop UI and this daemon
share a machine.

The defaults above are chosen for that setup: bridge `changed` events are the
primary state path, a full `list` resync runs every 30 s as a safety net, and a
full MQTT refresh runs every 60 s. Setting `RESYNC_INTERVAL` back to a few
seconds adds bridge traffic without improving normal state freshness.

The matching `laptop` defaults are `ui_refresh = 2`, `lapotron_refresh = 2`,
`redstone_refresh = 1`, `mqtt_publish_interval = 2`, `mqtt_state_interval = 60`,
and `mqtt_publish_batch = 2`. Laptop MQTT is telemetry only; set
`mqtt_enable = false` in the laptop config if its HA entities are not needed.

Allow the broker and the required internet access in `config/OpenComputers.cfg`:

```hocon
opencomputers {
  internet {
    filteringRules = [
      "allow ip:172.16.69.4"
      "allow default"
    ]
  }
}
```

## Home Assistant entities

One HA device is created under the base topic `gtnh/turbines/<node>`, with
per-set entities:

| Entity | Component | Topic suffix | Meaning |
|---|---|---|---|
| Turbine N <cable> | switch | `turbine_N/state` | `ON` = running, `OFF` = stopped; command `turbine_N/set` |
| Turbine N EStop | binary_sensor | `turbine_N/estop/state` | `ON` = EStop requested / critical fault |
| Turbine N Bank Up | sensor | `turbine_N/bank_up/state` | `Nominal`, `Fault`, `Overflow`, `Idle`, `Unknown` |
| Turbine N Bank Down | sensor | `turbine_N/bank_down/state` | same |
| Broker Link | binary_sensor | `link/state` | `ONLINE` / `OFFLINE` |
| Availability | — | `availability` | retained `online` / `offline` |

Switch commands:

- `ON` → pulse **Reset** (cyan) to start the turbine,
- `OFF` → pulse **EStop** (grey) to stop it.

Discovery configs are retained QoS 1 under
`homeassistant/<component>/<node>_<suffix>/config`.

## Cleaning old merged entities

Older builds used the laptop's `oc_<address>` node, so HA merged the turbine
entities into the laptop device. Update, stop the old daemon, clean the old
topics, then start the new node:

```text
oppm update ab_turbinecontrol
rc ab_turbinecontrol stop
ab_turbinecontrol_cleanup
rc ab_turbinecontrol start
```

The cleanup script defaults to the current computer's old laptop node. Pass an
explicit old node if needed:

```text
ab_turbinecontrol_cleanup oc_1a2b3c4d
```

It removes only the turbine switch, EStop, bank, availability and old turbine
state topics. It deliberately leaves the laptop's `..._link` discovery topic
alone; restart or reconnect the laptop afterwards so it republishes its own
Broker Link entity.

## Service control

```text
rc ab_turbinecontrol start
rc ab_turbinecontrol stop
rc ab_turbinecontrol enable
rc ab_turbinecontrol disable
```

`rc.d/ab_turbinecontrol.lua` starts the daemon in an OpenOS background thread, so rc
continues booting while the daemon runs. Logs go to `/etc/ab_turbinecontrol.log`.

## Notes

- Switch commands always pulse Reset/EStop; the cached status is not used to
  suppress them, so a stale state cannot swallow an HA command.
- Red status is authoritative: `ON` means stopped. It drives the HA switch
  state and the overall stopped state.
- Grey is the EStop request/critical-fault line; it is also the pulse used to
  request EStop.
- `Maintenance` has priority over `FlowBoost` for bank state:
  `Fault` > `Overflow` > `Nominal` > `Idle`.
- The daemon does not modify turbine wiring; it only reads diagnostics and
  pulses EStop/Reset.
