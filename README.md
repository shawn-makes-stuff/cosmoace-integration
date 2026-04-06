# CosmoACE Integration

Standalone Anycubic ACE Pro add-on package for OpenCentauri CosmOS.

This package installs on top of an already-running CosmOS printer. It does not
require a firmware rebuild.

This build is macro-driven. Klipper macros call the ACE Python transport
directly through a small shell wrapper on the printer.

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

The installer auto-registers the ACE macros with Klipper and restarts the
`klipper` service when available.

The only manual printer-side change is your existing filament sensor block in
`printer.cfg`. For your current sensor name `runout`, it should be:

```cfg
[filament_switch_sensor runout]
switch_pin: PC0
pause_on_runout: False
event_delay: 0.2
debounce_delay: 0.02
runout_gcode:
  ACE_SENSOR_EVENT EVENT=RUNOUT
insert_gcode:
  ACE_SENSOR_EVENT EVENT=INSERT
```

If your sensor object has a different name, either update
`variable_sensor_name` in `/etc/klipper/config/ace-addon.cfg`
or run:

```gcode
ACE_SET_SENSOR_NAME NAME=your_sensor_name
```

## Main Macros

- `ACE_START_PRINT SLOT=1`
  First-load flow. Homes, moves to the tray, feeds from ACE until the sensor
  inserts, pushes about 730mm to the printhead, sync-loads through the
  hotend, purges, and wipes.
- `ACE_ORCA_START SLOT=1`
  Blocking OrcaSlicer-safe first-load flow. Loads to the sensor, pushes to the
  printhead, heats, sync-loads, purges, wipes, and only then returns.
- `ACE_COLOR_SWAP SLOT=2`
  Saves the print position, pauses without using the stock park move, raises Z
  by 5mm, cuts the current filament, moves to the tray, unloads about 900mm to
  the sensor, retracts the slot about 90mm to clear the hub, loads the new
  slot, sync-loads, purges, wipes, returns XY, returns Z, and resumes.
- `ACE_ORCA_TOOLCHANGE SLOT=2`
  Blocking OrcaSlicer-safe color change flow. Pauses, cuts, unloads to the
  sensor, retracts the old slot clear, loads the new slot, purges, wipes,
  returns to the saved print position, and resumes before returning.
- `ACE_END_PRINT_CLEAR`
  Raises Z by 5mm, cuts the filament, moves to the tray, cools the hotend,
  unloads to the sensor, and retracts the active slot clear for the next
  print.
- `ACE_ORCA_END_PRINT`
  Blocking OrcaSlicer-safe end-of-print clear. Cuts, cools, unloads to the
  sensor, retracts the active slot clear, and resets ACE state.
- `ACE_RETRACT_SLOT`
  Retracts the active slot a short distance past the sensor. Default is 90mm.
- `ACE_SYNC_LOAD`
  Feeds the ACE and extruder together in chunks to pull filament through the
  hotend before purge.
- `ACE_WIPE`
  Runs the tray wipe motion only.
- `ACE_STATUS`
  Prints the current ACE macro state.

Defaults like the 730mm load distance, 900mm unload-to-sensor distance, 90mm
slot retract distance, 40mm sync-load length, purge length, and speeds live in
`/etc/klipper/config/ace-addon.cfg`.

## Requirements

- The Klipper `gcode_shell_command` extension must be installed.
- `MOVE_TO_TRAY`, `PAUSE_BASE`, `RESUME`, and `M729` must exist on the
  printer. On stock OpenCentauri/CosmOS these come from the bundled tray and
  Mainsail macros.
- `ACE_CUT_FILAMENT` uses the built-in cutter coordinates in `ace-addon.cfg`.

## Uninstall

```sh
cd /var/volatile/tmp/usb/sda1/CosmoACE-Integration
./uninstall.sh
```

## Package For Release

```sh
./create-package.sh
```

Output goes to:

- `dist/cosmoace-integration-<timestamp>.tar.gz`
