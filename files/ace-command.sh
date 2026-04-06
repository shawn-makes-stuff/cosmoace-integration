#!/bin/sh
set -eu

PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
ACE_SCRIPT="${ACE_SCRIPT:-/user-resource/ace-addon/ace-addon.py}"
ACE_CONFIG="${ACE_ADDON_CONFIG:-/user-resource/ace-addon/ace-addon.conf}"
ACE_URL="${ACE_URL:-http://127.0.0.1:8091}"
ACE_HTTP_CONNECT_TIMEOUT="${ACE_HTTP_CONNECT_TIMEOUT:-2}"
ACE_HTTP_TIMEOUT="${ACE_HTTP_TIMEOUT:-30}"

usage() {
    echo "Usage: $0 <cmd> [args...]"
    echo "Commands: feed, feed-wait, retract, retract-wait, feed-to-sensor, retract-to-sensor, clear-hub, stop, stop-unwind, dry-start, dry-stop, status, status-refresh, slot-status, assert-slot-ready, set-serial, debug-cli"
    exit 1
}

fetch_json() {
    local method="$1"
    local path="$2"
    local payload="${3:-}"
    if command -v curl >/dev/null 2>&1; then
        if [ -n "${payload}" ]; then
            curl -sS \
                --connect-timeout "${ACE_HTTP_CONNECT_TIMEOUT}" \
                --max-time "${ACE_HTTP_TIMEOUT}" \
                -X "${method}" \
                -H "Content-Type: application/json" \
                -d "${payload}" \
                "${ACE_URL}${path}"
        else
            curl -sS \
                --connect-timeout "${ACE_HTTP_CONNECT_TIMEOUT}" \
                --max-time "${ACE_HTTP_TIMEOUT}" \
                -X "${method}" \
                "${ACE_URL}${path}"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if [ -n "${payload}" ]; then
            wget -qO- -T "${ACE_HTTP_TIMEOUT}" --post-data="${payload}" --header="Content-Type: application/json" "${ACE_URL}${path}"
        else
            wget -qO- -T "${ACE_HTTP_TIMEOUT}" "${ACE_URL}${path}"
        fi
    else
        echo '{"ok":false,"error":"neither curl nor wget found"}'
        exit 1
    fi
}

validate_json_ok() {
    "${PYTHON_BIN}" -c 'import json, sys
raw = sys.stdin.read()
if not raw.strip():
    sys.exit(1)
data = json.loads(raw)
if isinstance(data, dict) and not data.get("ok", True):
    sys.exit(1)
'
}

post_json() {
    local payload="$1"
    local response
    response="$(fetch_json POST /command "${payload}")"
    printf '%s\n' "${response}"
    printf '%s' "${response}" | validate_json_ok >/dev/null
}

get_json() {
    local path="$1"
    fetch_json GET "${path}"
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
    feed-wait)
        slot="${2:-1}"
        mm="${3:-0}"
        speed="${4:-0}"
        post_json "{\"cmd\":\"feed_wait\",\"slot\":${slot},\"mm\":${mm},\"speed\":${speed}}"
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
    clear-hub)
        slot="${2:-1}"
        mm="${3:-90}"
        step_mm="${4:-10}"
        max_extra_mm="${5:-60}"
        speed="${6:-15}"
        sensor="${7:-runout}"
        settle_s="${8:-0.25}"
        confirm_s="${9:-0.5}"
        post_json "{\"cmd\":\"clear_hub\",\"slot\":${slot},\"mm\":${mm},\"step_mm\":${step_mm},\"max_extra_mm\":${max_extra_mm},\"speed\":${speed},\"sensor\":\"${sensor}\",\"settle_s\":${settle_s},\"confirm_s\":${confirm_s}}"
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
        post_json '{"cmd":"status_refresh"}' >/dev/null
        get_json "/status"
        ;;
    slot-status)
        slot="${2:-1}"
        post_json "{\"cmd\":\"slot_status\",\"slot\":${slot}}"
        ;;
    assert-slot-ready)
        slot="${2:-1}"
        post_json "{\"cmd\":\"assert_slot_ready\",\"slot\":${slot}}"
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
