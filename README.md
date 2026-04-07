# CosmoACE Integration

CosmoACE is a lightweight Anycubic ACE Pro add-on for CosmOS / OpenCentauri.

This repo is intentionally focused on:
- CosmOS / OpenCentauri
- OrcaSlicer and PrusaSlicer-style forks
- lightweight printer-side integration

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

- A working CosmOS installation
- SSH access as `root`
- Klipper `gcode_shell_command`
- A configured `filament_switch_sensor`
- Printer-side tray / wipe / pause macros already present:
  - `MOVE_TO_TRAY`
  - `M729`
  - `PAUSE_BASE`
  - `RESUME`

Set your gcode in orcaslicer
https://github.com/shawn-makes-stuff/cosmoace-integration/blob/main/docs/ORCA_GCODE.md

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

## Hardware
You will need this filament hub adapter which mounts to the Carbon Centauri's run-out sensor
https://www.printables.com/model/1662192-centauri-carbon-multi-material-filament-hub-4-colo

A modified ace cable.
You will need to either modify the 4 pin end of the ace cable, or build an adapter. Pins 3 and 4 need to be swapped.
<img width="210" height="247" alt="image" src="https://github.com/user-attachments/assets/815fdfb6-2ac8-48da-8321-fbdc7530f543" />


## Required Printer Config

The only required manual printer config is your existing filament sensor hook, add this to printer.cfg

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
path. With the stock setup, the distance from sensor to printhead is about 730. Some tuning might still be needed in ace_addon.cfg

```cfg
variable_load_to_printhead_mm: 730
```

If this value is too short, the new filament will not reach the hotend.
If it is too long, you will overfeed before sync-load / purge.


## Uninstall

```sh
cd /var/volatile/tmp/usb/sda1/CosmoACE-Integration
./uninstall.sh
```

## Package For Release

```sh
./create-package.sh
```
