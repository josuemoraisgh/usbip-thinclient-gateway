# USB/IP Broker C++ MSI

Este e o pacote nativo para o Windows Server. Ele substitui a dependencia de
Python no servidor por um servico C++ instalado por MSI.

## Build

Pre-requisitos na maquina de build:

- Visual Studio Build Tools com C++.
- WiX Toolset 6.
- Extensao WiX Firewall: `wix extension add -g WixToolset.Firewall.wixext/6.0.2`.
- Flutter SDK para compilar o monitor de bandeja.

Build:

```powershell
cd C:\SourceCode\ThinClient\windows-usbip-broker-cpp
.\build.ps1
```

Saida:

```text
windows-usbip-broker-cpp\build\UsbipSuite-2.0.0-x64.msi
```

## Instalacao no Windows Server

O MSI e per-machine e dispara UAC para instalacao elevada.

Instalacao por duplo clique ou padrao:

```powershell
msiexec /i .\build\UsbipSuite-2.0.0-x64.msi
```

O assistente do MSI pede elevacao/UAC, permite escolher a pasta de instalacao,
e mostra uma tela para informar:

- IPs dos thin clients para polling, separados por virgula.
- Caminho do `usbip.exe`.
- Porta TCP de eventos, padrao `12000`.

Instalacao silenciosa ou parametrizada:

```powershell
msiexec /i .\build\UsbipSuite-2.0.0-x64.msi THINCLIENTS="192.168.100.31,192.168.100.32" USBIPPATH="C:\usbip\usbip.exe"
```

Se instalado sem `THINCLIENTS`, o broker ainda funciona por eventos enviados
pelos thin clients Linux para a porta TCP 12000.

## Atualizacao

Para atualizar uma instalacao existente, execute o MSI novo por cima da versao
instalada:

```powershell
msiexec /i .\build\UsbipSuite-2.0.0-x64.msi
```

O instalador aceita upgrade mesmo quando a versao exibida continua igual, para
facilitar builds de correcao. Durante a atualizacao, o `config.ini` existente em
`C:\ProgramData\UsbipBrokerCpp\config.ini` e preservado: o MSI cria apenas
chaves ausentes com valores padrao e nao substitui valores alterados pelo
usuario. Os binarios, servico, firewall e autostart continuam sendo atualizados
pelo pacote novo.

## Arquivos instalados

- Servico: `UsbipBrokerCpp`
- Binario: `C:\Program Files\UsbipSuite\UsbipBrokerService.exe`
- Monitor: `C:\Program Files\UsbipSuite\monitor\usbip_monitor.exe`
- INF WinUSB padrao: `C:\Program Files\UsbipSuite\drivers\usbip-winusb.inf`
- Configuracao: `C:\ProgramData\UsbipBrokerCpp\config.ini`
- Estado atual do tray: `C:\ProgramData\UsbipBrokerCpp\state.txt`
- Logs: `C:\ProgramData\UsbipBrokerCpp\logs\broker.log`
- Auditoria COM/estacao: `C:\ProgramData\UsbipBrokerCpp\logs\audit.csv`

## Regras WinUSB por Get-PnpDevice

O servico tambem pode aplicar WinUSB automaticamente para interfaces PnP
especificas. A lista fica em `C:\ProgramData\UsbipBrokerCpp\config.ini`:

```ini
[WinUSB]
Enabled=1
DefaultDriverInf=C:\Program Files\UsbipSuite\drivers\usbip-winusb.inf
SettleSeconds=3
RetryCount=2
Rules=ESP32S3_NATIVE_JTAG,ESP_PROG_FT2232_JTAG

[WinUSB.ESP32S3_NATIVE_JTAG]
Description=ESP32-S3 native USB Serial/JTAG - somente interface JTAG
Pattern=USB\VID_303A&PID_1001&MI_02*
DriverInf=

[WinUSB.ESP_PROG_FT2232_JTAG]
Description=ESP-PROG FT2232H channel A - JTAG/OpenOCD
Pattern=USB\VID_0403&PID_6010&MI_00*
DriverInf=
```

Para descobrir novos dispositivos, execute no servidor:

```powershell
Get-PnpDevice -PresentOnly |
  Where-Object InstanceId -match 'VID_303A|VID_0403|VID_10C4|VID_1A86' |
  Select-Object Class,FriendlyName,InstanceId,Status
```

Coloque no `Pattern` o prefixo do `InstanceId` da interface que deve usar
WinUSB, terminando com `*`. Exemplos recomendados:

| Dispositivo | Pattern para WinUSB | Observacao |
| --- | --- | --- |
| ESP32-S3 USB Serial/JTAG nativo | `USB\VID_303A&PID_1001&MI_02*` | Troca so a interface JTAG. Nao use `MI_00`/`MI_01` se elas forem COM. |
| ESP-PROG FT2232H | `USB\VID_0403&PID_6010&MI_00*` | Canal A/JTAG. Normalmente `MI_01` e UART/COM e deve ficar no driver serial. |

Se voce ja tiver um pacote assinado do Zadig/libwdi ou do fabricante, informe
o caminho dele em `DriverInf=` dentro da regra. Se `DriverInf` ficar vazio, o
servico usa `DefaultDriverInf`.

## Validacao

```powershell
Get-Service UsbipBrokerCpp
Get-Content C:\ProgramData\UsbipBrokerCpp\logs\broker.log -Wait
usbip.exe port
```

## Pre-requisitos de runtime

O MSI instala o broker, o servico, a configuracao, a regra de firewall e um INF
padrao para politica WinUSB. Ele nao instala o cliente/importador USB/IP.

No Windows Server ainda e necessario ter:

- `usbip.exe` importador, recomendado via `usbip-win2`.
- Driver serial Espressif/Windows para manter as interfaces COM.
- Para uso em producao, driver WinUSB assinado para as interfaces JTAG, ou
  apontar `DriverInf` para um pacote assinado ja validado.
