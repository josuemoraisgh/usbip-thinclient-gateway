# Linux USB/IP Manager

Instalador e daemon Python para thin clients Linux que exportam dispositivos USB
para um Windows Server via USB/IP.

## O que ele configura

- Instala dependencias basicas (`python3`, `usbip`, `usbutils`, `hwdata`).
- Carrega `usbip-core` e `usbip-host` no boot.
- Cria `usbipd.service` para expor dispositivos na porta TCP 3240.
- Cria `usbip-manager.service` para reconciliar e fazer rebind automatico.
- Cria regra `udev` para reagir a insercao/remocao de USB.
- Ignora ModemManager/brltty para ESP32-S3 e bridges seriais comuns.
- Pode avisar um broker Windows via JSON TCP na porta 12000.

## Instalacao rapida

```bash
sudo bash ./install.sh --server-ip 192.168.100.26
```

Com notificacao para o broker Windows:

```bash
sudo bash ./install.sh --server-ip 192.168.100.26 --notify-host 192.168.100.26 --notify-port 12000
```

Para exportar somente dispositivos na allowlist:

```bash
sudo bash ./install.sh --allowlist-only
```

Se o thin client nao usa ModemManager/brltty, e voce quer evitar conflito com
ESP32-S3 durante boot/flash:

```bash
sudo bash ./install.sh --disable-conflicting-services
```

## Comandos uteis

```bash
systemctl status usbipd.service usbip-manager.service
journalctl -u usbip-manager.service -f
python3 /opt/usbip-manager/usbip_manager.py --config /etc/usbip-manager/config.json scan
python3 /opt/usbip-manager/usbip_manager.py --config /etc/usbip-manager/config.json status
usbip list -l
```

No Windows, o cliente deve conseguir listar e anexar:

```powershell
usbip.exe list -r <ip-do-thinclient>
usbip.exe attach -r <ip-do-thinclient> -b <busid>
```

## Politicas

`bind_policy` em `/etc/usbip-manager/config.json`:

- `allow_all`: exporta todos os USBs, exceto hubs/root hubs e bloqueios.
- `allowlist`: exporta apenas VID/PID em `allowed_devices`.
- `disabled`: nao exporta automaticamente.

Para ESP32-S3 nativo, a entrada principal e:

```json
{"vid": "303a", "pid": "1001", "name": "Espressif ESP32-S3 USB Serial/JTAG"}
```

Para ESP-PROG, mantenha tambem:

```json
{"vid": "0403", "pid": "6010", "name": "ESP-PROG / FTDI FT2232H"}
```

## Desinstalacao

```bash
sudo bash ./install.sh --uninstall
```
