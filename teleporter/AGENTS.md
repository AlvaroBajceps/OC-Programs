# Teleporter — AE2 Spatial Teleportation Safety System

Agent operating knowledge for the teleporter program under
`src/OC-Programs/teleporter/`. Pair with the repo-root `AGENTS.md` for
workspace-wide toolchain and workflow rules; everything there (Lua 5.2,
selene/stylua/LuaLS mandatory run, no AI-slop comments, vendored stubs)
applies here too.

## Repository and commit policy

`src/OC-Programs/` is a **separate, nested git repository** — not a
submodule of the workspace root. Teleporter commits go to the OC-Programs
repo (`git -C src/OC-Programs ...`), never to the root repo. The root repo
sees `src/OC-Programs/` as untracked and must not stage it.

**Auto-commit**: when developing the teleporter, always write commits
automatically once your changes pass the mandatory workflow
(selene + stylua + lua-language-server). This overrides the root
`AGENTS.md` rule "Never push, commit, tag, or amend without an explicit
user instruction" — for the teleporter, committing is part of the
development loop, not something to ask permission for. Write atomic commits
(one logical change each) following the `Teleporter: <description>` message
convention already in the log. **Pushing** still requires an explicit user
instruction.

## Vocabulary (read this before touching the UI or protocol)

A single teleportation event is called a **warp** in user-facing strings
(banners, buttons, status text) — chosen for the Star-Trek console feel.
The wire protocol and internal code keep the `tp_` / `teleport` identifiers
(`MT.TP_*` message tags, `tp_active_seq`, `OUTCOME.*` codes, FSM state
strings) for on-disk and network stability. When editing the UI, change the
visible words to "warp"; when editing the protocol, leave the identifiers
alone.

### Warp chamber (elevator model)

The network operates like an elevator: exactly one physical **warp chamber**
(the teleporter entity) exists, shared by all nodes. The Red bundled-cable
signal indicates the chamber's current location — high at the node where the
chamber physically resides. At most one node may hold Red high at any time
(2+ = hardware conflict / unhealthy). Zero Red signals means the chamber is
in transit between nodes (transient, not a fault).

Only the node holding the chamber (Red high locally, `redstone.is_red_high()
== true`) may be the **sender** of a warp. It can warp to any online
destination directly via `request_teleport`. Nodes without the chamber cannot
initiate — they call `summon_chamber`, which sends `TP_SUMMON` to the holder;
the holder then initiates the normal `TP_REQ` handshake back to the summoner
(who becomes the receiver).

Every teleporter instance on the wired network plays exactly one of three
roles during a given warp:

- **Sender** — the teleporter instance that *requests* a warp from itself to
  some destination. It initiates the handshake (`TP_REQ`) and owns the
  countdown (broadcasts `TP_SYNC` each tick). FSM state `COUNTDOWN_LOCAL`
  (or `REQUESTING` during the initial `TP_REQ` → `TP_ACK` handshake).
- **Receiver** — the teleporter instance that the sender is warping *to*. It
  is the destination of the warp. FSM state `COUNTDOWN_REMOTE` with
  `tp_active_dest == config.MY_ADDR`. It answers `TP_REQ` with `TP_ACK` and
  broadcasts `TP_PWR` each tick so the sender can verify destination power.
- **Bystander** — a teleporter instance connected to the network that is
  neither sender nor receiver for the current warp. FSM state
  `COUNTDOWN_REMOTE` with `tp_active_dest != config.MY_ADDR`. It observes the
  countdown via `TP_SYNC` and is locked out of starting its own warp while one
  is in progress (the UI shows a "warp in progress" overlay, no peer
  selection / no initiate button).

Role detection lives in `ui.lua`'s `render_countdown` and branches the
screen layout accordingly. The FSM itself (`protocol.lua`) does not name
roles — it only tracks `APP_STATE` plus `tp_active_src` / `tp_active_dest`,
from which the UI derives the role.

## Cancellation

Any node — sender, receiver, or bystander — can cancel an in-progress warp
by pressing CANCEL during the countdown (or during `REQUESTING`). The
cancelling node broadcasts `TP_ABORT` with `OUTCOME.USER_CANCEL` and a reason
string of the form `Cancelled by <node display name>`, so every node's
cooldown screen reports exactly who aborted. Hardware faults and power drops
abort automatically with their own outcome codes (`HW_FAULT`, `SRC_POWER`,
`DST_POWER`) and do not carry a user name.

## Module map

```
bin/teleporter.lua          composition root: wires modules, owns event loop
lib/teleporter/config.lua   constants, OUTCOME/MT enums, node identity (name)
lib/teleporter/util.lua     serialization pack/unpack + small helpers
lib/teleporter/modem.lua    wired-modem transport (send/broadcast)
lib/teleporter/ae2.lua      me_controller power telemetry (+mock fallback)
lib/teleporter/redstone.lua bundled-cable health sensing (Black/Red signals)
lib/teleporter/peers.lua    peer directory + selected-destination state
lib/teleporter/display.lua  GPU setup, double-buffered drawing primitives
lib/teleporter/protocol.lua FSM + wire-message handling (discovery, handshake)
lib/teleporter/ui.lua       every screen, hit-testing, touch/keyboard input
rc.d/teleporter.lua         OpenOS service entrypoint (clears term, runs bin)
```

The UI owns no state except `rename_buffer` and the cross-cutting `app` table
(`dirty`, `shutting_down`, `rename_mode`). All teleport lifecycle state lives
in `protocol.lua` and is exposed read-only via `protocol.snapshot()`.

## FSM states

`IDLE` → `REQUESTING` (sender awaits `TP_ACK` after `TP_REQ`; or non-holder
awaits `TP_REQ` after `TP_SUMMON` — tracked via `tp_summon_mode`) →
`COUNTDOWN_LOCAL` (sender counts down, broadcasts `TP_SYNC`) → `COOLDOWN`
(all nodes). Receivers and bystanders enter `COUNTDOWN_REMOTE` directly on
the first `TP_SYNC`. Any countdown state can transition to `COOLDOWN` via
`TP_ABORT` / `TP_DONE` / hardware fault / power loss. See `protocol.lua`
header comment for the full message sequence.
