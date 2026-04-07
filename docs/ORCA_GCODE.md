# Orca Slicer G-Code

Use these macros in OrcaSlicer or a PrusaSlicer-style fork.

CosmoACE is designed for a blocking multicolor flow:

1. Start on the selected slot.
2. On color change, unload the current slot, clear the hub, load the next slot, push to the printhead, sync-load, purge, wipe, and resume.
3. On end print, clear the active slot and reset ACE state.

## Start G-Code

```gcode
M400 ; wait for buffer to clear
M220 S100 ; feed speed 100%
M221 S100 ; flow rate 100%

M104 S140 ; pre-heat nozzle
M140 S[bed_temperature_initial_layer_single]
G90

M106 P2 S255
M190 S[bed_temperature_initial_layer_single]
M106 P2 S0

_ACE_ORCA_START SLOT={initial_extruder + 1} TEMP=[nozzle_temperature_initial_layer]
```

## Change Filament G-Code

Put the swap flow here, not in `Tool change G-code`.

```gcode
_ACE_ORCA_TOOLCHANGE SLOT={next_extruder + 1} TEMP={new_filament_temp} PURGE={flush_length}
SET_PRINT_STATS_INFO CURRENT_LAYER={layer_num + 1}
```

## End G-Code

```gcode
M400 ; wait for buffer to clear
_ACE_ORCA_END_PRINT

M140 S0 ; bed off
M106 S255 ; cooling nozzle
M83
G92 E0
G2 I1 J0 Z{max_layer_z+0.5} F3000
G90
{if max_layer_z > 50}G1 Z{min(max_layer_z+50, printable_height+0.5)} F20000{else}G1 Z100 F20000 {endif}
M204 S5000
M400
G1 X202 F20000
M400
G1 Y250 F20000
G1 Y264.5 F1200
M400
M104 S0
M140 S0
M106 S0
M106 P2 S0
M106 P3 S0
M84
```

## Notes

- Orca's `flush_length` is passed directly into `_ACE_ORCA_TOOLCHANGE`.
- The slicer should call `_ACE_ORCA_*` macros directly.
- Keep `Tool change G-code` empty if you are already using `Change Filament G-code`.
- `initial_extruder` and `next_extruder` are used as Orca placeholder indices, so the macros add `+ 1` to match ACE slot numbers.

## Required Printer Setup

Your printer config needs the filament sensor to call:

```cfg
runout_gcode:
  _ACE_SENSOR_EVENT EVENT=RUNOUT
insert_gcode:
  _ACE_SENSOR_EVENT EVENT=INSERT
```

If your sensor object is not named `runout`, update `variable_sensor_name` in `/etc/klipper/config/ace-addon.cfg` or call:

```gcode
ACE_SET_SENSOR_NAME NAME=your_sensor_name
```
