# Laptop Reborn

Graphical OpenComputers dashboard for GregTech **lapotronic capacitors,
supercapacitors, and other EU energy-storage blocks**. It replaces the old
text-mode `laptop` program with a coloured, double-buffered panel, keeps the
original redstone telegraph byte-for-byte, and publishes the same telemetry to
Home Assistant over MQTT.

- **Local UI** — single battery panel with percent, bar, stored/capacity,
  passive loss and distance to full or empty; auto-scaled charge trend; power
  flow with comparative bars and a signed NET; corrected time-to-edge panel;
  auto-ranged power history; status column with the raw GT sensor text and a
  window summary.
- **Redstone mirror** — battery bars on `east`, load+ on `up`, load- on `west`,
  refreshed every 0.4 s, with the old blink/pulse math preserved.
- **MQTT + Home Assistant** — eleven discovery entities plus an availability
  topic. Telemetry is OC → HA only in v1; the program never subscribes to
  commands.
- **Resilient runtime** — MQTT lives in its own OpenOS thread, so a broker
  outage or a slow luamqtt download never freezes the UI.

Package: `laptop_reborn` in the `OC-Programs` OPPM repository. Current version
**1.2.0**.

## Screens

Compact, 34×12 (`-x 1x`):

```text
  LAPTOP REBORN    CHARGING  34x12
┌─────────────┐┌─────────────────┐
│BATTERY   85%││POWER FLOW       │
│             ││  IN 98.3 kEU/t  │
│21.1/24.8 GEU││  OUT 57.7 kEU/t │
└─────────────┘│NET   +40.6 kEU/t│
┌─────────────┐│─────────────────│
│TREND   +0.3%││5m    +38.0 kEU/t│
└─────────────┘└─────────────────┘
Filled in 1h 22m│ MAINT OK LAP ON 
POWER HISTORY   25.3 .. 50.0 kEU/t
Q quit R refresh T redstone  RS ON
```

Full, 80×25 (`-x max` or `-x auto` on a tier-2 screen):

```text
  LAPTOP REBORN v1.2.0                                           CHARGING  80x25
┌─────────────────────────┐┌────────────────────────────┐┌─────────────────────┐
│        BATTERY       85%││POWER FLOW                  ││  CHARGING           │
│                         ││  IN 98.3 kEU/t             ││MAINT OK             │
│        21.09/24.84 GEU  ││  OUT 57.7 kEU/t            ││LAPOTRON ONLINE      │
│        LOSS 143.0 EU/t  ││ NET            +40.6 kEU/t ││LINK ONLINE          │
│        3.75 GEU to full ││────────────────────────────││  RS ON              │
│                         ││AVG 5m           +38.0 kEU/t││─────────────────────│
└─────────────────────────┘│AVG 1h           +27.1 kEU/t││GT SENSOR            │
┌─────────────────────────┐│                            ││Time to Full         │
│CHARGE TREND        +0.3%│└────────────────────────────┘│1.45 hours           │
│85.1%│                   │┌────────────────────────────┐│─────────────────────│
│     │                   ││TIME TO EDGE                ││WINDOW 96s           │
│     │                   ││Filled in 1h 22m            ││CHARGE 84.6 .. 84.9% │
│     │                   ││at +38.0 kEU/t (5m)         ││NET 25 .. 50 kEU/t   │
│     │                   │└────────────────────────────┘│                     │
│     │                   │┌────────────────────────────┐│                     │
│     │                   ││POWER HISTORY 25 .. 50 kEU/t││                     │
│     │                   ││                            ││                     │
│     │                   ││                            ││                     │
│     │                   ││                            ││                     │
│     │                   ││                            ││                     │
│84.3%┴                   ││                            ││                     │
└─────────────────────────┘└────────────────────────────┘└─────────────────────┘
Q quit R refresh T redstone                                                RS ON
```

Both dumps are text only: colours, LEDs, filled bars, and the battery sprite
are omitted. The 80×25 layout draws the battery sprite only when the panel has
room; 68×24 is text-only, so its panels never truncate to make space for a
sprite. Other sizes fall back through the `full` / `medium` / `compact` layout
classes: 50×18 keeps the medium two-column arrangement, and 30×10 keeps the
compact header, battery, power, and status rows. A class drops rows rather than
overlapping or drawing outside the screen.

## Features and icons

| Element | Icon | Source |
|---|---|---|
| Battery panel | battery sprite when the panel has room | `theme.COMPILED.battery` |
| Power flow | coloured LEDs, value text, comparative bars | palette |
| Signed NET | colour by sign, `+` prefix when charging | palette |
| Charge trend | auto-scaled filled column chart | palette |
| Power history | auto-ranged column chart; `display.spark` on short panels | palette + `display.spark` |
| Header / footer | mode pill, link LED, rails, RS badge | palette |

Sprites are compiled once at module load and never push panel text out of its
rect. Only the battery sprite is drawn, and only on a panel large enough to
hold it (80×25); smaller classes show the same information as text, bars, and
LEDs.

## Power and edge math

`NET` is the true instantaneous `power_in − power_out` in EU/t: the 5 s GT
averages subtracted, with no unit conversion. Older builds multiplied a filtered
net by 20 to convert EU/t to EU/s and then displayed the result as EU/t, so a
real 40.6 kEU/t read as 562.8 kEU/t. The 20 ticks/s factor now appears only
inside the time-to-edge division.

Time to edge divides the remaining energy (capacity minus stored when charging,
stored when discharging) by a rate in EU/s. The rate is the 5 m average net when
it points the same way as the instantaneous net; otherwise it uses the
instantaneous net. The Kalman filter is gone from this program: `ab_lapotron`
is the only sensor dependency, and the 5 m / 1 h averages come straight from
the GT sensor lines.

## Install

From the OpenComputers shell, with the `OC-Programs` OPPM repository added:

```text
oppm install laptop_reborn
```

This installs:

| File | Installed path |
|---|---|
| `bin/laptop_reborn.lua` | `/bin/laptop_reborn.lua` |
| `rc.d/laptop_reborn.lua` | `/etc/rc.d/laptop_reborn.lua` |
| `lib/laptop_reborn/*.lua` | `/lib/laptop_reborn/` |

Dependency `ab_lapotron` is installed automatically. It is the only package
dependency since 1.2.0; `ab_kalman` was removed. Start it manually:

```text
laptop_reborn
```

Or start it at boot:

```text
rc laptop_reborn enable
reboot
```

The `rc.d` entry clears the terminal and calls `laptop_reborn`; it blocks the
shell until the dashboard exits, which is intentional on a dedicated laptop.

## Prerequisites

| Requirement | Why |
|---|---|
| Internet Card | First run downloads the pinned luamqtt sources into `/lib/mqtt`. |
| OpenOS 1.8.9 (bundled with the GTNH fork) | `thread`, `event`, `buffer`, `filesystem`. |
| Lua 5.3 CPU or `defaultLua53=true` | The package targets Lua 5.3. |
| Broker allow-rule | GTNH OC denies `172.16.0.0/12` by default. |
| Capacitor Adapter / direct link | The capacitor or supercapacitor must be readable through an Adapter or directly. |

## Supported storages

`laptop_reborn` auto-detects the connected storage at startup:

- **Classic lapotronic capacitor** with the 24-line `getSensorInformation()` API
  (handled by `ab_lapotron`). Publishes 5 s / 5 m / 1 h averages and maintenance.
- **GT supercapacitor / energy container** via the compound `gt_machine`
  environment. On GTNH 2.8.4 this exposes both the 24-line sensor API and the
  direct getters (`getEUStored` / `getStoredEU`, `getEUCapacity` /
  `getEUMaxStored`, `getAverageElectricInput`, `getAverageElectricOutput`,
  `getName`, `isMachineActive`). The program prefers the sensor API because it
  carries the true large-number capacity and the 5 m / 1 h averages, then falls
  back to the direct getters automatically if the sensor format is missing or
  cannot be parsed. Direct-only storage still provides charge, in/out/net, edge
  time, and status; 5 m / 1 h averages may be omitted in that fallback.

When several energy blocks are connected, a device whose `getName()` contains
`capacitor` or `lapotron` wins; unrelated 24-line GT machines are ignored. Pin
a specific device with `DEV_LAPOTRON` (the component address) in
`/etc/laptop_reborn.config.lua`.

Allow the broker and the luamqtt download in `config/OpenComputers.cfg`:

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

The broker is `172.16.69.4:1883` from the GTNH container. `127.0.0.1` there is
the container loopback, not the homeserver.

## Home Assistant entities

Discovery prefix `homeassistant`. Node name is `oc_` plus the first eight
alphanumeric characters of the computer address.

| Entity | Component | Topic suffix | Notes |
|---|---|---|---|
| Charge | sensor | `charge/state` | `%`, device class battery, attribute `capacity_total` |
| Stored Energy | sensor | `stored/state` | EU, state class total, attribute `capacity_total` |
| Total Capacity | sensor | `capacity/state` | EU, diagnostic |
| Power In | sensor | `power_in/state` | EU/t |
| Power Out | sensor | `power_out/state` | EU/t |
| Net Power | sensor | `power_net/state` | EU/t, attributes `in_5m`, `out_5m`, `in_1h`, `out_1h`, `net_5m`, `net_1h`, `passive_loss` |
| Time To Edge | sensor | `edge_time/state` | seconds (`device_class: duration`), adaptive quantization, attributes `edge_text`, `percent` |
| Energy Status | sensor | `status/state` | enum, diagnostic, attributes `maintenance`, `state`, `status_text`, `redstone_enabled`, `link` |
| Maintenance | binary_sensor | `maintenance/state` | problem, diagnostic |
| Lapotron Online | binary_sensor | `lapotron_online/state` | connectivity, diagnostic |
| Broker Link | binary_sensor | `link/state` | connectivity, diagnostic |
| Availability | — | `availability` | retained `online` / `offline` |

Discovery payloads are retained QoS 1 and carry `unique_id`,
`default_entity_id`, the shared `device` block, and `origin`.

`Energy Status` is a string enum (`device_class: enum`) with the options
`Charging`, `Discharging`, `Idle`, `Full`, `Empty`, `Maintenance`, `Offline`,
and `Unknown`. The program publishes the matching state; `Unknown` is the
fallback when no valid mode is available. Attribute topics exist for `charge`
and `stored` (both carry `capacity_total`), `power_net` (`in_5m`, `out_5m`,
`in_1h`, `out_1h`, `net_5m`, `net_1h`, `passive_loss`), `edge_time`
(`edge_text`, `percent`), and `status` (`maintenance`, `state`, `status_text`,
`redstone_enabled`, `link`).

### Home Assistant activity

`Energy Status` changes only when the mode transitions, not on every poll. The
raw GT sensor line (for example `Time to Full: 1.45 hours`) is no longer the
entity state; it is published as `status_text` inside the `status` attributes,
next to `state`, `maintenance`, `redstone_enabled`, and `link`. This keeps the
Activity log free of one entry per second.

Numeric states are quantized before publishing so retained entities do not flap:

| Entity | Quantization |
|---|---|
| Charge | whole percent |
| Stored Energy | 0.1% of total capacity |
| Total Capacity | whole EU |
| Power In / Out / Net | two significant digits |
| Time To Edge | adaptive step: 300 s above 20 min, 60 s above 5 min, 15 s above 1 min, 5 s below 1 min |

Attributes use the same quantization. The raw `edge_text` stays a string
attribute.

Publishing is triggered only when the quantized payload changes. `STATE_INTERVAL`
(30 s) is a heartbeat that republishes identical values; those republications do
not create new Home Assistant state changes.

## Topic scheme

```text
gtnh/laptop/<node>/<key>/state        retained state, QoS 1
gtnh/laptop/<node>/<key>/attributes   JSON attributes (power_net, edge_time, status)
gtnh/laptop/<node>/availability       retained "online" / "offline"
homeassistant/<component>/<node>_<key>/config   retained discovery
```

`<key>` is one of `charge`, `stored`, `capacity`, `power_in`, `power_out`,
`power_net`, `edge_time`, `status`, `maintenance`, `lapotron_online`, `link`.
Attribute topics are also published for `charge` and `stored` next to the three
keys listed above. The node also publishes an MQTT Last Will that marks
availability `offline` if the computer loses power.

## Configuration override

`/etc/laptop_reborn.config.lua` survives `oppm update`. It must return a table;
keys merge shallowly over the packaged defaults. A missing, invalid, or
non-table file is ignored and the program keeps the defaults.

```lua
-- /etc/laptop_reborn.config.lua
return {
  BROKER_HOST = "172.16.69.4",
  BROKER_PORT = 1883,
  USERNAME = "",
  PASSWORD = "",
  ENABLE_MQTT = true,
  ENABLE_REDSTONE = true,
  SCALE = "auto",
  THEME = "dark",
  DEV_LAPOTRON = "v_lapotron", -- virtual reader for a dry run
  -- DEV_REDSTONE = "aaaa-bbbb-cccc-dddd",
  POLL_INTERVAL = 1.0,
  LOOP_INTERVAL = 0.4,
  UI_TICK = 2,
  STATE_INTERVAL = 30,
}
```

`-S/--reset-cfg` writes a fresh default table, `-s/--save-cfg` writes the
effective configuration after CLI overrides. Both write through a temporary
file and `os.rename` when the filesystem supports it.

## CLI flags

```text
-h, --help          show help
-r, --redstone      enable the redstone mirror
-R, --no-redstone   disable the redstone mirror
-V, --virtual       use the virtual lapotron device
-c, --config=[path] use a config override file
-S, --reset-cfg     write a fresh config and exit
-s, --save-cfg      write the effective config and exit
-M, --no-mqtt       disable MQTT / Home Assistant telemetry
-x, --scale=[mode]  1x | 2x | max | auto
--version           print the version
--diag              print component API / gt_machine discovery diagnostics
```

Scale presets are 34×12 (`1x`), 68×24 (`2x`), and 80×25 (`max`). `auto`
picks the largest preset that fits the screen. The program never exceeds
80×25 and clamps down to the actual screen size.

## Controls

| Input | Action |
|---|---|
| `Q` / `q` / click Quit | Stop, zero redstone, publish offline, free the buffer |
| `R` / `r` / click Refresh | Republish MQTT discovery |
| `T` / `t` / click Redstone | Toggle the redstone mirror (zeros outputs immediately) |
| `Ctrl+C` | Same clean shutdown as `Q` |

Every action is also available through `ui.handle_click`, so a screen without
a keyboard remains usable. The footer shows the current redstone state.

## Redstone wiring

The mirror reproduces old `laptop` v2.3.0 exactly:

| Signal | Side | Meaning |
|---|---|---|
| Battery bars | `east` | `floor(capacityUsed / 11)`, charging adds a parity bar, empty blinks on the first two of every eight ticks |
| Load + | `up` | Positive `in - out` after the three voltage-scale clamps |
| Load − | `west` | Negative load, absolute value |

Sides are relative to the redstone component. Use a **Redstone I/O block** if
the computer case has no Redstone Card, and wire its `east`, `up`, and `west`
outputs to the receiving machines. The mirror is updated every
`LOOP_INTERVAL` (0.4 s). Pressing `T` or disabling `ENABLE_REDSTONE` writes
zero to all six sides immediately and on shutdown.

If more than one redstone component is connected, set `DEV_REDSTONE` to the
address of the intended one. With no address the program prefers
`component.redstone`.

## Testing

Host tests use injected fakes only; no network or in-game runtime is touched.

```bash
export PATH="$HOME/.local/bin:$PATH"
stylua src/OC-Programs/laptop_reborn tests/laptop_reborn_*_spec.lua
selene src/OC-Programs/laptop_reborn tests/laptop_reborn_*_spec.lua
stylua --check src/OC-Programs/laptop_reborn tests/laptop_reborn_*_spec.lua
busted tests/laptop_reborn_redstone_spec.lua \
       tests/laptop_reborn_app_spec.lua \
       tests/laptop_reborn_bin_spec.lua
```

The full package suite also includes the config, format, lapotron, model,
theme, layout, display, ui, HA, and mqtt_boot specs.

## In-game verification checklist

1. `oppm install laptop_reborn` reports no missing files.
2. `laptop_reborn -V` starts against the virtual lapotron and draws the panel.
3. `laptop_reborn` with the real capacitor or supercapacitor shows charge,
   stored/total EU, in/out/net, edge time, and status.
4. NET equals IN − OUT. It is displayed in EU/t and is not multiplied by 20.
5. Press `T`: the redstone outputs drop to 0 and the footer badge changes.
6. Press `T` again: the telegraph resumes on `east`/`up`/`west`.
7. In HA, the device appears with eleven entities and `Broker Link = ON`.
8. `Energy Status` reads `Charging` (or the current mode), and the Activity log
   does not gain a new entry every second.
9. The `Energy Status` attributes show the raw GT text in `status_text`, for
   example `Time to Full: 1.45 hours`.
10. Unplug the Adapter: the panel shows offline and HA marks
    `Lapotron Online = OFF` without crashing.
11. Press `Q`: redstone returns to 0, availability becomes `offline`, the
    original screen resolution is restored, and the shell returns.
12. Start a second copy: it refuses with an "already running" message.
13. Reboot with `rc laptop_reborn enable`: the dashboard starts before the
    shell and reconnects to the broker.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `no supported capacitor/energy storage` | No component exposes either the 24-line sensor API or the direct EU getters. Check the Adapter/cable, or set `DEV_LAPOTRON` to the component address. Run `laptop_reborn --diag` to see what the program can enumerate. |
| Old `no component API` error persists after `oppm update` | The installed build is stale or an old module was cached in the current shell. `laptop_reborn --version` must report **1.2.0**; if it does not, push/pull the OPPM repo and update again. v1.2.0 clears its own module cache at startup; reboot once if the old `bin` is still loaded. |
| `luamqtt unavailable` / `module 'mqtt' not found` | Internet Card missing, `raw.githubusercontent.com` blocked, or `/lib/mqtt` not writable. The program retries every `MQTT_RETRY` seconds; it never exits. |
| Broker unreachable / `CONNACK` failure | OC filter still denies `172.16.69.4`, Mosquitto listens only on loopback, or the credentials are wrong. The UI keeps running and the link shows `RETRY`/`FAULT`. |
| Back-buffer / VRAM warning | The GPU cannot allocate a full-screen buffer. Lower the scale (`-x 1x`) or use a tier-2 GPU/screen. Without a buffer the display still draws directly. |
| `already running` | Another `laptop_reborn` survived the previous stop. Stop it or reboot once. Two instances would fight over the MQTT client ID and redstone sides. |
| `display lost; stopping` | The screen was removed or another program bound the GPU. The program stops instead of leaving a headless zombie; restart it after restoring the screen. |
| Entities missing in HA | Discovery prefix differs from the MQTT integration, or the broker rejected the retained discovery publish. Press `R` to republish and check the broker log. |
| Entities `unavailable` | No retained `online` on the availability topic. Check the Last Will and the broker connection. |
| Redstone never moves | The component has no `setOutput`, `DEV_REDSTONE` points at the wrong device, or the mirror is toggled off. The footer badge shows the mirror state. |
| Old laptop listeners still fire | Older builds registered global listeners. Reboot the computer once; this build uses `event.pull` only and disposes the lapotron reader on shutdown. |
