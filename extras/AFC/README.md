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
| `AFC_ACE.py` | Klipper's extras, via the overlay below |
| `afc-ace-extras.init` | `/etc/init.d/afc-ace-extras` — mounts that overlay at boot |
| `afc-ace.cfg` | `/etc/klipper/config/` — the unit, lanes, hub, toolhead |
| `afc-ace-macros.cfg` | `/etc/klipper/config/` — cutter, purge |
| `install.sh` | run on the printer; does all of the above |

`AFC_ACE.py` is self-contained: it registers its own unit type with AFC's lane
gates on import, so **no AFC file needs editing**. COSMOS already ships AFC.

## Install

COSMOS (26.09) runs Klipper from a read-only image, so the driver cannot be
copied into `klippy/extras`. `install.sh` adds a boot script that overlays a
writable layer from `/data/afc-ace/` onto that folder before Klipper starts,
puts the driver there, copies the configs and adds the includes to
`printer.cfg` (after the COSMOS ones, with a backup in `config-backups/`):

```ini
[include klipper-readonly/*.cfg]
[include extras-readonly/afc.cfg]   # COSMOS's own: PREP, BT_* macros
[include afc-ace.cfg]
[include afc-ace-macros.cfg]
```

```sh
scp -r extras/AFC root@printer:/tmp/afc-ace
ssh root@printer sh /tmp/afc-ace/install.sh
```

Re-run it after a COSMOS update. It never overwrites an existing
`afc-ace.cfg`, which holds your serial path and tuned bowden length. Set
`serial:` there to your unit — `ls -l /dev/serial/by-path/` on the printer. Use
a by-path name; `/dev/ttyACM*` numbering moves between boots.

To uninstall: remove the three includes, delete `/etc/init.d/afc-ace-extras`
and `/etc/rc*.d/S93afc-ace-extras`, and reboot.

## Slicer

Start gcode (OrcaSlicer), replacing whatever `PRINT_START` line you have:

```
M400
PRINT_START EXTRUDER=[nozzle_temperature_initial_layer] BED=[bed_temperature_initial_layer_single] CHAMBER=0 TOOL={initial_extruder}
```

`TOOL=` is what matters: since 26.08, COSMOS's `PRINT_START` runs
`T{TOOL}` itself when AFC is loaded, then heats and runs KAMP's `LINE_PURGE`
beside the part (`adaptive_purge` in `cosmos.conf`). A load purges over the
tray on its own (AFC's `poop_cmd`); the line purge primes a tool that was
already loaded. Nothing else is needed in the start gcode.

Change filament gcode: `T{next_extruder} PURGE_LENGTH={flush_length}`. AFC's
`T0`–`T3` handle the change.

## The one number to tune

`afc_bowden_length` in `afc-ace.cfg` — the blind push from the frame sensor to
just short of the extruder gears (810 as shipped: 815mm measured to the gears
on a Centauri Carbon). `tool_stn` (5) then pushes the last few mm with the
extruder turning, and the purge pulls the filament on to the nozzle.

To measure yours, push a lane to the gears by hand, then retract it in one long
`LANE_MOVE` plus short steps until the sensor clears, subtracting ~1mm per
command (see Known rough edges).

```
SET_BOWDEN_LENGTH HUB=ACE_1 LENGTH=+10     # live, effective next load
```

Too short and the gears never grab (dry purge, air on layer 1). Too long and
the ACE shoves filament into stopped gears. Stay a few mm short and let
`tool_stn` close the gap. There is no save command — write the final number
back into `afc-ace.cfg` by hand.

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

A dry cycle runs its full duration: `TURN_OFF_HEATERS` (idle timeout, print
end/cancel macros) does not stop it. Stop it with `AFC_ACE_DRYER_STOP`, M112,
or — on Kalico — `SET_HEATER_TEMPERATURE ... TARGET=0`. On mainline Klipper
that last one cannot be told apart from `TURN_OFF_HEATERS`, so use
`AFC_ACE_DRYER_STOP` there.

## Recovering a lane

`AFC_RESET` hands ACE lanes to the driver, but AFC refuses it earlier whenever
no lane is tool-loaded. Run the driver's command directly to pull a lane back
clear of the sensors and park it behind the splitter:

```
AFC_ACE_RESET UNIT=ACE_1 LANE=lane2
```

## Known rough edges

- Every ACE move command loses about 1mm, whatever its length (measured:
  10 × 5mm retracts moved ~40mm, one 50mm retract ~50mm). One long move is
  accurate; a sum of short `LANE_MOVE` steps is not. When measuring by
  stepping, subtract ~1mm per command.

- A second chained ACE works (`optional`/`monitor_only`, commented out in
  `afc-ace.cfg`) but has had far less use than a single unit.
- The ACE drops its USB link ~3.5s after the last frame it receives. The driver
  keeps its own heartbeat, so no keep-alive service is needed — but nothing
  else may hold that serial port. If CosmoACE's `ace-keepalive` is still
  installed, it will fight the driver for the port.
- COSMOS **CANVAS/AFC support must stay disabled** (`elegoo_canvas = False` in
  `cosmos.conf`, the default).
