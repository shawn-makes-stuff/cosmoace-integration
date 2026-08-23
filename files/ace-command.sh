#!/bin/sh
# Thin wrapper around ace-addon.py: one short-lived process per command.
# Klipper calls this through [gcode_shell_command ace_rpc].
set -eu

PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
ACE_SCRIPT="${ACE_SCRIPT:-/user-resource/ace-addon/ace-addon.py}"
ACE_CONFIG="${ACE_ADDON_CONFIG:-/user-resource/ace-addon/ace-addon.conf}"

usage() {
    echo "Usage: $0 <cmd> [args...]"
    echo "Commands: feed, feed-wait, retract-wait, feed-to-sensor, retract-to-sensor,"
    echo "          wait-motion, clear-hub, stop, stop-unwind, assist-start, assist-stop,"
    echo "          dry-start, dry-stop, status, status-refresh, panel-status, slot-status,"
    echo "          set-filament, debug-cli"
    echo "Slots are 1-8: 1-4 on the first ACE, 5-8 on a second one declared as [ace2]."
    exit 1
}

ace() {
    "${PYTHON_BIN}" "${ACE_SCRIPT}" --config "${ACE_CONFIG}" "$@"
}

cmd_json() {
    name="$1"; shift
    ace command --cmd "$name" --params-json "$1"
}

[ $# -ge 1 ] || usage

cmd="$1"
case "${cmd}" in
    feed)
        ace command --cmd feed --slot "${2:-1}" --mm "${3:-0}" --speed "${4:-0}"
        ;;
    feed-wait)
        ace command --cmd feed_wait --slot "${2:-1}" --mm "${3:-0}" --speed "${4:-0}" \
            --timeout_s "${5:-0}"
        ;;
    retract-wait)
        ace command --cmd retract_wait --slot "${2:-1}" --mm "${3:-0}" --speed "${4:-0}" \
            --timeout_s "${5:-0}"
        ;;
    feed-to-sensor)
        # feed-to-sensor <slot> <mm> <speed> <sensor> <timeout> <settle_timeout> <confirm_s>
        params="{\"slot\":${2:-1},\"mm\":${3:-1200},\"speed\":${4:-25}"
        [ -n "${5:-}" ] && [ "$5" != "0" ] && params="${params},\"sensor\":\"$5\""
        [ -n "${6:-}" ] && [ "$6" != "0" ] && params="${params},\"timeout_s\":$6"
        [ -n "${7:-}" ] && [ "$7" != "0" ] && params="${params},\"settle_timeout_s\":$7"
        [ -n "${8:-}" ] && [ "$8" != "0" ] && params="${params},\"confirm_s\":$8"
        cmd_json feed_to_sensor "${params}}"
        ;;
    retract-to-sensor)
        params="{\"slot\":${2:-1},\"mm\":${3:-1200},\"speed\":${4:-15}"
        [ -n "${5:-}" ] && [ "$5" != "0" ] && params="${params},\"sensor\":\"$5\""
        [ -n "${6:-}" ] && [ "$6" != "0" ] && params="${params},\"timeout_s\":$6"
        [ -n "${7:-}" ] && [ "$7" != "0" ] && params="${params},\"settle_timeout_s\":$7"
        [ -n "${8:-}" ] && [ "$8" != "0" ] && params="${params},\"confirm_s\":$8"
        cmd_json retract_to_sensor "${params}}"
        ;;
    wait-motion)
        ace command --cmd wait_motion --slot "${2:-1}" --timeout_s "${3:-5}"
        ;;
    clear-hub)
        # clear-hub <slot> <mm> <step_mm> <max_extra_mm> <speed> <sensor> <settle_s> <confirm_s>
        params="{\"slot\":${2:-1},\"mm\":${3:-90},\"step_mm\":${4:-10},\"max_extra_mm\":${5:-60},\"speed\":${6:-15}"
        [ -n "${7:-}" ] && [ "$7" != "0" ] && params="${params},\"sensor\":\"$7\""
        [ -n "${8:-}" ] && [ "$8" != "0" ] && params="${params},\"settle_s\":$8"
        [ -n "${9:-}" ] && [ "$9" != "0" ] && params="${params},\"confirm_s\":$9"
        cmd_json clear_hub "${params}}"
        ;;
    stop)
        ace command --cmd stop --slot "${2:-1}"
        ;;
    stop-unwind)
        ace command --cmd stop_unwind --slot "${2:-1}"
        ;;
    assist-start)
        ace command --cmd assist_start --slot "${2:-1}"
        ;;
    assist-stop)
        ace command --cmd assist_stop --slot "${2:-1}"
        ;;
    dry-start)
        # dry-start <temp> <minutes> <fan> <unit 0|1>
        ace command --cmd dry_start --temp-c "${2:-45}" --minutes "${3:-240}" \
            --fan-speed "${4:-7000}" --unit "${5:-0}"
        ;;
    dry-stop)
        # dry-stop <unit 0|1>
        ace command --cmd dry_stop --unit "${2:-0}"
        ;;
    status)
        ace status
        ;;
    status-refresh)
        ace status --refresh
        ;;
    panel-status)
        # compact status for the web panel: slots and defaults for every unit,
        # no transport debug (the full dump gets truncated in the gcode console)
        ace status --refresh --compact
        ;;
    slot-status)
        ace command --cmd slot_status --slot "${2:-1}"
        ;;
    set-filament)
        # set-filament <slot 1..8> <type> <hex color RRGGBB>
        # raw_method params are nested, which slot routing does not descend
        # into, so resolve the unit and local index here.
        slot="${2:-1}"; ftype="${3:-PLA}"; hex="${4:-FFFFFF}"
        unit=$(( (slot - 1) / 4 )); idx=$(( (slot - 1) % 4 ))
        r=$(printf '%d' "0x$(echo "${hex}" | cut -c1-2)")
        g=$(printf '%d' "0x$(echo "${hex}" | cut -c3-4)")
        b=$(printf '%d' "0x$(echo "${hex}" | cut -c5-6)")
        params="{\"method\":\"set_filament_info\",\"params\":{\"index\":${idx},\"type\":\"${ftype}\",\"color\":[${r},${g},${b}]}}"
        ace command --cmd raw_method --unit "${unit}" --params-json "${params}"
        ;;
    debug-cli)
        shift || true
        ace "$@"
        ;;
    *)
        usage
        ;;
esac
