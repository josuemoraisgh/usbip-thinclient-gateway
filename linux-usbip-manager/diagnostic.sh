#!/bin/bash
set -e

# Diagnóstico USB/IP Manager + ESP32
# Uso: sudo ./diagnostic.sh > diag.txt 2>&1

echo "==== 1. Status dos serviços ===="
systemctl status usbipd.service usbip-manager.service --no-pager

echo
ls -l /etc/systemd/system/multi-user.target.wants/ | grep usbip || true

echo "\n==== 2. lsusb (ESP32) ===="
lsusb | grep -i -E "303a|10c4|1a86|0403" || echo "(nenhum dispositivo ESP32 detectado)"

echo "\n==== 3. dmesg (últimos 30) ===="
dmesg | tail -30

echo "\n==== 4. journalctl usbip-manager ===="
journalctl -u usbip-manager.service -n 50 --no-pager

echo "\n==== 5. udevadm info (ESP32) ===="
for dev in $(ls /sys/bus/usb/devices/*/idVendor 2>/dev/null | xargs grep -l -E '303a|10c4|1a86|0403'); do
  dir=$(dirname "$dev")
  echo "--- $dir ---"
  udevadm info -a -p "$dir"
done || echo "(nenhum dispositivo ESP32 detectado)"

echo "\n==== 6. usbip list -l ===="
usbip list -l || echo "(usbip não está rodando?)"

echo "\n==== 7. Config do manager ===="
cat /etc/usbip-manager/config.json 2>/dev/null || echo "(sem config)"

echo "\n==== 8. Regras udev ===="
cat /etc/udev/rules.d/90-usbip-manager.rules 2>/dev/null || echo "(sem regra)"

echo "\n==== 9. Kernel modules ===="
lsmod | grep usbip || echo "(usbip não carregado)"

echo "\n==== 10. Versões ===="
usbip --version || true
usbipd --version || true
udevadm --version || true
cat /etc/os-release

echo "\n==== FIM ===="
