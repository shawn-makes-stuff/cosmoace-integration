# ACE Macro Reference

CosmoACE is built around one supported print path: blocking OrcaSlicer / PrusaSlicer-style start, toolchange, and end macros. The older async flow is gone.

This document lists the macros in `files/ace_macros.cfg`, what each one does, and which variables you can tune in `/etc/klipper/config/ace-addon.cfg`.

## Runtime Pieces

- `gcode_shell_command ace_rpc`: shell bridge Klipper uses to talk to the addon service.
- `[gcode_macro _ACE_CONFIG]`: user-editable configuration values.
- `[gcode_macro _ACE_STATE]`: internal runtime state for the current print.

## Config Variables

Edit these in `/etc/klipper/config/ace-addon.cfg`.

| Variable | Default | Used by | Purpose |
| --- | ---: | --- | --- |
| `variable_sensor_name` | `runout` | Most load/unload macros | Filament sensor object name in Klipper. |
| `variable_load_to_sensor_search_mm` | `1200` | `ACE_LOAD_TO_SENSOR`, `_ACE_ORCA_START`, `_ACE_ORCA_TOOLCHANGE` | Max distance to search for the sensor while loading. |
| `variable_load_to_printhead_mm` | `730` | `ACE_LOAD_TO_PRINTHEAD`, `_ACE_ORCA_START`, `_ACE_ORCA_TOOLCHANGE` | Distance from sensor to printhead. |
| `variable_unload_to_sensor_search_mm` | `900` | `ACE_UNLOAD_TO_SENSOR`, `_ACE_ORCA_START`, `_ACE_ORCA_TOOLCHANGE`, `_ACE_ORCA_END_PRINT` | Max distance to search for sensor clear while retracting. |
| `variable_unload_to_sensor_probe_mm` | `10` | `ACE_PROBE_SENSOR_IN`, `ACE_PROBE_SENSOR_OUT` | Small probe distance for sensor tests. |
| `variable_unload_to_sensor_probe_speed_mm_s` | `5` | `ACE_PROBE_SENSOR_OUT` | Speed for the retract probe. |
| `variable_retract_slot_mm` | `90` | `ACE_RETRACT_SLOT`, `ACE_CLEAR_HUB`, `_ACE_ORCA_TOOLCHANGE`, `_ACE_ORCA_END_PRINT` | Hub-clear retract after the sensor has cleared. |
| `variable_clear_hub_step_mm` | `10` | `ACE_CLEAR_HUB` | Extra retract step size if the hub is still blocked. |
| `variable_clear_hub_max_extra_mm` | `60` | `ACE_CLEAR_HUB` | Maximum extra retract allowed while clearing the hub. |
| `variable_clear_hub_settle_s` | `0.25` | `ACE_CLEAR_HUB` | Post-step settle delay before checking the sensor again. |
| `variable_clear_hub_confirm_s` | `1.0` | `ACE_CLEAR_HUB` | Sensor-clear confirmation window before success is reported. |
| `variable_extruder_release_mm` | `30` | `_ACE_CUT_FILAMENT` | Small extruder release after the cut motion. |
| `variable_extruder_release_speed_mm_s` | `4` | `_ACE_CUT_FILAMENT` | Speed for the release retract. |
| `variable_feed_speed_mm_s` | `25` | Load macros and probe-in paths | Default ACE feed speed. |
| `variable_retract_speed_mm_s` | `15` | Unload and retract macros | Default ACE retract speed. |
| `variable_purge_mm` | `40` | `ACE_PURGE`, `_ACE_ORCA_START`, `_ACE_ORCA_TOOLCHANGE` | Default purge amount at the tray. |
| `variable_purge_chunk_mm` | `100` | `ACE_PURGE` | Chunk size for long purges to stay under Klipper limits. |
| `variable_purge_temp` | `250` | `_ACE_HEAT_FOR_PURGE`, `_ACE_ORCA_START`, `_ACE_ORCA_TOOLCHANGE` | Hotend temperature for purge operations. |
| `variable_purge_speed_mm_s` | `3` | `ACE_PURGE`, `ACE_SYNC_LOAD`, `_ACE_ORCA_START`, `_ACE_ORCA_TOOLCHANGE` | Default speed for purge and sync-load extrusion. |
| `variable_sync_load_mm` | `40` | `ACE_SYNC_LOAD`, `_ACE_ORCA_START`, `_ACE_ORCA_TOOLCHANGE` | How much to sync-load after the push-to-printhead stage. |
| `variable_sync_load_chunk_mm` | `5` | `ACE_SYNC_LOAD` | Chunk size for sync-load so ACE and extruder stay serialized. |
| `variable_sync_load_settle_s` | `0.25` | `ACE_SYNC_LOAD` | Delay between sync-load chunks. |
| `variable_swap_lift_z` | `5` | `_ACE_DROP_BED` | How far to lift before moving the bed/toolhead during a swap. |
| `variable_lift_speed_mm_s` | `10` | `_ACE_DROP_BED` | Speed for the swap lift. |
| `variable_return_xy_speed_mm_s` | `200` | `_ACE_RETURN_XY` | Speed used when returning to the saved XY position. |
| `variable_return_z_speed_mm_s` | `10` | `_ACE_RETURN_Z` | Speed used when returning to the saved Z position. |
| `variable_cut_x` | `255` | `_ACE_CUT_FILAMENT` | X position for the cut blade move. |
| `variable_cut_y` | `3` | `_ACE_CUT_FILAMENT` | Y position for the cut blade move. |
| `variable_cut_clear_y` | `30` | `_ACE_CUT_FILAMENT` | Safe Y position before and after the cut move. |

## Public Macros

These are the commands you normally use from the console or call from slicer G-code.

| Macro | What it does | Inputs |
| --- | --- | --- |
| `ACE_SET_SENSOR_NAME` | Changes which `filament_switch_sensor` object the addon watches. | `NAME` |
| `ACE_STATUS` | Prints the current ACE mode, slot state, sensor state, and saved return position. | none |
| `ACE_SLOT_STATUS` | Queries the addon service for the selected slot's readiness. | `SLOT` |
| `ACE_LOAD_TO_SENSOR` | Loads a slot until the sensor triggers. | `SLOT`, optional `LENGTH`, `SPEED`, `SENSOR` |
| `ACE_LOAD_TO_PRINTHEAD` | Pushes the current or pending slot from the sensor to the printhead. | `SLOT`, optional `LENGTH`, `SPEED` |
| `ACE_UNLOAD_TO_SENSOR` | Retracts a slot until the sensor clears. | `SLOT`, optional `LENGTH`, `SPEED`, `SENSOR` |
| `ACE_RETRACT_SLOT` | Short retract past the sensor to keep the hub path open. | `SLOT`, optional `LENGTH`, `SPEED` |
| `ACE_CLEAR_HUB` | Clears the hub path after unload and rechecks the live sensor before success is reported. | `SLOT`, optional `LENGTH`, `STEP`, `MAX_EXTRA`, `SPEED`, `SENSOR`, `SETTLE_S`, `CONFIRM_S` |
| `ACE_PROBE_SENSOR_OUT` | Retracts a short distance and reports whether the sensor is clear. | `SLOT`, optional `LENGTH`, `SPEED` |
| `ACE_PROBE_SENSOR_IN` | Feeds a short distance and reports whether the sensor is triggered. | `SLOT`, optional `LENGTH`, `SPEED` |
| `ACE_PURGE` | Purges at the tray, splitting long purges into safe chunks. | `LENGTH`, optional `SPEED`, `CHUNK` |
| `ACE_SYNC_LOAD` | Sync-loads ACE and extruder together in small chunks. | `SLOT`, optional `LENGTH`, `SPEED`, `ACE_SPEED`, `CHUNK`, `SETTLE_S` |
| `ACE_WIPE` | Runs the tray wipe motion. | none |

## Orca / Prusa-Fork Entry Macros

These are the slicer-facing entry points. They are hidden on purpose so the Mainsail macro panel stays focused on troubleshooting.

| Macro | What it does | Inputs |
| --- | --- | --- |
| `_ACE_ORCA_START` | Blocking print start: home if needed, move to purge, load to sensor, push to printhead, sync-load, purge, wipe, and mark the slot active. | `SLOT`, optional `SENSOR`, `LOAD_LENGTH`, `LOAD_SPEED`, `PUSH_LENGTH`, `TEMP`, `SYNC_LENGTH`, `PURGE`, `SPEED`, `ACE_SPEED`, `CHUNK`, `WIPE` |
| `_ACE_ORCA_TOOLCHANGE` | Blocking mid-print swap: save position, pause, lift/drop, cut, unload to sensor, clear hub, load the next slot, push to printhead, sync-load, purge, wipe, return, and resume. | `SLOT`, optional `SENSOR`, `UNLOAD_LENGTH`, `UNLOAD_SPEED`, `RETRACT_LENGTH`, `LOAD_LENGTH`, `LOAD_SPEED`, `PUSH_LENGTH`, `TEMP`, `SYNC_LENGTH`, `PURGE`, `SPEED`, `ACE_SPEED`, `CHUNK`, `WIPE` |
| `_ACE_ORCA_END_PRINT` | End-of-print clear: cut, unload to sensor, clear hub, and reset ACE state. | optional `SENSOR`, `UNLOAD_LENGTH`, `UNLOAD_SPEED`, `RETRACT_LENGTH` |
| `_ACE_TOOL_SELECT` | Routes unexpected `T0`..`T3` commands into the blocking toolchange path during an active print. | `SLOT` |
| `T0` | Safety alias for slot 1. | none |
| `T1` | Safety alias for slot 2. | none |
| `T2` | Safety alias for slot 3. | none |
| `T3` | Safety alias for slot 4. | none |

## Internal Support Macros

These are implementation helpers. They are callable from the console, but they are not the recommended user-facing entry points.

| Macro | What it does | Inputs |
| --- | --- | --- |
| `_ACE_PRE_TOOLCHANGE` | No-op hook before a toolchange. Useful if you want to extend behavior later. | none |
| `_ACE_POST_TOOLCHANGE` | No-op hook after resume / toolchange completion. | none |
| `_ACE_SET_MODE` | Updates the internal ACE mode and prints the mode change. | `MODE` |
| `_ACE_CLEAR_RETURN_POSITION` | Clears the saved return XY/Z position. | none |
| `_ACE_SAVE_RETURN_POSITION` | Saves the current toolhead position for later resume. | none |
| `_ACE_RESET_STATE` | Resets ACE state, cancels delayed resume, clears return position, and reloads the live sensor state. | none |
| `_ACE_ASSERT_SLOT_READY` | Refuses to continue if the selected slot is not ready according to the addon service. | `SLOT` |
| `_ACE_SLOT_LOAD_RAW` | Sends a raw ACE `feed` request. | `SLOT`, `LENGTH`, `SPEED` |
| `_ACE_SLOT_LOAD_WAIT_RAW` | Sends a blocking ACE feed request and waits for completion. | `SLOT`, `LENGTH`, `SPEED`, optional `TIMEOUT_S` |
| `_ACE_SLOT_UNLOAD_RAW` | Sends a raw ACE `retract` request. | `SLOT`, `LENGTH`, `SPEED` |
| `_ACE_SLOT_UNLOAD_WAIT_RAW` | Sends a blocking ACE retract request and waits for completion. | `SLOT`, `LENGTH`, `SPEED`, optional `TIMEOUT_S` |
| `_ACE_SLOT_WAIT_IDLE_RAW` | Waits for the ACE slot to become idle. | `SLOT`, optional `TIMEOUT_S` |
| `_ACE_SLOT_LOAD_TO_SENSOR_WAIT_RAW` | Blocking raw load that stops when the sensor triggers. | `SLOT`, `LENGTH`, `SPEED`, `SENSOR`, optional `TIMEOUT_S` |
| `_ACE_SLOT_UNLOAD_TO_SENSOR_WAIT_RAW` | Blocking raw unload that stops when the sensor clears. | `SLOT`, `LENGTH`, `SPEED`, `SENSOR`, optional `TIMEOUT_S` |
| `_ACE_SENSOR_EVENT` | Sensor insert/runout hook used by Klipper. It records the event and pauses on real runout during printing. | `EVENT` |
| `_ACE_PAUSE_PRINT` | Validates that a print is active, then pauses it through Klipper. | none |
| `_ACE_DROP_BED` | Raises the toolhead to create swap clearance. | optional `LIFT`, `SPEED` |
| `_ACE_RETURN_XY` | Returns to the saved XY position. | optional `SPEED` |
| `_ACE_RETURN_Z` | Returns to the saved Z position. | optional `SPEED` |
| `_ACE_RESUME_PRINT` | Resumes a paused print after post-toolchange cleanup. | none |
| `_ACE_DELAYED_RESUME_PRINT` | Delayed wrapper that resumes only if the print is still paused. | none |
| `_ACE_MOVE_TO_PURGE` | Moves the toolhead to the purge tray and waits for motion to settle. | none |
| `_ACE_HEAT_FOR_PURGE` | Heats the hotend to purge temperature. | optional `TEMP` |
| `_ACE_PURGE` | Internal purge implementation used by `ACE_PURGE` and the Orca start/toolchange flows. | `LENGTH`, optional `SPEED`, `CHUNK` |
| `_ACE_SYNC_LOAD` | Internal sync-load implementation used by the start/toolchange flows. | `SLOT`, `LENGTH`, `CHUNK`, `SPEED`, `ACE_SPEED`, optional `SETTLE_S` |
| `_ACE_WIPE` | Internal wipe implementation that runs `M729` and waits for motion to finish. | none |
| `_ACE_CUT_FILAMENT` | Moves to the cut position and releases the extruder slightly. | optional `RELEASE_MM`, `RELEASE_SPEED` |

## Recommended Manual Sequences

Load a slot to the sensor, then push a little farther:

```gcode
ACE_LOAD_TO_SENSOR SLOT=1
ACE_LOAD_TO_PRINTHEAD SLOT=1 LENGTH=20
```

Unload a slot back to the sensor:

```gcode
ACE_UNLOAD_TO_SENSOR SLOT=1
```

Clear the hub path after unload:

```gcode
ACE_CLEAR_HUB SLOT=1
```

Probe the sensor in either direction:

```gcode
ACE_PROBE_SENSOR_IN SLOT=1
ACE_PROBE_SENSOR_OUT SLOT=1
```

## Sensor Hook

Your printer config should call the hidden sensor event macro:

```cfg
[filament_switch_sensor runout]
pause_on_runout: False
runout_gcode:
  _ACE_SENSOR_EVENT EVENT=RUNOUT
insert_gcode:
  _ACE_SENSOR_EVENT EVENT=INSERT
```

If your sensor object is not named `runout`, change `variable_sensor_name` in `ace-addon.cfg` or call `ACE_SET_SENSOR_NAME`.
