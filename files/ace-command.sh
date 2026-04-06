#!/bin/sh
set -eu

PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
ACE_SCRIPT="${ACE_SCRIPT:-/user-resource/ace-addon/ace-addon.py}"
ACE_CONFIG="${ACE_ADDON_CONFIG:-/user-resource/ace-addon/ace-addon.conf}"
ACE_URL="${ACE_URL:-http://127.0.0.1:8091}"

usage() {
    echo "Usage: $0 <cmd> [args...]"
    echo "Commands: feed, retract, retract-wait, feed-to-sensor, retract-to-sensor, stop, stop-unwind, dry-start, dry-stop, status, status-refresh, set-serial, debug-cli"
    exit 1
}

post_json() {
    local payload="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -s -X POST -H "Content-Type: application/json" -d "${payload}" "${ACE_URL}/command"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --post-data="${payload}" --header="Content-Type: application/json" "${ACE_URL}/command"
    else
        echo '{"ok":false,"error":"neither curl nor wget found"}'
        exit 1
    fi
}

get_json() {
    local path="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -s "${ACE_URL}${path}"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "${ACE_URL}${path}"
    else
        echo '{"ok":false,"error":"neither curl nor wget found"}'
        exit 1
    fi
}

run_python() {
    "${PYTHON_BIN}" "${ACE_SCRIPT}" --config "${ACE_CONFIG}" "$@"
}

if [ $# -lt 1 ]; then
    usage
fi

cmd="$1"
case "${cmd}" in
    feed)
        slot="${2:-1}"
        mm="${3:-0}"
        speed="${4:-0}"
        post_json "{\"cmd\":\"feed\",\"slot\":${slot},\"mm\":${mm},\"speed\":${speed}}"
        ;;
    retract)
        slot="${2:-1}"
        mm="${3:-0}"
        speed="${4:-0}"
        post_json "{\"cmd\":\"retract\",\"slot\":${slot},\"mm\":${mm},\"speed\":${speed}}"
        ;;
    retract-wait)
        slot="${2:-1}"
        mm="${3:-0}"
        speed="${4:-0}"
        post_json "{\"cmd\":\"retract_wait\",\"slot\":${slot},\"mm\":${mm},\"speed\":${speed}}"
        ;;
    feed-to-sensor)
        slot="${2:-1}"
        mm="${3:-0}"
        speed="${4:-0}"
        sensor="${5:-runout}"
        timeout="${6:-0}"
        post_json "{\"cmd\":\"feed_to_sensor\",\"slot\":${slot},\"mm\":${mm},\"speed\":${speed},\"sensor\":\"${sensor}\",\"timeout_s\":${timeout}}"
        ;;
    retract-to-sensor)
        slot="${2:-1}"
        mm="${3:-0}"
        speed="${4:-0}"
        sensor="${5:-runout}"
        timeout="${6:-0}"
        post_json "{\"cmd\":\"retract_to_sensor\",\"slot\":${slot},\"mm\":${mm},\"speed\":${speed},\"sensor\":\"${sensor}\",\"timeout_s\":${timeout}}"
        ;;
    stop)
        slot="${2:-1}"
        post_json "{\"cmd\":\"stop\",\"slot\":${slot}}"
        ;;
    stop-unwind)
        slot="${2:-1}"
        post_json "{\"cmd\":\"stop_unwind\",\"slot\":${slot}}"
        ;;
    dry-start)
        temp="${2:-45}"
        mins="${3:-240}"
        fan="${4:-7000}"
        post_json "{\"cmd\":\"dry_start\",\"temp_c\":${temp},\"minutes\":${mins},\"fan_speed\":${fan}}"
        ;;
    dry-stop)
        post_json '{"cmd":"dry_stop"}'
        ;;
    status)
        get_json "/status"
        ;;
    status-refresh)
        post_json '{"cmd":"status_refresh"}'
        ;;
    set-serial)
        port="${2:-auto}"
        baudrate="${3:-115200}"
        post_json "{\"cmd\":\"set_serial\",\"port\":\"${port}\",\"baudrate\":${baudrate}}"
        ;;
    debug-cli)
        shift || true
        run_python "$@"
        ;;
    *)
        usage
        ;;
esac
