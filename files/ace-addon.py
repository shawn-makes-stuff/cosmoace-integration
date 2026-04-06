#!/usr/bin/env python3
"""ACE addon service with Anycubic ACE framed JSON RPC transport."""

import argparse
import configparser
import glob
import json
import logging
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

try:
    import serial  # type: ignore
except Exception:  # pragma: no cover
    serial = None

DEFAULT_CONFIG_PATH = "/user-resource/ace-addon/ace-addon.conf"
DEFAULT_LISTEN_HOST = "127.0.0.1"
DEFAULT_LISTEN_PORT = 8091


def read_text(path: str, default: str = "") -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except Exception:
        return default


class AceTransport:
    def __init__(self, cfg: configparser.ConfigParser) -> None:
        self.port = cfg.get("ace", "serial_port", fallback="auto").strip() or "auto"
        self.baudrate = cfg.getint("ace", "baudrate", fallback=115200)
        self.command_timeout_s = cfg.getfloat("ace", "command_timeout_s", fallback=1.0)
        self.rpc_timeout_s = cfg.getfloat("ace", "rpc_timeout_s", fallback=2.5)
        self.read_idle_s = cfg.getfloat("ace", "read_idle_s", fallback=0.08)
        self.read_max_bytes = cfg.getint("ace", "read_max_bytes", fallback=4096)
        self._resolved_port: Optional[str] = None
        self._ser = None
        self._io_lock = threading.Lock()
        self._request_id = 0
        self.last_error: Optional[str] = None
        self.last_tx: Optional[str] = None
        self.last_rx: Optional[str] = None
        self.last_tx_hex: Optional[str] = None
        self.last_rx_hex: Optional[str] = None
        self.last_seen_unix: float = 0.0
        self.last_rpc: Optional[Dict[str, Any]] = None

    def _port_holders(self, port: str) -> list:
        target = os.path.realpath(port)
        holders = []
        try:
            pids = [p for p in os.listdir("/proc") if p.isdigit()]
        except Exception:
            return holders
        my_pid = os.getpid()
        for pid_s in pids:
            pid = int(pid_s)
            if pid == my_pid:
                continue
            fd_dir = f"/proc/{pid_s}/fd"
            try:
                fds = os.listdir(fd_dir)
            except Exception:
                continue
            found = False
            for fd in fds:
                link_path = os.path.join(fd_dir, fd)
                try:
                    link = os.path.realpath(link_path)
                except Exception:
                    continue
                if link == target:
                    comm = read_text(f"/proc/{pid_s}/comm", "?")
                    cmdline = read_text(f"/proc/{pid_s}/cmdline", "").replace("\x00", " ").strip()
                    holders.append({"pid": pid, "comm": comm, "cmdline": cmdline})
                    found = True
                    break
            if found:
                continue
        return holders

    def _klipper_serial_ports(self) -> set:
        ports = set()
        paths = [
            "/etc/klipper/config/printer.cfg",
            "/etc/klipper/config/klipper-readonly",
            "/etc/klipper/config",
        ]
        files = []
        for path in paths:
            if os.path.isdir(path):
                for root, _, names in os.walk(path):
                    for name in names:
                        if not name.endswith(".cfg"):
                            continue
                        files.append(os.path.join(root, name))
            elif os.path.isfile(path):
                files.append(path)

        for file_path in files:
            try:
                with open(file_path, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        s = line.strip()
                        if not s or s.startswith("#"):
                            continue
                        if not s.lower().startswith("serial:"):
                            continue
                        raw = s.split(":", 1)[1].strip()
                        if not raw.startswith("/dev/"):
                            continue
                        ports.add(raw)
                        ports.add(os.path.realpath(raw))
            except Exception:
                continue
        return ports

    def _scan_serial_ports(self) -> Dict[str, Any]:
        candidates = []
        seen = set()

        for path in sorted(glob.glob("/dev/serial/by-id/*")):
            real = os.path.realpath(path)
            candidates.append({"path": path, "realpath": real, "source": "by-id"})
            seen.add(path)
            seen.add(real)

        for pattern in ["/dev/ttyACM*", "/dev/ttyUSB*"]:
            for path in sorted(glob.glob(pattern)):
                real = os.path.realpath(path)
                if path in seen or real in seen:
                    continue
                candidates.append({"path": path, "realpath": real, "source": "glob"})
                seen.add(path)
                seen.add(real)

        klipper_ports = self._klipper_serial_ports()
        report = []
        free_candidates = []
        for item in candidates:
            path = item["path"]
            real = item["realpath"]
            holders = self._port_holders(path)
            in_use = bool(holders)
            owned_by_klipper = path in klipper_ports or real in klipper_ports
            report_item = {
                "path": path,
                "realpath": real,
                "source": item["source"],
                "in_use": in_use,
                "holders": holders,
                "owned_by_klipper": owned_by_klipper,
            }
            report.append(report_item)
            if not in_use and not owned_by_klipper:
                free_candidates.append(path)

        return {
            "candidates": report,
            "free_candidates": free_candidates,
        }

    def _resolve_target_port(self) -> Optional[str]:
        if self.port.lower() != "auto":
            self._resolved_port = self.port
            return self._resolved_port
        scan = self._scan_serial_ports()
        free = scan.get("free_candidates", [])
        if not free:
            self._resolved_port = None
            self.last_error = "no free USB serial ports found (all candidates are busy or used by klipper)"
            return None
        self._resolved_port = str(free[0])
        return self._resolved_port

    def connect(self) -> bool:
        if serial is None:
            self.last_error = "pyserial is not available"
            return False
        if self._ser and self._ser.is_open:
            return True
        target_port = self._resolve_target_port()
        if not target_port:
            return False
        holders = self._port_holders(target_port)
        if holders:
            lead = holders[0]
            self.last_error = (
                f"port {target_port} is already in use by pid {lead.get('pid')} ({lead.get('comm')})"
            )
            return False
        try:
            self._ser = serial.Serial(
                target_port,
                self.baudrate,
                timeout=self.command_timeout_s,
                write_timeout=self.command_timeout_s,
            )
            self.last_error = None
            self.last_seen_unix = time.time()
            return True
        except Exception as exc:
            self.last_error = f"connect failed: {exc}"
            self._ser = None
            return False

    def disconnect(self) -> None:
        try:
            if self._ser:
                self._ser.close()
        except Exception:
            pass
        self._ser = None

    @staticmethod
    def _crc16_mcrf4xx(data: bytes) -> int:
        crc = 0xFFFF
        for byte in data:
            v = byte ^ (crc & 0xFF)
            v ^= (v & 0x0F) << 4
            crc = (((v << 8) | (crc >> 8)) ^ (v >> 4) ^ (v << 3)) & 0xFFFF
        return crc

    @staticmethod
    def _build_frame(payload: bytes) -> bytes:
        frame = bytearray()
        frame.extend(b"\xFF\xAA")
        frame.extend(len(payload).to_bytes(2, "little"))
        frame.extend(payload)
        frame.extend(AceTransport._crc16_mcrf4xx(payload).to_bytes(2, "little"))
        frame.extend(b"\xFE")
        return bytes(frame)

    def _read_exact(self, count: int, deadline: float) -> bytes:
        assert self._ser is not None
        out = bytearray()
        idle_timeout = max(0.01, self.read_idle_s)
        while len(out) < count:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            old_timeout = getattr(self._ser, "timeout", self.command_timeout_s)
            try:
                current_timeout = old_timeout if isinstance(old_timeout, float) else remaining
                self._ser.timeout = max(idle_timeout, min(current_timeout, remaining))
                chunk = self._ser.read(count - len(out))
            finally:
                self._ser.timeout = old_timeout
            if not chunk:
                continue
            out.extend(chunk)
        return bytes(out)

    def _read_frame(self, timeout_s: float) -> Dict[str, Any]:
        assert self._ser is not None
        deadline = time.time() + timeout_s
        header = bytearray()

        # Find frame header 0xFFAA
        while time.time() < deadline:
            b = self._read_exact(1, deadline)
            if not b:
                continue
            header.append(b[0])
            if len(header) > 2:
                header = header[-2:]
            if len(header) == 2 and header[0] == 0xFF and header[1] == 0xAA:
                break
        else:
            return {"ok": False, "error": "timeout waiting for frame header"}

        raw_len = self._read_exact(2, deadline)
        if len(raw_len) != 2:
            return {"ok": False, "error": "timeout waiting for frame length"}
        payload_len = int.from_bytes(raw_len, "little")
        if payload_len <= 0 or payload_len > self.read_max_bytes:
            return {"ok": False, "error": f"invalid frame payload length {payload_len}"}

        payload = self._read_exact(payload_len, deadline)
        if len(payload) != payload_len:
            return {"ok": False, "error": "timeout waiting for frame payload"}

        crc_raw = self._read_exact(2, deadline)
        if len(crc_raw) != 2:
            return {"ok": False, "error": "timeout waiting for frame crc"}
        crc_got = int.from_bytes(crc_raw, "little")
        crc_expected = self._crc16_mcrf4xx(payload)
        if crc_got != crc_expected:
            return {"ok": False, "error": f"crc mismatch got={crc_got:04x} expected={crc_expected:04x}"}

        # Consume trailing bytes until frame terminator 0xFE.
        while time.time() < deadline:
            tail = self._read_exact(1, deadline)
            if not tail:
                continue
            if tail == b"\xFE":
                break
        else:
            return {"ok": False, "error": "timeout waiting for frame terminator"}

        self.last_rx_hex = payload.hex()
        self.last_rx = self._bytes_to_ascii_safe(payload)
        self.last_seen_unix = time.time()
        try:
            parsed = json.loads(payload.decode("utf-8"))
            if isinstance(parsed, dict):
                self.last_rpc = parsed
            return {"ok": True, "payload": parsed, "payload_raw": payload}
        except Exception:
            return {"ok": True, "payload_raw": payload}

    def _read_matching_response(self, request_id: int, timeout_s: float) -> Dict[str, Any]:
        deadline = time.time() + timeout_s
        mismatches = []
        while time.time() < deadline:
            remaining = max(0.05, deadline - time.time())
            response = self._read_frame(remaining)
            if not response.get("ok", False):
                error = str(response.get("error", "rpc read failed"))
                if mismatches and error == "timeout waiting for frame header":
                    return {
                        "ok": False,
                        "error": f"{error} after {len(mismatches)} stale frame(s)",
                        "stale_ids": mismatches,
                    }
                return response
            parsed = response.get("payload")
            if not isinstance(parsed, dict):
                logging.warning("ignoring non-dict ACE RPC frame while waiting for id=%s", request_id)
                continue
            response_id = parsed.get("id")
            if response_id == request_id:
                return {"ok": True, "response": parsed}
            mismatches.append(response_id)
            logging.warning(
                "ignoring stale ACE RPC frame while waiting for id=%s; got id=%s",
                request_id,
                response_id,
            )
        return {
            "ok": False,
            "error": f"timeout waiting for matching rpc response id={request_id}",
            "stale_ids": mismatches,
        }

    @staticmethod
    def _bytes_to_ascii_safe(data: bytes) -> str:
        return data.decode("ascii", errors="backslashreplace")

    @staticmethod
    def _clean_hex(value: str) -> str:
        return "".join(ch for ch in value if ch not in " \t\r\n:")

    def _next_id(self) -> int:
        current = self._request_id
        self._request_id = (self._request_id + 1) % 300000
        return current

    def rpc_call(self, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        if not method:
            return {"ok": False, "error": "rpc method required"}
        if not self.connect():
            return {"ok": False, "error": self.last_error or "not connected"}
        assert self._ser is not None

        req: Dict[str, Any] = {"id": self._next_id(), "method": method}
        if params:
            req["params"] = params
        payload = json.dumps(req, separators=(",", ":")).encode("utf-8")
        frame = self._build_frame(payload)

        with self._io_lock:
            try:
                self._ser.write(frame)
                self._ser.flush()
                self.last_tx_hex = frame.hex()
                self.last_tx = self._bytes_to_ascii_safe(payload)
                self.last_seen_unix = time.time()
                response = self._read_matching_response(int(req["id"]), self.rpc_timeout_s)
                if not response.get("ok", False):
                    self.last_error = str(response.get("error", "rpc read failed"))
                    return {"ok": False, "error": self.last_error}
                parsed = response.get("response")
                if not isinstance(parsed, dict):
                    return {"ok": False, "error": "rpc response is not a JSON object"}
                self.last_error = None
                return {"ok": True, "request": req, "response": parsed}
            except Exception as exc:
                self.last_error = f"rpc failed: {exc}"
                self.disconnect()
                return {"ok": False, "error": self.last_error}

    def reconfigure(self, port: Optional[str], baudrate: Optional[int]) -> Dict[str, Any]:
        if port:
            self.port = port
            self._resolved_port = None
        if baudrate:
            self.baudrate = baudrate
        self.disconnect()
        if not self.connect():
            return {"ok": False, "error": self.last_error or "connect failed"}
        return {"ok": True, "transport": self.status()}

    def status(self) -> Dict[str, Any]:
        connected = bool(self._ser and self._ser.is_open)
        scan = self._scan_serial_ports()
        current_port = self._resolved_port if self.port.lower() == "auto" else self.port
        return {
            "connected": connected,
            "serial_port": current_port,
            "configured_serial_port": self.port,
            "resolved_serial_port": self._resolved_port,
            "baudrate": self.baudrate,
            "port_holders": self._port_holders(current_port) if current_port else [],
            "scan": scan,
            "last_error": self.last_error,
            "last_tx": self.last_tx,
            "last_rx": self.last_rx,
            "last_tx_hex": self.last_tx_hex,
            "last_rx_hex": self.last_rx_hex,
            "last_rpc": self.last_rpc,
            "last_seen_unix": self.last_seen_unix,
        }


def _int(payload: Dict[str, Any], key: str, fallback: int) -> int:
    value = payload.get(key, fallback)
    try:
        return int(value)
    except Exception:
        return fallback


def _float(payload: Dict[str, Any], key: str, fallback: float) -> float:
    value = payload.get(key, fallback)
    try:
        return float(value)
    except Exception:
        return fallback


class MoonrakerClient:
    def __init__(self, cfg: configparser.ConfigParser) -> None:
        self.base_url = cfg.get("moonraker", "url", fallback="http://127.0.0.1:7125").strip().rstrip("/")
        self.timeout_s = cfg.getfloat("moonraker", "timeout_s", fallback=3.0)

    def _request_json(
        self,
        method: str,
        path: str,
        payload: Optional[Dict[str, Any]] = None,
        timeout_s: Optional[float] = None,
    ) -> Dict[str, Any]:
        url = f"{self.base_url}{path}"
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        headers = {"Content-Type": "application/json"} if body is not None else {}
        req = Request(url, data=body, headers=headers, method=method)
        try:
            with urlopen(req, timeout=timeout_s or self.timeout_s) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
        except HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(raw) if raw else {}
            except Exception:
                parsed = {"raw": raw}
            return {
                "ok": False,
                "error": f"moonraker http {exc.code}",
                "status_code": exc.code,
                "response": parsed,
            }
        except URLError as exc:
            return {"ok": False, "error": f"moonraker url error: {exc.reason}"}
        except Exception as exc:
            return {"ok": False, "error": f"moonraker request failed: {exc}"}

        try:
            parsed = json.loads(raw) if raw else {}
        except Exception as exc:
            return {"ok": False, "error": f"moonraker returned invalid json: {exc}", "raw": raw}

        if isinstance(parsed, dict) and "error" in parsed:
            err = parsed.get("error")
            if isinstance(err, dict):
                message = err.get("message") or err.get("error") or json.dumps(err, sort_keys=True)
            else:
                message = str(err)
            return {"ok": False, "error": f"moonraker error: {message}", "response": parsed}

        return {"ok": True, "response": parsed}

    def query_objects(self, *objects: str, timeout_s: Optional[float] = None) -> Dict[str, Any]:
        encoded = [quote(name, safe="") for name in objects if name]
        path = "/printer/objects/query"
        if encoded:
            path = f"{path}?{'&'.join(encoded)}"
        return self._request_json("GET", path, timeout_s=timeout_s)


class AceController:
    def __init__(self, cfg: configparser.ConfigParser, start_polling: bool = True) -> None:
        self.cfg = cfg
        self.transport = AceTransport(cfg)
        self.moonraker = MoonrakerClient(cfg)
        self.default_feed_mm = cfg.getint("defaults", "feed_mm", fallback=90)
        self.default_retract_mm = cfg.getint("defaults", "retract_mm", fallback=90)
        self.default_dry_temp_c = cfg.getint("defaults", "dry_temp_c", fallback=45)
        self.default_dry_minutes = cfg.getint("defaults", "dry_minutes", fallback=240)
        self.feed_speed = cfg.getint("ace", "feed_speed", fallback=25)
        self.retract_speed = cfg.getint("ace", "retract_speed", fallback=15)
        self.dry_fan_speed = cfg.getint("ace", "dry_fan_speed", fallback=7000)
        self.keepalive_enabled = cfg.getboolean("ace", "keepalive_enabled", fallback=True)
        self.keepalive_interval_s = cfg.getfloat("ace", "keepalive_interval_s", fallback=1.0)
        self.sensor_name = cfg.get("klipper", "sensor_name", fallback="runout").strip() or "runout"
        self.last_ace_status: Optional[Dict[str, Any]] = None
        self.last_ace_status_unix: float = 0.0
        self.last_command: Optional[Dict[str, Any]] = None
        self._stop = threading.Event()
        self._poll_thread: Optional[threading.Thread] = None
        if start_polling:
            self._poll_thread = threading.Thread(target=self._poll_loop, name="ace-addon-poll", daemon=True)
            self._poll_thread.start()

    def close(self) -> None:
        self._stop.set()
        if self._poll_thread is not None:
            self._poll_thread.join(timeout=2.0)

    @staticmethod
    def _user_slot_to_index(slot: int) -> Optional[int]:
        if 1 <= slot <= 4:
            return slot - 1
        return None

    @staticmethod
    def _raw_index(value: int) -> Optional[int]:
        if 0 <= value <= 3:
            return value
        return None

    def _slot_from_payload(self, payload: Dict[str, Any]) -> Optional[int]:
        try:
            if "index" in payload and payload.get("index") is not None:
                return self._raw_index(int(payload["index"]))
            if "slot" in payload and payload.get("slot") is not None:
                return self._user_slot_to_index(int(payload["slot"]))
        except Exception:
            return None
        return None

    @staticmethod
    def _normalize_stop_result(slot: int, result: Dict[str, Any], method_name: str) -> Dict[str, Any]:
        error = str(result.get("error", "")).strip().lower()
        if result.get("ok", False) or error != "timeout waiting for frame header":
            return result
        logging.warning(
            "%s for slot %s timed out waiting for a reply frame; assuming success",
            method_name,
            slot + 1,
        )
        return {
            "ok": True,
            "assumed_success": True,
            "warning": f"{method_name} timed out waiting for reply; assuming success",
            "original_error": result.get("error"),
        }

    @staticmethod
    def _optional_int(value: Any) -> Optional[int]:
        if isinstance(value, bool):
            return None
        if isinstance(value, int):
            return value
        if isinstance(value, str):
            stripped = value.strip()
            if stripped and stripped.lstrip("-").isdigit():
                return int(stripped)
        return None

    def _update_status_cache(self, result: Dict[str, Any]) -> None:
        parsed = result.get("response")
        if not result.get("ok", False) or not isinstance(parsed, dict):
            return
        maybe_status = parsed.get("result")
        if isinstance(maybe_status, dict) and ("status" in maybe_status or "slots" in maybe_status):
            self.last_ace_status = maybe_status
            self.last_ace_status_unix = time.time()

    def _record_last_command(
        self,
        cmd: str,
        result: Dict[str, Any],
        slot: Optional[int] = None,
        extra: Optional[Dict[str, Any]] = None,
    ) -> None:
        record: Dict[str, Any] = {
            "cmd": cmd,
            "result_ok": result.get("ok", False),
            "unix_time": time.time(),
        }
        if slot is not None:
            record["slot"] = slot
        if extra:
            for key, value in extra.items():
                if value is not None:
                    record[key] = value
        if "warning" in result and result.get("warning"):
            record["warning"] = result.get("warning")
        if result.get("assumed_success", False):
            record["assumed_success"] = True
        self.last_command = record

    def _wait_for_motion_complete(self, slot: int, timeout_s: float, poll_interval_s: float = 0.2) -> Dict[str, Any]:
        deadline = time.time() + max(0.5, timeout_s)
        last_status: Optional[Dict[str, Any]] = None
        last_error: Optional[str] = None
        while time.time() < deadline:
            status_result = self.transport.rpc_call("get_status")
            if status_result.get("ok", False):
                parsed = status_result.get("response")
                if isinstance(parsed, dict) and isinstance(parsed.get("result"), dict):
                    result = parsed.get("result")
                    if isinstance(result, dict):
                        last_status = result
                        self.last_ace_status = result
                        self.last_ace_status_unix = time.time()
                        overall_status = str(result.get("status", "")).strip().lower()
                        action = str(result.get("action", "")).strip().lower()
                        slots = result.get("slots")
                        slot_status = ""
                        if isinstance(slots, list) and 0 <= slot < len(slots):
                            slot_entry = slots[slot]
                            if isinstance(slot_entry, dict):
                                slot_status = str(slot_entry.get("status", "")).strip().lower()
                        if overall_status != "busy" and action != "unwinding" and slot_status != "unwinding":
                            return {
                                "ok": True,
                                "status": result,
                            }
            else:
                last_error = str(status_result.get("error", "status refresh failed"))
            time.sleep(max(0.05, poll_interval_s))
        return {
            "ok": False,
            "error": "timeout waiting for ACE motion to complete",
            "last_status": last_status,
            "last_status_error": last_error,
        }

    def _query_sensor_state(self, sensor_name: str, timeout_s: float = 3.0) -> Dict[str, Any]:
        object_name = f"filament_switch_sensor {sensor_name}"
        result = self.moonraker.query_objects(object_name, timeout_s=timeout_s)
        if not result.get("ok", False):
            return result
        response = result.get("response")
        if not isinstance(response, dict):
            return {"ok": False, "error": "moonraker sensor query returned non-object"}
        payload = response.get("result")
        if not isinstance(payload, dict):
            return {"ok": False, "error": "moonraker sensor query missing result"}
        status = payload.get("status")
        if not isinstance(status, dict):
            return {"ok": False, "error": "moonraker sensor query missing status"}
        sensor = status.get(object_name)
        if not isinstance(sensor, dict):
            return {"ok": False, "error": f"moonraker sensor object '{object_name}' missing"}
        return {
            "ok": True,
            "sensor_name": sensor_name,
            "filament_detected": bool(sensor.get("filament_detected")),
            "status": sensor,
            "eventtime": payload.get("eventtime"),
        }

    def _wait_for_sensor_state(
        self,
        sensor_name: str,
        filament_detected: bool,
        timeout_s: float,
        poll_interval_s: float = 0.05,
    ) -> Dict[str, Any]:
        deadline = time.time() + max(0.2, timeout_s)
        last_result: Optional[Dict[str, Any]] = None
        while time.time() < deadline:
            result = self._query_sensor_state(sensor_name)
            if result.get("ok", False):
                last_result = result
                if bool(result.get("filament_detected")) == filament_detected:
                    return result
            else:
                last_result = result
            time.sleep(max(0.02, poll_interval_s))
        return {
            "ok": False,
            "error": f"timeout waiting for sensor '{sensor_name}' to become {'triggered' if filament_detected else 'clear'}",
            "last_sensor_result": last_result,
        }

    def _poll_loop(self) -> None:
        while not self._stop.is_set():
            if self.keepalive_enabled:
                try:
                    res = self.transport.rpc_call("get_status")
                    if res.get("ok", False):
                        parsed = res.get("response")
                        if isinstance(parsed, dict) and isinstance(parsed.get("result"), dict):
                            self.last_ace_status = parsed.get("result")
                            self.last_ace_status_unix = time.time()
                except Exception as exc:
                    self.transport.last_error = f"poll failed: {exc}"
            self._stop.wait(max(0.2, self.keepalive_interval_s))

    def execute(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        cmd = str(payload.get("cmd", "")).strip().lower()
        slot = self._slot_from_payload(payload)
        result: Dict[str, Any]
        extra_command_fields: Dict[str, Any] = {}

        if cmd == "feed":
            if slot is None:
                return {"ok": False, "error": "feed requires slot 1..4 or index 0..3"}
            mm = _int(payload, "mm", self.default_feed_mm)
            speed = _int(payload, "speed", self.feed_speed)
            result = self.transport.rpc_call("feed_filament", {"index": slot, "length": mm, "speed": speed})
        elif cmd == "retract":
            if slot is None:
                return {"ok": False, "error": "retract requires slot 1..4 or index 0..3"}
            mm = _int(payload, "mm", self.default_retract_mm)
            speed = _int(payload, "speed", self.retract_speed)
            result = self.transport.rpc_call(
                "unwind_filament",
                {"index": slot, "length": mm, "speed": speed, "mode": 0},
            )
        elif cmd == "retract_wait":
            if slot is None:
                return {"ok": False, "error": "retract_wait requires slot 1..4 or index 0..3"}
            mm = _int(payload, "mm", self.default_retract_mm)
            speed = _int(payload, "speed", self.retract_speed)
            timeout_s = _float(payload, "timeout_s", (float(mm) / max(float(speed), 1.0)) + 5.0)
            result = self.transport.rpc_call(
                "unwind_filament",
                {"index": slot, "length": mm, "speed": speed, "mode": 0},
            )
            if result.get("ok", False):
                wait_result = self._wait_for_motion_complete(slot, timeout_s)
                if not wait_result.get("ok", False):
                    result = wait_result
        elif cmd == "feed_to_sensor":
            if slot is None:
                return {"ok": False, "error": "feed_to_sensor requires slot 1..4 or index 0..3"}
            mm = _int(payload, "mm", self.default_feed_mm)
            speed = _int(payload, "speed", self.feed_speed)
            sensor_name = str(payload.get("sensor") or self.sensor_name).strip() or self.sensor_name
            timeout_s = _float(payload, "timeout_s", (float(mm) / max(float(speed), 1.0)) + 10.0)
            sensor_result = self._query_sensor_state(sensor_name)
            if sensor_result.get("ok", False) and sensor_result.get("filament_detected", False):
                return {"ok": False, "error": f"sensor '{sensor_name}' is already triggered", "sensor": sensor_result}
            result = self.transport.rpc_call("feed_filament", {"index": slot, "length": mm, "speed": speed})
            if result.get("ok", False):
                wait_result = self._wait_for_sensor_state(sensor_name, True, timeout_s)
                stop_result = self._normalize_stop_result(
                    slot,
                    self.transport.rpc_call("stop_feed_filament", {"index": slot}),
                    "stop_feed_filament",
                )
                settle_result = self._wait_for_motion_complete(slot, 5.0)
                if wait_result.get("ok", False) and stop_result.get("ok", False):
                    result = {
                        "ok": True,
                        "sensor_name": sensor_name,
                        "filament_detected": True,
                        "sensor": wait_result,
                        "stop_result": stop_result,
                        "settle_result": settle_result,
                    }
                    if stop_result.get("warning"):
                        result["warning"] = stop_result.get("warning")
                    if stop_result.get("assumed_success", False):
                        result["assumed_success"] = True
                    if not settle_result.get("ok", False):
                        result["settle_warning"] = settle_result.get("error")
                else:
                    result = {
                        "ok": False,
                        "error": wait_result.get("error", "sensor did not trigger") if not wait_result.get("ok", False) else stop_result.get("error", "stop failed"),
                        "sensor_name": sensor_name,
                        "sensor": wait_result,
                        "stop_result": stop_result,
                        "settle_result": settle_result,
                    }
        elif cmd == "retract_to_sensor":
            if slot is None:
                return {"ok": False, "error": "retract_to_sensor requires slot 1..4 or index 0..3"}
            mm = _int(payload, "mm", self.default_retract_mm)
            speed = _int(payload, "speed", self.retract_speed)
            sensor_name = str(payload.get("sensor") or self.sensor_name).strip() or self.sensor_name
            timeout_s = _float(payload, "timeout_s", (float(mm) / max(float(speed), 1.0)) + 10.0)
            settle_timeout_s = _float(payload, "settle_timeout_s", 5.0)
            sensor_result = self._query_sensor_state(sensor_name)
            if sensor_result.get("ok", False) and not sensor_result.get("filament_detected", False):
                result = {
                    "ok": True,
                    "already_clear": True,
                    "sensor_name": sensor_name,
                    "sensor": sensor_result,
                }
            else:
                result = self.transport.rpc_call(
                    "unwind_filament",
                    {"index": slot, "length": mm, "speed": speed, "mode": 0},
                )
                if result.get("ok", False):
                    wait_result = self._wait_for_sensor_state(sensor_name, False, timeout_s)
                    stop_result = self._normalize_stop_result(
                        slot,
                        self.transport.rpc_call("stop_unwind_filament", {"index": slot}),
                        "stop_unwind_filament",
                    )
                    settle_result = self._wait_for_motion_complete(slot, settle_timeout_s)
                    if wait_result.get("ok", False) and stop_result.get("ok", False) and settle_result.get("ok", False):
                        result = {
                            "ok": True,
                            "sensor_name": sensor_name,
                            "filament_detected": False,
                            "sensor": wait_result,
                            "stop_result": stop_result,
                            "settle_result": settle_result,
                        }
                        if stop_result.get("warning"):
                            result["warning"] = stop_result.get("warning")
                        if stop_result.get("assumed_success", False):
                            result["assumed_success"] = True
                    else:
                        error = wait_result.get("error", "sensor did not clear")
                        if wait_result.get("ok", False) and stop_result.get("ok", False):
                            error = settle_result.get("error", "ACE unwind did not settle after stop")
                        result = {
                            "ok": False,
                            "error": error,
                            "sensor_name": sensor_name,
                            "sensor": wait_result,
                            "stop_result": stop_result,
                            "settle_result": settle_result,
                        }
        elif cmd == "stop":
            if slot is None:
                return {"ok": False, "error": "stop requires slot 1..4 or index 0..3"}
            result = self.transport.rpc_call("stop_feed_filament", {"index": slot})
            result = self._normalize_stop_result(slot, result, "stop_feed_filament")
        elif cmd == "stop_unwind":
            if slot is None:
                return {"ok": False, "error": "stop_unwind requires slot 1..4 or index 0..3"}
            result = self.transport.rpc_call("stop_unwind_filament", {"index": slot})
            result = self._normalize_stop_result(slot, result, "stop_unwind_filament")
        elif cmd == "dry_start":
            temp_c = _int(payload, "temp_c", self.default_dry_temp_c)
            minutes = _int(payload, "minutes", self.default_dry_minutes)
            fan_speed = _int(payload, "fan_speed", self.dry_fan_speed)
            result = self.transport.rpc_call(
                "drying",
                {"temp": temp_c, "fan_speed": fan_speed, "duration": minutes},
            )
        elif cmd == "dry_stop":
            result = self.transport.rpc_call("drying_stop")
        elif cmd == "status_refresh":
            result = self.transport.rpc_call("get_status")
        elif cmd == "raw_method":
            method = str(payload.get("method", "")).strip()
            params = payload.get("params")
            if not method:
                return {"ok": False, "error": "raw_method requires 'method'"}
            if params is not None and not isinstance(params, dict):
                return {"ok": False, "error": "raw_method params must be object"}
            result = self.transport.rpc_call(method, params if isinstance(params, dict) else None)
            extra_command_fields["method"] = method
        elif cmd == "set_serial":
            port = payload.get("port")
            baudrate = self._optional_int(payload.get("baudrate"))
            result = self.transport.reconfigure(
                str(port).strip() if isinstance(port, str) and port.strip() else None,
                baudrate,
            )
            extra_command_fields["port"] = port
            extra_command_fields["baudrate"] = baudrate
        else:
            return {"ok": False, "error": f"unsupported cmd '{cmd}'"}

        self._update_status_cache(result)
        self._record_last_command(cmd, result, slot=slot, extra=extra_command_fields)
        return result

    def status(self) -> Dict[str, Any]:
        return {
            "service": "ace-addon",
            "api_version": "0.2",
            "transport": self.transport.status(),
            "defaults": {
                "feed_mm": self.default_feed_mm,
                "retract_mm": self.default_retract_mm,
                "dry_temp_c": self.default_dry_temp_c,
                "dry_minutes": self.default_dry_minutes,
            },
            "ace_status": self.last_ace_status,
            "ace_status_unix": self.last_ace_status_unix,
            "keepalive_enabled": self.keepalive_enabled,
            "keepalive_interval_s": self.keepalive_interval_s,
            "last_command": self.last_command,
        }


def parse_config(path: str) -> configparser.ConfigParser:
    cfg = configparser.ConfigParser()
    cfg.read_dict(
        {
            "service": {
                "listen_host": DEFAULT_LISTEN_HOST,
                "listen_port": str(DEFAULT_LISTEN_PORT),
                "log_path": "/board-resource/ace-addon.log",
            },
            "ace": {
                "serial_port": "auto",
                "baudrate": "115200",
                "command_timeout_s": "1.0",
                "rpc_timeout_s": "1.5",
                "read_idle_s": "0.08",
                "read_max_bytes": "4096",
                "feed_speed": "25",
                "retract_speed": "15",
                "dry_fan_speed": "7000",
                "keepalive_enabled": "true",
                "keepalive_interval_s": "1.0",
            },
            "klipper": {
                "sensor_name": "runout",
            },
            "moonraker": {
                "url": "http://127.0.0.1:7125",
                "timeout_s": "3.0",
            },
            "defaults": {
                "feed_mm": "90",
                "retract_mm": "90",
                "dry_temp_c": "45",
                "dry_minutes": "240",
            },
        }
    )
    cfg.read(path)
    return cfg


def configure_logging(cfg: configparser.ConfigParser) -> None:
    log_path = cfg.get("service", "log_path", fallback="/board-resource/ace-addon.log")
    log_dir = os.path.dirname(log_path)
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)
    handlers = [
        logging.FileHandler(log_path, encoding="utf-8"),
        logging.StreamHandler(),
    ]
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=handlers,
        force=True,
    )


def make_handler(controller: AceController):
    class Handler(BaseHTTPRequestHandler):
        def _json(self, status_code: int, payload: Dict[str, Any]) -> None:
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            if self.path == "/healthz":
                self._json(200, {"ok": True})
                return
            if self.path == "/status":
                self._json(200, {"ok": True, "status": controller.status()})
                return
            self._json(404, {"ok": False, "error": "not found"})

        def do_POST(self) -> None:  # noqa: N802
            if self.path != "/command":
                self._json(404, {"ok": False, "error": "not found"})
                return
            try:
                content_len = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(content_len) if content_len > 0 else b"{}"
                payload = json.loads(raw.decode("utf-8"))
                if not isinstance(payload, dict):
                    raise ValueError("payload must be object")
            except Exception as exc:
                self._json(400, {"ok": False, "error": f"bad request: {exc}"})
                return

            result = controller.execute(payload)
            code = 200 if result.get("ok", False) else 500
            self._json(code, result)

        def log_message(self, fmt: str, *args: Any) -> None:
            logging.info("http %s - %s", self.client_address[0], fmt % args)

    return Handler


def resolve_config_path(cli_path: Optional[str]) -> str:
    if cli_path:
        return cli_path
    env_path = os.environ.get("ACE_ADDON_CONFIG", "").strip()
    if env_path:
        return env_path
    return DEFAULT_CONFIG_PATH


def emit_json(payload: Dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def run_command(config_path: str, payload: Dict[str, Any]) -> int:
    cfg = parse_config(config_path)
    configure_logging(cfg)
    controller = AceController(cfg, start_polling=False)
    try:
        result = controller.execute(payload)
        emit_json(result)
        return 0 if result.get("ok", False) else 1
    finally:
        controller.close()
        controller.transport.disconnect()


def run_status(config_path: str, refresh: bool) -> int:
    cfg = parse_config(config_path)
    configure_logging(cfg)
    controller = AceController(cfg, start_polling=False)
    try:
        if refresh:
            controller.execute({"cmd": "status_refresh"})
        emit_json({"ok": True, "status": controller.status()})
        return 0
    finally:
        controller.close()
        controller.transport.disconnect()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default=None, help="Path to ace-addon.conf")
    subparsers = parser.add_subparsers(dest="action")

    command_parser = subparsers.add_parser("command", help="Send one ACE command")
    command_parser.add_argument("--cmd", required=True, help="feed|retract|retract_wait|feed_to_sensor|retract_to_sensor|stop|stop_unwind|dry_start|dry_stop|status_refresh|raw_method|set_serial")
    command_parser.add_argument("--slot", type=int, default=None, help="ACE user slot 1..4")
    command_parser.add_argument("--mm", type=int, default=None)
    command_parser.add_argument("--speed", type=int, default=None)
    command_parser.add_argument("--temp-c", dest="temp_c", type=int, default=None)
    command_parser.add_argument("--minutes", type=int, default=None)
    command_parser.add_argument("--fan-speed", dest="fan_speed", type=int, default=None)
    command_parser.add_argument("--method", default=None)
    command_parser.add_argument("--params-json", dest="params_json", default=None)
    command_parser.add_argument("--port", default=None)
    command_parser.add_argument("--baudrate", type=int, default=None)

    status_parser = subparsers.add_parser("status", help="Emit ACE transport/controller status")
    status_parser.add_argument("--refresh", action="store_true", help="Refresh ACE status over RPC before printing status")

    args = parser.parse_args()

    config_path = resolve_config_path(args.config)
    if args.action == "command":
        payload: Dict[str, Any] = {"cmd": args.cmd}
        if args.slot is not None:
            payload["slot"] = args.slot
        if args.mm is not None:
            payload["mm"] = args.mm
        if args.speed is not None:
            payload["speed"] = args.speed
        if args.temp_c is not None:
            payload["temp_c"] = args.temp_c
        if args.minutes is not None:
            payload["minutes"] = args.minutes
        if args.fan_speed is not None:
            payload["fan_speed"] = args.fan_speed
        if args.method:
            payload["method"] = args.method
        if args.params_json:
            try:
                payload["params"] = json.loads(args.params_json)
            except Exception as exc:
                print(f"Invalid --params-json: {exc}", file=sys.stderr)
                return 2
        if args.port:
            payload["port"] = args.port
        if args.baudrate is not None:
            payload["baudrate"] = args.baudrate
        return run_command(config_path, payload)
    if args.action == "status":
        return run_status(config_path, refresh=bool(args.refresh))
    cfg = parse_config(config_path)
    configure_logging(cfg)
    controller = AceController(cfg)
    host = cfg.get("service", "listen_host", fallback=DEFAULT_LISTEN_HOST)
    port = cfg.getint("service", "listen_port", fallback=DEFAULT_LISTEN_PORT)
    server = ThreadingHTTPServer((host, port), make_handler(controller))
    logging.info("ace-addon listening on %s:%d using config %s", host, port, config_path)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        controller.close()
        controller.transport.disconnect()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
