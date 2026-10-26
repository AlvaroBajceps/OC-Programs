# anchor_ctl

Headless OpenComputers daemon that drives a Railcraft **World Anchor** (chunk
loader) and reports a Computronics **drawer** (ender pearl buffer) to Home
Assistant over MQTT. All control is HA-only; the computer needs no screen,
keyboard, or GPU at runtime.

- Switch **Chunkloading** — toggles the anchor by driving the computer's
  bottom redstone side into a redstone conduit.
- Select **Boot Mode** — `on`, `off`, or `keep_state` policy for the next boot.
- Sensors for anchor status, fuel, drawer pearls, deployment metadata, broker
  link, and a problem flag with reasons.

Package: `anchor_ctl` in the `OC-Programs` OPPM repository.

## Why a microcontroller is not feasible

A microcontroller (MCU) cannot run this daemon:

- **EEPROM size.** GTNH's EEPROM code limit is **4096 bytes**. The pinned
  luamqtt build is **163,541 bytes across 10 files**; it cannot be embedded in
  EEPROM, and the MCU has no `require`, `package.path`, or filesystem to load
  external Lua modules.
- **No component bus.** An MCU only reaches components attached to its own
  internal slots. The World Anchor and the Computronics drawer sit in the
  world behind an **Adapter** on the component network; an MCU cannot see them.
- **No room for the client.** Even though an MCU Tier 2 has two card slots
  (Tier 2 + Tier 1), so an Internet Card and a Redstone Card fit, the 4096-byte
  EEPROM cannot hold an MQTT client, the HA discovery payloads, and the
  control logic. It also has no filesystem for `/lib/mqtt`, persisted state, or
  logs.

Use a full computer.

## Minimal computer

| Part | Qty | Notes |
|---|---|---|
| Computer Case Tier 2 | 1 | Required: one Tier-2 card slot and one Tier-1 card slot. A Tier-1 case cannot take the Internet Card (Tier 2). |
| CPU Tier 2 | 1 | 12 components; a CPU Tier 1 also works (8 components) |
| Memory (Tier 2.5) | 2 | The `oc:ram4` item, 512 KiB each = **1 MiB apparent**; GTNH `ramSizes` are 192/256/384/512/768/1024 KiB |
| HDD Tier 2 | 1 | 2 MB; OpenOS is ~0.4 MB raw and luamqtt ~164 KB, so this leaves comfortable headroom |
| EEPROM (Lua BIOS) | 1 | Standard Lua BIOS |
| Internet Card | 1 | One item, driver tier 2; must go in the **Tier-2** card slot |
| Redstone Card (Tier 1) | 1 | The plain Redstone Card; goes in the **Tier-1** card slot |
| Adapter + OC cable | 1 + cable | Adapter must touch both the World Anchor and the drawer |
| Power | — | Any OC-compatible power source |

A GPU, screen, and keyboard are needed **only** for the initial OpenOS install
and `oppm install`. The daemon is headless, and `rc.d` starts before the shell,
so those parts can be removed afterward. If you want no display at any point,
install OpenOS and this package on the HDD in a temporary computer, then move
the HDD into the headless case.

## Wiring

```
computer bottom face
      |
redstone conduit / redstone dust run
      |
all World Anchors in the chunkloading group
```

- `ENABLED_LEVEL = 0` (LOW) means **chunkloading ON**.
- `DISABLED_LEVEL = 15` (HIGH) means **chunkloading disabled**.

**Fail-safe warning.** A removed or broken computer lets the conduit default to
signal 0, which means chunkloading **ON**. If that failure mode is
unacceptable, set `ENABLED_LEVEL` / `DISABLED_LEVEL` in the config to invert the
polarity and rebuild the wiring accordingly.

OpenComputers persists redstone output in the computer NBT
(`RedstoneAware.rs.output`) across reboots, so the daemon's boot sequence reads
the real anchor at startup instead of trusting the saved output. If the
**computer** is broken or replaced, that persisted output resets to 0, and the
daemon reconciles from the anchor's actual `isDisabled()` state on the next
poll.

## Component facts

- The World Anchor component is **`anchor`**. There is no `world_anchor`
  component name. The relevant method is `isDisabled()`.
- The drawer is Computronics **`drawer`**. Slots are **1-based**:
  `getItemCount(1)`, `getItemName(1)` returns `item.enderPearl`, and
  `getMaxCapacity(1)` returns `4096`.
- `slot = -1` on a component object is the adapter base-component slot, not an
  aggregate sentinel. Do not read `-1` to total a multi-slot drawer; sum slots
  `1..getDrawerCount()`.

## Deployment configuration

Edit the `DEPLOYMENT` block and the broker/wiring constants at the top of
`lib/anchor_ctl/config.lua`:

- Source tree: `src/OC-Programs/anchor_ctl/lib/anchor_ctl/config.lua`
- Installed computer: `/lib/anchor_ctl/config.lua` (overwritten by
  `oppm update` — for machine-specific values use the override file below)

```lua
local DEPLOYMENT = {
  DIMENSION_ID = 0,
  DIMENSION_NAME = "Overworld",
  CHUNKS_CHUNKLOADED = 0,
}
```

Also confirm:

- `BROKER_HOST` / `BROKER_PORT` (default `172.16.69.4:1883`).
- `ENABLED_LEVEL` / `DISABLED_LEVEL` and `REDSTONE_SIDE` (default bottom = 0).
- `ANCHOR_ADDRESS` / `DRAWER_ADDRESS` when more than one of either component is
  on the network.
- `DRAWER_SLOT` when the drawer has a single slot but the pearls are not in
  slot 1.

### Per-machine overrides that survive `oppm update`

`lib/anchor_ctl/config.lua` is shipped by the package, so `oppm update` replaces
it. Put machine-specific values in `/etc/anchor_ctl.config.lua` instead. The
daemon loads that file at startup, merges its keys over the packaged defaults,
and never overwrites it. `DEPLOYMENT` is merged field by field, and the
`deployment_name` plus the Home Assistant device name follow the effective
dimension.

```lua
-- /etc/anchor_ctl.config.lua
return {
  DEPLOYMENT = {
    DIMENSION_ID = -1,
    DIMENSION_NAME = "Nether",
    CHUNKS_CHUNKLOADED = 0,
  },
  -- Any top-level cfg key can be overridden, for example:
  -- BROKER_HOST = "172.16.69.4",
  -- REDSTONE_SIDE = 0,
  -- ANCHOR_ADDRESS = "aaaa-bbbb-cccc-dddd",
}
```

A missing file is ignored. A file that cannot be loaded, raises, or does not
return a table is logged to `/etc/anchor_ctl.log` and the daemon continues with
the packaged defaults. Restart the daemon (or reboot) after editing.
`/etc/anchor_ctl.state` holds the runtime boot mode and is not a config
override.

Install from the `OC-Programs` OPPM repository:

```
oppm install anchor_ctl
rc anchor_ctl enable
reboot
```

`rc.d/anchor_ctl.lua` calls `os.execute("anchor_ctl")`, so it **blocks boot
completion by design** on a dedicated headless computer. That is intentional:
the anchor must not be left uncontrolled by a shell that finishes booting
before the daemon owns the redstone side.

## Home Assistant entities

| Entity | Type | Topic suffix | Notes |
|---|---|---|---|
| Chunkloading | switch | `chunkloading/state` | HA commands `chunkloading/set`; not optimistic |
| Chunkloading Status | binary_sensor | `chunkloading/state` | `device_class: running` |
| Ender Pearls | sensor | `ender_pearls/state` | Attributes: capacity, percent, item count, item name |
| Boot Mode | select | `boot_mode/state` | `on` / `off` / `keep_state`, `entity_category: config` |
| Broker Link | binary_sensor | `link/state` | `ONLINE` / `OFFLINE`, connectivity diagnostic |
| Problem | binary_sensor | `problem/state` | Attributes list each reason |
| Deployment | sensor | `deployment/state` | State is the dimension name; attributes carry dimension id and chunk count |
| Anchor Fuel | sensor | `anchor_fuel/state` | Pearls left in the anchor's fuel slot |

Unknown numeric or boolean values publish the literal `"unknown"`, never a
guessed value.

## Troubleshooting

- **No internet card / luamqtt download fails.** The daemon logs the failure and
  retries every `MQTT_RETRY` seconds forever. It never reboots or shuts down the
  computer.
- **MQTT connection refused (CONNACK) or timeouts.** Check the broker address
  from the GTNH container and allow `ip:172.16.69.4` in
  `OpenComputers.cfg` **before** the `deny private` rule, because GTNH denies
  `172.16.0.0/12` by default.
- **Missing anchor or drawer.** Set `ANCHOR_ADDRESS` / `DRAWER_ADDRESS`. With
  more than one matching component and no configured address, the daemon marks
  a problem instead of guessing.
- **Drawer contains the wrong item.** The Problem sensor reports
  `drawer contains <item>, not ender pearls`; only items in `PEARL_ITEM_NAMES`
  count.
- **Redstone mismatch.** `anchor did not follow redstone` appears when the
  anchor's actual state disagrees with the written redstone level for longer
  than `MISMATCH_TIMEOUT`. Check the conduit, the bottom side, and the anchor's
  redstone mode.
- **State file or log.** Persisted boot mode lives in `/etc/anchor_ctl.state`;
  the append-only log is `/etc/anchor_ctl.log`. It is truncated at startup and
  re-checked every 64 writes, so a long broker outage cannot fill the HDD.
- **Boot mode semantics.** `on` forces chunkloading on at boot, `off` forces it
  off, and `keep_state` reads `isDisabled()` from the anchor. If the anchor is
  unknown, `keep_state` falls back to `KEEP_STATE_FALLBACK_ENABLED`.
- **Retained commands are ignored.** HA is expected to publish switch/select
  commands non-retained. A retained command would replay on every reconnect and
  fight the anchor, so the daemon acknowledges but discards it.
- **HA restart recovery.** Discovery, availability, link, and all state topics
  are republished on every connect. The MQTT last-will marks the device offline
  if the computer loses power, and the next boot republishes online state.
- **Broker Link on an abrupt drop.** The daemon cannot publish to a socket that
  is already gone, so the retained `link/state` value can stay stale until the
  next successful connect. The MQTT last-will marks the availability topic
  offline at the same time, so HA shows the whole device as unavailable rather
  than presenting a stale `ONLINE` link.
