# ACE Macros

CosmoACE now has one supported print path: blocking OrcaSlicer / PrusaSlicer
fork style start, toolchange, and end macros. The older async macro flow has
been removed.

## Slicer Entry Points

### `_ACE_ORCA_START SLOT=<1..4>`
Blocking print-start load. Homes if needed, moves to the tray, loads the slot
to the sensor, pushes to the printhead, sync-loads, purges, wipes, and returns
only when printing can begin.

### `_ACE_ORCA_TOOLCHANGE SLOT=<1..4>`
Blocking mid-print color swap. Pauses the print, saves the return position,
cuts, unloads to the sensor, retracts the old slot clear of the hub, loads the
new slot to the sensor, pushes to the printhead, sync-loads, purges, wipes,
returns XY/Z, and resumes.

### `_ACE_ORCA_END_PRINT`
Blocking end-of-print clear. Cuts, unloads to the sensor, retracts the active
slot clear of the hub, and resets ACE state.

### `T0`, `T1`, `T2`, `T3`
Safety aliases that route unexpected slicer tool commands into the blocking
toolchange path during an active print.

## Troubleshooting Macros

### `ACE_STATUS`
Prints the current ACE mode, current slot, pending slot, live sensor state, and
saved return position.

### `ACE_SLOT_STATUS SLOT=<1..4>`
Queries the addon service for the selected slot's live ACE status before a
start or toolchange.

### `ACE_SET_SENSOR_NAME NAME=<sensor>`
Changes which `filament_switch_sensor` object the macros use.

### `ACE_LOAD_TO_SENSOR SLOT=<1..4>`
Blocking load to the configured filament sensor.

### `ACE_LOAD_TO_PRINTHEAD SLOT=<1..4>`
Blocking fixed-distance push from the sensor to the printhead.

### `ACE_UNLOAD_TO_SENSOR SLOT=<1..4>`
Blocking unload until the configured filament sensor clears.

### `ACE_RETRACT_SLOT SLOT=<1..4>`
Blocking short retract after the sensor clears so the hub path is open for the
next slot.

### `ACE_PROBE_SENSOR_OUT SLOT=<1..4>`
Retracts the slot by the configured probe amount and reports whether the sensor
is still triggered.

### `ACE_PROBE_SENSOR_IN SLOT=<1..4>`
Feeds the slot by the configured probe amount and reports whether the sensor is
triggered.

### `ACE_SYNC_LOAD SLOT=<1..4>`
Feeds the ACE and extruder together in small chunks to pull filament through
the hotend.

### `ACE_PURGE LENGTH=<mm> SPEED=<mm/s>`
Purges at the tray. Long purges are automatically split into smaller chunks so
they stay below Klipper's `max_extrude_only_distance` limit.

### `ACE_WIPE`
Runs the tray wipe motion using `M729`.

## Hidden Helpers

Most implementation macros now start with `_ACE_`. They are still callable from
the console, but Mainsail hides them by default so the macro panel stays focused
on troubleshooting commands instead of slicer orchestration.

Your filament sensor block should call `_ACE_SENSOR_EVENT EVENT=RUNOUT` and
`_ACE_SENSOR_EVENT EVENT=INSERT`.
