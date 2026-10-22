# MQTT / Home Assistant industrial panel

`mqtt_ha` is an OpenComputers control panel package that proves the whole
MQTT chain end to end:

- downloads pinned [`xHasKx/luamqtt`](https://github.com/xHasKx/luamqtt) sources
  into `/lib/mqtt` on first run (MIT, commit
  `14ad9be4c327972be68726d3c796c781eb4cc542`);
- connects to Mosquitto at `172.16.69.4:1883` over plaintext TCP;
- exposes **one** bidirectional control to Home Assistant and **one**
  diagnostic link sensor;
- publishes retained availability (`online` / `offline`) with an MQTT Last Will;
- rubs out the old test entities from earlier versions (retained discovery
  cleanup);
- draws a double-buffered industrial HMI on the OC screen using the same
  `display.lua` renderer as the AE2 teleporter.

Use it to verify the chain before building a real control program.

## Files

| Package file | Installed path | Purpose |
|---|---|---|
| `bin/mqtt_ha.lua` | `/bin/mqtt_ha.lua` | MQTT client, discovery, control panel |
| `rc.d/mqtt_ha.lua` | `/etc/rc.d/mqtt_ha.lua` | Boot entrypoint: clears the terminal and starts the panel |
| `lib/mqtt_ha/display.lua` | `/lib/mqtt_ha/display.lua` | Double-buffered GPU renderer shared with the teleporter |

The renderer is a variant of
`src/OC-Programs/teleporter/lib/teleporter/display.lua` with a backward-compatible
double-line box style and a `draw_text` helper. It binds the screen, allocates a
VRAM back-buffer, and flips the finished frame with one `bitblt`, so the panel
does not tear or flicker. The program requires it as `mqtt_ha.display`; without
it the program still runs, using a compact built-in panel.

## What appears in Home Assistant

| Entity | Type | Purpose |
|---|---|---|
| `light.oc_<node>_lamp` | light | **Panel Lamp**. Main control. HA → OC command, OC → HA state. |
| `binary_sensor.oc_<node>_link` | binary sensor | **Broker Link**. `ONLINE` / `OFFLINE`, `device_class: connectivity`, diagnostic category. |
| `select.oc_<node>_restart_mode` | select | **Restart Mode**. `off` / `on` / `keep_state`, config category. Sets what the lamp does on the next program or computer restart. |

The light uses `mdi:ceiling-light`; the link sensor uses `mdi:lan-connect`; the
restart select uses `mdi:restart`. Discovery is retained, has `unique_id`,
`default_entity_id`, a shared `device` block, and `origin`. The device page is
named `GTNH Industrial Panel oc_<node>` with model `Industrial HMI`.

Restart Mode semantics:

- `off` forces the lamp OFF at boot.
- `on` forces the lamp ON at boot.
- `keep_state` restores the last persisted lamp value (the default).

Changing the mode only affects the **next** boot; it does not change the current
lamp immediately. A boot in `off` or `on` mode records the forced value as the
last lamp state, so a later `keep_state` boot restores that value rather than
the lamp from before the forced boot.

## Local state file

The program stores the policy and the last lamp value in
`/etc/mqtt_ha.state`:

```text
# restart_mode=off|on|keep_state; last_lamp is used only by keep_state
restart_mode=keep_state
last_lamp=on
```

`restart_mode` is the boot policy and wins at startup. `last_lamp` is only the
last lamp value; it is used **only** when `restart_mode=keep_state`. So a file
with `restart_mode=on` and `last_lamp=off` starts with the lamp **ON**, and a
file with `restart_mode=off` and `last_lamp=on` starts **OFF**. When a forced
mode changes the lamp at boot, the new value is written back as `last_lamp`.

The file is written on every lamp change, every mode change, every applied HA
command, on shutdown/interrupt, and periodically, so the panel survives a
program or computer restart.

Deleting the file resets the panel: the first boot lands OFF with
`restart_mode=keep_state` (there is no saved lamp value to restore). Files from
2.1.0 using `lamp=` instead of `last_lamp=` are still read correctly.

## Diagnosing a state mismatch

If the lamp comes back differently from what you expect, inspect
`/etc/mqtt_ha.state` directly:

1. If `last_lamp` is stale, the last save failed or the program was killed
   before the change was saved; check the event log for `state save failed`.
2. If the file is correct but the boot state differs, `restart_mode` forced the
   value (`on`/`off`), or a stale retained command was ignored.
3. If starting the program prints `already running`, another instance survived
   the previous stop. Stop it with `Q` / the footer hint, or reboot the computer
   once. Multiple instances fight over the same MQTT client ID and state file.
4. If the state file changes while the program is stopped, an **older build's
   global event listener is still active**. OpenOS event listeners are shared by
   the whole Lua state and older versions did not unregister them on exit. Reboot
   the computer once after installing 2.1.3; the current build de-registers its
   listeners on shutdown and ignores callbacks once its owning process is gone.

The old `switch.oc_<node>_button`, `button.oc_<node>_toggle`, and
`light.oc_<node>_bulb` entities are intentionally gone. On every connect the
program publishes empty retained payloads to their discovery topics and old
state topics, so HA removes them. There is no separate "test button" and no
press-only toggle: the lamp is the control, in both directions.

If HA still shows the old entities after the first run, wait for the MQTT
integration to process the retained deletions, then reload
**Settings → Devices & Services → MQTT**. A HA restart also clears them.

## On-screen UI

The panel is an industrial control cabinet:

- double-line chassis, steel borders, amber hazard stripe, status LEDs;
- a large block-art output lamp (yellow when on, dark when off) with a power
  bar and an `OUTPUT LAMP : ON/OFF` nameplate;
- a big `BREAKER` button that shows `ON` / `OFF` and turns green when live; its
  panel title also shows the restart mode as `BREAKER // <MODE>`;
- a `TELEMETRY` panel (broker, link status, lamp, restart mode, uptime, RX/TX,
  last command, error, topic, keepalive);
- an `EVENT LOG` panel with colour-coded `SYS` / `HA` / `OC` / `ERR` lines;
- a footer with key hints.

Controls:

| Input | Action |
|---|---|
| Click the lamp panel | Toggle the lamp |
| Click the breaker | Toggle the lamp |
| **Space** / **Enter** | Toggle the lamp |
| **M** | Cycle the restart mode (`off` → `on` → `keep_state`) |
| **R** | Republish discovery (retained) |
| **Q** / **Ctrl+C** | Publish `offline`, free the back-buffer, exit |

Every on-screen control is also clickable: the lamp panel, the breaker, and the
`[M]` / `[R]` / `[Q]` footer hints. Keyboard shortcuts require a keyboard
component attached to the same computer and the player within 8 blocks of it;
if keys do nothing, use the click targets.

The current lamp and restart mode are saved to disk on every change, on
Ctrl+C/`Q`, and every state interval. Saves are written to a temporary file and
renamed into place, so interrupting the program cannot leave a truncated state
file.

The OC → HA path updates the screen immediately (optimistic), then publishes
`ON` / `OFF` to `gtnh/oc/<node>/lamp/state` at QoS 1, retained. HA → OC updates
the same state and echoes it back. The header `LINK` LED is green when the
broker link is up; `ACT` lights for five seconds after traffic.

A tier-2 screen (80×25) uses the normal two-column layout. A tier-3 screen
(160×50) scales the lamp sprite to 2× and shows the full telemetry set. Narrow
screens fall back to a single-column layout; the compact panel shows the mode in
the breaker title, and the minimal panel shows a `MODE  <mode>` line. If no
GPU/back-buffer is available the program runs headless and logs to the console.

## 1. Broker

From the GTNH container, the broker is `172.16.69.4:1883`; from the homeserver
host it is `127.0.0.1:1883`. Do not use `127.0.0.1` from OC: that is the GTNH
container's loopback, not the host.

### Quick test: anonymous broker

For a first test on the private `gtnh-network`, set the mounted
`/var/opt/docker/gtnh/ha/mosquitto/mosquitto.conf` to:

```conf
listener 1883 0.0.0.0
allow_anonymous true
persistence true
persistence_location /mosquitto/data/
log_dest stdout
```

Then restart the broker:

```bash
docker compose -f /var/opt/docker/gtnh/ha/compose.yml restart gtnh_mosquitto
```

The example ships with empty `username` / `password`, so it works with this
profile.

### Recommended: authenticated broker

Switch to a password file after the first successful test:

```conf
listener 1883 0.0.0.0
allow_anonymous false
password_file /mosquitto/config/passwd
persistence true
persistence_location /mosquitto/data/
log_dest stdout
```

Create users:

```bash
docker exec -it gtnh_mosquitto mosquitto_passwd -c /mosquitto/config/passwd oc
docker exec -it gtnh_mosquitto mosquitto_passwd -b /mosquitto/config/passwd homeassistant 'change-me'
docker exec -it gtnh_mosquitto chown mosquitto:mosquitto /mosquitto/config/passwd
docker compose -f /var/opt/docker/gtnh/ha/compose.yml restart gtnh_mosquitto
```

Then set `username = "oc"` and `password = "..."` in `M.CONFIG` and configure the
HA integration with the `homeassistant` credentials.

`src/OC-Programs/mqtt_ha/mosquitto.conf.example` contains the authenticated profile.

## 2. Home Assistant

1. Open `http://172.16.69.3:8123` from the GTNH network, or
   `http://127.0.0.1:8123` from the homeserver host.
2. **Settings → Devices & Services → Add Integration → MQTT**.
3. Broker: `172.16.69.4` (or `gtnh_mosquitto`).
4. Port: `1883`.
5. Username/password: leave blank for anonymous, or use the broker credentials.
6. Leave the discovery prefix at `homeassistant` unless you change
   `M.CONFIG.discovery_prefix` too.

No YAML is required; the example uses MQTT discovery. The auto-generated
**Controls** card now shows one entity, **Panel Lamp**. **Broker Link** appears
under the device's diagnostic entities.

## 3. Allow the broker in OpenComputers

GTNH's default OC internet filter denies `172.16.0.0/12`. In the server's
`config/OpenComputers.cfg` (or the GTNH equivalent), allow the broker IP:

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

Restart the server after editing. `allow default` also lets the first-run
luamqtt download reach `raw.githubusercontent.com`. Add `ip:172.16.69.3` only if
you later use HA's HTTP API.

## 4. Install on the OC computer

Install the package with OPPM:

```text
oppm install mqtt_ha
mqtt_ha
```

The manifest installs `/bin/mqtt_ha.lua`, `/etc/rc.d/mqtt_ha.lua`, and
`/lib/mqtt_ha/display.lua`, so `require("mqtt_ha.display")` resolves without any
extra `package.path` setup. The rc.d entry clears the terminal and starts the
panel at boot. If the package repository is not registered yet, add this
OC-Programs repo to OPPM first (see its README).

The first run creates `/lib/mqtt/` and downloads the ten luamqtt modules. Later
runs reuse them. The display library is installed with the package and is not
downloaded at runtime.

## 5. Verify

Expected OC console output before the UI takes over:

```text
Installing luamqtt into /lib/mqtt
  init.lua
  ...
MQTT HA panel running headless; press Ctrl+C to stop
```

The install lines are cleared when the panel draws. With a working screen the
program does not print after taking over the display; the footer shows the
controls instead.

In HA:

1. Open **Settings → Devices & Services → MQTT** (or the entity list).
2. Find `GTNH Industrial Panel oc_<addr>`.
3. Click the breaker or the lamp on the OC screen. `Panel Lamp` flips in HA
   within a fraction of a second, and the OC lamp/telemetry redraw.
4. Toggle `Panel Lamp` in HA. The OC lamp, breaker, telemetry, and event log
   update.
5. Check `Broker Link` shows `ONLINE` while OC is connected.
6. Test persistence: set `Restart Mode` to `on` in HA, press **Q** (or stop the
   program), then start it again. The lamp comes back ON. Repeat with `off` to
   confirm it stays OFF at boot, and with `keep_state` to confirm the last lamp
   value is restored.
7. Press **Q** or **Ctrl+C**. OC publishes retained `offline`, frees the
   back-buffer, and returns to the shell. The link sensor becomes unavailable.

If the entities do not appear, see the troubleshooting section below.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `connect timeout` / `connection refused` | OC filter still denies `172.16.69.4`, or Mosquitto listens only on `127.0.0.1`. Use `listener 1883 0.0.0.0`. |
| `CONNACK rc=5` / not authorized | Broker requires auth; fill `M.CONFIG.username/password` or allow anonymous for the test. |
| TCP connects, then closes | Wrong broker port, or a TLS-only listener. OC raw TCP is plaintext; use `1883`, not `8883`. |
| `Display unavailable: display library not found` | Reinstall the package so `/lib/mqtt_ha/display.lua` exists. The compact fallback still works. |
| `GPU does not have enough VRAM for a back-buffer` | Use a tier-2 or tier-3 GPU/screen, or lower the screen resolution. The program falls back to the compact panel. |
| Old `OC Test Bulb` / `OC Test Button` / `OC Toggle Button` still visible | The retained cleanup runs on connect. Reload the MQTT integration or restart HA; check that OC reached `connect` (see the event log). |
| Entities missing in HA | Discovery config not retained, `unique_id` missing, or HA MQTT integration uses a different discovery prefix. Check the OC event log for `discovery published` / `discovery failed`. |
| Entities show `unavailable` | Availability topic has no retained `online`; check `gtnh/oc/<node>/availability` and `Broker Link`. |
| Commands do nothing | Subscription failed, wrong `base_topic`, or HA published to a different `command_topic`. The log shows `HA lamp on/off` when a command arrives. |
| Screen flickers or tears | `mqtt_ha.display` is missing and the fallback is redrawing directly; reinstall the package to get the back-buffer. |
| Script stops when the chunk unloads | OC pauses with the chunk; the broker drops the keepalive. The client reconnects on resume; discovery and state are republished on `connect`. |
| `state save failed` in the event log | `/etc` is not writable, the filesystem is missing, or the disk is full. The program retries via a direct write, but if that also fails the lamp and restart mode will not survive a restart. |
| `already running; refusing to start` | Another copy of the program is still alive, usually because Ctrl+C did not end the previous one. Stop it with `Q` / the footer hint, or reboot the computer once. |
| Lamp state changes by itself after a restart | Compare `/etc/mqtt_ha.state` with the screen. A retained command being ignored is logged as `ignored retained command`; a forced boot is logged as `restart mode forced lamp on/off`. If neither appears, look for a second instance or an HA automation publishing `lamp/set`. |
| State file changes while the program is stopped | An older build left global `key_down` / `interrupted` listeners registered in the shell's Lua state. Reboot the computer once; 2.1.3 unregisters its listeners and ignores callbacks after its process dies. |
| Keybinds (`M` / `R` / `Q` / Space) do nothing | No keyboard component attached to this computer, the player is farther than 8 blocks from the keyboard, or the screen does not have keyboard focus. All controls are clickable; use the lamp, breaker, and footer hints. |
| Ctrl+C does not exit | Use **Q** or click `[Q/^C]` in the footer. Plain Ctrl+C is delivered as an OC `interrupted` event; Ctrl+Alt+C hard-kills the process and bypasses screen cleanup. Keep `sleep > 0` in `M.ioloop_options` (`0.05`) so interrupts are pumped. |
| `module 'mqtt' not found` | The bootstrap download failed. Check the Internet Card and `raw.githubusercontent.com` access; the files must exist under `/lib/mqtt/`. |

## Notes

- `luamqtt` is downloaded at runtime, not committed to this repo. The download is
  pinned to a commit for reproducibility.
- `lib/mqtt_ha/display.lua` is shipped with the package because the teleporter
  library is in a separate package and is not installed by default.
- OC raw TCP has no TLS. Keep MQTT on the private Docker network and do not
  publish `1883` publicly.
- The example uses `clean = true`; commands sent while OC is offline are not
  queued. For production controls, decide whether you want a durable session
  (stale commands) or clean sessions (lost commands) and add command IDs plus
  `message_expiry_interval`.
- State and availability are retained; discovery configs are retained. This is
  intentional so HA recovers after a restart. Delete retained configs with an
  empty retained publish when decommissioning the computer.
- Commands received with the MQTT retain flag set are ignored. HA publishes
  commands non-retained (`retain = false` in discovery), so a stale retained
  `lamp/set` or `restart_mode/set` message cannot flip the panel at boot.
- Starting a second copy while one is still in OpenOS's process list is refused,
  so two instances cannot alternate writes to the state file or fight over the
  same MQTT client ID.
- Local persistence to `/etc/mqtt_ha.state` is intentional alongside the
  retained MQTT state. MQTT retention restores what HA displays; the local file
  restores the panel lamp and restart policy even if the broker loses its
  retained messages or OC boots before the broker is reachable.
- State writes use a temp file plus `os.rename` when the filesystem supports it,
  with a direct-write fallback. On the normal atomic path, a hard kill during a
  save leaves a complete state file instead of a truncated one.
