# Laptop Reborn

Graphical OpenComputers dashboard for a GregTech **Lapotronic Capacitor**. It
replaces the old text-mode `laptop` program with a coloured, double-buffered
panel, keeps the original redstone telegraph byte-for-byte, and publishes the
same telemetry to Home Assistant over MQTT.

- **Local UI** — battery gauge, in/out/net power, time to full/empty, GT energy
  status, maintenance flag, lapotron online state, sparkline history.
- **Redstone mirror** — battery bars on `east`, load+ on `up`, load- on `west`,
  refreshed every 0.4 s, with the old blink/pulse math preserved.
- **MQTT + Home Assistant** — eleven discovery entities plus an availability
  topic. Telemetry is OC → HA only in v1; the program never subscribes to
  commands.
- **Resilient runtime** — MQTT lives in its own OpenOS thread, so a broker
  outage or a slow luamqtt download never freezes the UI.

Package: `laptop_reborn` in the `OC-Programs` OPPM repository.

## Screens

Compact, 34×12 (`-x 1x`):

```text
  LAPTOP REBORN       ONLINE 34x12
┌─────────────┐┌─────────────────┐
│  BATTERY    ││POWER FLOW       │
│  61%        ││  IN 119.6 kEU/t │
│  11.8G/19.4G││  OUT 117.0 kEU/t│
└─────────────┘│  NET 2.6 kEU/t  │
┌─────────────┐│AVG 5m           │
│             ││  IN 120.2 kEU/t │
└─────────────┘└─────────────────┘
Filled in 1.76d  MAINT OK LAP ON
HIST
Q quit R refresh T redstone  RS ON
```

Full, 80×25 (`-x max` or `-x auto` on a tier-2 screen):

```text
  LAPTOP REBORN v1.0.0                                              ONLINE 80x25
┌────────────────────────┐┌─────────────────────────┐┌─────────────────────────┐
│        BATTERY         ││POWER FLOW               ││        MAINT OK         │
│        61%             ││  IN 119.6 kEU/t         ││        LAPOTRON ONLINE  │
│        11.78/19.44 GEU ││  OUT 117.0 kEU/t        ││          RS ON          │
│        CAP 19.44 GEU   ││  NET 2.6 kEU/t          ││        Running normally │
│        LOSS 112.0 EU/t ││AVG 5m                   ││        LINK ONLINE      │
│                        ││  IN 120.2 kEU/t         ││        CAP 19.44 GEU    │
│                        ││  OUT 112.4 kEU/t        ││        PANEL v1.0.0     │
└────────────────────────┘│AVG 1h                   ││        SCALE 80x25      │
┌────────────────────────┐│  IN 120.2 kEU/t         ││                         │
│CHARGE         61%      ││  OUT 112.4 kEU/t        ││                         │
│                        │└─────────────────────────┘│                         │
│                        │┌─────────────────────────┐│                         │
│11.78/19.44 GEU         ││EDGE TIME                ││                         │
│LOSS 112.0 EU/t         ││Filled in 1.76d          ││                         │
│CHARGE HISTORY          │└─────────────────────────┘│                         │
│                        │┌─────────────────────────┐│                         │
│                        ││POWER HISTORY            ││                         │
│                        ││                         ││                         │
│                        ││                         ││                         │
│                        ││                         ││                         │
│                        ││                         ││                         │
└────────────────────────┘└─────────────────────────┘└─────────────────────────┘
Q quit R refresh T redstone                                    LINK ONLINE RS ON
```

The exact layout degrades through `compact` / `medium` / `full` classes; it
never overlaps or draws outside the screen.

## Features and icons

| Element | Icon | Source |
|---|---|---|
| Battery panel | battery sprite | `theme.COMPILED.battery` |
| Gauge flow direction | arrow_up / arrow_down / transfer sprite | `theme.COMPILED` |
| Edge time | clock sprite when it fits, LED fallback | `theme.COMPILED.clock` |
| Maintenance | wrench / warning sprite | `theme.COMPILED` |
| Power in / out / net | coloured status LEDs + text | palette |
| Header / footer | coloured link LED, rails, RS badge | palette |
| Sparklines | coloured cell bars (no glyphs) | `display.spark` |

Sprites are compiled once at module load; each is at most 7×7 cells so the
compact layout still has room for text. A sprite is only drawn when its panel
is tall enough; otherwise the same information is shown with a coloured LED.

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

Dependencies `ab_lapotron` and `ab_kalman` are installed automatically. Start
it manually:

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
| Lapotron Adapter | The capacitor must be readable through an Adapter or directly. |

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
| Charge | sensor | `charge/state` | `%`, device class battery |
| Stored Energy | sensor | `stored/state` | EU, total |
| Total Capacity | sensor | `capacity/state` | EU, diagnostic |
| Power In | sensor | `power_in/state` | EU/t |
| Power Out | sensor | `power_out/state` | EU/t |
| Net Power | sensor | `power_net/state` | EU/t, attributes |
| Time To Edge | sensor | `edge_time/state` | seconds, duration, attributes |
| Energy Status | sensor | `status/state` | diagnostic, attributes |
| Maintenance | binary_sensor | `maintenance/state` | problem, diagnostic |
| Lapotron Online | binary_sensor | `lapotron_online/state` | connectivity, diagnostic |
| Broker Link | binary_sensor | `link/state` | connectivity, diagnostic |
| Availability | — | `availability` | retained `online` / `offline` |

Discovery payloads are retained QoS 1 and carry `unique_id`,
`default_entity_id`, the shared `device` block, and `origin`. Attribute topics
exist for `charge` / `stored` (total capacity), `power_net` (5 m/1 h averages,
filtered net, passive loss), `edge_time` (edge text, percent), and `status`
(maintenance, status text, redstone state, link).

## Topic scheme

```text
gtnh/laptop/<node>/<key>/state        retained state, QoS 1
gtnh/laptop/<node>/<key>/attributes   JSON attributes (power_net, edge_time, status)
gtnh/laptop/<node>/availability       retained "online" / "offline"
homeassistant/<component>/<node>_<key>/config   retained discovery
```

`<key>` is one of `charge`, `stored`, `capacity`, `power_in`, `power_out`,
`power_net`, `edge_time`, `status`, `maintenance`, `lapotron_online`, `link`.
The node also publishes an MQTT Last Will that marks availability `offline` if
the computer loses power.

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

The full package suite also includes the config, format, model, theme, layout,
display, HA, and mqtt_boot specs.

## In-game verification checklist

1. `oppm install laptop_reborn` reports no missing files.
2. `laptop_reborn -V` starts against the virtual lapotron and draws the panel.
3. `laptop_reborn` with the real capacitor shows charge, stored/total EU,
   in/out/net, edge time, and status.
4. Press `T`: the redstone outputs drop to 0 and the footer badge changes.
5. Press `T` again: the telegraph resumes on `east`/`up`/`west`.
6. In HA, the device appears with eleven entities and `Broker Link = ON`.
7. Unplug the Adapter: the panel shows offline and HA marks
   `Lapotron Online = OFF` without crashing.
8. Press `Q`: redstone returns to 0, availability becomes `offline`, the
   original screen resolution is restored, and the shell returns.
9. Start a second copy: it refuses with an "already running" message.
10. Reboot with `rc laptop_reborn enable`: the dashboard starts before the
    shell and reconnects to the broker.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `luamqtt unavailable` / `module 'mqtt' not found` | Internet Card missing, `raw.githubusercontent.com` blocked, or `/lib/mqtt` not writable. The program retries every `MQTT_RETRY` seconds; it never exits. |
| Broker unreachable / `CONNACK` failure | OC filter still denies `172.16.69.4`, Mosquitto listens only on loopback, or the credentials are wrong. The UI keeps running and the link shows `RETRY`/`FAULT`. |
| Back-buffer / VRAM warning | The GPU cannot allocate a full-screen buffer. Lower the scale (`-x 1x`) or use a tier-2 GPU/screen. Without a buffer the display still draws directly. |
| `already running` | Another `laptop_reborn` survived the previous stop. Stop it or reboot once. Two instances would fight over the MQTT client ID and redstone sides. |
| `display lost; stopping` | The screen was removed or another program bound the GPU. The program stops instead of leaving a headless zombie; restart it after restoring the screen. |
| Entities missing in HA | Discovery prefix differs from the MQTT integration, or the broker rejected the retained discovery publish. Press `R` to republish and check the broker log. |
| Entities `unavailable` | No retained `online` on the availability topic. Check the Last Will and the broker connection. |
| Redstone never moves | The component has no `setOutput`, `DEV_REDSTONE` points at the wrong device, or the mirror is toggled off. The footer badge shows the mirror state. |
| Old laptop listeners still fire | Older builds registered global listeners. Reboot the computer once; this build uses `event.pull` only and disposes the lapotron reader on shutdown. |
