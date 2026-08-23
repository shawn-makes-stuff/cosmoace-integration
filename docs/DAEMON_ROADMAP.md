# Daemon Roadmap (pinned — not started)

Decision: replace the CLI-per-command transport with a persistent daemon that
owns the ACE serial port. The CLI/`ace_rpc` entry point stays but becomes a
thin client over a unix socket. Supersedes the interim flock-heartbeat idea —
that option cannot deliver cancel or mid-print comms.

## Why

Proven 2026-08-23: the ACE Pro drops its USB link ~3.5s after the last
complete frame (comms watchdog) and re-enumerates (~0.5s offline). The
CLI-per-command design therefore reset-loops the ACE permanently. Consequences:

- Intermittent errno-5 failures when a command lands in the reconnect window
  (mitigated by the rpc_call retry, but only mitigated).
- Feed assist is almost certainly wiped by the first reset after `ACE_LOAD`
  finishes — prints likely run assist-less, dragging the full bowden.
  (Unverified: `assist-start`, wait 15s, `get_status` — check before build.)

## Core requirements

1. **Persistent connection + heartbeat** — `get_status` every ~2s, no resets,
   ever. Reconnect/re-resolve by-id path on any drop.
2. **Desired-state reconciliation** — daemon tracks what *should* be true
   (assist on for slot N, dryer running at T°C) and re-arms it after any
   reset/reconnect. This is what makes "feed assist through all movements"
   real: assist survives everything, is on whenever filament is loaded.
3. **Non-blocking operations** — motion commands return a job id immediately.
   One motion at a time (daemon queues/rejects overlap). Macros wait by
   polling job state in short calls from a `delayed_gcode` loop, so the
   Klipper gcode queue stays responsive: PAUSE / CANCEL_PRINT / M112 are
   never stuck behind a 40s purge or 60s unwind.
4. **Abort endpoint** — `CANCEL_PRINT` hooks an `ACE_ABORT` macro → daemon
   issues `stop_feed`/`stop_unwind`, kills the job, then runs **slack
   recovery**: an aborted unwind skips the spool take-up (known slack
   pile-up), so abort must follow with a short completed unwind to respool.
5. **Mid-print communication, slot config locked** — the heartbeat keeps slot
   colors/types/RFID fresh for the UI panel during prints, but slot
   remapping / set_filament_info is rejected while a print is active.

## Complements to build on top (roughly in value order)

- **Toolchange preflight**: before `ACE_START` / each `T<n>`, verify the
  target slot is `ready` and its RFID type/color matches what the gcode
  expects; refuse with a clear error instead of feeding a wrong or empty slot.
- **Resumable toolchange state machine**: daemon records which phase a swap
  died in (cut / unwind / feed / sync / purge); an `ACE_RECOVER` macro resumes
  from that phase instead of the current "figure it out by sensor" dance.
- **Endless spool / runout failover**: on runout, auto-switch to another slot
  with matching material+color and continue the print (daemon already sees
  slot status live). Opt-in.
- **Dryer management**: keep drying through a print, auto-stop at print end;
  expose in the Mainsail panel.
- **Health telemetry**: count watchdog resets, assist drop-outs, feed slip
  (assist_count deltas vs extruded mm); surface in `ACE_STATUS` and the panel.
- **Multi-unit foundation**: address every op as (unit, index) from day one —
  units are separate USB serial devices pinned by USB path (multiACE model);
  user slots 1–8 map `unit=(slot-1)//4`, `index=(slot-1)%4`. The daemon is
  the natural single owner for N transports. 8-slot hub exists (Kobra series).

## Constraints

- **No rewrite.** The daemon is the existing `AceController.execute()` behind
  a unix socket instead of behind argparse: `ace-addon.py` grows a `serve`
  subcommand (accept loop → json line → `execute()` → json line back) plus
  the heartbeat/reconcile thread. ~150 lines added, nothing rewritten.
  Existing macros keep working unchanged in phase 1.
- **The Carbon is tiny** (2-core ARMv7, limited RAM; klippy + moonraker +
  screen UI already running). Budget: one long-lived python proc (~15MB RSS),
  stdlib + pyserial only, no frameworks. A 2s heartbeat is noise CPU-wise.
  Net win available: `ace-command.sh` can talk to the socket with busybox
  `nc` instead of spawning a fresh python interpreter per macro call —
  today's biggest per-command cost (~1s startup, CPU spike) disappears.
- **8-color later, no dead weight now.** Don't build multi-unit, but keep
  addressing clean so it drops in: controller holds a dict of transports
  keyed by unit (one entry today), ops resolve user slot → (unit, index).
  That's a shape choice, not a feature.

## Migration sketch (phased, each phase ships alone)

1. **Daemon, blocking semantics**: `serve` subcommand + heartbeat +
   desired-state reconcile + init.d service. CLI tries the socket, falls
   back to direct serial when the daemon is down (today's behavior =
   degraded mode). Macros untouched. This alone kills the reset loop and
   keeps assist alive — most of the value, smallest diff.
2. **nc client path** in ace-command.sh (perf win, optional).
3. **Job model**: non-blocking ops + `ACE_ABORT` + slack recovery; macro
   waits become delayed_gcode polls; hook CANCEL_PRINT.
4. **Preflight + resumable toolchange state machine + panel wiring.**
5. Endless spool, dryer, telemetry, multi-unit — as wanted.

Keep the rpc_call retry even after the daemon lands — belt and suspenders.
