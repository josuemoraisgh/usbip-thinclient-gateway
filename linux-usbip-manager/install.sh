#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/usbip-manager"
CONFIG_DIR="/etc/usbip-manager"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SYSTEMD_DIR="/etc/systemd/system"
UDEV_RULE="/etc/udev/rules.d/90-usbip-manager.rules"
MODULES_FILE="/etc/modules-load.d/usbip-manager.conf"

BIND_POLICY="allow_all"
SERVER_IP=""
NOTIFY_HOST=""
NOTIFY_PORT="12000"
ENABLE_NOTIFY="0"
DISABLE_CONFLICTING_SERVICES="0"
UNINSTALL="0"

usage() {
  cat <<'EOF'
USB/IP Manager installer for Debian/Armbian thin clients.

Usage:
  sudo bash ./install.sh [options]

Options:
  --server-ip IP                  Limit firewall rule to the Windows Server IP.
  --notify-host IP_OR_HOST        Send JSON TCP events to a Windows broker.
  --notify-port PORT              Notification port. Default: 12000.
  --allow-all                     Export every USB device except hubs/root hubs. Default.
  --allowlist-only                Export only VID/PID entries in config.json.
  --disable-conflicting-services  Stop/disable ModemManager and brltty if installed.
  --uninstall                     Stop services and remove installed files.
  -h, --help                      Show this help.

Examples:
  sudo bash ./install.sh --server-ip 192.168.100.26
  sudo bash ./install.sh --server-ip 192.168.100.26 --notify-host 192.168.100.26
  sudo bash ./install.sh --allowlist-only --disable-conflicting-services
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This installer must run as root. Use sudo." >&2
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server-ip)
        SERVER_IP="${2:-}"
        shift 2
        ;;
      --notify-host)
        NOTIFY_HOST="${2:-}"
        ENABLE_NOTIFY="1"
        shift 2
        ;;
      --notify-port)
        NOTIFY_PORT="${2:-12000}"
        shift 2
        ;;
      --allow-all)
        BIND_POLICY="allow_all"
        shift
        ;;
      --allowlist-only)
        BIND_POLICY="allowlist"
        shift
        ;;
      --disable-conflicting-services)
        DISABLE_CONFLICTING_SERVICES="1"
        shift
        ;;
      --uninstall)
        UNINSTALL="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 2
        ;;
    esac
  done
}

find_tool() {
  local name="$1"
  if command -v "${name}" >/dev/null 2>&1; then
    command -v "${name}"
    return 0
  fi
  for path in "/usr/sbin/${name}" "/usr/bin/${name}" "/sbin/${name}" "/bin/${name}"; do
    if [[ -x "${path}" ]]; then
      echo "${path}"
      return 0
    fi
  done
  local candidate
  candidate="$(find /usr/lib/linux-tools -type f -name "${name}" 2>/dev/null | sort | tail -n 1 || true)"
  if [[ -n "${candidate}" ]]; then
    echo "${candidate}"
    return 0
  fi
  echo "${name}"
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y python3 usbutils hwdata
    if ! command -v usbip >/dev/null 2>&1; then
      apt-get install -y usbip || true
    fi
    if ! command -v usbip >/dev/null 2>&1; then
      apt-get install -y linux-tools-generic linux-cloud-tools-generic || true
    fi
  else
    echo "apt-get not found. Install python3, usbip, usbutils and hwdata manually." >&2
  fi
}

require_tool() {
  local name="$1"
  local found
  found="$(find_tool "${name}")"
  case "${found}" in
    /*)
      return 0
      ;;
    *)
      echo "Required tool not found: ${name}. Install it and run this installer again." >&2
      exit 1
      ;;
  esac
}

validate_tools() {
  require_tool python3
  require_tool usbip
  require_tool usbipd
  require_tool modprobe
  require_tool udevadm
  require_tool systemctl
}

write_config() {
  mkdir -p "${CONFIG_DIR}"
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    install -m 0644 "${SCRIPT_DIR}/config.example.json" "${CONFIG_FILE}"
  fi

  python3 - "$CONFIG_FILE" "$BIND_POLICY" "$ENABLE_NOTIFY" "$NOTIFY_HOST" "$NOTIFY_PORT" <<'PY'
import json
import sys

path, bind_policy, enable_notify, notify_host, notify_port = sys.argv[1:6]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

default_allowed = [
    {"vid": "303a", "pid": "1001", "name": "Espressif ESP32-S3 USB Serial/JTAG"},
    {"vid": "303a", "pid": "*", "name": "Espressif devices"},
    {"vid": "10c4", "pid": "ea60", "name": "Silicon Labs CP210x"},
    {"vid": "1a86", "pid": "7523", "name": "WCH CH340/CH341"},
    {"vid": "0403", "pid": "6010", "name": "ESP-PROG / FTDI FT2232H"},
    {"vid": "0403", "pid": "6001", "name": "FTDI FT232"},
]
allowed = data.setdefault("allowed_devices", [])
for candidate in default_allowed:
    if not any(
        str(item.get("vid", "")).lower() == candidate["vid"]
        and str(item.get("pid", "")).lower() == candidate["pid"]
        for item in allowed
        if isinstance(item, dict)
    ):
        allowed.append(candidate)

data["bind_policy"] = bind_policy
data.setdefault("notify", {})
data["notify"]["enabled"] = enable_notify == "1"
if notify_host:
    data["notify"]["host"] = notify_host
data["notify"]["port"] = int(notify_port)

with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

write_services() {
  local usbipd_bin modprobe_bin python_bin
  usbipd_bin="$(find_tool usbipd)"
  modprobe_bin="$(find_tool modprobe)"
  python_bin="$(find_tool python3)"

  cat > "${SYSTEMD_DIR}/usbipd.service" <<EOF
[Unit]
Description=USB/IP export daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStartPre=${modprobe_bin} -a usbip-core usbip-host
ExecStart=${usbipd_bin} -D -4
PIDFile=/run/usbipd.pid
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

  cat > "${SYSTEMD_DIR}/usbip-manager.service" <<EOF
[Unit]
Description=USB/IP thin client manager
After=network-online.target usbipd.service
Wants=network-online.target
Requires=usbipd.service

[Service]
Type=simple
ExecStart=${python_bin} ${INSTALL_DIR}/usbip_manager.py --config ${CONFIG_FILE} monitor
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

  cat > "${SYSTEMD_DIR}/usbip-manager-udev@.service" <<EOF
[Unit]
Description=USB/IP udev event for %I
After=usbipd.service
Requires=usbipd.service

[Service]
Type=oneshot
ExecStart=${python_bin} ${INSTALL_DIR}/usbip_manager.py --config ${CONFIG_FILE} event --busid %I
EOF
}

write_udev_rules() {
  cat > "${UDEV_RULE}" <<'EOF'
# Keep common serial/JTAG devices away from local probing while usbip-manager exports them.
ACTION=="add|change", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTR{idVendor}=="303a", ATTR{idProduct}=="1001", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{BRLTTY_BRAILLE_DRIVER}="ignore"
ACTION=="add|change", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTR{idVendor}=="303a", ATTR{idProduct}=="*", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{BRLTTY_BRAILLE_DRIVER}="ignore"
ACTION=="add|change", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTR{idVendor}=="10c4", ATTR{idProduct}=="ea60", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{BRLTTY_BRAILLE_DRIVER}="ignore"
ACTION=="add|change", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTR{idVendor}=="1a86", ATTR{idProduct}=="7523", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{BRLTTY_BRAILLE_DRIVER}="ignore"
ACTION=="add|change", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTR{idVendor}=="0403", ATTR{idProduct}=="6010", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{BRLTTY_BRAILLE_DRIVER}="ignore"
ACTION=="add|change", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTR{idVendor}=="0403", ATTR{idProduct}=="6001", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{BRLTTY_BRAILLE_DRIVER}="ignore"

# Every add/remove event schedules a short oneshot. The daemon also polls as a fallback.
ACTION=="add|remove", SUBSYSTEM=="usb", DEVTYPE=="usb_device", TAG+="systemd", ENV{SYSTEMD_WANTS}+="usbip-manager-udev@$kernel.service"
EOF
}

write_modules_file() {
  cat > "${MODULES_FILE}" <<'EOF'
usbip-core
usbip-host
EOF
}

configure_firewall() {
  if [[ -z "${SERVER_IP}" ]]; then
    echo "No --server-ip provided; skipping firewall automation for TCP 3240."
    return 0
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi "Status: active"; then
    ufw allow from "${SERVER_IP}" to any port 3240 proto tcp
    return 0
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${SERVER_IP} port port=3240 protocol=tcp accept"
    firewall-cmd --reload
    return 0
  fi

  echo "No active ufw/firewalld detected. Ensure TCP 3240 is reachable only from ${SERVER_IP}."
}

disable_conflicting_services() {
  if [[ "${DISABLE_CONFLICTING_SERVICES}" != "1" ]]; then
    return 0
  fi

  for service in ModemManager.service brltty.service; do
    if systemctl list-unit-files "${service}" >/dev/null 2>&1; then
      systemctl disable --now "${service}" || true
    fi
  done
}

install_files() {
  mkdir -p "${INSTALL_DIR}"
  install -m 0755 "${SCRIPT_DIR}/usbip_manager.py" "${INSTALL_DIR}/usbip_manager.py"
}

reload_and_start() {
  systemctl daemon-reload
  systemctl enable --now usbipd.service
  systemctl enable --now usbip-manager.service
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=usb --action=add || true
}

uninstall_files() {
  systemctl disable --now usbip-manager.service usbipd.service 2>/dev/null || true
  rm -f "${SYSTEMD_DIR}/usbip-manager.service"
  rm -f "${SYSTEMD_DIR}/usbip-manager-udev@.service"
  rm -f "${SYSTEMD_DIR}/usbipd.service"
  rm -f "${UDEV_RULE}"
  rm -f "${MODULES_FILE}"
  rm -rf "${INSTALL_DIR}"
  systemctl daemon-reload
  udevadm control --reload-rules 2>/dev/null || true
  echo "Removed USB/IP Manager. Config kept at ${CONFIG_DIR}."
}

parse_args "$@"
require_root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${UNINSTALL}" == "1" ]]; then
  uninstall_files
  exit 0
fi

install_packages
validate_tools
install_files
write_config
write_modules_file
write_services
write_udev_rules
configure_firewall
disable_conflicting_services
reload_and_start

echo
echo "USB/IP Manager installed."
echo "Config: ${CONFIG_FILE}"
echo "Status: systemctl status usbip-manager.service usbipd.service"
echo "Logs:   journalctl -u usbip-manager.service -f"
echo "Scan:   python3 ${INSTALL_DIR}/usbip_manager.py --config ${CONFIG_FILE} scan"
