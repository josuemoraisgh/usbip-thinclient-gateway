# Relatorio de pente fino - USB/IP ThinClient

Data da revisao: 2026-04-25

## Resultado geral

O projeto atual esta coerente para o objetivo: thin clients Linux exportam USB
via USB/IP, e o Windows Server importa/anexa os dispositivos por um servico
nativo C++ instalado por MSI.

O caminho recomendado ficou:

1. Windows Server: instalar `windows-usbip-broker-cpp/build/UsbipSuite-2.0.0-x64.msi`.
2. Cada thin client Linux: executar `linux-usbip-manager/install.sh`.
3. ESP32-S3: usar allowlist `303a:1001`, manter a interface COM no driver
   serial e aplicar WinUSB somente na interface JTAG (`MI_02`) quando necessario.

## Correcoes feitas durante o pente fino

- Corrigido `windows-cleanup.ps1`, que estava com encoding corrompido e nao
  passava no parser do PowerShell.
- Corrigido teste Flutter legado que ainda referenciava `MyApp` do template.
- Corrigida documentacao que ainda apontava para `UsbipBrokerCpp-1.0.0-x64.msi`.
- Corrigido checkbox `AUTOSTARTTRAY`: agora ele realmente controla a entrada
  de auto-start do monitor de bandeja.
- Adicionada politica WinUSB por `config.ini`, baseada em `Get-PnpDevice` e
  `InstanceId`, para ESP32-S3 e ESP-PROG.
- Adicionado INF padrao `drivers/usbip-winusb.inf` ao MSI.
- Removidos artefatos obsoletos do build antigo 1.0.
- Regerado o MSI final `UsbipSuite-2.0.0-x64.msi`.

## Validacoes executadas

- Python Linux: `python -m py_compile linux-usbip-manager/usbip_manager.py`
- JSON Linux: `python -m json.tool linux-usbip-manager/config.example.json`
- Bash Linux: `bash -n linux-usbip-manager/install.sh`
- Bash Linux: `bash -n linux-usbip-manager/uninstall.sh`
- PowerShell: parser OK para `windows-cleanup.ps1`
- PowerShell: parser OK para `windows-usbip-broker-cpp/build.ps1`
- Flutter: `flutter analyze` sem issues
- Flutter: `flutter test` aprovado
- Flutter Windows release: build OK
- C++ broker: build OK com MSVC
- WiX MSI: build OK
- WiX MSI validation: OK com supressao especifica de ICE60 para asset de fonte
  do Flutter (`MaterialIcons-Regular.otf`)

MSI final:

```text
windows-usbip-broker-cpp/build/UsbipSuite-2.0.0-x64.msi
SHA256: C70F9E8B1E532E7E8CEC625A11AC22DB6892A6F106E4A5B01F919176721335DF
```

## O que o thin client Linux faz

- Instala dependencias basicas (`python3`, `usbip`, `usbutils`, `hwdata`).
- Carrega `usbip-core` e `usbip-host`.
- Cria `usbipd.service` para exportar USB na porta TCP 3240.
- Cria `usbip-manager.service`, um daemon Python que reconcilia dispositivos
  continuamente.
- Cria regra `udev` para reagir a insercao/remocao de USB.
- Usa retry e atraso de estabilizacao para lidar com reenumeracao.
- Exporta dispositivos por politica:
  - `allow_all`: todos exceto hubs/root hubs.
  - `allowlist`: somente VID/PID configurados.
  - `disabled`: sem bind automatico.
- Inclui ESP32-S3 nativo `303a:1001`, ESP-PROG/FT2232H `0403:6010` e bridges
  comuns CP210x, CH340 e FTDI.
- Marca dispositivos seriais/JTAG para evitar probing local por
  `ModemManager`/`brltty`.
- Pode notificar o Windows por JSON TCP na porta 12000.

## O que o Windows Server faz

- MSI instala o servico `UsbipBrokerCpp`.
- MSI instala o monitor de bandeja Flutter `usbip_monitor.exe`.
- MSI instala `C:\Program Files\UsbipSuite\drivers\usbip-winusb.inf`.
- MSI cria `C:\ProgramData\UsbipBrokerCpp\config.ini`.
- MSI abre regra de firewall para eventos TCP 12000.
- O servico roda em background e:
  - faz polling dos thin clients configurados;
  - escuta eventos enviados pelos thin clients;
  - executa `usbip.exe list -r <thinclient>`;
  - filtra por allowlist de VID/PID;
  - executa `usbip.exe attach -r <thinclient> -b <busid>`;
  - faz retry em caso de falha;
  - evita reanexar dispositivos ja listados em `usbip.exe port`;
  - le regras `[WinUSB]` do `config.ini`;
  - executa `Get-PnpDevice -PresentOnly` para localizar interfaces PnP;
  - aplica `pnputil /add-driver <INF> /install` quando o `InstanceId` casa com
    uma regra WinUSB;
  - registra log operacional;
  - registra auditoria COM x estacao em `audit.csv`.

## Regras WinUSB padrao

A troca para WinUSB nao e feita por "tem duas COM", porque esse criterio pode
atingir a interface errada. O criterio correto e o `InstanceId` da interface USB.

Padrao instalado:

```ini
[WinUSB]
Enabled=1
DefaultDriverInf=C:\Program Files\UsbipSuite\drivers\usbip-winusb.inf
SettleSeconds=3
RetryCount=2
Rules=ESP32S3_NATIVE_JTAG,ESP_PROG_FT2232_JTAG

[WinUSB.ESP32S3_NATIVE_JTAG]
Pattern=USB\VID_303A&PID_1001&MI_02*

[WinUSB.ESP_PROG_FT2232_JTAG]
Pattern=USB\VID_0403&PID_6010&MI_00*
```

Lista recomendada:

| Dispositivo | O que colocar em `Pattern` | Por que |
| --- | --- | --- |
| ESP32-S3 USB Serial/JTAG nativo | `USB\VID_303A&PID_1001&MI_02*` | Interface JTAG; preserva as interfaces COM/CDC. |
| ESP-PROG FT2232H | `USB\VID_0403&PID_6010&MI_00*` | Canal A/JTAG; preserva `MI_01` como UART/COM. |

Para outro dispositivo, rode:

```powershell
Get-PnpDevice -PresentOnly |
  Where-Object InstanceId -match 'VID_303A|VID_0403|VID_10C4|VID_1A86' |
  Select-Object Class,FriendlyName,InstanceId,Status
```

Copie o prefixo do `InstanceId` da interface de debug/JTAG para uma nova regra,
terminando com `*`.

## Por que e melhor que a versao antiga

A versao antiga `elielprado/usbip_client_server` funciona como prova de conceito,
mas depende de parsing fixo de texto e de comandos remotos simples:

- `client.py` usa IP fixo do servidor.
- `client.py` suporta no maximo 3 dispositivos.
- `client.py` assume que cada dispositivo ocupa exatamente 3 linhas em
  `usbip list -l`.
- `client.py` corta `busid` por posicao fixa, por exemplo `[9:13]`.
- `server.py` decide o que fazer pelo tamanho exato da string recebida
  (`15`, `30`, `45`).
- `server.py` tambem corta `busid` e serial por posicoes fixas.
- Nao ha polling no Windows.
- Nao ha reconciliacao de estado.
- Nao ha retry estruturado.
- Nao ha allowlist por VID/PID.
- Nao ha tratamento especifico para reset/reenumeracao do ESP32-S3.
- Nao ha instalador MSI/servico nativo.
- Nao ha logs/auditoria.
- O Windows executa comando vindo da rede sem validacao forte.

O projeto novo remove essas fragilidades: ele usa descoberta real por
`usbip list`, filtra por VID/PID, trabalha com qualquer `busid`, reexecuta
bind/attach quando necessario, e roda como servico nos dois lados.

## Por que a ESP32-S3 deve funcionar agora

O ESP32-S3 nativo aparece para o sistema como USB Serial/JTAG e normalmente usa
VID/PID `303a:1001`. No Windows ele aparece como porta `COM*`; no Linux como
`/dev/ttyACM*`.

A falha da versao antiga provavelmente acontecia por uma combinacao destes
fatores:

- ESP32-S3 reseta durante flash/download mode e reenumera no USB.
- A versao antiga disparava apenas scripts pontuais por udev, sem estado e sem
  reconciliacao continua.
- Se o `busid` tivesse mais de 3-4 caracteres, o corte fixo de string quebrava.
- Se o dispositivo aparecesse como `unknown product`, o `BLOCKLIST` antigo podia
  bloquear por conter `UNKNOWN`.
- `ModemManager`/`brltty` no Linux podiam abrir a porta serial antes do bind.
- O Windows nao tinha polling para recuperar evento perdido.

Na versao nova:

- Linux reconhece `303a:1001` explicitamente.
- Linux espera estabilizacao do udev antes de bind.
- Linux tenta bind novamente.
- Windows recebe evento e tambem faz polling.
- Windows tenta attach novamente.
- O driver serial no Windows cria a porta COM depois do attach.
- A politica WinUSB corrige a interface JTAG por `InstanceId` apos o attach,
  reduzindo a necessidade de rodar Zadig manualmente a cada reenumeracao.
- O monitor registra a COM atribuida e a estacao de origem.

## Pendencias para producao

- Instalar no Windows um cliente/importador USB/IP compativel, recomendado
  `usbip-win2`. O `usbipd-win_5.1.0_x64.msi` existente no workspace nao substitui
  isso, pois e voltado principalmente para exportar USB do Windows para Linux/WSL.
- Instalar/manter o driver serial Espressif no Windows Server para as interfaces
  COM.
- Assinar o INF WinUSB padrao ou apontar `DriverInf` para um pacote WinUSB
  assinado do fabricante/Zadig/libwdi. Em Windows x64 de producao, INF sem
  assinatura pode ser recusado ou perder no ranking de drivers.
- Testar ponta a ponta com ESP32-S3 real, incluindo flash via `idf.py flash`.
- Assinar o MSI e o EXE com certificado de code signing antes de distribuicao.
- Se o objetivo for um MSI totalmente "um clique", empacotar tambem o instalador
  do `usbip-win2` e validar o licenciamento/distribuicao dele.
