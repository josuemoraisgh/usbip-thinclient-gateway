#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT_DIR}/bin"
mkdir -p "${OUT_DIR}"

arch="$(uname -m)"
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

compiler="${CXX:-g++}"
if ! command -v "${compiler}" >/dev/null 2>&1; then
  echo "C++ compiler not found. Install g++ on the build machine, not on every thin client." >&2
  exit 1
fi

output="${OUT_DIR}/usbip-manager-linux-${target}"
"${compiler}" -std=c++17 -O2 -s -Wall -Wextra -pedantic \
  "${ROOT_DIR}/usbip_manager.cpp" \
  -o "${output}"

chmod 0755 "${output}"
echo "Built ${output}"
