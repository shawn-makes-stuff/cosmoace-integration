# CosmoACE Integration

CosmoACE is a lightweight Anycubic ACE Pro add-on for CosmOS / OpenCentauri.

This repo is intentionally focused on:
- CosmOS / OpenCentauri
- OrcaSlicer and PrusaSlicer-style forks
- lightweight printer-side integration

It does not target generic Klipper distributions or every slicer.

## What It Does

CosmoACE installs:
- a Python-based ACE CLI tool
- a shell wrapper Klipper can call
- a Klipper macro set for blocking start, toolchange, and end-print flows

The supported print flow is:
1. Load the selected slot until the filament sensor triggers.
2. Push from the sensor to the printhead by a configured distance.
3. Sync-load, purge, wipe, and start printing.
4. On toolchange, cut, unload back to the sensor, clear the hub, load the next slot, push to the printhead, sync-load, purge, wipe, and resume.

## Requirements
An Elegoo Centauri Carbon and an Anycubic ACE Pro

- A working CosmOS installation
- SSH access as `root`
- Klipper `gcode_shell_command`
- A configured `filament_switch_sensor`
- Printer-side tray / wipe / pause macros already present:
  - `MOVE_TO_TRAY`
  - `M729`
  - `PAUSE_BASE`
  - `RESUME`

Set your gcode in OrcaSlicer:
[OrcaSlicer G-Code Guide](docs/ORCA_GCODE.md)

## Install

1. Copy this repository to a USB drive.
2. SSH into the printer as `root` (password: `OpenCentauri`).
3. Run:

```sh
# Navigate to your USB mount (usually /user-resource/.tmp/ on Centauri)
cd /user-resource/.tmp/cosmoace-integration
chmod +x install.sh uninstall.sh
./install.sh
```

### Manual Install (If script fails)
If you prefer to install manually or the script encounters issues with your specific firmware version:

1. **Remount as Read-Write:**
   ```sh
   mount -o remount,rw /
   ```
2. **Create Directories:**
   ```sh
   mkdir -p /user-resource/ace-addon
   mkdir -p /etc/klipper/config/klipper-readonly
   ```
3. **Copy Files:**
   ```sh
   cp files/ace-addon.py /user-resource/ace-addon/
   cp files/ace-command.sh /user-resource/ace-addon/
   cp files/ace-addon.conf /user-resource/ace-addon/
   cp files/ace_macros.cfg /etc/klipper/config/ace-addon.cfg
   ```
4. **Set Permissions & Symlink:**
   ```sh
   chmod +x /user-resource/ace-addon/*.sh /user-resource/ace-addon/*.py
   ln -sfn /etc/klipper/config/ace-addon.cfg /etc/klipper/config/klipper-readonly/ace-addon.cfg
   ```
5. **Remount as Read-Only:**
   ```sh
   mount -o remount,ro /
   ```
6. **Restart Klipper:**
   ```sh
   service klipper restart
   ```

## Hardware
You will need this filament hub adapter which mounts to the Carbon Centauri's run-out sensor:
[Filament Hub Adapter (Printables)](https://www.printables.com/model/1662192-centauri-carbon-multi-material-filament-hub-4-colo)

### Modified ACE Cable
You will need to either modify the 4-pin end of the ACE cable or build an adapter. Pins 3 and 4 need to be swapped.

## Required Printer Config

Add this to your `printer.cfg`:

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
- `pause_on_runout` must be `False`.
- The macro name must be `_ACE_SENSOR_EVENT`.
- If your sensor object is not named `runout`, update `variable_sensor_name` in `ace-addon.cfg`.

## Required Tuning

The main tuning value in `ace-addon.cfg` is:
- `variable_load_to_printhead_mm` (Default: `730`)

This is the distance from your filament sensor to the printhead. If too short, the filament won't reach; if too long, it will overfeed.

## Uninstall

```sh
cd /user-resource/.tmp/cosmoace-integration
./uninstall.sh
```
