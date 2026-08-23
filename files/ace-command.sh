#!/bin/sh
set -eu

PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
ACE_SCRIPT="${ACE_SCRIPT:-/user-resource/ace-addon/ace-addon.py}"
ACE_CONFIG="${ACE_ADDON_CONFIG:-/user-resource/ace-addon/ace-addon.conf}"
# Daemon thin client: busybox nc to the daemon's loopback TCP listener.
# Skips the ~1s python startup per call (a toolchange makes ~20 calls).
NC_PORT="${ACE_DAEMON_PORT:-7877}"

usage() {
    echo "Usage: $0 <cmd> [args...]"
    echo "Commands: feed, feed-wait, retract, retract-wait, feed-to-sensor, retract-to-sensor, wait-motion, clear-hub, stop, stop-unwind, assist-start, assist-stop, dry-start, dry-stop, status, status-refresh, slot-status, assert-slot-ready, set-filament, set-serial, debug-cli"
    exit 1
}

# $1 = daemon JSON payload, $2 = "always" to print success output too,
# remaining args = python fallback argv. Tries nc first; an empty response
# means the daemon is down and the python CLI takes over (direct serial).
run_cmd() {
    payload="$1"; print_mode="$2"; shift 2
    resp="$(printf '%s\n' "$payload" | nc 127.0.0.1 "$NC_PORT" 2>/dev/null || true)"
    if [ -n "$resp" ]; then
        case "$resp" in
            *'"ok": true'*|*'"ok":true'*)
                [ "$print_mode" = always ] && printf '%s\n' "$resp"
                return 0
                ;;
            *)
                printf '%s\n' "$resp"
                return 1
                ;;
        esac
    fi
    "${PYTHON_BIN}" "${ACE_SCRIPT}" --config "${ACE_CONFIG}" "$@"
}

if [ $# -lt 1 ]; then
    usage
fi

cmd="$1"
case "${cmd}" in
    feed)
        run_cmd "{\"cmd\":\"feed\",\"slot\":${2:-1},\"mm\":${3:-0},\"speed\":${4:-0}}" quiet \
            command --cmd feed --slot "${2:-1}" --mm "${3:-0}" --speed "${4:-0}"
        ;;
    feed-wait)
        run_cmd "{\"cmd\":\"feed_wait\",\"slot\":${2:-1},\"mm\":${3:-0},\"speed\":${4:-0},\"timeout_s\":${5:-0}}" quiet \
            command --cmd feed_wait --slot "${2:-1}" --mm "${3:-0}" --speed "${4:-0}" --timeout_s "${5:-0}"
        ;;
    retract)
        run_cmd "{\"cmd\":\"retract\",\"slot\":${2:-1},\"mm\":${3:-0},\"speed\":${4:-0}}" quiet \
            command --cmd retract --slot "${2:-1}" --mm "${3:-0}" --speed "${4:-0}"
        ;;
    retract-wait)
        run_cmd "{\"cmd\":\"retract_wait\",\"slot\":${2:-1},\"mm\":${3:-0},\"speed\":${4:-0},\"timeout_s\":${5:-0}}" quiet \
            command --cmd retract_wait --slot "${2:-1}" --mm "${3:-0}" --speed "${4:-0}" --timeout_s "${5:-0}"
        ;;
    feed-to-sensor)
        # feed-to-sensor <slot> <mm> <speed> <sensor> <timeout> <settle_timeout> <confirm_s>
        params="{\"slot\":${2:-1},\"mm\":${3:-1200},\"speed\":${4:-25}"
        [ -n "${5:-}" ] && [ "$5" != "0" ] && params="${params},\"sensor\":\"$5\""
        [ -n "${6:-}" ] && [ "$6" != "0" ] && params="${params},\"timeout_s\":$6"
        [ -n "${7:-}" ] && [ "$7" != "0" ] && params="${params},\"settle_timeout_s\":$7"
        [ -n "${8:-}" ] && [ "$8" != "0" ] && params="${params},\"confirm_s\":$8"
        params="${params}}"
        run_cmd "{\"cmd\":\"feed_to_sensor\",\"params\":${params}}" quiet \
            command --cmd feed_to_sensor --params-json "${params}"
        ;;
    retract-to-sensor)
        params="{\"slot\":${2:-1},\"mm\":${3:-1200},\"speed\":${4:-15}"
        [ -n "${5:-}" ] && [ "$5" != "0" ] && params="${params},\"sensor\":\"$5\""
        [ -n "${6:-}" ] && [ "$6" != "0" ] && params="${params},\"timeout_s\":$6"
        [ -n "${7:-}" ] && [ "$7" != "0" ] && params="${params},\"settle_timeout_s\":$7"
        [ -n "${8:-}" ] && [ "$8" != "0" ] && params="${params},\"confirm_s\":$8"
        params="${params}}"
        run_cmd "{\"cmd\":\"retract_to_sensor\",\"params\":${params}}" quiet \
            command --cmd retract_to_sensor --params-json "${params}"
        ;;
    wait-motion)
        run_cmd "{\"cmd\":\"wait_motion\",\"slot\":${2:-1},\"timeout_s\":${3:-5}}" quiet \
            command --cmd wait_motion --slot "${2:-1}" --timeout_s "${3:-5}"
        ;;
    clear-hub)
        # clear-hub <slot> <mm> <step_mm> <max_extra_mm> <speed> <sensor> <settle_s> <confirm_s>
        params="{\"slot\":${2:-1},\"mm\":${3:-90},\"step_mm\":${4:-10},\"max_extra_mm\":${5:-60},\"speed\":${6:-15}"
        [ -n "${7:-}" ] && [ "$7" != "0" ] && params="${params},\"sensor\":\"$7\""
        [ -n "${8:-}" ] && [ "$8" != "0" ] && params="${params},\"settle_s\":$8"
        [ -n "${9:-}" ] && [ "$9" != "0" ] && params="${params},\"confirm_s\":$9"
        params="${params}}"
        run_cmd "{\"cmd\":\"clear_hub\",\"params\":${params}}" quiet \
            command --cmd clear_hub --params-json "${params}"
        ;;
    stop)
        run_cmd "{\"cmd\":\"stop\",\"slot\":${2:-1}}" quiet command --cmd stop --slot "${2:-1}"
        ;;
    stop-unwind)
        run_cmd "{\"cmd\":\"stop_unwind\",\"slot\":${2:-1}}" quiet command --cmd stop_unwind --slot "${2:-1}"
        ;;
    assist-start)
        run_cmd "{\"cmd\":\"assist_start\",\"slot\":${2:-1}}" quiet command --cmd assist_start --slot "${2:-1}"
        ;;
    assist-stop)
        run_cmd "{\"cmd\":\"assist_stop\",\"slot\":${2:-1}}" quiet command --cmd assist_stop --slot "${2:-1}"
        ;;
    dry-start)
        # dry-start <temp> <minutes> <fan> <unit 0|1>
        run_cmd "{\"cmd\":\"dry_start\",\"temp_c\":${2:-45},\"minutes\":${3:-240},\"fan_speed\":${4:-7000},\"unit\":${5:-0}}" quiet \
            command --cmd dry_start --temp-c "${2:-45}" --minutes "${3:-240}" --fan-speed "${4:-7000}" --unit "${5:-0}"
        ;;
    dry-stop)
        # dry-stop <unit 0|1>
        run_cmd "{\"cmd\":\"dry_stop\",\"unit\":${2:-0}}" quiet command --cmd dry_stop --unit "${2:-0}"
        ;;
    status)
        run_cmd "{\"action\":\"status\"}" always status
        ;;
    status-refresh)
        run_cmd "{\"action\":\"status\",\"refresh\":true}" always status --refresh
        ;;
    slot-status)
        run_cmd "{\"cmd\":\"slot_status\",\"slot\":${2:-1}}" always command --cmd slot_status --slot "${2:-1}"
        ;;
    assert-slot-ready)
        run_cmd "{\"cmd\":\"assert_slot_ready\",\"slot\":${2:-1}}" quiet command --cmd assert_slot_ready --slot "${2:-1}"
        ;;
    set-filament)
        # set-filament <slot 1..8> <type> <hex color RRGGBB>
        # raw_method params are nested, which the daemon's slot routing does
        # not descend into - compute unit and local index here instead.
        slot="${2:-1}"; ftype="${3:-PLA}"; hex="${4:-FFFFFF}"
        unit=$(( (slot - 1) / 4 )); idx=$(( (slot - 1) % 4 ))
        r=$(printf '%d' "0x$(echo "${hex}" | cut -c1-2)")
        g=$(printf '%d' "0x$(echo "${hex}" | cut -c3-4)")
        b=$(printf '%d' "0x$(echo "${hex}" | cut -c5-6)")
        params="{\"method\":\"set_filament_info\",\"params\":{\"index\":${idx},\"type\":\"${ftype}\",\"color\":[${r},${g},${b}]}}"
        run_cmd "{\"cmd\":\"raw_method\",\"unit\":${unit},\"params\":${params}}" quiet \
            command --cmd raw_method --unit "${unit}" --params-json "${params}"
        ;;
    set-serial)
        run_cmd "{\"cmd\":\"set_serial\",\"port\":\"${2:-auto}\",\"baudrate\":${3:-115200}}" quiet \
            command --cmd set_serial --port "${2:-auto}" --baudrate "${3:-115200}"
        ;;
    debug-cli)
        shift || true
        "${PYTHON_BIN}" "${ACE_SCRIPT}" --config "${ACE_CONFIG}" "$@"
        ;;
    *)
        usage
        ;;
esac
