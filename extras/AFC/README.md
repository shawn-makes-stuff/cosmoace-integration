# ACE Pro on AFC — experimental

> **Experimental. Not CosmoACE.** This is a separate path to the same
> hardware: instead of CosmoACE's shell-command macros, the ACE is driven as a
> native [AFC](https://github.com/ArmoredTurtle/AFC-Klipper-Add-On) unit type.
> It is related to this repo only by being "ACE on COSMOS". The two cannot run
> at the same time — both register `T0`–`T3`. Uninstall CosmoACE
> (`./uninstall.sh`) before using this.
>
> The ACE is not officially supported by AFC. `AFC_ACE.py` is not part of
> upstream AFC and is not reviewed by them.

Assumes you already know how to run AFC.

## What's here

| File | Goes where |
|---|---|
| `AFC_ACE.py` | `/usr/share/klipper/klippy/extras/` |
| `afc-ace.cfg` | `/etc/klipper/config/` — the unit, lanes, hub, toolhead |
| `afc-ace-macros.cfg` | `/etc/klipper/config/` — cutter, purge, print-start prep |

`AFC_ACE.py` is self-contained: it registers its own unit type with AFC's lane
gates on import, so **no AFC file needs editing**. Drop it in and restart.

## Install

AFC first, the normal way. Then:

```sh
# 1. the driver (this path is a writable ext4 mount on COSMOS)
scp AFC_ACE.py root@printer:/usr/share/klipper/klippy/extras/

# 2. the config
scp afc-ace.cfg afc-ace-macros.cfg root@printer:/etc/klipper/config/
```

Then include them from `printer.cfg`, **after** the COSMOS includes so the
frame-sensor override wins:

```ini
[include klipper-readonly/*.cfg]
[include afc.cfg]              # AFC's own installer wrote this
[include afc-ace.cfg]
[include afc-ace-macros.cfg]
```

Set `serial:` in `afc-ace.cfg` to your unit — `ls -l /dev/serial/by-path/` on
the printer. Use a by-path name; `/dev/ttyACM*` numbering moves between boots.

Restart Klipper. `PREP` runs on its own and the lanes should come up populated.

## Slicer

Start gcode (OrcaSlicer), replacing whatever `PRINT_START` line you have:

```
M400
PRINT_START EXTRUDER=[nozzle_temperature_initial_layer] BED=[bed_temperature_initial_layer_single] CHAMBER=0 TOOL={initial_extruder}
AFC_PRINT_PREP TOOL={initial_extruder} PURGE_LENGTH=100 EXTRUDER=[nozzle_temperature_initial_layer]
```

`AFC_PRINT_PREP` is the piece worth understanding: it parks over the tray,
heats there, then either purges the already-loaded tool or starts the change to
the one the print wants. The purge on the already-loaded path is deliberate —
after a heat-up the nozzle has oozed and left air behind the tip, so purging
pulls the filament the rest of the way in with the extruder rather than the ACE
shoving it, and gets flow going before the first line.

Leave the toolchange gcode alone; AFC's `T0`–`T3` handle it.

## The one number to tune

`afc_bowden_length` in `afc-ace.cfg` — the blind push from the frame sensor to
the extruder inlet. Sensor → nozzle total is `afc_bowden_length + tool_stn`
(750mm as shipped: 710 + 40, measured on a Centauri Carbon).

```
SET_BOWDEN_LENGTH HUB=ACE_1 LENGTH=+10     # live, effective next load
```

Too short and the gears never grab (prints air on layer 1). Too long and you
get ooze before the purge. The first one wastes a print, so if it comes up
short, go **up** in ~10mm steps. There is no save command — write the final
number back into `afc-ace.cfg` by hand.

Everything else is sensor-referenced: `dist_hub` and the unload lengths are
caps, not measurements, so they only need to be generous.

## Hardware

Same as CosmoACE — see the main [README](../../README.md) for the filament hub
adapter and the pin 3/4 cable swap. Nothing extra.

## Extras this gets you over CosmoACE

Because the ACE is a real AFC unit here, the AFC ecosystem applies: Spoolman,
runout with endless-spool groups, `AFC_STATS`, the Mainsail/Fluidd AFC panels,
and the MMU panel in grumpyscreen.

The dryer is drivable from gcode. Use the dedicated command when you want the
ACE's own timed dry cycle (temp, duration, fan):

```
AFC_ACE_DRYER_START UNIT=ACE_1 TEMP=45 DURATION=240 FAN_SPEED=7000
AFC_ACE_DRYER_STOP UNIT=ACE_1
```

It is also registered as a normal Klipper heater, so it graphs and shows up in
any UI's temperature list:

```
SET_HEATER_TEMPERATURE HEATER=ace_dryer_ACE_1 TARGET=45
```

## Known rough edges

- A second chained ACE works (`optional`/`monitor_only`, commented out in
  `afc-ace.cfg`) but has had far less use than a single unit.
- The ACE drops its USB link ~3.5s after the last frame it receives. The driver
  keeps its own heartbeat, so no keep-alive service is needed — but nothing
  else may hold that serial port. If CosmoACE's `ace-keepalive` is still
  installed, it will fight the driver for the port.
- COSMOS **CANVAS/AFC support must stay disabled** (`elegoo_canvas = False` in
  `cosmos.conf`, the default).
