# CosmoACE Integration

CosmoACE is a lightweight Anycubic ACE Pro add-on for CosmOS / OpenCentauri.
It adds a blocking, slicer-safe multicolor workflow for printers wired like:

`ACE -> hub -> filament sensor -> printhead`

This repo is intentionally focused on:

- CosmOS / OpenCentauri
- OrcaSlicer and PrusaSlicer-style forks
- lightweight printer-side integration
- adjustable distances and speeds in Klipper macros

It does not target generic Klipper distributions or every slicer.

## What It Does

CosmoACE installs:

- a small ACE RPC service
- a shell wrapper Klipper can call
- a Klipper macro set for blocking start, toolchange, and end-print flows

The supported print flow is:

1. Load the selected slot until the filament sensor triggers.
2. Push from the sensor to the printhead by a configured distance.
3. Sync-load, purge, wipe, and start printing.
4. On toolchange, cut, unload back to the sensor, clear the hub, load the next slot, push to the printhead, sync-load, purge, wipe, and resume.

## Requirements

- A working CosmOS / OpenCentauri printer
- SSH access as `root`
- Klipper `gcode_shell_command`
- A configured `filament_switch_sensor`
- Printer-side tray / wipe / pause macros already present:
  - `MOVE_TO_TRAY`
  - `M729`
  - `PAUSE_BASE`
  - `RESUME`

## Install

1. Copy this repository to a USB drive.
2. SSH into the printer as `root`.
3. Run:

```sh
cd /var/volatile/tmp/usb/sda1/CosmoACE-Integration
chmod +x install.sh uninstall.sh create-package.sh
./install.sh
```

Installed files:

- `/user-resource/ace-addon/ace-addon.conf`
- `/user-resource/ace-addon/ace-addon.py`
- `/user-resource/ace-addon/ace-command.sh`
- `/user-resource/ace-addon/ace_macros.default.cfg`
- `/etc/klipper/config/ace-addon.cfg`
- `/etc/klipper/config/klipper-readonly/ace-addon.cfg` -> symlink to `/etc/klipper/config/ace-addon.cfg`

`/etc/klipper/config/ace-addon.cfg` is your editable live macro config.

## Required Printer Config

The only required manual printer config is your existing filament sensor hook.

Example:

```cfg
[filament_switch_sensor runout]
switch_pin: PC0
pause_on_runout: False
event_delay: 0.2
debounce_delay: 0.02
runout_gcode:
  _ACE_SENSOR_EVENT EVENT=RUNOUT
insert_gcode:
  _ACE_SENSOR_EVENT EVENT=INSERT
```

Notes:

- `pause_on_runout` must be `False`
- the macro name must be `_ACE_SENSOR_EVENT`
- if your sensor object is not named `runout`, update `variable_sensor_name` in `ace-addon.cfg`

You can also change the sensor name from the console:

```gcode
ACE_SET_SENSOR_NAME NAME=your_sensor_name
```

## Required Tuning

The main required tuning value is:

- `variable_load_to_printhead_mm`

This is the distance from your filament sensor to the printhead for the active
path. In the current project defaults:

```cfg
variable_load_to_printhead_mm: 730
```

If this value is too short, the new filament will not reach the hotend.
If it is too long, you will overfeed before sync-load / purge.

Other useful tuning values in `/etc/klipper/config/ace-addon.cfg`:

- `variable_load_to_sensor_search_mm`
- `variable_unload_to_sensor_search_mm`
- `variable_retract_slot_mm`
- `variable_clear_hub_step_mm`
- `variable_clear_hub_max_extra_mm`
- `variable_purge_mm`
- `variable_purge_chunk_mm`
- `variable_sync_load_mm`
- `variable_sync_load_chunk_mm`
- `variable_feed_speed_mm_s`
- `variable_retract_speed_mm_s`

Defaults are conservative and intended to be adjustable in-place.

## Slicer Support

Supported slicers:

- OrcaSlicer
- PrusaSlicer forks / clones that support the same style of custom machine G-code placeholders

The intended entry macros are hidden on purpose:

- `_ACE_ORCA_START`
- `_ACE_ORCA_TOOLCHANGE`
- `_ACE_ORCA_END_PRINT`

This keeps the Mainsail macro panel focused on troubleshooting instead of print pipeline internals.

## Orca / Prusa-Fork G-Code

Use these in your printer preset.

### Start G-code

```gcode
M400
M220 S100
M221 S100
M104 S140
M140 S[bed_temperature_initial_layer_single]
G90

M106 P2 S255
M190 S[bed_temperature_initial_layer_single]
M106 P2 S0

_ACE_ORCA_START SLOT={initial_extruder + 1} TEMP=[nozzle_temperature_initial_layer]
```

### Change Filament G-code

```gcode
_ACE_ORCA_TOOLCHANGE SLOT={next_extruder + 1} TEMP={new_filament_temp} PURGE={flush_length}
SET_PRINT_STATS_INFO CURRENT_LAYER={layer_num + 1}
```

### End G-code

```gcode
M400
_ACE_ORCA_END_PRINT
```

Important:

- if your slicer has both `Tool change G-code` and `Change filament G-code`, put the swap flow in `Change filament G-code`
- leave slicer-native toolchange handling out of the way
- `T0`..`T3` exist as safety aliases, but the slicer should call the `_ACE_ORCA_*` macros directly

## Public Troubleshooting Macros

These are the macros intended to stay visible and useful from the Mainsail panel:

- `ACE_STATUS`
- `ACE_SLOT_STATUS SLOT=1`
- `ACE_SET_SENSOR_NAME NAME=runout`
- `ACE_LOAD_TO_SENSOR SLOT=1`
- `ACE_LOAD_TO_PRINTHEAD SLOT=1 LENGTH=20`
- `ACE_UNLOAD_TO_SENSOR SLOT=1`
- `ACE_RETRACT_SLOT SLOT=1`
- `ACE_CLEAR_HUB SLOT=1`
- `ACE_PROBE_SENSOR_IN SLOT=1`
- `ACE_PROBE_SENSOR_OUT SLOT=1`
- `ACE_SYNC_LOAD SLOT=1 LENGTH=20`
- `ACE_PURGE LENGTH=20`
- `ACE_WIPE`

Useful manual sequences:

Load to sensor, then push a bit past it:

```gcode
ACE_LOAD_TO_SENSOR SLOT=1
ACE_LOAD_TO_PRINTHEAD SLOT=1 LENGTH=20
```

Unload back to the sensor:

```gcode
ACE_UNLOAD_TO_SENSOR SLOT=1
```

Clear the hub path after unload:

```gcode
ACE_CLEAR_HUB SLOT=1
```

## Current Behavior Notes

- Start and toolchange flows are blocking.
- Toolchanges use Orca’s `flush_length` as the purge amount.
- Large purges are automatically split into chunks to stay below Klipper `max_extrude_only_distance`.
- Hub clearing is handled after unload-to-sensor before the next slot is loaded.
- The sensor controls the hub-to-sensor leg.
- The sensor-to-printhead leg is distance-based, because there is no downstream sensor after the filament switch sensor.

## Files You Will Actually Edit

Usually only these:

- `/etc/klipper/config/ace-addon.cfg`
- your Orca / Prusa-fork printer preset

You normally do not need to edit:

- `ace-addon.py`
- `ace-command.sh`

## Uninstall

```sh
cd /var/volatile/tmp/usb/sda1/CosmoACE-Integration
./uninstall.sh
```

## Package For Release

```sh
./create-package.sh
```

Output:

- `dist/cosmoace-integration-<timestamp>.tar.gz`
