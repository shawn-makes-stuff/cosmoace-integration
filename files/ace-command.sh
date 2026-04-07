#!/bin/sh
set -eu

PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
ACE_SCRIPT="${ACE_SCRIPT:-/user-resource/ace-addon/ace-addon.py}"
ACE_CONFIG="${ACE_ADDON_CONFIG:-/user-resource/ace-addon/ace-addon.conf}"

usage() {
    echo "Usage: $0 <cmd> [args...]"
    echo "Commands: feed, feed-wait, retract, retract-wait, feed-to-sensor, retract-to-sensor, wait-motion, clear-hub, stop, stop-unwind, dry-start, dry-stop, status, status-refresh, slot-status, assert-slot-ready, set-serial, debug-cli"
    exit 1
}

run_python_cmd() {
    cmd_name="$1"
    shift
    "${PYTHON_BIN}" "${ACE_SCRIPT}" --config "${ACE_CONFIG}" command --cmd "${cmd_name}" "$@"
}

if [ $# -lt 1 ]; then
    usage
fi

cmd="$1"
case "${cmd}" in
    feed)
        run_python_cmd "feed" --slot "${2:-1}" --mm "${3:-0}" --speed "${4:-0}"
        ;;
    feed-wait)
        run_python_cmd "feed_wait" --slot "${2:-1}" --mm "${3:-0}" --speed "${4:-0}" --timeout_s "${5:-0}"
        ;;
    retract)
        run_python_cmd "retract" --slot "${2:-1}" --mm "${3:-0}" --speed "${4:-0}"
        ;;
    retract-wait)
        run_python_cmd "retract_wait" --slot "${2:-1}" --mm "${3:-0}" --speed "${4:-0}" --timeout_s "${5:-0}"
        ;;
    feed-to-sensor)
        # feed-to-sensor <slot> <mm> <speed> <sensor> <timeout> <settle_timeout> <confirm_s>
        # Using --params-json for complex mapping
        params="{\"slot\":${2:-1},\"mm\":${3:-1200},\"speed\":${4:-25}"
        [ -n "${5:-}" ] && [ "$5" != "0" ] && params="${params},\"sensor\":\"$5\""
        [ -n "${6:-}" ] && [ "$6" != "0" ] && params="${params},\"timeout_s\":$6"
        [ -n "${7:-}" ] && [ "$7" != "0" ] && params="${params},\"settle_timeout_s\":$7"
        [ -n "${8:-}" ] && [ "$8" != "0" ] && params="${params},\"confirm_s\":$8"
        params="${params}}"
        "${PYTHON_BIN}" "${ACE_SCRIPT}" --config "${ACE_CONFIG}" command --cmd "feed_to_sensor" --params-json "${params}"
        ;;
    retract-to-sensor)
        params="{\"slot\":${2:-1},\"mm\":${3:-1200},\"speed\":${4:-15}"
        [ -n "${5:-}" ] && [ "$5" != "0" ] && params="${params},\"sensor\":\"$5\""
        [ -n "${6:-}" ] && [ "$6" != "0" ] && params="${params},\"timeout_s\":$6"
        [ -n "${7:-}" ] && [ "$7" != "0" ] && params="${params},\"settle_timeout_s\":$7"
        [ -n "${8:-}" ] && [ "$8" != "0" ] && params="${params},\"confirm_s\":$8"
        params="${params}}"
        "${PYTHON_BIN}" "${ACE_SCRIPT}" --config "${ACE_CONFIG}" command --cmd "retract_to_sensor" --params-json "${params}"
        ;;
    wait-motion)
        run_python_cmd "wait_motion" --slot "${2:-1}" --timeout_s "${3:-5}"
        ;;
    clear-hub)
        # clear-hub <slot> <mm> <step_mm> <max_extra_mm> <speed> <sensor> <settle_s> <confirm_s>
        params="{\"slot\":${2:-1},\"mm\":${3:-90},\"step_mm\":${4:-10},\"max_extra_mm\":${5:-60},\"speed\":${6:-15}"
        [ -n "${7:-}" ] && [ "$7" != "0" ] && params="${params},\"sensor\":\"$7\""
        [ -n "${8:-}" ] && [ "$8" != "0" ] && params="${params},\"settle_s\":$8"
        [ -n "${9:-}" ] && [ "$9" != "0" ] && params="${params},\"confirm_s\":$9"
        params="${params}}"
        "${PYTHON_BIN}" "${ACE_SCRIPT}" --config "${ACE_CONFIG}" command --cmd "clear_hub" --params-json "${params}"
        ;;
    stop)
        run_python_cmd "stop" --slot "${2:-1}"
        ;;
    stop-unwind)
        run_python_cmd "stop_unwind" --slot "${2:-1}"
        ;;
    dry-start)
        run_python_cmd "dry_start" --temp-c "${2:-45}" --minutes "${3:-240}" --fan-speed "${4:-7000}"
        ;;
    dry-stop)
        run_python_cmd "dry_stop"
        ;;
    status)
        "${PYTHON_BIN}" "${ACE_SCRIPT}" --config "${ACE_CONFIG}" status
        ;;
    status-refresh)
        "${PYTHON_BIN}" "${ACE_SCRIPT}" --config "${ACE_CONFIG}" status --refresh
        ;;
    slot-status)
        run_python_cmd "slot_status" --slot "${2:-1}"
        ;;
    assert-slot-ready)
        run_python_cmd "assert_slot_ready" --slot "${2:-1}"
        ;;
    set-serial)
        run_python_cmd "set_serial" --port "${2:-auto}" --baudrate "${3:-115200}"
        ;;
    debug-cli)
        shift || true
        "${PYTHON_BIN}" "${ACE_SCRIPT}" --config "${ACE_CONFIG}" "$@"
        ;;
    *)
        usage
        ;;
esac
