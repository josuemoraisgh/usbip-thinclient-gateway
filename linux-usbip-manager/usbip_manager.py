#!/usr/bin/env python3
"""
USB/IP device manager for Linux thin clients.

This daemon keeps locally inserted USB devices exported through Linux USB/IP.
It is intentionally dependency-free so it can run on Armbian/Debian images with
only Python 3 and usbip tools installed.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import fnmatch
import glob
import json
import logging
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional, Set


DEFAULT_CONFIG: Dict[str, Any] = {
    "bind_policy": "allow_all",
    "allowed_devices": [
        {"vid": "303a", "pid": "1001", "name": "Espressif ESP32-S3 USB Serial/JTAG"},
        {"vid": "303a", "pid": "*", "name": "Espressif devices"},
        {"vid": "10c4", "pid": "ea60", "name": "Silicon Labs CP210x"},
        {"vid": "1a86", "pid": "7523", "name": "WCH CH340/CH341"},
        {"vid": "0403", "pid": "6010", "name": "ESP-PROG / FTDI FT2232H"},
        {"vid": "0403", "pid": "6001", "name": "FTDI FT232"},
    ],
    "blocked_devices": [
        {"vid": "1d6b", "pid": "*", "name": "Linux USB root hubs"}
    ],
    "block_usb_hubs": True,
    "settle_seconds": 2.0,
    "retry_count": 6,
    "retry_delay_seconds": 1.5,
    "reconcile_interval_seconds": 5.0,
    "command_timeout_seconds": 15.0,
    "state_path": "/run/usbip-manager/state.json",
    "usbip_tcp_port": 3240,
    "notify": {
        "enabled": False,
        "mode": "json_tcp",
        "host": "",
        "port": 12000,
        "timeout_seconds": 2.0,
        "tls": False,
        "shared_secret": "",
    },
    "commands": {
        "usbip": "",
        "usbipd": "",
        "modprobe": "",
        "udevadm": "",
    },
}


@dataclasses.dataclass
class UsbDevice:
    busid: str
    vid: str
    pid: str
    manufacturer: str = ""
    product: str = ""
    serial: str = ""
    device_class: str = ""
    speed: str = ""
    driver: str = ""
    interface_drivers: List[str] = dataclasses.field(default_factory=list)

    @property
    def name(self) -> str:
        parts = [self.manufacturer.strip(), self.product.strip()]
        return " ".join(part for part in parts if part) or f"{self.vid}:{self.pid}"

    @property
    def is_exported(self) -> bool:
        drivers = [self.driver] + self.interface_drivers
        return any(driver == "usbip-host" for driver in drivers)

    def to_dict(self) -> Dict[str, Any]:
        data = dataclasses.asdict(self)
        data.update({
            "name": self.name,
            "is_exported": self.is_exported,
        })
        return data


def deep_merge(base: Dict[str, Any], override: Dict[str, Any]) -> Dict[str, Any]:
    result = json.loads(json.dumps(base))
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def normalize_hex(value: str) -> str:
    value = str(value).lower().strip()
    if not value:
        return ""
    if value.startswith("0x"):
        value = value[2:]
    return value.zfill(4) if value != "*" else value


def command_path(configured: str, name: str) -> str:
    if configured and Path(configured).exists():
        return configured
    found = shutil.which(name)
    if found:
        return found
    for directory in ("/usr/sbin", "/usr/bin", "/sbin", "/bin"):
        candidate = Path(directory) / name
        if candidate.exists():
            return str(candidate)
    candidates = sorted(glob.glob(f"/usr/lib/linux-tools/*/{name}"))
    if candidates:
        return candidates[-1]
    return name


def setup_logging(verbose: bool = False) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )


@contextlib.contextmanager
def process_lock(state_path: Path, timeout: float = 30.0):
    lock_dir = state_path.with_suffix(state_path.suffix + ".lock")
    deadline = time.monotonic() + timeout
    lock_dir.parent.mkdir(parents=True, exist_ok=True)
    while True:
        try:
            os.mkdir(lock_dir)
            break
        except FileExistsError:
            try:
                if time.time() - lock_dir.stat().st_mtime > 120:
                    os.rmdir(lock_dir)
                    continue
            except OSError:
                pass
            if time.monotonic() >= deadline:
                raise TimeoutError(f"Timed out waiting for lock {lock_dir}")
            time.sleep(0.2)
    try:
        yield
    finally:
        with contextlib.suppress(OSError):
            os.rmdir(lock_dir)


class UsbipManager:
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        commands = config.get("commands", {})
        self.usbip = command_path(commands.get("usbip", ""), "usbip")
        self.modprobe = command_path(commands.get("modprobe", ""), "modprobe")
        self.udevadm = command_path(commands.get("udevadm", ""), "udevadm")
        self.state_path = Path(config.get("state_path", "/run/usbip-manager/state.json"))

    def run(self, args: List[str], check: bool = False):
        logging.debug("Running command: %s", " ".join(args))
        completed = subprocess.run(
            args,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=float(self.config.get("command_timeout_seconds", 15.0)),
            check=False,
        )
        if check and completed.returncode != 0:
            raise RuntimeError(completed.stdout.strip())
        return completed

    def load_modules(self) -> None:
        result = self.run([self.modprobe, "-a", "usbip-core", "usbip-host"])
        if result.returncode != 0:
            logging.warning("Could not load USB/IP kernel modules: %s", result.stdout.strip())

    def settle_udev(self) -> None:
        if shutil.which(self.udevadm) or Path(self.udevadm).exists():
            result = self.run([self.udevadm, "settle"], check=False)
            if result.returncode != 0:
                logging.debug("udevadm settle returned: %s", result.stdout.strip())

    def load_state(self) -> Dict[str, Any]:
        try:
            return json.loads(self.state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {"devices": {}}

    def save_state(self, state: Dict[str, Any]) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(prefix=".state.", dir=str(self.state_path.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(state, handle, indent=2, sort_keys=True)
                handle.write("\n")
            os.replace(tmp_name, self.state_path)
        finally:
            with contextlib.suppress(OSError):
                os.unlink(tmp_name)

    def list_devices(self) -> List[UsbDevice]:
        base = Path("/sys/bus/usb/devices")
        devices: List[UsbDevice] = []
        if not base.exists():
            logging.warning("%s does not exist; this must run on Linux", base)
            return devices

        for devdir in sorted(base.iterdir(), key=lambda path: path.name):
            busid = devdir.name
            if ":" in busid or busid.startswith("usb"):
                continue
            vid = normalize_hex(read_text(devdir / "idVendor"))
            pid = normalize_hex(read_text(devdir / "idProduct"))
            if not vid or not pid:
                continue
            driver = ""
            driver_link = devdir / "driver"
            if driver_link.is_symlink():
                driver = driver_link.resolve().name
            interface_drivers: List[str] = []
            for interface in sorted(base.glob(f"{busid}:*")):
                link = interface / "driver"
                if link.is_symlink():
                    interface_drivers.append(link.resolve().name)
            devices.append(
                UsbDevice(
                    busid=busid,
                    vid=vid,
                    pid=pid,
                    manufacturer=read_text(devdir / "manufacturer"),
                    product=read_text(devdir / "product"),
                    serial=read_text(devdir / "serial"),
                    device_class=normalize_hex(read_text(devdir / "bDeviceClass"))[-2:],
                    speed=read_text(devdir / "speed"),
                    driver=driver,
                    interface_drivers=interface_drivers,
                )
            )
        self.merge_usbip_export_status(devices)
        return devices

    def merge_usbip_export_status(self, devices: List[UsbDevice]) -> None:
        result = self.run([self.usbip, "list", "-l"], check=False)
        if result.returncode != 0:
            logging.debug("usbip list -l failed: %s", result.stdout.strip())
            return
        current_busid = ""
        exported: Set[str] = set()
        for raw_line in result.stdout.splitlines():
            line = raw_line.strip()
            if line.startswith("- busid "):
                current_busid = line.split()[2]
            elif current_busid and "usbip-host" in line:
                exported.add(current_busid)
        for device in devices:
            if device.busid in exported and "usbip-host" not in device.interface_drivers:
                device.interface_drivers.append("usbip-host")

    def matches_rule(self, device: UsbDevice, rule: Dict[str, Any]) -> bool:
        vid = normalize_hex(rule.get("vid", "*"))
        pid = normalize_hex(rule.get("pid", "*"))
        busid = str(rule.get("busid", "*"))
        if not fnmatch.fnmatch(device.vid, vid):
            return False
        if not fnmatch.fnmatch(device.pid, pid):
            return False
        if busid != "*" and not fnmatch.fnmatch(device.busid, busid):
            return False
        return True

    def is_allowed(self, device: UsbDevice) -> bool:
        if self.config.get("block_usb_hubs", True) and device.device_class == "09":
            return False
        if any(self.matches_rule(device, rule) for rule in self.config.get("blocked_devices", [])):
            return False
        policy = self.config.get("bind_policy", "allow_all")
        if policy == "disabled":
            return False
        if policy == "allow_all":
            return True
        if policy == "allowlist":
            return any(self.matches_rule(device, rule) for rule in self.config.get("allowed_devices", []))
        logging.warning("Unknown bind_policy %r; refusing device %s", policy, device.busid)
        return False

    def bind_device(self, device: UsbDevice) -> bool:
        if not self.is_allowed(device):
            logging.debug("Skipping USB %s %s:%s (%s)", device.busid, device.vid, device.pid, device.name)
            return False
        if device.is_exported:
            self.record_device("already_exported", device)
            return True

        retries = int(self.config.get("retry_count", 6))
        delay = float(self.config.get("retry_delay_seconds", 1.5))
        for attempt in range(1, retries + 1):
            logging.info("Exporting USB %s %s:%s %s (attempt %s/%s)", device.busid, device.vid, device.pid, device.name, attempt, retries)
            result = self.run([self.usbip, "bind", "-b", device.busid], check=False)
            output = result.stdout.strip()
            if result.returncode == 0 or "already" in output.lower():
                self.record_device("exported", device)
                self.notify("exported", device)
                return True
            logging.warning("usbip bind failed for %s: %s", device.busid, output)
            time.sleep(delay)
            refreshed = self.device_by_busid(device.busid)
            if refreshed:
                device = refreshed
                if device.is_exported:
                    self.record_device("exported", device)
                    self.notify("exported", device)
                    return True
        self.record_device("failed", device, {"last_error": output if "output" in locals() else ""})
        self.notify("failed", device, {"error": output if "output" in locals() else ""})
        return False

    def unbind_device(self, busid: str) -> bool:
        result = self.run([self.usbip, "unbind", "-b", busid], check=False)
        if result.returncode == 0 or "not bound" in result.stdout.lower():
            logging.info("Unexported USB %s", busid)
            return True
        logging.warning("usbip unbind failed for %s: %s", busid, result.stdout.strip())
        return False

    def device_by_busid(self, busid: str) -> Optional[UsbDevice]:
        for device in self.list_devices():
            if device.busid == busid:
                return device
        return None

    def record_device(self, status: str, device: UsbDevice, extra: Optional[Dict[str, Any]] = None) -> None:
        with process_lock(self.state_path):
            state = self.load_state()
            entry = {
                "status": status,
                "last_seen": time.time(),
                "device": device.to_dict(),
            }
            entry.update(extra or {})
            state.setdefault("devices", {})[device.busid] = entry
            self.save_state(state)

    def record_removed(self, busid: str) -> None:
        with process_lock(self.state_path):
            state = self.load_state()
            previous = state.setdefault("devices", {}).get(busid, {})
            if previous.get("status") != "removed":
                previous["status"] = "removed"
                previous["removed_at"] = time.time()
                state["devices"][busid] = previous
                self.save_state(state)
                self.notify("removed", None, {"busid": busid, "previous": previous})

    def prune_removed_devices(self, present_busids: Set[str]) -> None:
        state = self.load_state()
        for busid, entry in list(state.get("devices", {}).items()):
            if entry.get("status") == "removed":
                continue
            if busid not in present_busids:
                self.record_removed(busid)

    def reconcile(self, target_busid: Optional[str] = None) -> int:
        operation_lock = Path(str(self.state_path) + ".operation")
        with process_lock(operation_lock):
            self.load_modules()
            self.settle_udev()
            devices = self.list_devices()
            present_busids = set(device.busid for device in devices)
            count = 0
            for device in devices:
                if target_busid and device.busid != target_busid:
                    continue
                if self.bind_device(device):
                    count += 1
            if not target_busid:
                self.prune_removed_devices(present_busids)
            elif target_busid not in present_busids:
                self.record_removed(target_busid)
            return count

    def handle_event(self, busid: str) -> None:
        settle = float(self.config.get("settle_seconds", 2.0))
        if settle > 0:
            time.sleep(settle)
        self.reconcile(target_busid=busid)

    def monitor(self) -> None:
        interval = float(self.config.get("reconcile_interval_seconds", 5.0))
        logging.info("USB/IP manager started; policy=%s, interval=%ss", self.config.get("bind_policy"), interval)
        while True:
            try:
                exported = self.reconcile()
                logging.debug("Reconcile complete; %s device(s) exported or already exported", exported)
            except Exception:
                logging.exception("Reconcile cycle failed")
            time.sleep(interval)

    def notify(self, event: str, device: Optional[UsbDevice], extra: Optional[Dict[str, Any]] = None) -> None:
        notify_config = self.config.get("notify", {})
        if not notify_config.get("enabled", False):
            return
        host = notify_config.get("host", "")
        port = int(notify_config.get("port", 12000))
        if not host:
            logging.warning("Notification is enabled but notify.host is empty")
            return

        payload: Dict[str, Any] = {
            "event": event,
            "thinclient": socket.gethostname(),
            "usbip_port": int(self.config.get("usbip_tcp_port", 3240)),
            "timestamp": time.time(),
        }
        if device:
            payload["device"] = device.to_dict()
        if extra:
            payload.update(extra)
        secret = str(notify_config.get("shared_secret", ""))
        if secret:
            payload["shared_secret"] = secret

        data = (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        timeout = float(notify_config.get("timeout_seconds", 2.0))
        try:
            raw_socket = socket.create_connection((host, port), timeout=timeout)
            with raw_socket:
                if notify_config.get("tls", False):
                    context = ssl.create_default_context()
                    with context.wrap_socket(raw_socket, server_hostname=host) as tls_socket:
                        tls_socket.sendall(data)
                else:
                    raw_socket.sendall(data)
            logging.debug("Sent %s notification to %s:%s", event, host, port)
        except OSError as exc:
            logging.warning("Could not notify %s:%s about %s: %s", host, port, event, exc)


def load_config(path: Path) -> Dict[str, Any]:
    if not path.exists():
        return DEFAULT_CONFIG
    with path.open("r", encoding="utf-8") as handle:
        loaded = json.load(handle)
    return deep_merge(DEFAULT_CONFIG, loaded)


def print_json(data: Any, pretty: bool = True) -> None:
    if pretty:
        print(json.dumps(data, indent=2, sort_keys=True))
    else:
        print(json.dumps(data, separators=(",", ":"), sort_keys=True))


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Linux USB/IP thin client manager")
    parser.add_argument("--config", default="/etc/usbip-manager/config.json")
    parser.add_argument("--verbose", action="store_true")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("monitor", help="Run continuous reconciliation loop")
    subparsers.add_parser("scan", help="Print detected USB devices as JSON")
    subparsers.add_parser("status", help="Print state and detected devices")

    event_parser = subparsers.add_parser("event", help="Handle one udev event")
    event_parser.add_argument("--busid", required=True)

    bind_parser = subparsers.add_parser("bind", help="Export one device now")
    bind_parser.add_argument("--busid", required=True)

    unbind_parser = subparsers.add_parser("unbind", help="Stop exporting one device")
    unbind_parser.add_argument("--busid", required=True)

    args = parser.parse_args(argv)
    setup_logging(args.verbose)
    manager = UsbipManager(load_config(Path(args.config)))

    if args.command == "monitor":
        manager.monitor()
        return 0
    if args.command == "event":
        manager.handle_event(args.busid)
        return 0
    if args.command == "scan":
        print_json([device.to_dict() for device in manager.list_devices()])
        return 0
    if args.command == "status":
        print_json({"state": manager.load_state(), "devices": [device.to_dict() for device in manager.list_devices()]})
        return 0
    if args.command == "bind":
        device = manager.device_by_busid(args.busid)
        if not device:
            logging.error("USB device %s not found", args.busid)
            return 2
        return 0 if manager.bind_device(device) else 1
    if args.command == "unbind":
        return 0 if manager.unbind_device(args.busid) else 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
