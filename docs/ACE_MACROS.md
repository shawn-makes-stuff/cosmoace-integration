# ACE Macros

This document lists the CosmoACE Klipper macros in `files/ace_macros.cfg` and
what each one does.

## Print Start

### `ACE_START_PRINT SLOT=<1..4>`
Start-of-print orchestration. Clears any stale pause state, homes if needed,
moves to the tray, resets ACE state, and begins loading the requested slot to
the sensor. Once the sensor triggers, `ACE_COMPLETE_LOAD` continues the flow.

### `ACE_ORCA_START SLOT=<1..4>`
Blocking start-of-print flow for OrcaSlicer. Loads the selected slot to the
sensor, pushes to the printhead, heats, sync-loads, purges, wipes, and only
then returns to the slicer.

### `ACE_MOVE_TO_PURGE`
Moves the toolhead to the tray / purge position by reusing `MOVE_TO_TRAY`.

### `ACE_LOAD_TO_SENSOR SLOT=<1..4>`
Feeds the selected ACE slot forward until the filament sensor reports insert.

### `ACE_LOAD_TO_PRINTHEAD SLOT=<1..4>`
Pushes the selected slot from the sensor through the long path to the printhead
using the configured fixed distance.

### `ACE_HEAT_FOR_PURGE TEMP=<c>`
Heats the hotend and waits for purge temperature.

### `ACE_SYNC_LOAD SLOT=<1..4>`
Feeds the ACE and extruder together in chunks so the filament is positively
pulled through the hotend instead of relying on the extruder alone.

### `ACE_PURGE LENGTH=<mm> SPEED=<mm/s>`
Extrudes a purge amount at the tray after the filament is loaded. Large purge
lengths are automatically split into smaller chunks so they stay below
Klipper's `max_extrude_only_distance` limit.

### `ACE_WIPE`
Runs the tray wipe motion only using `M729`.

### `ACE_COMPLETE_LOAD SLOT=<1..4>`
Auto-load continuation used after the sensor insert event. Moves to the tray,
pushes to printhead, heats, sync-loads, purges, wipes, sets print mode, and
optionally resumes if this load is part of a color swap.

### `ACE_LOAD_FOR_PURGE`
Helper flow that moves to the tray, heats, sync-loads, purges, and optionally
wipes without using the full auto-load sequence.

## Color Swap

### `ACE_COLOR_SWAP SLOT=<1..4>`
Mid-print color change orchestration. Verifies an active print, saves the
return position, pauses without the stock park move, raises Z by the configured
swap lift, cuts the filament, moves to the tray, unloads the current slot to
the sensor, retracts that slot clear of the hub, loads the new slot, then the
auto-load path purges, wipes, returns XY, returns Z, and resumes the print.

### `ACE_ORCA_TOOLCHANGE SLOT=<1..4>`
Blocking mid-print toolchange flow for OrcaSlicer. It pauses, lifts, cuts,
unloads the current slot to the sensor, retracts that slot clear, loads the new
slot to the sensor, pushes to the printhead, sync-loads, purges, wipes, returns
to the saved position, and resumes before returning to the slicer.

### `ACE_SAVE_RETURN_POSITION`
Captures the current XYZ gcode position so the swap flow can return XY first
and Z second.

### `ACE_PAUSE_PRINT`
Pauses an active print using `PAUSE_BASE` so ACE controls the park motion
instead of the stock pause macro.

### `ACE_DROP_BED`
Raises Z relative by the configured swap clearance. On this CoreXY bed-slinger
that effectively drops the bed away from the part.

### `ACE_CUT_FILAMENT`
Moves through the cutter path and releases the filament from the extruder using
`FORCE_MOVE`.

### `ACE_UNLOAD_TO_SENSOR SLOT=<1..4>`
Retracts the active slot in one continuous movement until the filament sensor
clears.

### `ACE_RETRACT_SLOT SLOT=<1..4>`
Retracts the slot a short fixed distance after the sensor clears so the hub
path is open for the next slot. The current default is 90mm.

### `ACE_PROBE_SENSOR_OUT SLOT=<1..4>`
Retracts the slot by 10mm and reports whether the filament sensor is clear
after the move.

### `ACE_PROBE_SENSOR_IN SLOT=<1..4>`
Feeds the slot by 10mm and reports whether the filament sensor is triggered
after the move.

### `ACE_RETURN_XY`
Moves back to the saved X/Y position while holding the current safe Z height.

### `ACE_RETURN_Z`
Moves Z back to the saved print height after XY is back in place.

### `ACE_RESUME_PRINT`
Runs the post-toolchange hook and resumes the paused print.

## Print End

### `ACE_END_PRINT_CLEAR`
End-of-print orchestration. Raises Z, cuts the filament, moves to the tray,
turns off the hotend, unloads to the sensor, and retracts the slot clear for
the next print.

### `ACE_ORCA_END_PRINT`
Blocking end-of-print clear flow for OrcaSlicer. Cuts the filament, cools the
hotend, unloads to the sensor, retracts the active slot clear, and resets ACE
state before returning to the slicer.

### `ACE_UNLOAD SLOT=<1..4>`
Manual unload helper. Moves to the tray, cuts filament, unloads to the sensor,
and retracts the slot clear.

## Misc

### `ACE_SET_SENSOR_NAME NAME=<sensor>`
Changes which `filament_switch_sensor` object the ACE macros use.

### `ACE_SET_MODE MODE=<name>`
Updates the internal ACE mode state for debugging and event routing.

### `ACE_RESET_STATE`
Clears ACE event/error state, cached sensor state, pending slot, and saved
return position.

### `ACE_CLEAR_RETURN_POSITION`
Clears the saved XYZ return target.

### `ACE_STATUS`
Prints the current ACE mode, slot tracking, sensor state, and saved return
position.

### `ACE_SENSOR_EVENT EVENT=INSERT|RUNOUT`
Event dispatcher called by the configured filament sensor. Stops ACE motion on
insert/runout and advances the current load/unload state machine.

### `_ACE_SLOT_LOAD_RAW SLOT=<1..4>`
Low-level raw ACE feed command.

### `_ACE_SLOT_UNLOAD_RAW SLOT=<1..4>`
Low-level raw ACE retract command.

### `_ACE_SLOT_STOP_RAW SLOT=<1..4>`
Low-level raw ACE stop command.

### `_ACE_PRE_TOOLCHANGE`
No-op hook that can be overridden if extra pre-swap behavior is needed.

### `_ACE_POST_TOOLCHANGE`
No-op hook that can be overridden if extra post-swap behavior is needed.

### `ACE_UNLOAD_SLOT`
Compatibility alias that currently forwards to `ACE_RETRACT_SLOT`.

### `_ACE_TOOL_SELECT SLOT=<1..4>`
Routes slicer tool selections into `ACE_ORCA_TOOLCHANGE` during an active
print. Outside a print it refuses to start a swap and tells you to use the
explicit ACE load/start macros instead.

### `T0`, `T1`, `T2`, `T3`
Tool aliases that forward to `_ACE_TOOL_SELECT SLOT=1..4`.
