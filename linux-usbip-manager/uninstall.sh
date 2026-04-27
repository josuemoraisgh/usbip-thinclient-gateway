#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/usbip-manager"
CONFIG_DIR="/etc/usbip-manager"
SYSTEMD_DIR="/etc/systemd/system"
UDEV_RULE="/etc/udev/rules.d/90-usbip-manager.rules"
MODULES_FILE="/etc/modules-load.d/usbip-manager.conf"
RUNTIME_DIR="/run/usbip-manager"

KEEP_CONFIG=0
FORCE=0
CLEAN_SYSTEM=0
PURGE_PYTHON=0
PURGE_OPTIONAL=0

usage() {
  cat <<'EOF'
USB/IP Manager uninstall and thin-client cleanup.

Usage:
  sudo bash ./uninstall.sh [options]

Options:
  --keep-config      Keep /etc/usbip-manager.
  --clean-system     Clean apt/dpkg cache, apt lists, old logs and journal.
  --purge-python     Also purge python packages. Use only on dedicated thin clients.
  --purge-optional   Purge optional packages used only for diagnostics: hwdata usbutils.
  --force            Do not ask for confirmation.
  -h, --help         Show this help.

Recommended for a small dedicated thin client:
  sudo bash ./uninstall.sh --clean-system --purge-optional --purge-python --force
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo bash ./uninstall.sh" >&2
    exit 1
  fi
}

confirm() {
  if [[ "${FORCE}" == "1" ]]; then
    return 0
  fi
  local answer
  read -rp "$* [s/N] " answer
  [[ "${answer}" == "s" || "${answer}" == "S" ]]
}

remove_file() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    rm -f "${path}"
    echo "Removed file: ${path}"
  fi
}

remove_dir() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    rm -rf "${path}"
    echo "Removed directory: ${path}"
  fi
}

apt_purge_if_installed() {
  if ! command -v dpkg >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then
    return 0
  fi
  local packages=()
  local package
  for package in "$@"; do
    if dpkg -s "${package}" >/dev/null 2>&1; then
      packages+=("${package}")
    fi
  done
  if [[ "${#packages[@]}" -gt 0 ]]; then
    apt-get purge -y --autoremove "${packages[@]}" || true
  fi
}

clean_system_space() {
  echo "Cleaning apt/dpkg cache and logs..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get clean || true
    apt-get autoclean || true
  fi

  rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
  rm -rf /var/cache/apt/archives/partial/* 2>/dev/null || true
  rm -rf /var/lib/apt/lists/* 2>/dev/null || true
  rm -rf /var/cache/debconf/*-old 2>/dev/null || true

  truncate -s 0 /var/log/dpkg.log 2>/dev/null || true
  truncate -s 0 /var/log/apt/history.log 2>/dev/null || true
  truncate -s 0 /var/log/apt/term.log 2>/dev/null || true
  find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
  find /var/log -type f -name "*.1" -delete 2>/dev/null || true
  find /var/log -type f -name "*.old" -delete 2>/dev/null || true

  if command -v journalctl >/dev/null 2>&1; then
    journalctl --vacuum-size=20M 2>/dev/null || true
  fi

  if command -v dpkg >/dev/null 2>&1; then
    dpkg --configure -a || true
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-config)
      KEEP_CONFIG=1
      shift
      ;;
    --clean-system)
      CLEAN_SYSTEM=1
      shift
      ;;
    --purge-python)
      PURGE_PYTHON=1
      CLEAN_SYSTEM=1
      shift
      ;;
    --purge-optional)
      PURGE_OPTIONAL=1
      CLEAN_SYSTEM=1
      shift
      ;;
    --force)
      FORCE=1
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

require_root

echo "USB/IP Manager uninstall"
echo "  keep config    : ${KEEP_CONFIG}"
echo "  clean system   : ${CLEAN_SYSTEM}"
echo "  purge optional : ${PURGE_OPTIONAL}"
echo "  purge python   : ${PURGE_PYTHON}"

if [[ "${PURGE_PYTHON}" == "1" ]]; then
  echo
  echo "WARNING: --purge-python can remove packages used by other OS tools."
  echo "Use it only on a dedicated thin client image."
fi

confirm "Continue uninstall/cleanup?" || {
  echo "Cancelled."
  exit 0
}

systemctl disable --now usbip-manager.service usbipd.service 2>/dev/null || true
mapfile -t active_udev < <(systemctl list-units --all --no-legend 'usbip-manager-udev@*' 2>/dev/null | awk '{print $1}' || true)
for unit in "${active_udev[@]}"; do
  [[ -n "${unit}" ]] && systemctl stop "${unit}" 2>/dev/null || true
done

remove_file "${SYSTEMD_DIR}/usbip-manager.service"
remove_file "${SYSTEMD_DIR}/usbip-manager-udev@.service"
remove_file "${SYSTEMD_DIR}/usbipd.service"
remove_file "${UDEV_RULE}"
remove_file "${MODULES_FILE}"
remove_dir "${INSTALL_DIR}"
remove_dir "${RUNTIME_DIR}"

if [[ "${KEEP_CONFIG}" != "1" ]]; then
  remove_dir "${CONFIG_DIR}"
fi

systemctl daemon-reload 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true

rmmod usbip_host 2>/dev/null || true
rmmod usbip_core 2>/dev/null || true

if [[ "${PURGE_OPTIONAL}" == "1" ]]; then
  apt_purge_if_installed hwdata usbutils
fi

if [[ "${PURGE_PYTHON}" == "1" ]]; then
  apt_purge_if_installed python3 python3-minimal python3.9 python3.9-minimal python3-apt
fi

if [[ "${CLEAN_SYSTEM}" == "1" ]]; then
  clean_system_space
fi

echo
echo "Uninstall/cleanup complete."
df -h / /var /tmp 2>/dev/null || df -h /
