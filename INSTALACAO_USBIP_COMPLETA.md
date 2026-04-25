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
sudo bash ./install.sh --server-ip 192.168.100.26 --notify-host 192.168.100.26
```

Se quiser exportar somente ESP32-S3 e bridges seriais conhecidas:

```bash
sudo bash ./install.sh --server-ip 192.168.100.26 --notify-host 192.168.100.26 --allowlist-only
```

Validacao:

```bash
systemctl status usbipd.service usbip-manager.service
journalctl -u usbip-manager.service -f
usbip list -l
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
