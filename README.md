# CosmoACE Integration

CosmoACE is a lightweight Anycubic ACE Pro add-on for COSMOS on the Elegoo Centauri Carbon.

This repo is intentionally focused on:
- COSMOS firmware (not stock, not generic Klipper distributions)
- OrcaSlicer and PrusaSlicer-style forks
- lightweight printer-side integration

## What It Does

CosmoACE installs:
- a Python-based ACE CLI tool (talks the ACE framed JSON-RPC protocol over USB serial)
- a shell wrapper Klipper calls via `gcode_shell_command`
- a Klipper macro set for blocking start, toolchange, and end-print flows

The supported print flow is:
1. Load the selected slot until the filament sensor triggers.
2. Push from the sensor to the printhead by a configured distance.
3. Sync-load, purge, wipe, and start printing.
4. On toolchange: cut, unload back to the sensor, clear the hub, load the next slot, push to the printhead, sync-load, purge, wipe, and resume.

The installer also replaces the stock `[filament_switch_sensor filament_sensor]` section (same object name, same pin) with an ACE-aware version, so runout/insert events are routed to CosmoACE instead of the stock pause/purge prompt flow. **No manual `printer.cfg` editing is required.**

## Requirements

- An Elegoo Centauri Carbon running a recent **COSMOS** build (tested against 26.07.0)
- An Anycubic ACE Pro
- Network or USB access to the printer
- COSMOS **CANVAS/AFC support must be disabled** (`elegoo_canvas = False` in `cosmos.conf`, the default). Both systems register `T0`–`T3` and cannot coexist; the installer refuses to run if CANVAS is enabled. Do not enable it after installing either — Klipper will fail to start until one of the two is removed.

Everything else the macros need (`MOVE_TO_TRAY`, `KICK`, `PAUSE_BASE`, `RESUME_BASE`, `gcode_shell_command`) ships with COSMOS.

## Hardware

You will need this filament hub adapter (or similar) which mounts to the Centauri Carbon's runout sensor:
[Filament Hub Adapter (Printables)](https://www.printables.com/model/1662192-centauri-carbon-multi-material-filament-hub-4-colo)

### Modified ACE Cable
You will need to either modify the 4-pin end of the ACE cable or build an adapter. Pins 3 and 4 need to be swapped.
You might also be able to swap the pin on the mainboard connector itself, but that requires opening the printer.

Plug the ACE's USB cable into one of the printer's external USB ports. The add-on auto-detects the ACE serial port (it skips ports owned by Klipper, such as the internal toolhead MCU).

## Install

A note on the environment: COSMOS is a minimal embedded image (busybox +
sysvinit, read-only rootfs) — there is no `apt`, `pip`, `git`, or `systemctl`
on the printer. The installer only uses tools that ship with COSMOS.

SSH login is `root` with an **empty password** (just press Enter).

### Option A: download on the printer (no computer-side tools needed)

SSH into the printer and run:

```sh
cd /user-resource
curl -k -f -S -L -o cosmoace.tar.gz https://github.com/shawn-makes-stuff/cosmoace-integration/archive/refs/heads/main.tar.gz
tar xzf cosmoace.tar.gz && rm cosmoace.tar.gz
sh cosmoace-integration-main/install.sh
```

(`-k` matches how COSMOS's own updater fetches from GitHub — certificate
verification is not reliable on the device.)

### Option B: via USB drive

1. Copy this repository folder onto the root of your **FAT32** USB drive (not exFAT/NTFS —
   COSMOS only automounts vfat and ext2/3/4).
2. Plug the drive into the printer. COSMOS automounts partitions at
   `/tmp/usb/<name>`, normally `/tmp/usb/sda1`. If nothing appears under
   `/tmp/usb/`, the drive likely has no partition table or an unsupported
   filesystem.
3. SSH into the printer and run:

```sh
# the USB mount is noexec, so invoke the script through sh:
sh /tmp/usb/sda1/cosmoace-integration/install.sh
```

### Option C: copy from your computer (scp)

COSMOS's SSH server is dropbear, which has no SFTP support — modern OpenSSH
clients (9.0+) default to SFTP mode for `scp`, so force the classic protocol
with `-O`:

```sh
scp -O -r cosmoace-integration root@<printer-ip>:/user-resource/
ssh root@<printer-ip>
sh /user-resource/cosmoace-integration/install.sh
```

If your `scp` rejects `-O` as an unknown option, it is an older client that
already uses the classic protocol — just omit the flag.

The installer is idempotent — re-run it any time. It:
- copies the CLI tool and config to `/user-resource/ace-addon/`
- installs the macro set to `/etc/klipper/config/ace-addon.cfg`
- adds `[include ace-addon.cfg]` to `printer.cfg`
- restarts Klipper

`ace-addon.conf` is preserved unless it contains settings that are broken on current COSMOS. The macro file (`ace-addon.cfg`) is replaced on every install when it differs from the shipped version — your previous copy is backed up to `/etc/klipper/config/config-backups/`, so re-apply tuning like `variable_load_to_printhead_mm` from there.

## Slicer Setup

The whole slicer setup is three one-liners: `ACE_START ...` in machine start
G-code, `T{next_extruder} PURGE={flush_length}` as the change-filament G-code,
and `ACE_END` in machine end G-code. See the
[OrcaSlicer G-Code Guide](docs/ORCA_GCODE.md).
Macro reference and tuning variables: [ACE Macro Reference](docs/ACE_MACROS.md).

I have also added an exported preset for ocaslicer, just import and print.

## Required Tuning

The main tuning value in `/etc/klipper/config/ace-addon.cfg` is:
- `variable_load_to_printhead_mm` (default: `730`)

This is the distance from the filament sensor to the printhead. If too short, the filament won't reach; if too long, it will overfeed.
Note: If you change the location of your sensor, such as moving it closer tot the printhead, you will need to recalibrate this value.

## Verify

After install, from the printer web UI console:

```gcode
ACE_STATUS
ACE_SLOT_STATUS SLOT=1
ACE_LOAD_TO_SENSOR SLOT=1
ACE_UNLOAD_TO_SENSOR SLOT=1
ACE_LOAD SLOT=1 TEMP=220   ; full load incl. purge (hot end will heat)
ACE_UNLOAD                 ; full unload incl. cut
```

Logs: `/board-resource/ace-addon.log` on the printer.

## Surviving Updates and Resets

- **COSMOS firmware update:** everything survives (`/user-resource/`, `printer.cfg`, and `ace-addon.cfg` are all preserved). COSMOS wipes only its own `*-readonly` config directories.
- **Factory reset:** wipes `/etc`, which removes the macro config and the `printer.cfg` include. `/user-resource/` survives — just re-run `install.sh`.

## Uninstall

The installer keeps a copy of the uninstaller at a stable path:

```sh
sh /user-resource/ace-addon/uninstall.sh
```

This removes the include line, macros, and add-on files, restoring stock COSMOS filament sensor behavior. Your tuned macro config is backed up to `/etc/klipper/config/config-backups/` first.
