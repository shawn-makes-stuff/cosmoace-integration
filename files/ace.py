import json
import logging
import queue
import struct
import threading
import time

import serial


HEADER = b"\xff\xaa"
FOOTER = 0xFE
DEFAULT_SLOT_COUNT = 4


class AceError(Exception):
    pass


class AceRequestTicket:
    def __init__(self, request, timeout):
        self.request = dict(request)
        self.timeout = timeout
        self.event = threading.Event()
        self.response = None
        self.error = None

    def set_response(self, response):
        self.response = response
        self.event.set()

    def set_error(self, error):
        self.error = error
        self.event.set()


class AceController:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.gcode = self.printer.lookup_object("gcode")
        self.name = config.get_name()

        self.enabled = config.getboolean("enabled", False)
        self.serial_name = config.get(
            "serial", "/dev/serial/by-id/usb-ANYCUBIC_ACE_0-if00"
        )
        self.baud = config.getint("baud", default=115200, minval=1)
        self.feed_speed = config.getint(
            "feed_speed", default=25, minval=1, maxval=25
        )
        self.retract_speed = config.getint(
            "retract_speed", default=25, minval=1, maxval=25
        )
        self.toolchange_retract_length = config.getint(
            "toolchange_retract_length", default=100, minval=0
        )
        self.retract_mode = config.getint(
            "retract_mode", default=0, minval=0, maxval=1
        )
        self.park_hit_count = config.getint(
            "park_hit_count", default=5, minval=1
        )
        self.assist_poll_interval = config.getfloat(
            "assist_poll_interval", default=0.7, above=0.0
        )
        self.command_margin = config.getfloat(
            "command_margin", default=2.0, minval=0.0
        )
        self.operation_timeout = config.getfloat(
            "operation_timeout", default=30.0, above=0.0
        )
        self.request_timeout = config.getfloat(
            "request_timeout", default=2.0, above=0.0
        )
        self.keepalive_interval = config.getfloat(
            "keepalive_interval", default=1.5, above=0.0
        )
        self.reconnect_interval = config.getfloat(
            "reconnect_interval", default=1.0, above=0.0
        )
        self.disable_assist_after_toolchange = config.getboolean(
            "disable_assist_after_toolchange", True
        )
        self.max_dryer_temperature = config.getint(
            "max_dryer_temperature", default=55, minval=1
        )
        self.default_drying_duration = config.getint(
            "default_drying_duration", default=240, minval=1
        )
        self.drying_fan_speed = config.getint(
            "drying_fan_speed", default=7000, minval=1
        )
        self.allow_drying_while_printing = config.getboolean(
            "allow_drying_while_printing", False
        )
        self.verify_sensor_mode = config.getchoice(
            "verify_sensor",
            {
                "disabled": "disabled",
                "optional": "optional",
                "required": "required",
            },
            default="disabled",
        )
        self.toolhead_sensor_name = config.get("toolhead_sensor", None)
        self.sensor_timeout = config.getfloat(
            "sensor_timeout", default=3.0, above=0.0
        )

        self.pre_toolchange_macro = config.get(
            "pre_toolchange_macro", "_ACE_PRE_TOOLCHANGE"
        )
        self.post_toolchange_macro = config.get(
            "post_toolchange_macro", "_ACE_POST_TOOLCHANGE"
        )
        self.empty_error_macro = config.get(
            "empty_error_macro", "_ACE_ON_EMPTY_ERROR"
        )
        self.verify_error_macro = config.get(
            "verify_error_macro", "_ACE_ON_VERIFY_ERROR"
        )
        self.comm_error_macro = config.get(
            "comm_error_macro", "_ACE_ON_COMM_ERROR"
        )

        try:
            self.save_variables = self.printer.load_object(config, "save_variables")
        except config.error:
            self.save_variables = None
        self.active_slot = self._load_saved_slot()

        self.toolhead_sensor = None
        self.status = self._build_default_status()
        self.slot_count = DEFAULT_SLOT_COUNT
        self.device_info = {}
        self.last_error = ""

        self.state_lock = threading.RLock()
        self.request_queue = queue.Queue()
        self.main_queue = queue.Queue()
        self.shutdown_evt = threading.Event()
        self.worker_thread = None
        self.main_timer = None
        self.serial_port = None
        self.rx_buffer = bytearray()
        self.next_request_id = 0
        self.last_connect_attempt = 0.0
        self.last_request_ts = 0.0
        self.connected = False
        self.toolchange_in_progress = False
        self.connected_once = False

        self.printer.register_event_handler("klippy:ready", self._handle_ready)
        self.printer.register_event_handler(
            "klippy:disconnect", self._handle_disconnect
        )

        self.gcode.register_command(
            "ACE_QUERY_STATUS",
            self.cmd_ACE_QUERY_STATUS,
            desc=self.cmd_ACE_QUERY_STATUS_help,
        )
        self.gcode.register_command(
            "ACE_START_DRYING",
            self.cmd_ACE_START_DRYING,
            desc=self.cmd_ACE_START_DRYING_help,
        )
        self.gcode.register_command(
            "ACE_STOP_DRYING",
            self.cmd_ACE_STOP_DRYING,
            desc=self.cmd_ACE_STOP_DRYING_help,
        )
        self.gcode.register_command(
            "ACE_ENABLE_FEED_ASSIST",
            self.cmd_ACE_ENABLE_FEED_ASSIST,
            desc=self.cmd_ACE_ENABLE_FEED_ASSIST_help,
        )
        self.gcode.register_command(
            "ACE_DISABLE_FEED_ASSIST",
            self.cmd_ACE_DISABLE_FEED_ASSIST,
            desc=self.cmd_ACE_DISABLE_FEED_ASSIST_help,
        )
        self.gcode.register_command(
            "ACE_PARK_TO_TOOLHEAD",
            self.cmd_ACE_PARK_TO_TOOLHEAD,
            desc=self.cmd_ACE_PARK_TO_TOOLHEAD_help,
        )
        self.gcode.register_command(
            "ACE_FEED",
            self.cmd_ACE_FEED,
            desc=self.cmd_ACE_FEED_help,
        )
        self.gcode.register_command(
            "ACE_RETRACT",
            self.cmd_ACE_RETRACT,
            desc=self.cmd_ACE_RETRACT_help,
        )
        self.gcode.register_command(
            "ACE_CHANGE_TOOL",
            self.cmd_ACE_CHANGE_TOOL,
            desc=self.cmd_ACE_CHANGE_TOOL_help,
        )
        self.gcode.register_command(
            "ACE_SET_ACTIVE_SLOT",
            self.cmd_ACE_SET_ACTIVE_SLOT,
            desc=self.cmd_ACE_SET_ACTIVE_SLOT_help,
        )
        self.gcode.register_command(
            "ACE_DEBUG",
            self.cmd_ACE_DEBUG,
            desc=self.cmd_ACE_DEBUG_help,
        )

    def _build_default_status(self):
        return {
            "status": "disconnected",
            "action": "idle",
            "dryer_status": {
                "status": "stop",
                "target_temp": 0,
                "duration": 0,
                "remain_time": 0,
            },
            "temp": 0,
            "enable_rfid": 1,
            "fan_speed": 0,
            "feed_assist_count": 0,
            "cont_assist_time": 0.0,
            "slots": [
                {
                    "index": index,
                    "status": "unknown",
                    "sku": "",
                    "brand": "",
                    "type": "",
                    "color": [0, 0, 0],
                    "rfid": 0,
                }
                for index in range(DEFAULT_SLOT_COUNT)
            ],
        }

    def _load_saved_slot(self):
        if self.save_variables is None:
            return -1
        try:
            saved = self.save_variables.allVariables.get("ace_active_slot", -1)
            return int(saved)
        except Exception:
            return -1

    def _handle_ready(self):
        self._load_toolhead_sensor()
        self.shutdown_evt.clear()
        self.main_timer = self.reactor.register_timer(
            self._main_eval, self.reactor.NOW
        )
        if not self.enabled:
            logging.info("ACE: Disabled in config")
            return
        self.worker_thread = threading.Thread(
            target=self._worker_loop, name="ace-worker"
        )
        self.worker_thread.daemon = True
        self.worker_thread.start()

    def _handle_disconnect(self):
        self.shutdown_evt.set()
        if self.request_queue is not None:
            self.request_queue.put(None)
        if self.worker_thread is not None:
            self.worker_thread.join(timeout=2.0)
            self.worker_thread = None
        if self.main_timer is not None:
            self.reactor.unregister_timer(self.main_timer)
            self.main_timer = None
        self._close_serial()

    def _load_toolhead_sensor(self):
        self.toolhead_sensor = None
        if not self.toolhead_sensor_name:
            return
        sensor = self.printer.lookup_object(self.toolhead_sensor_name, None)
        if sensor is None and self.verify_sensor_mode == "required":
            raise self.printer.config_error(
                "ACE requires toolhead sensor '%s'" % (self.toolhead_sensor_name,)
            )
        self.toolhead_sensor = sensor

    def _main_eval(self, eventtime):
        while not self.main_queue.empty():
            callback = self.main_queue.get_nowait()
            if callback is not None:
                try:
                    callback()
                except Exception:
                    logging.exception("ACE: Main thread callback failed")
        return eventtime + 0.1

    def _schedule_main(self, callback):
        self.main_queue.put(callback)

    def _worker_loop(self):
        while not self.shutdown_evt.is_set():
            try:
                if not self.connected and not self._maybe_connect():
                    pending = self.request_queue.get(timeout=self.reconnect_interval)
                    if pending is not None:
                        self.request_queue.put(pending)
                    continue
            except queue.Empty:
                continue

            try:
                ticket = self.request_queue.get(timeout=self.keepalive_interval)
            except queue.Empty:
                ticket = None

            if ticket is None:
                if self.shutdown_evt.is_set():
                    break
                if self.connected:
                    try:
                        self._perform_request(
                            {"method": "get_status"},
                            timeout=self.request_timeout,
                            update_status=True,
                        )
                    except Exception as exc:
                        self._handle_worker_error(exc, report_disconnect=True)
                continue

            try:
                response = self._perform_request(ticket.request, timeout=ticket.timeout)
                ticket.set_response(response)
            except Exception as exc:
                self._handle_worker_error(exc, report_disconnect=True)
                ticket.set_error(exc)

    def _maybe_connect(self):
        now = time.monotonic()
        if now - self.last_connect_attempt < self.reconnect_interval:
            return False
        self.last_connect_attempt = now
        try:
            self.serial_port = serial.Serial(
                port=self.serial_name,
                baudrate=self.baud,
                timeout=0.1,
                write_timeout=1.0,
            )
            self.rx_buffer = bytearray()
            info = self._perform_request({"method": "get_info"}, update_status=False)
            status = self._perform_request(
                {"method": "get_status"}, update_status=True
            )
            self.device_info = info.get("result", {})
            self.slot_count = int(
                self.device_info.get(
                    "slots",
                    len(status.get("result", {}).get("slots", []))
                    or DEFAULT_SLOT_COUNT,
                )
            )
            self.connected = True
            self.connected_once = True
            self.last_error = ""

            model = self.device_info.get("model", "ACE")
            firmware = self.device_info.get("firmware", "unknown")
            self._schedule_main(
                lambda: self.gcode.respond_info(
                    "ACE connected: %s (%s)" % (model, firmware)
                )
            )
            logging.info("ACE: Connected to %s", self.serial_name)
            return True
        except Exception as exc:
            self._close_serial()
            self.last_error = str(exc)
            logging.info("ACE: Connect failed: %s", exc)
            return False

    def _close_serial(self):
        if self.serial_port is not None:
            try:
                self.serial_port.close()
            except Exception:
                pass
        self.serial_port = None
        self.connected = False
        with self.state_lock:
            self.status["status"] = "disconnected"
            self.status["action"] = "idle"

    def _handle_worker_error(self, exc, report_disconnect):
        was_connected = self.connected
        self.last_error = str(exc)
        self._close_serial()
        if report_disconnect and was_connected and self.comm_error_macro:
            self._schedule_main(lambda: self._run_macro(self.comm_error_macro))
        logging.warning("ACE: Worker error: %s", exc)

    def _next_id(self):
        request_id = self.next_request_id
        self.next_request_id = (self.next_request_id + 1) % 300000
        return request_id

    def _perform_request(self, request, timeout=None, update_status=None):
        if self.serial_port is None:
            raise AceError("ACE is not connected")
        if "id" not in request:
            request["id"] = self._next_id()
        payload = json.dumps(request, separators=(",", ":")).encode("utf-8")
        if len(payload) > 1024:
            raise AceError("ACE payload too large")
        frame = (
            HEADER
            + struct.pack("<H", len(payload))
            + payload
            + struct.pack("<H", self._calc_crc(payload))
            + bytes([FOOTER])
        )
        self.serial_port.write(frame)
        self.serial_port.flush()
        self.last_request_ts = time.monotonic()

        response = self._read_response(timeout or self.request_timeout)
        if response.get("id") != request["id"]:
            raise AceError(
                "ACE response id mismatch: expected %s got %s"
                % (request["id"], response.get("id"))
            )
        if response.get("code", 0) != 0:
            raise AceError(response.get("msg", "ACE command failed"))

        method = request.get("method", "")
        if update_status is None:
            update_status = method == "get_status"
        if update_status:
            self._update_status(response.get("result", {}))
        return response

    def _read_response(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            chunk = self.serial_port.read(256)
            if chunk:
                self.rx_buffer.extend(chunk)
                frame = self._extract_frame()
                if frame is not None:
                    return self._parse_frame(frame)
        raise AceError("ACE request timed out")

    def _extract_frame(self):
        buffer = self.rx_buffer
        start = buffer.find(HEADER)
        if start == -1:
            if len(buffer) > 1:
                del buffer[:-1]
            return None
        if start > 0:
            del buffer[:start]
        if len(buffer) < 7:
            return None

        payload_len = struct.unpack("<H", bytes(buffer[2:4]))[0]
        if payload_len <= 0 or payload_len > 1024:
            del buffer[:2]
            raise AceError("ACE frame length out of range: %s" % (payload_len,))

        min_footer_index = 2 + 2 + payload_len + 2
        footer_index = buffer.find(bytes([FOOTER]), min_footer_index)
        if footer_index == -1:
            return None

        frame = bytes(buffer[: footer_index + 1])
        del buffer[: footer_index + 1]
        return frame

    def _parse_frame(self, frame):
        payload_len = struct.unpack("<H", frame[2:4])[0]
        payload = frame[4 : 4 + payload_len]
        crc_data = frame[4 + payload_len : 6 + payload_len]
        if len(crc_data) != 2:
            raise AceError("ACE frame missing CRC")
        calc_crc = struct.pack("<H", self._calc_crc(payload))
        if calc_crc != crc_data:
            raise AceError("ACE frame CRC mismatch")
        try:
            return json.loads(payload.decode("utf-8"))
        except Exception as exc:
            raise AceError("ACE JSON decode failed: %s" % (exc,))

    def _calc_crc(self, payload):
        crc = 0xFFFF
        for byte in payload:
            data = byte ^ (crc & 0xFF)
            data ^= (data & 0x0F) << 4
            crc = ((data << 8) | (crc >> 8)) ^ (data >> 4) ^ (data << 3)
        return crc & 0xFFFF

    def _update_status(self, new_status):
        if not isinstance(new_status, dict):
            return
        with self.state_lock:
            self.status.update(new_status)
            slots = self.status.get("slots", [])
            if isinstance(slots, list) and slots:
                self.slot_count = len(slots)
            self.status["status"] = new_status.get(
                "status", self.status.get("status", "ready")
            )

    def get_status(self, eventtime):
        with self.state_lock:
            status = dict(self.status)
            status["slots"] = [dict(slot) for slot in self.status.get("slots", [])]
        status.update(
            {
                "enabled": bool(self.enabled),
                "connected": bool(self.connected),
                "active_slot": int(self.active_slot),
                "last_error": self.last_error,
                "serial": self.serial_name,
                "verify_sensor": self.verify_sensor_mode,
                "toolhead_sensor": self.toolhead_sensor_name or "",
                "toolchange_in_progress": bool(self.toolchange_in_progress),
                "device_info": dict(self.device_info),
            }
        )
        return status

    def _ensure_enabled(self, gcmd):
        if not self.enabled:
            raise gcmd.error("ACE is disabled in config")

    def _queue_request(self, request, timeout=None):
        ticket = AceRequestTicket(request, timeout or self.request_timeout)
        self.request_queue.put(ticket)
        return ticket

    def _wait_for_ticket(self, ticket):
        now = self.reactor.monotonic()
        while not ticket.event.is_set():
            now = self.reactor.pause(now + 0.05)
        if ticket.error is not None:
            raise ticket.error
        return ticket.response

    def _request(self, request):
        if not self.connected:
            raise AceError("ACE is not connected")
        ticket = self._queue_request(request)
        return self._wait_for_ticket(ticket)

    def _request_status(self):
        response = self._request({"method": "get_status"})
        return response.get("result", {})

    def _slot_state(self, slot):
        status = self._request_status()
        slots = status.get("slots", [])
        if slot < 0 or slot >= len(slots):
            raise AceError("ACE slot %s is out of range" % (slot,))
        return slots[slot].get("status", "unknown")

    def _ensure_slot_ready(self, slot):
        if self._slot_state(slot) != "ready":
            self._run_macro(self.empty_error_macro, INDEX=slot)
            raise AceError("ACE slot %s is not ready" % (slot,))

    def _wait_until_ready(self, label, timeout):
        deadline = self.reactor.monotonic() + timeout
        now = self.reactor.monotonic()
        while now < deadline:
            status = self._request_status()
            if status.get("status") == "ready":
                return status
            now = self.reactor.pause(now + 0.2)
        raise AceError("ACE timed out while %s" % (label,))

    def _wait_for_park_completion(self, slot):
        deadline = self.reactor.monotonic() + self.operation_timeout
        last_count = None
        stable_hits = 0
        now = self.reactor.monotonic()
        while now < deadline:
            status = self._request_status()
            if status.get("status") == "ready":
                assist_count = int(status.get("feed_assist_count", 0))
                if last_count is None or assist_count != last_count:
                    last_count = assist_count
                    stable_hits = 0
                else:
                    stable_hits += 1
                    if stable_hits >= self.park_hit_count:
                        return status
            else:
                stable_hits = 0
            now = self.reactor.pause(now + self.assist_poll_interval)
        raise AceError("ACE park to toolhead timed out for slot %s" % (slot,))

    def _is_printing(self):
        idle_timeout = self.printer.lookup_object("idle_timeout")
        return idle_timeout.get_status(self.reactor.monotonic())["state"] == "Printing"

    def _verify_toolhead_sensor(self):
        if self.verify_sensor_mode == "disabled":
            return True
        if self.toolhead_sensor is None:
            if self.verify_sensor_mode == "optional":
                return True
            raise AceError(
                "ACE required toolhead sensor '%s' is unavailable"
                % (self.toolhead_sensor_name,)
            )

        deadline = self.reactor.monotonic() + self.sensor_timeout
        now = self.reactor.monotonic()
        while now < deadline:
            sensor_status = self.toolhead_sensor.get_status(now)
            if sensor_status.get("filament_detected"):
                return True
            now = self.reactor.pause(now + 0.1)

        self._run_macro(self.verify_error_macro)
        raise AceError("ACE toolhead sensor did not detect filament after toolchange")

    def _run_macro(self, macro_name, **params):
        if not macro_name:
            return
        command = [macro_name]
        for key, value in sorted(params.items()):
            command.append("%s=%s" % (key, value))
        self.gcode.run_script_from_command(" ".join(command))

    def _save_active_slot(self, slot, save_to_disk=True):
        self.active_slot = slot
        if self.save_variables is None or not save_to_disk:
            return
        self.gcode.run_script_from_command(
            "SAVE_VARIABLE VARIABLE=ace_active_slot VALUE=%d" % (slot,)
        )

    def _stop_feed_assist(self, slot):
        try:
            self._request({"method": "stop_feed_assist", "params": {"index": slot}})
        except Exception as exc:
            logging.info("ACE: Failed to stop feed assist for slot %s: %s", slot, exc)

    cmd_ACE_QUERY_STATUS_help = "Query ACE status and print a human readable summary"

    def cmd_ACE_QUERY_STATUS(self, gcmd):
        self._ensure_enabled(gcmd)
        status = self._request_status() if self.connected else self.get_status(0.0)
        slot_states = ", ".join(
            "T%d=%s" % (slot.get("index", idx), slot.get("status", "unknown"))
            for idx, slot in enumerate(status.get("slots", []))
        )
        dryer = status.get("dryer_status", {})
        gcmd.respond_info(
            "ACE connected=%s active_slot=%s status=%s action=%s dryer=%s temp=%s slots=[%s]"
            % (
                self.connected,
                self.active_slot,
                status.get("status", "unknown"),
                status.get("action", "idle"),
                dryer.get("status", "unknown"),
                status.get("temp", 0),
                slot_states,
            )
        )

    cmd_ACE_START_DRYING_help = "Start the ACE dryer"

    def cmd_ACE_START_DRYING(self, gcmd):
        self._ensure_enabled(gcmd)
        if not self.allow_drying_while_printing and self._is_printing():
            raise gcmd.error("ACE drying is disabled while printing")
        temperature = gcmd.get_int("TEMPERATURE", minval=1)
        duration = gcmd.get_int(
            "DURATION", default=self.default_drying_duration, minval=1
        )
        if temperature > self.max_dryer_temperature:
            raise gcmd.error(
                "ACE drying temperature exceeds max_dryer_temperature (%d)"
                % (self.max_dryer_temperature,)
            )
        self._request(
            {
                "method": "drying",
                "params": {
                    "temp": temperature,
                    "fan_speed": self.drying_fan_speed,
                    "duration": duration,
                },
            }
        )
        gcmd.respond_info(
            "ACE drying started at %dC for %d minutes" % (temperature, duration)
        )

    cmd_ACE_STOP_DRYING_help = "Stop the ACE dryer"

    def cmd_ACE_STOP_DRYING(self, gcmd):
        self._ensure_enabled(gcmd)
        # Some ACE firmware revisions may accept drying_stop but take a moment
        # to update dryer_status. Retry and confirm state reaches "stop".
        self._request({"method": "drying_stop"})
        deadline = self.reactor.monotonic() + min(self.operation_timeout, 10.0)
        retry_at = self.reactor.monotonic() + 1.0
        now = self.reactor.monotonic()
        while now < deadline:
            status = self._request_status()
            dryer_state = str(
                status.get("dryer_status", {}).get("status", "")
            ).lower()
            if dryer_state in ("stop", "idle", "ready", ""):
                gcmd.respond_info("ACE drying stopped")
                return
            if now >= retry_at:
                self._request({"method": "drying_stop"})
                retry_at = now + 1.0
            now = self.reactor.pause(now + 0.4)
        raise gcmd.error("ACE dryer did not report stop state")

    cmd_ACE_ENABLE_FEED_ASSIST_help = "Enable ACE feed assist for a slot"

    def cmd_ACE_ENABLE_FEED_ASSIST(self, gcmd):
        self._ensure_enabled(gcmd)
        slot = gcmd.get_int("INDEX", minval=0, maxval=self.slot_count - 1)
        self._request({"method": "start_feed_assist", "params": {"index": slot}})
        gcmd.respond_info("ACE feed assist enabled for slot %d" % (slot,))

    cmd_ACE_DISABLE_FEED_ASSIST_help = "Disable ACE feed assist for a slot"

    def cmd_ACE_DISABLE_FEED_ASSIST(self, gcmd):
        self._ensure_enabled(gcmd)
        slot = gcmd.get_int("INDEX", minval=0, maxval=self.slot_count - 1)
        self._stop_feed_assist(slot)
        gcmd.respond_info("ACE feed assist disabled for slot %d" % (slot,))

    cmd_ACE_PARK_TO_TOOLHEAD_help = "Feed a slot from ACE to the toolhead"

    def cmd_ACE_PARK_TO_TOOLHEAD(self, gcmd):
        self._ensure_enabled(gcmd)
        slot = gcmd.get_int("INDEX", minval=0, maxval=self.slot_count - 1)
        self._ensure_slot_ready(slot)
        self._request({"method": "start_feed_assist", "params": {"index": slot}})
        try:
            self._wait_for_park_completion(slot)
            self._verify_toolhead_sensor()
        finally:
            self._stop_feed_assist(slot)
        gcmd.respond_info("ACE parked slot %d to the toolhead" % (slot,))

    cmd_ACE_FEED_help = "Feed filament forward from the ACE"

    def cmd_ACE_FEED(self, gcmd):
        self._ensure_enabled(gcmd)
        slot = gcmd.get_int("INDEX", minval=0, maxval=self.slot_count - 1)
        length = gcmd.get_int("LENGTH", minval=1)
        speed = gcmd.get_int("SPEED", default=self.feed_speed, minval=1, maxval=25)
        self._request(
            {
                "method": "feed_filament",
                "params": {"index": slot, "length": length, "speed": speed},
            }
        )
        self._wait_until_ready(
            "feeding slot %d" % (slot,),
            self.operation_timeout
            + (float(length) / float(speed))
            + self.command_margin,
        )
        gcmd.respond_info(
            "ACE fed slot %d forward by %dmm at %d" % (slot, length, speed)
        )

    cmd_ACE_RETRACT_help = "Retract filament back into the ACE"

    def cmd_ACE_RETRACT(self, gcmd):
        self._ensure_enabled(gcmd)
        slot = gcmd.get_int("INDEX", minval=0, maxval=self.slot_count - 1)
        length = gcmd.get_int("LENGTH", minval=1)
        speed = gcmd.get_int(
            "SPEED", default=self.retract_speed, minval=1, maxval=25
        )
        self._request(
            {
                "method": "unwind_filament",
                "params": {
                    "index": slot,
                    "length": length,
                    "speed": speed,
                    "mode": self.retract_mode,
                },
            }
        )
        self._wait_until_ready(
            "retracting slot %d" % (slot,),
            self.operation_timeout
            + (float(length) / float(speed))
            + self.command_margin,
        )
        gcmd.respond_info(
            "ACE retracted slot %d by %dmm at %d" % (slot, length, speed)
        )

    cmd_ACE_CHANGE_TOOL_help = "Perform an ACE toolchange to TOOL=<0-3| -1>"

    def cmd_ACE_CHANGE_TOOL(self, gcmd):
        self._ensure_enabled(gcmd)
        tool = gcmd.get_int("TOOL")
        if tool < -1 or tool >= self.slot_count:
            raise gcmd.error("ACE tool index is out of range")
        if self.toolchange_in_progress:
            raise gcmd.error("ACE toolchange already in progress")
        previous = self.active_slot
        if previous == tool:
            gcmd.respond_info("ACE tool %d is already active" % (tool,))
            return
        if tool != -1:
            self._ensure_slot_ready(tool)

        self.toolchange_in_progress = True
        try:
            self._run_macro(self.pre_toolchange_macro, FROM=previous, TO=tool)
            if previous != -1:
                self._request(
                    {
                        "method": "unwind_filament",
                        "params": {
                            "index": previous,
                            "length": self.toolchange_retract_length,
                            "speed": self.retract_speed,
                            "mode": self.retract_mode,
                        },
                    }
                )
                self._wait_until_ready(
                    "retracting active filament",
                    self.operation_timeout
                    + (
                        float(self.toolchange_retract_length)
                        / float(self.retract_speed)
                    )
                    + self.command_margin,
                )

            if tool != -1:
                self._request(
                    {"method": "start_feed_assist", "params": {"index": tool}}
                )
                try:
                    self._wait_for_park_completion(tool)
                    if self.disable_assist_after_toolchange:
                        self._stop_feed_assist(tool)
                    self._verify_toolhead_sensor()
                finally:
                    if not self.disable_assist_after_toolchange:
                        pass
                self._save_active_slot(tool)
            else:
                self._save_active_slot(-1)

            self._run_macro(self.post_toolchange_macro, FROM=previous, TO=tool)
            gcmd.respond_info("ACE toolchange %d -> %d complete" % (previous, tool))
        except Exception as exc:
            if tool != -1:
                self._stop_feed_assist(tool)
            raise gcmd.error(str(exc))
        finally:
            self.toolchange_in_progress = False

    cmd_ACE_SET_ACTIVE_SLOT_help = (
        "Manually set the tracked ACE active slot for recovery workflows"
    )

    def cmd_ACE_SET_ACTIVE_SLOT(self, gcmd):
        slot = gcmd.get_int("SLOT")
        if slot < -1 or slot >= self.slot_count:
            raise gcmd.error("ACE slot is out of range")
        save_to_disk = bool(gcmd.get_int("SAVE", default=1, minval=0, maxval=1))
        self._save_active_slot(slot, save_to_disk=save_to_disk)
        gcmd.respond_info(
            "ACE active slot set to %d%s"
            % (slot, " and saved" if save_to_disk else "")
        )

    cmd_ACE_DEBUG_help = "Send a raw ACE RPC method for debugging"

    def cmd_ACE_DEBUG(self, gcmd):
        self._ensure_enabled(gcmd)
        method = gcmd.get("METHOD")
        params_raw = gcmd.get("PARAMS", "{}")
        try:
            params = json.loads(params_raw)
        except Exception as exc:
            raise gcmd.error("ACE debug params are not valid JSON: %s" % (exc,))
        response = self._request({"method": method, "params": params})
        gcmd.respond_info(str(response))


def load_config(config):
    return AceController(config)
