# Instalacao completa USB/IP

Este pacote fica dividido em dois instaladores:

- `linux-usbip-manager/install.sh`: executar uma vez em cada thin client Linux.
- `windows-usbip-broker-cpp/build/UsbipSuite-2.0.0-x64.msi`: executar uma vez no Windows Server.

## 1. Windows Server recomendado: MSI C++

Pre-requisitos:

- Cliente/importador USB/IP para Windows instalado, por exemplo `usbip-win2`.
- Driver do dispositivo final instalado no Windows, como o driver Espressif USB
  Serial/JTAG para ESP32-S3.
- Para JTAG/OpenOCD, um driver WinUSB assinado ou o INF padrao do MSI aceito
  pela politica do Windows.

PowerShell como Administrador:

```powershell
cd C:\SourceCode\ThinClient\windows-usbip-broker-cpp
.\build.ps1
msiexec /i .\build\UsbipSuite-2.0.0-x64.msi
```

O assistente do MSI pede elevacao/UAC e abre uma tela para informar os IPs dos
thin clients e o caminho do `usbip.exe`. Para instalacao silenciosa:

```powershell
msiexec /i .\build\UsbipSuite-2.0.0-x64.msi THINCLIENTS="192.168.100.31,192.168.100.32" USBIPPATH="C:\usbip\usbip.exe"
```

Validacao:

```powershell
Get-Service UsbipBrokerCpp
Get-Content C:\ProgramData\UsbipBrokerCpp\logs\broker.log -Wait
```

O MSI instala o servico `UsbipBrokerCpp`, o monitor de bandeja, cria
`C:\ProgramData\UsbipBrokerCpp\config.ini`, abre a regra de firewall para eventos
TCP 12000 e grava auditoria em `C:\ProgramData\UsbipBrokerCpp\logs\audit.csv`.
Se instalar sem `THINCLIENTS`, o broker ainda funciona por eventos enviados pelos
thin clients Linux.

### Regras WinUSB no config.ini

O MSI tambem instala `C:\Program Files\UsbipSuite\drivers\usbip-winusb.inf` e
preenche estas regras:

```ini
[WinUSB]
Enabled=1
DefaultDriverInf=C:\Program Files\UsbipSuite\drivers\usbip-winusb.inf
Rules=ESP32S3_NATIVE_JTAG,ESP_PROG_FT2232_JTAG

[WinUSB.ESP32S3_NATIVE_JTAG]
Pattern=USB\VID_303A&PID_1001&MI_02*

[WinUSB.ESP_PROG_FT2232_JTAG]
Pattern=USB\VID_0403&PID_6010&MI_00*
```

Para adicionar outro dispositivo, descubra o `InstanceId`:

```powershell
Get-PnpDevice -PresentOnly |
  Where-Object InstanceId -match 'VID_303A|VID_0403|VID_10C4|VID_1A86' |
  Select-Object Class,FriendlyName,InstanceId,Status
```

Adicione uma nova regra em `Rules=` e crie uma secao `[WinUSB.NOME_DA_REGRA]`
com `Pattern=<prefixo do InstanceId>*`. Escolha a interface de debug/JTAG; nao
coloque a interface COM no WinUSB.

## 2. Thin client Linux

Em cada thin client:

```bash
cd linux-usbip-manager
sudo bash ./install.sh
```

O instalador Linux agora assume por padrao o Windows Server `10.0.64.28` para
`--server-ip` e `--notify-host`, com notificacao na porta TCP 12000.
Se `usbip` ou `usbipd` nao existirem, ele tenta instalar automaticamente o
runtime USB/IP do Linux via `apt-get`, exceto quando usado com `--skip-packages`.

Para thin clients com pouco espaco, o pacote Linux tambem aceita um binario C++
nativo. Este pacote ja inclui `bin/usbip-manager-linux-arm64`:

```text
SHA256: BD808BBBE20E22B8E1E8A25F8F42CB7C911E7F31A3AC1B81FBAD75819F99C0D9
```

Se precisar recompilar, use uma maquina Linux/Armbian da mesma arquitetura:

```bash
cd linux-usbip-manager
bash ./build-native.sh
```

Depois copie a pasta para o pendrive. Se existir
`bin/usbip-manager-linux-arm64`, o instalador usa esse binario C++:

```bash
sudo bash ./install.sh --skip-packages
```

Se quiser exportar somente ESP32-S3 e bridges seriais conhecidas:

```bash
sudo bash ./install.sh --allowlist-only
```

Validacao:

```bash
systemctl status usbipd.service usbip-manager.service
journalctl -u usbip-manager.service -f
usbip list -l
```

Se o `install.sh` parar em `apt-get update` com erro de
`bullseye-backports Release`, o repositório APT do thin client esta obsoleto. A
versao atual do instalador tenta comentar essa entrada automaticamente e criar
backup. Para corrigir manualmente:

```bash
sudo sed -i -E '/bullseye-backports/ s/^/# disabled: /' /etc/apt/sources.list
sudo find /etc/apt/sources.list.d -name '*.list' -type f -exec sed -i -E '/bullseye-backports/ s/^/# disabled: /' {} \;
sudo apt-get update --allow-releaseinfo-change
sudo bash ./install.sh
```

Se aparecer `Nao foi possivel resolver 'deb.debian.org'` ou
`Nao foi possivel resolver 'apt.armbian.com'`, o problema e DNS/internet no thin
client. Correcao rapida para testar:

```bash
ip route
ping -c 3 8.8.8.8
getent hosts deb.debian.org
printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" | sudo tee /etc/resolv.conf
sudo apt-get update --allow-releaseinfo-change
sudo bash ./install.sh
```

Se a internet nao for necessaria agora e os utilitarios USB/IP ja estiverem
instalados, pule o APT:

```bash
command -v usbip usbipd modprobe udevadm systemctl
sudo bash ./install.sh --skip-packages
```

Se aparecer `Nao ha espaco disponivel no dispositivo`, limpe cache/logs, repare
o `dpkg` e rode sem APT:

```bash
df -h / /var /tmp
sudo apt-get clean
sudo rm -rf /var/cache/apt/archives/*.deb /var/lib/apt/lists/*
sudo journalctl --vacuum-size=20M 2>/dev/null || true
sudo find /var/log -type f -name "*.gz" -delete
sudo find /var/log -type f -name "*.1" -delete
sudo dpkg --configure -a
sudo bash ./install.sh --skip-packages
```

## Fluxo operacional

1. Usuario conecta o ESP32-S3 no thin client.
2. Linux detecta o USB, ignora `ModemManager`/`brltty` e faz `usbip bind`.
3. Linux avisa o Windows pela porta TCP 12000.
4. Windows executa `usbip.exe attach -r <thinclient> -b <busid>`.
5. Se o ESP32-S3 resetar durante flash/bootloader, Linux faz rebind e Windows
   reanexa no proximo evento ou polling.

O polling no Windows fica ativo mesmo com notificacao habilitada, para recuperar
eventos perdidos.
