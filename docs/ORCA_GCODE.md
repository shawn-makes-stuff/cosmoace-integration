# Orca Slicer G-Code

Use these in OrcaSlicer or a PrusaSlicer-style fork. The entire slicer setup
is three one-liners — everything else lives in the printer-side macros.

## Machine Start G-Code

```gcode
M400
ACE_START SLOT={initial_extruder + 1} BED=[bed_temperature_initial_layer_single] TEMP=[nozzle_temperature_initial_layer]
```

`ACE_START` heats the bed, homes (which loads the default bed mesh), recovers
any leftover filament from an interrupted print, loads the slot to the sensor,
pushes it to the printhead, sync-loads through the hotend, purges, and wipes.

Optional parameters: `CHAMBER=<temp>` (waits for chamber temperature) and
`PURGE=<mm>` (initial purge length, default `variable_purge_mm`).

## Change Filament G-Code

```gcode
T{next_extruder} PURGE={flush_length}
```

The `T0`–`T3` macros route this into the blocking toolchange: cut, move to the
purge tray, unload to the sensor, clear the hub, load the next slot to the
sensor, push to the printhead, sync-load, purge, wipe, and resume where the
print left off. `PURGE` is optional; without it the default purge length is
used. Keep `Tool change G-code` empty.

## Machine End G-Code

```gcode
M400
ACE_END
```

`ACE_END` cuts, unloads the active slot back past the hub, resets ACE state,
and then runs the native COSMOS `PRINT_END` (park, heaters and fans off,
steppers off). Do not add manual wipe moves or `M729` — on COSMOS `M729`
triggers an emergency stop.

## Notes

- `initial_extruder` and `next_extruder` are 0-based; `ACE_START` takes 1-based
  slots (hence the `+ 1`), while `T0`–`T3` already map T-number to slot 1–4.
- If the slicer emits a redundant `T<n>` for the already-active slot, the
  macro just reports "already active" and continues.
- A cancelled print skips the end gcode, leaving filament loaded — the next
  `ACE_START` detects this and unloads it automatically.

## Required Printer Setup

None. The CosmoACE installer replaces the stock COSMOS
`[filament_switch_sensor filament_sensor]` section with an ACE-aware version
(same object name, same pin `PC0`). The COSMOS `PRINT_START`/`PAUSE`/`RESUME`
macros keep working because the object name is unchanged.

If you move the sensor to a different object, update `variable_sensor_name`
in `/etc/klipper/config/ace-addon.cfg` (macros) and `sensor_name` in
`/user-resource/ace-addon/ace-addon.conf` (service).

An optional toolhead sensor at the extruder inlet is supported and off by
default — see [ACE_MACROS.md](ACE_MACROS.md#optional-toolhead-sensor). It needs
no slicer change.

## Why not the stock COSMOS start/end gcode?

The stock `PRINT_START` cancels the print when no filament is detected and
line-purges before ACE could load anything — and CosmoACE unloads filament at
the end of every print. A dedicated `ACE_START` entry point is therefore
unavoidable; it performs the same essential steps with the load folded in.
