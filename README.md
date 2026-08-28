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
- a tiny keep-alive service (`/etc/init.d/ace-keepalive`) — the ACE drops its
  own USB link ~3.5s after the last frame it received, which would clear feed
  assist mid-print. This is a shell loop writing one frame every 2s, not a
  service that owns the port; commands still talk to the ACE directly.
- an "ACE Pro" Mainsail dashboard panel, plus a bundled panel loader for
  COSMOS builds that don't ship the Mainsail Panel Extender (both skipped if
  Mainsail isn't the selected web UI)
- support for **two chained ACEs**: slots 1-4 on the first, 5-8 on the second
<img width="438" height="299" alt="image" src="https://github.com/user-attachments/assets/814cb587-f0f3-4201-95f9-11d421ea3524" />
<BR>
<br>

The supported print flow is:
1. Load the selected slot until the filament sensor triggers.
2. Push from the sensor to the printhead by a configured distance.
3. Sync-load, purge, wipe, and start printing.
4. On toolchange: cut, retract the whole path back to the slot in one completed
   unwind (so the ACE respools instead of piling up slack), load the next slot,
   push to the printhead, sync-load, purge, wipe, and resume.

The installer also replaces the stock `[filament_switch_sensor filament_sensor]` section (same object name, same pin) with an ACE-aware version, so runout/insert events are routed to CosmoACE instead of the stock pause/purge prompt flow. **No manual `printer.cfg` editing is required.**

## Requirements

- An Elegoo Centauri Carbon running a recent **COSMOS** build (tested against 26.07.0)
- An Anycubic ACE Pro
- Network or USB access to the printer
- COSMOS **CANVAS/AFC support must be disabled** (`elegoo_canvas = False` in `cosmos.conf`, the default). Both systems register `T0`–`T3` and cannot coexist; the installer refuses to run if CANVAS is enabled. Do not enable it after installing either — Klipper will fail to start until one of the two is removed.

Everything else the macros need (`MOVE_TO_TRAY`, `KICK`, `PAUSE_BASE`, `RESUME_BASE`, `gcode_shell_command`) ships with COSMOS.

## Hardware

You will need [this filament hub adapter](https://www.printables.com/model/1820714-anycubic-filament-hub-to-elegoo-centauri-carbon-fi) (or similar) which mounts to the Centauri Carbon's runout sensor:
<br>
<br>
<img width="540" height="540" alt="IMG_5330" src="https://github.com/user-attachments/assets/08e2b6c4-4dfd-4131-bc70-6a60aec7596f" />

### Modified ACE Cable
You will need to either modify the 4-pin end of the ACE cable or build an adapter. Pins 3 and 4 need to be swapped.
You might also be able to swap the pin on the mainboard connector itself, but that requires opening the printer.

Plug the ACE's USB cable into one of the printer's external USB ports. With a
single ACE, the add-on auto-detects its serial port (skipping ports owned by
Klipper, such as the internal toolhead MCU).

### A second ACE (8 colors)

Chain the second unit into the first one's spare USB port. That port is a plain
USB hub pass-through — the second ACE is its own serial device, not something
proxied through the first — so no special protocol support is needed. You also
need an 8-input filament hub feeding the printer's single sensor.

**No configuration needed.** The default `serial_port = auto` finds ACEs by
their USB product string and assigns them in USB-topology order: the unit
plugged into the printer is slots 1-4, the one chained into its spare port is
slots 5-8. (Device names can't be used for this — chained ACEs all report the
same USB by-id name, and `ttyACM` numbering shifts between boots.)

Slots 5-8 and `T4`-`T7` address the second unit, and the panel shows eight
spools with a dryer per unit. Only add an `[ace2]` section if you need to pin
its port or give it different tuning; keys omitted there fall back to `[ace]`.

Note that anything sensor-verified for slots 5-8 only works once that unit
physically feeds the printer's single filament sensor.

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

The installer asks one hardware question (or takes an env default when there is no TTY):

| Option | Env | Default | Meaning |
| --- | --- | --- | --- |
| Toolhead sensor | `HAS_TOOLHEAD` | from `ace-addon.conf`, else `0` | Canvas/CC1 sensor on `hotend:PB2` (`ace_toolhead.cfg`) |

Hub / chassis staging through `filament_sensor` on PC0 is always enabled (Shawn baseline).

Examples:

```sh
# Hub only (default — no toolhead sensor file)
HAS_TOOLHEAD=0 sh install.sh

# Hub + Canvas toolhead sensor (guided feed to the extruder inlet)
HAS_TOOLHEAD=1 sh install.sh
```

`has_toolhead` is written to `/user-resource/ace-addon/ace-addon.conf` under `[klipper]`
and mirrored into `ace-addon.cfg` as `variable_has_toolhead`. Existing
`sensor_name` / `toolhead_sensor_name` values in the conf are preserved on
reinstall. You can also toggle at runtime with `ACE_SET_HAS_TOOLHEAD ENABLE=0|1`
(runtime only until the next install; edit `ace-addon.conf` or re-run install to
persist). Toolhead hardware still needs `[include ace_toolhead.cfg]` installed.
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
- asks (or reads `HAS_TOOLHEAD`) whether you have a toolhead sensor
- copies the CLI tool, keep-alive script and config to `/user-resource/ace-addon/`
- writes `has_toolhead` into `ace-addon.conf` `[klipper]` (preserves sensor names)
- installs the keep-alive service (`/etc/init.d/ace-keepalive`, started at boot)
- installs the Mainsail panel to `/user-resource/webui-addons/panels/cosmoace/`,
  and on builds without the Mainsail Panel Extender also installs the bundled
  loader plus `/etc/init.d/cosmoace-webui`, which serves a patched Mainsail
  entry point from `/etc/webui` through Moonraker's existing static serving —
  no system files are modified
- installs the macro set to `/etc/klipper/config/ace-addon.cfg` and mirrors
  `has_toolhead` into `variable_has_toolhead`
- when `HAS_TOOLHEAD=1`, installs `/etc/klipper/config/ace_toolhead.cfg` and
  `[include ace_toolhead.cfg]`
- adds `[include ace-addon.cfg]` to `printer.cfg`
- removes the older long-running daemon service, if a previous version left one
- restarts Klipper

`ace-addon.conf` is preserved unless it contains settings that are broken on current COSMOS; `has_toolhead` is updated on each install while `sensor_name` / `toolhead_sensor_name` are left as-is. The macro file (`ace-addon.cfg`) is replaced when it differs from the shipped version (compared after applying the same sensor substitutions) — your previous copy is backed up to `/etc/klipper/config/config-backups/`, so re-apply tuning like `variable_load_to_printhead_mm` (or the toolhead search lengths) from there.

## Slicer Setup

Slicer setup is three one-liners: `ACE_START ...` in machine start
G-code, `T{next_extruder} PURGE={flush_length}` as the change-filament G-code,
and `ACE_END` in machine end G-code.

I have also added an exported preset for Cosmo ACE, in ocaslicer.
Import this, select machine preset, and tune any other machine settings as needed. (if you want)

## Required Tuning

The main tuning value in `/etc/klipper/config/ace-addon.cfg` is:
- `variable_load_to_printhead_mm` (default: `730`)

This is the distance from the filament sensor to the printhead. If too short, the filament won't reach; if too long, it will overfeed.
Note: If you change the location of your sensor, such as moving it closer tot the printhead, you will need to recalibrate this value.

Worth knowing about the two speed values: the ACE's spool take-up rollers rewind
slower than the feed gear retracts, so a fast `variable_retract_speed_mm_s`
trades slack inside the ACE for speed. Drop it toward `25` if slack becomes a
problem, or try `retract_mode = 1` in `ace-addon.conf`.

## Verify

After install, from the printer web UI console:

```gcode
ACE_STATUS
ACE_SLOT_STATUS SLOT=1     ; SLOT=5 for the first slot of a second ACE
ACE_LOAD_TO_SENSOR SLOT=1
ACE_UNLOAD_TO_SENSOR SLOT=1
ACE_LOAD SLOT=1 TEMP=220   ; full load incl. purge (hot end will heat)
ACE_UNLOAD                 ; full unload incl. cut
```

Logs: `/board-resource/ace-addon.log` on the printer.
Keep-alive: `/etc/init.d/ace-keepalive status`. If it isn't running the flow
still works, but feed assist won't survive a print and the ACE will
re-enumerate on USB every few seconds.

## Further Reading

- [docs/ACE_MACROS.md](docs/ACE_MACROS.md) — every macro, config variable, and design note
- [docs/ORCA_GCODE.md](docs/ORCA_GCODE.md) — the slicer one-liners
- [docs/HARDWARE_NOTES.md](docs/HARDWARE_NOTES.md) — ACE watchdog, two-unit USB topology, cutter mechanics, board limits

## Surviving Updates and Resets

- **COSMOS firmware update:** everything survives (`/user-resource/`, `printer.cfg`, and `ace-addon.cfg` are all preserved). COSMOS wipes only its own `*-readonly` config directories.
- **Factory reset:** wipes `/etc`, which removes the macro config and the `printer.cfg` include. `/user-resource/` survives — just re-run `install.sh`.

## Uninstall

The installer keeps a copy of the uninstaller at a stable path:

```sh
sh /user-resource/ace-addon/uninstall.sh
```

This removes the include line, macros, add-on files, the keep-alive service and
the Mainsail panel (and its bundled loader, unless another panel still needs
it), restoring stock COSMOS filament sensor behavior. Your tuned macro config is
backed up to `/etc/klipper/config/config-backups/` first.
