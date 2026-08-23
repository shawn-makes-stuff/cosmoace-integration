# ACE Macro Reference

CosmoACE provides one supported print path: blocking OrcaSlicer / PrusaSlicer-style
start, toolchange, and end flows. See [ORCA_GCODE.md](ORCA_GCODE.md) for the
three slicer one-liners.

## Runtime Pieces

- `[gcode_shell_command ace_rpc]`: shell bridge Klipper uses to talk to the ACE CLI.
- `[gcode_macro _ACE_CONFIG]`: user-editable tuning values.
- `[gcode_macro _ACE_STATE]`: runtime state (`mode`, `current_slot`, `pending_slot`).

## Config Variables

Edit these in `/etc/klipper/config/ace-addon.cfg`.

| Variable | Default | Purpose |
| --- | ---: | --- |
| `variable_sensor_name` | `filament_sensor` | Filament sensor object name (COSMOS stock name — keep it unless you know why). |
| `variable_load_to_sensor_search_mm` | `1200` | Max feed distance while searching for the sensor. |
| `variable_load_to_printhead_mm` | `730` | **The value to tune**: distance from sensor to printhead. |
| `variable_unload_to_sensor_search_mm` | `900` | Max retract distance while waiting for the sensor to clear (manual `ACE_UNLOAD_TO_SENSOR`). |
| `variable_unload_extra_mm` | `170` | Added to `load_to_printhead_mm` for the full-unload retract (hub clearance + slip margin), run as one completed unwind so the ACE respools. Over-length is safe. |
| `variable_retract_past_sensor_mm` | `90` | Extra retract past the sensor to clear the hub path. |
| `variable_feed_speed_mm_s` | `25` | ACE feed speed. |
| `variable_retract_speed_mm_s` | `15` | ACE retract speed. |
| `variable_purge_mm` | `40` | Default purge length (overridden per-change by `PURGE=`). |
| `variable_purge_speed_mm_s` | `3` | Extrusion speed for purge and sync-load. |
| `variable_purge_temp` | `250` | Fallback hotend temperature when no `TEMP=` is given. |
| `variable_sync_load_mm` | `40` | Sync-load length after the push to the printhead. |
| `variable_sync_load_chunk_mm` | `5` | Chunk size keeping ACE and extruder in step during sync-load. |

## Public Macros

| Macro | What it does | Inputs |
| --- | --- | --- |
| `ACE_START` | Blocking print start: heat, home, recover leftovers, full load, purge, wipe. | `SLOT`, `BED`, `TEMP`, opt. `CHAMBER`, `PURGE` |
| `ACE_END` | End of print: unload the active slot, then COSMOS `PRINT_END`. | none |
| `T0`–`T3` | Toolchange during a print (cut → unload → clear hub → load → purge → resume). | opt. `TEMP`, `PURGE` |
| `ACE_LOAD` | Full manual load of a slot: sensor → printhead → sync → purge → wipe. Leaves ACE feed assist on for the slot. | `SLOT`, opt. `TEMP`, `PURGE` |
| `ACE_UNLOAD` | Full manual unload: stop feed assist, cut, one completed retract back to the slot (respools), verify sensor clear. Heats if needed. | opt. `SLOT` |
| `ACE_LOAD_TO_SENSOR` | Feed a slot until the sensor triggers. | `SLOT` |
| `ACE_LOAD_TO_PRINTHEAD` | Push the pending slot from sensor to printhead. | opt. `SLOT`, `LENGTH` |
| `ACE_UNLOAD_TO_SENSOR` | Retract until the sensor clears. | opt. `SLOT` |
| `ACE_CLEAR_HUB` | Retract past the sensor until the hub path is confirmed clear. | opt. `SLOT` |
| `ACE_SYNC_LOAD` | Feed ACE and extruder together through the hotend. | opt. `SLOT` |
| `ACE_PURGE` | Purge at the tray in one move (macros raise max_extrude_only_distance to 1000mm). | opt. `LENGTH` |
| `ACE_WIPE` | Flick the purge blob off at the tray (COSMOS `KICK`). | none |
| `ACE_STATUS` | Print ACE mode, slots, and live sensor state. | none |
| `ACE_SLOT_STATUS` | Query slot readiness from the ACE itself. | `SLOT` |
| `ACE_SET_FILAMENT` | Store a slot's material + color on the ACE (`set_filament_info`). | `SLOT`, `TYPE`, `COLOR` (RRGGBB) |

## Internal Macros

| Macro | Purpose |
| --- | --- |
| `_ACE_TOOLCHANGE` | The blocking mid-print swap behind `T0`–`T3`. |
| `_ACE_TOOL_SELECT` | Routes `T<n>` to a toolchange during a print, ignores it otherwise. |
| `_ACE_SENSOR_EVENT` | Sensor hook; pauses on a genuine runout during printing. |
| `_ACE_VERIFY_SENSOR` | Raises if the sensor is not in the expected state (`TRIGGERED=0/1`). |
| `_ACE_RESUME_PRINT` / `_ACE_DELAYED_RESUME` | Resume via `RESUME_BASE` after the toolchange macro finishes. |
| `_ACE_LIFT` | Guarded 5mm Z lift before cut moves. |
| `_ACE_SLOT_LOAD_RAW` / `_ACE_SLOT_WAIT_IDLE_RAW` | Fire-and-forget ACE feed + wait, used by sync-load. |
| `_ACE_RESET_STATE` | Clears mode/slots and cancels a pending delayed resume. |

## Design notes

- **Every shell call is verified.** COSMOS's `gcode_shell_command` never aborts
  a macro on failure, so after each ACE move that must have changed the sensor
  state, `_ACE_VERIFY_SENSOR` checks it and raises on mismatch. The two steps
  the sensor cannot verify (push to printhead, sync-load) fail loudly in the
  console but cannot stop the flow — watch the purge after a load.
- **Cutting uses the COSMOS `UNLOAD_FILAMENT` macro** (cut at the blade, move
  to the tray, back the filament 30mm out of the extruder gears). The addon
  overrides `CUT_FILAMENT` itself (same blade coordinates, but the ram runs at
  300mm/s and presses twice — the stock single F1200 press sometimes fails to
  shear). If a firmware update moves the blade, update the override too.
- **Resume uses `RESUME_BASE`**, which restores the position captured at
  `PAUSE_BASE` — no manual position bookkeeping.

## Sensor Hook

No manual setup needed. COSMOS removes Klipper's duplicate-section checks and
`ace-addon.cfg` is parsed after the stock config, so `ace_macros.cfg` simply
redefines the stock sensor section — later keys override earlier ones (the
same mechanism COSMOS's own `macros.cfg` uses to override `client.cfg`):

```cfg
[filament_switch_sensor filament_sensor]
switch_pin: PC0
pause_on_runout: False
event_delay: 0.2
debounce_delay: 0.02
smart: True
runout_distance: 0
runout_gcode:
  _ACE_SENSOR_EVENT EVENT=RUNOUT
insert_gcode:
  _ACE_SENSOR_EVENT EVENT=INSERT
immediate_runout_gcode:
```

Every key of the stock section is set explicitly — anything omitted would
leak through from the stock definition (`runout_distance: 770` and the stock
`immediate_runout_gcode` in particular).

Keeping the name `filament_sensor` matters: the stock COSMOS `PRINT_START`,
`PRINT_END`, `PAUSE`, and `RESUME` macros query that exact object.

Note: if a future COSMOS release renames its stock sensor section, this
override becomes a second sensor on the same pin and Klipper will fail with
a "pin PC0 used multiple times" error until `ace-addon.cfg` is updated.

## Recommended Manual Sequences

Full load / unload from the console:

```gcode
ACE_LOAD SLOT=1 TEMP=220
ACE_UNLOAD
```

Step by step:

```gcode
ACE_LOAD_TO_SENSOR SLOT=1
ACE_LOAD_TO_PRINTHEAD SLOT=1 LENGTH=20
ACE_UNLOAD_TO_SENSOR SLOT=1
ACE_CLEAR_HUB SLOT=1
```
