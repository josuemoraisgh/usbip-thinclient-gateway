#!/bin/bash
set -e

# Diagnóstico detalhado do usbipd.service
# Uso: sudo ./diagnostic-usbipd.sh > diag-usbipd.txt 2>&1

echo "==== 1. Status do usbipd.service ===="
systemctl status usbipd.service --no-pager

echo "\n==== 2. Tentando rodar usbipd manualmente ===="
sudo /usr/sbin/usbipd -d -4 || echo "(usbipd falhou)"

echo "\n==== 3. Kernel modules ===="
lsmod | grep usbip || echo "(usbip não carregado)"

ls /lib/modules/$(uname -r)/kernel/drivers/usb/usbip 2>/dev/null || echo "(usbip kernel module ausente)"

echo "\n==== 4. dmesg (últimos 40) ===="
dmesg | tail -40

echo "\n==== 5. Porta 3240 ===="
ss -ltnp | grep 3240 || echo "(porta 3240 não está em uso)"

netstat -anp 2>/dev/null | grep 3240 || echo "(netstat: porta 3240 não está em uso)"

echo "\n==== 6. Versão do usbipd ===="
usbipd --version || true

which usbipd

ls -l /usr/sbin/usbipd


echo "\n==== 7. Arquivos residuais de versões antigas ===="
find /usr/local/bin /usr/local/sbin /usr/bin /usr/sbin /bin /sbin -name 'usbip*' 2>/dev/null

find /lib/modules/$(uname -r) -name 'usbip*' 2>/dev/null

find /etc/ -name '*usbip*' 2>/dev/null

find /opt/ -name '*usbip*' 2>/dev/null

echo "\n==== 8. Pacotes instalados ===="
dpkg -l | grep usbip || echo "(usbip não instalado via apt)"

echo "\n==== FIM ===="
