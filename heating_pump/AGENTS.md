# Heating Pump — Deep Earth Heating Pump Controller

Agent operating knowledge for the heating_pump program under
`src/OC-Programs/heating_pump/`. Pair with the repo-root `AGENTS.md` for
workspace-wide toolchain and workflow rules; everything there (Lua 5.2,
selene/stylua/LuaLS mandatory run, no AI-slop comments, vendored stubs)
applies here too.

## Repository and commit policy

`src/OC-Programs/` is a **separate, nested git repository** — not a
submodule of the workspace root. Heating pump commits go to the OC-Programs
repo (`git -C src/OC-Programs ...`), never to the root repo. The root repo
sees `src/OC-Programs/` as untracked and must not stage it.

**Auto-commit**: when developing the heating pump, always write commits
automatically once your changes pass the mandatory workflow
(selene + stylua + lua-language-server). This overrides the root
`AGENTS.md` rule "Never push, commit, tag, or amend without an explicit
user instruction" — for the heating pump, committing is part of the
development loop. Write atomic commits following the
`HeatingPump: <description>` message convention already in the log.
**Pushing** still requires an explicit user instruction.

## Domain vocabulary

A **pump** is a GregTech Deep Earth Heating Pump (DEHP) multiblock accessed
via a `gt_machine` component adapter. Each pump produces **hot coolant**
(output/supply side) and consumes **cold coolant** (input/demand side) at a
rate of 3840 L/s (= 192 L/tick at 20 tps).

**Hot coolant** fills the hot tank — when the hot tank level is low
(< 30%), the controller enables another pump to increase production. When
high (> 70%), a pump is disabled.

**Cold coolant** supplies the pumps — when the cold tank level is low
(< 25%), the controller refuses to enable new pumps (caution cap). The
**emergency floor** at 200 kL triggers immediate shutdown of ALL pumps.
Recovery requires rising above 300 kL (hysteresis, preventing rapid
toggle).

**Maintenance** refers to the GT multiblock repair state reported via
`getSensorInformation()`. A pump with pending maintenance is **excluded**
from the eligible pool and commanded off. The controller parses the
sensor lines for §-color-coded maintenance messages.

**Min-runtime** (5 seconds) prevents rapid on/off cycling: once a pump is
enabled in normal operation, it stays on for at least 5 seconds even if
the controller wants to disable it.

**Failsafe**: if the cold tank transposer is unreadable (offline or nil
amount), the controller enters EMERGENCY mode and shuts down all pumps.
Missing cold telemetry must never satisfy the threshold — an unreadable
cold tank is assumed empty. This prevents DEHP explosions from running dry.

## Module map

```
bin/heating_pump.lua            composition root: discovers components, wires
                                modules, owns the event/render loop
lib/heating_pump/config.lua     constants: thresholds, timing, colors, screen
                                dimensions, pump rate
lib/heating_pump/machine.lua    wraps a single gt_machine pump: refresh,
                                maintenance parse, set_work_allowed, uptime
lib/heating_pump/tank.lua       wraps a single transposer adapter: auto-probe
                                tank side, read fluid amount/capacity
lib/heating_pump/stats.lua      sliding-window rate tracker for hot/cold tank
                                fill-rate deltas (60s + 10s windows)
lib/heating_pump/controller.lua the balancing + emergency-shutdown brain:
                                hysteresis, cold caution, min-runtime lock
lib/heating_pump/display.lua    double-buffered 80x25 dashboard renderer with
                                box-drawing primitives and bar charts
rc.d/heating_pump.lua           OpenOS service entrypoint: start() clears term
                                and runs the bin via os.execute
```

The bin owns the `app` cross-cutting table (`dirty`, `shutting_down`).
The controller owns all control state (mode, desired_active, last_action,
history). The display reads snapshots from controller, machines, tanks,
and stats — it owns no persistent state.

## Control algorithm

1. **Data refresh**: every tick, all machines and both tanks are refreshed
   via pcall'd component reads. A sample is pushed to the stats ring buffer.

2. **Emergency check**: if the cold tank is offline (`.online == false`) or
   its amount is nil or below `COLD_EMERGENCY_L` (200 kL) → enter EMERGENCY
   mode, force ALL pumps off immediately (ignoring min-runtime). Return
   early.

3. **Emergency exit**: if in EMERGENCY and cold amount ≥
   `COLD_EMERGENCY_RECOVERY_L` (300 kL) → exit to NORMAL.

4. **Normal hysteresis**:
   - Count healthy pumps (online + not maintenance).
   - If hot_pct < `HOT_LOW_PCT` (30%) and desired < healthy_count →
     increment `desired_active`.
   - If hot_pct > `HOT_HIGH_PCT` (70%) and desired > 0 →
     decrement `desired_active`.
   - Deadband: between 30-70%, hold steady.

5. **Cold caution**: if cold_pct < `COLD_CAUTION_PCT` (25%), cap
   `desired_active` — allow decreasing but not increasing.

6. **Reconciliation**: build ordered list of eligible pumps (online +
   not maintenance, sorted by index). First `desired_active` eligible
   pumps should be ON; the rest OFF. Maintenance/offline pumps are
   always OFF. Min-runtime: a pump enabled < 5s ago stays on.

## Safety principles

1. **Cold tank offline ⇒ emergency shutdown**: the cold tank is the sole
   safety constraint. If its telemetry is unavailable, ALL pumps stop.
2. **Shutdown always turns pumps off**: both `shutdown()` and `fatal()`
   iterate ALL machines and call `set_work_allowed(false)`.
3. **Maintenance pumps excluded**: pumps with `needs_maintenance == true`
   are never eligible for enabling and are always commanded off.
4. **Never enable without cold telemetry**: adding a new pump to the
   active set is gated on cold_pct ≥ `COLD_CAUTION_PCT` and a readable
   cold tank amount.
