#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/usbip-manager"
CONFIG_DIR="/etc/usbip-manager"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SYSTEMD_DIR="/etc/systemd/system"
UDEV_RULE="/etc/udev/rules.d/90-usbip-manager.rules"
MODULES_FILE="/etc/modules-load.d/usbip-manager.conf"

DEFAULT_WINDOWS_SERVER_IP="10.0.64.28"
MIN_APT_FREE_KB="51200"
BIND_POLICY="allow_all"
SERVER_IP="${DEFAULT_WINDOWS_SERVER_IP}"
NOTIFY_HOST="${DEFAULT_WINDOWS_SERVER_IP}"
NOTIFY_PORT="12000"
ENABLE_NOTIFY="1"
NOTIFY_HOST_EXPLICIT="0"
DISABLE_CONFLICTING_SERVICES="0"
UNINSTALL="0"
SKIP_PACKAGES="0"
CLEAN_SYSTEM="0"
PURGE_OPTIONAL="0"
PURGE_PYTHON="0"

usage() {
  cat <<'EOF'
USB/IP Manager installer for Debian/Armbian thin clients.

Usage:
  sudo bash ./install.sh [options]

Options:
  --server-ip IP                  Limit firewall rule to the Windows Server IP. Default: 10.0.64.28.
  --notify-host IP_OR_HOST        Send JSON TCP events to a Windows broker. Default: 10.0.64.28.
  --notify-port PORT              Notification port. Default: 12000.
  --no-notify                     Do not send JSON TCP events to the Windows broker.
  --allow-all                     Export every USB device except hubs/root hubs. Default.
  --allowlist-only                Export only VID/PID entries in config.json.
  --disable-conflicting-services  Stop/disable ModemManager and brltty if installed.
  --skip-packages                 Do not run apt-get; use tools already installed.
  --uninstall                     Stop services and remove installed files.
  --clean-system                  With --uninstall, clean apt/dpkg cache and logs.
  --purge-optional                With --uninstall, purge hwdata and usbutils.
  --purge-python                  With --uninstall, purge python packages.
  -h, --help                      Show this help.

Examples:
  sudo bash ./install.sh
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
        if [[ "${NOTIFY_HOST_EXPLICIT}" != "1" ]]; then
          NOTIFY_HOST="${SERVER_IP}"
        fi
        shift 2
        ;;
      --notify-host)
        NOTIFY_HOST="${2:-}"
        ENABLE_NOTIFY="1"
        NOTIFY_HOST_EXPLICIT="1"
        shift 2
        ;;
      --notify-port)
        NOTIFY_PORT="${2:-12000}"
        shift 2
        ;;
      --no-notify)
        ENABLE_NOTIFY="0"
        NOTIFY_HOST=""
        shift
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
      --skip-packages)
        SKIP_PACKAGES="1"
        shift
        ;;
      --uninstall)
        UNINSTALL="1"
        shift
        ;;
      --clean-system)
        CLEAN_SYSTEM="1"
        shift
        ;;
      --purge-optional)
        PURGE_OPTIONAL="1"
        CLEAN_SYSTEM="1"
        shift
        ;;
      --purge-python)
        PURGE_PYTHON="1"
        CLEAN_SYSTEM="1"
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

have_tool() {
  local found
  found="$(find_tool "$1")"
  [[ "${found}" == /* ]]
}

required_runtime_tools_present() {
  have_tool usbip &&
  have_tool usbipd &&
  have_tool modprobe &&
  have_tool udevadm &&
  have_tool systemctl
}

native_manager_source() {
  local arch target
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "${arch}" in
    aarch64|arm64)
      target="arm64"
      ;;
    armv7l|armv6l|armhf)
      target="armhf"
      ;;
    x86_64|amd64)
      target="x64"
      ;;
    *)
      target="${arch}"
      ;;
  esac

  if [[ -x "${SCRIPT_DIR}/usbip_manager" ]]; then
    echo "${SCRIPT_DIR}/usbip_manager"
    return 0
  fi
  if [[ -x "${SCRIPT_DIR}/bin/usbip-manager-linux-${target}" ]]; then
    echo "${SCRIPT_DIR}/bin/usbip-manager-linux-${target}"
    return 0
  fi
  if [[ -f "${SCRIPT_DIR}/bin/usbip-manager-linux-${target}" ]]; then
    chmod +x "${SCRIPT_DIR}/bin/usbip-manager-linux-${target}" 2>/dev/null || true
    echo "${SCRIPT_DIR}/bin/usbip-manager-linux-${target}"
    return 0
  fi
  return 1
}

disable_stale_bullseye_backports() {
  local changed=0
  local files=()

  if [[ -f /etc/apt/sources.list ]]; then
    files+=("/etc/apt/sources.list")
  fi

  local source_file
  for source_file in /etc/apt/sources.list.d/*.list; do
    [[ -f "${source_file}" ]] || continue
    files+=("${source_file}")
  done

  for source_file in "${files[@]}"; do
    if grep -Eq '^[[:space:]]*deb(-src)?[[:space:]].*[[:space:]]bullseye-backports([[:space:]]|$)' "${source_file}"; then
      local backup="${source_file}.usbip-manager.$(date +%Y%m%d%H%M%S).bak"
      cp -p "${source_file}" "${backup}"
      sed -i -E '/^[[:space:]]*deb(-src)?[[:space:]].*[[:space:]]bullseye-backports([[:space:]]|$)/ s/^/# disabled by usbip-manager installer: /' "${source_file}"
      echo "Disabled stale bullseye-backports entry in ${source_file}."
      echo "Backup saved as ${backup}."
      changed=1
    fi
  done

  [[ "${changed}" -eq 1 ]]
}

apt_update_with_repair() {
  if apt-get update --allow-releaseinfo-change; then
    return 0
  fi

  echo "apt-get update failed. Checking for obsolete bullseye-backports entries..." >&2
  if disable_stale_bullseye_backports; then
    echo "Retrying apt-get update after disabling bullseye-backports..." >&2
    apt-get update --allow-releaseinfo-change
    return $?
  fi

  return 1
}

print_dns_help() {
  cat >&2 <<'EOF'
WARNING: APT could not resolve Debian/Armbian hosts.
This usually means DNS or internet routing is not working on this thin client.

Quick checks:
  ip route
  ping -c 3 8.8.8.8
  getent hosts deb.debian.org
  cat /etc/resolv.conf

Temporary DNS fix:
  printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" | sudo tee /etc/resolv.conf
  sudo apt-get update --allow-releaseinfo-change
EOF
}

has_enough_apt_space() {
  local path="$1"
  local available
  available="$(df -Pk "${path}" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ -n "${available}" && "${available}" -ge "${MIN_APT_FREE_KB}" ]]
}

print_space_help() {
  cat >&2 <<'EOF'
WARNING: There is not enough free space for apt/dpkg on this thin client.
The installer will skip package installation and continue with installed tools.

Quick cleanup:
  df -h / /var /tmp
  sudo apt-get clean
  sudo rm -rf /var/cache/apt/archives/*.deb /var/lib/apt/lists/*
  sudo journalctl --vacuum-size=20M 2>/dev/null || true
  sudo find /var/log -type f -name "*.gz" -delete
  sudo find /var/log -type f -name "*.1" -delete
  sudo dpkg --configure -a

If USB/IP tools already exist, run:
  sudo bash ./install.sh --skip-packages
EOF
}

try_apt_install() {
  local package="$1"
  local marker="${2:-}"
  local label="${3:-${package}}"

  if [[ -n "${marker}" ]]; then
    case "${marker}" in
      /*)
        if [[ -e "${marker}" ]]; then
          return 0
        fi
        ;;
      *)
        if command -v "${marker}" >/dev/null 2>&1; then
          return 0
        fi
        ;;
    esac
  elif dpkg -s "${package}" >/dev/null 2>&1; then
    return 0
  fi

  if ! apt-get install -y "${package}"; then
    echo "WARNING: Could not install ${label} (${package}). Continuing; validation will stop if it is required." >&2
  fi
}

install_usbip_runtime() {
  if required_runtime_tools_present; then
    return 0
  fi

  echo "USB/IP runtime tools are missing; trying to install them automatically."

  local kernel
  kernel="$(uname -r 2>/dev/null || true)"

  local candidates=(
    "usbip"
  )

  if [[ -n "${kernel}" ]]; then
    candidates+=("linux-tools-${kernel}")
  fi

  candidates+=(
    "linux-tools-generic"
    "linux-cloud-tools-generic"
  )

  local package
  for package in "${candidates[@]}"; do
    if required_runtime_tools_present; then
      return 0
    fi
    try_apt_install "${package}" "" "${package}"
  done

  if ! required_runtime_tools_present && command -v apt-cache >/dev/null 2>&1; then
    local armbian_package
    armbian_package="$(
      apt-cache search --names-only '^linux-tools-(current|edge|legacy)-' 2>/dev/null \
        | awk '{print $1}' \
        | head -n 1
    )"
    if [[ -n "${armbian_package}" ]]; then
      try_apt_install "${armbian_package}" "" "${armbian_package}"
    fi
  fi

  if ! required_runtime_tools_present; then
    echo "WARNING: Could not install complete USB/IP runtime automatically." >&2
    echo "Missing tools after install attempt:" >&2
    for tool in usbip usbipd modprobe udevadm systemctl; do
      if ! have_tool "${tool}"; then
        echo "  - ${tool}" >&2
      fi
    done
  fi
}

install_packages() {
  if [[ "${SKIP_PACKAGES}" == "1" ]]; then
    echo "Skipping package installation (--skip-packages)."
    return 0
  fi

  if required_runtime_tools_present; then
    echo "Required USB/IP runtime tools already present; skipping apt-get."
    return 0
  fi

  if ! has_enough_apt_space /var || ! has_enough_apt_space /tmp; then
    print_space_help
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    if ! apt_update_with_repair; then
      echo "WARNING: apt-get update still failed after repair attempt." >&2
      echo "Continuing with already installed tools; validation will stop if something is missing." >&2
      print_dns_help
    fi

    install_usbip_runtime
  else
    echo "apt-get not found. Install usbip and usbipd manually, or use --skip-packages if they already exist." >&2
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
  [[ -x "${INSTALL_DIR}/usbip_manager" ]] || {
    echo "Native manager not installed. Copy bin/usbip-manager-linux-$(uname -m) or bin/usbip-manager-linux-arm64 to this folder." >&2
    exit 1
  }
  require_tool usbip
  require_tool usbipd
  require_tool modprobe
  require_tool udevadm
  require_tool systemctl
}

write_config() {
  mkdir -p "${CONFIG_DIR}"
  if [[ -f "${CONFIG_FILE}" ]]; then
    cp -p "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat > "${CONFIG_FILE}" <<EOF
{
  "bind_policy": "${BIND_POLICY}",
  "allowed_devices": [
    {"vid": "303a", "pid": "1001", "name": "Espressif ESP32-S3 USB Serial/JTAG"},
    {"vid": "303a", "pid": "*", "name": "Espressif devices"},
    {"vid": "10c4", "pid": "ea60", "name": "Silicon Labs CP210x"},
    {"vid": "1a86", "pid": "7523", "name": "WCH CH340/CH341"},
    {"vid": "0403", "pid": "6010", "name": "ESP-PROG / FTDI FT2232H"},
    {"vid": "0403", "pid": "6001", "name": "FTDI FT232"}
  ],
  "blocked_devices": [
    {"vid": "1d6b", "pid": "*", "name": "Linux USB root hubs"}
  ],
  "block_usb_hubs": true,
  "settle_seconds": 2.0,
  "retry_count": 6,
  "retry_delay_seconds": 1.5,
  "reconcile_interval_seconds": 5.0,
  "command_timeout_seconds": 15.0,
  "state_path": "/run/usbip-manager/state.json",
  "usbip_tcp_port": 3240,
  "notify": {
    "enabled": $([[ "${ENABLE_NOTIFY}" == "1" ]] && echo true || echo false),
    "mode": "json_tcp",
    "host": "${NOTIFY_HOST}",
    "port": ${NOTIFY_PORT},
    "timeout_seconds": 2.0,
    "tls": false,
    "shared_secret": ""
  },
  "commands": {
    "usbip": "",
    "usbipd": "",
    "modprobe": "",
    "udevadm": ""
  }
}
EOF
}

write_services() {
  local usbipd_bin modprobe_bin manager_monitor manager_event
  usbipd_bin="$(find_tool usbipd)"
  modprobe_bin="$(find_tool modprobe)"
  manager_monitor="${INSTALL_DIR}/usbip_manager --config ${CONFIG_FILE} monitor"
  manager_event="${INSTALL_DIR}/usbip_manager --config ${CONFIG_FILE} event --busid %I"

  rm -f "${SYSTEMD_DIR}/usbip-manager.service"
  rm -f "${SYSTEMD_DIR}/usbip-manager-udev@.service"
  rm -f "${SYSTEMD_DIR}/usbipd.service"

  # Force Type=simple (no -D). Even when usbipd --help lists -D, the fork
  # implementation in newer builds is broken (does not write a usable PID file
  # and hangs systemd until TimeoutStartSec). Type=simple works on all known
  # versions and is supervised correctly.
  local usbipd_type="simple"
  local usbipd_args="-4"

  {
    cat <<EOF
[Unit]
Description=USB/IP export daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=${usbipd_type}
ExecStartPre=${modprobe_bin} -a usbip-core usbip-host
ExecStart=${usbipd_bin} ${usbipd_args}
EOF
    cat <<'EOF'
Restart=on-failure
RestartSec=2s
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF
  } > "${SYSTEMD_DIR}/usbipd.service"

  cat > "${SYSTEMD_DIR}/usbip-manager.service" <<EOF
[Unit]
Description=USB/IP thin client manager
After=network-online.target usbipd.service
Wants=network-online.target
Requires=usbipd.service

[Service]
Type=simple
ExecStart=${manager_monitor}
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
ExecStart=${manager_event}
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

# Every add/remove event schedules a short oneshot. The daemon also polls as a safety net.
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

stop_existing_runtime() {
  systemctl disable --now usbip-manager.service usbipd.service 2>/dev/null || true
  systemctl stop 'usbip-manager-udev@*.service' 2>/dev/null || true

  local pid
  for pid in $(pidof usbipd 2>/dev/null || true); do
    kill "${pid}" 2>/dev/null || true
  done
  sleep 1
  for pid in $(pidof usbipd 2>/dev/null || true); do
    kill -9 "${pid}" 2>/dev/null || true
  done

  systemctl reset-failed usbip-manager.service usbipd.service 2>/dev/null || true
}

install_files() {
  mkdir -p "${INSTALL_DIR}"
  local native_source
  if ! native_source="$(native_manager_source)"; then
    echo "Native C++ manager was not found." >&2
    echo "Expected one of:" >&2
    echo "  ${SCRIPT_DIR}/usbip_manager" >&2
    echo "  ${SCRIPT_DIR}/bin/usbip-manager-linux-arm64" >&2
    echo "  ${SCRIPT_DIR}/bin/usbip-manager-linux-armhf" >&2
    echo "  ${SCRIPT_DIR}/bin/usbip-manager-linux-x64" >&2
    exit 1
  fi
  install -m 0755 "${native_source}" "${INSTALL_DIR}/usbip_manager"
  echo "Installed native C++ manager: ${native_source}"
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
  if [[ -f "${SCRIPT_DIR}/uninstall.sh" ]]; then
    args=("--force")
    [[ "${CLEAN_SYSTEM}" == "1" ]] && args+=("--clean-system")
    [[ "${PURGE_OPTIONAL}" == "1" ]] && args+=("--purge-optional")
    [[ "${PURGE_PYTHON}" == "1" ]] && args+=("--purge-python")
    bash "${SCRIPT_DIR}/uninstall.sh" "${args[@]}"
  else
    uninstall_files
  fi
  exit 0
fi

install_files
install_packages
validate_tools
stop_existing_runtime
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
echo "Server IP: ${SERVER_IP}"
if [[ "${ENABLE_NOTIFY}" == "1" ]]; then
  echo "Notify: ${NOTIFY_HOST}:${NOTIFY_PORT}"
else
  echo "Notify: disabled"
fi
echo "Status: systemctl status usbip-manager.service usbipd.service"
echo "Logs:   journalctl -u usbip-manager.service -f"
if [[ -x "${INSTALL_DIR}/usbip_manager" ]]; then
  echo "Scan:   ${INSTALL_DIR}/usbip_manager --config ${CONFIG_FILE} scan"
fi
