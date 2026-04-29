# USB/IP ThinClient Gateway

Sistema completo para exportar dispositivos USB de thin clients Linux e importá-los automaticamente no Windows Server via USB/IP.

## Componentes

| Componente | Diretório | Descrição |
|---|---|---|
| **Broker C++** | `windows-usbip-broker-cpp/` | Serviço Windows que conecta nas thin clients e anexa os dispositivos USB/IP |
| **Monitor de bandeja** | `windows-tray-monitor/` | App Flutter (system tray) que exibe a relação COM × estação em tempo real |
| **Manager Linux** | `linux-usbip-manager/` | Daemon C++ nas thin clients que exporta os dispositivos via `usbipd` |
| **MSI unificado** | `windows-usbip-broker-cpp/build/` | Instalador que entrega o broker + monitor de bandeja em uma única etapa |

---

## Instalação rápida

### 1. Windows Server

**Pré-requisito:** `usbip.exe` (usbip-win) instalado — ex.: `C:\usbip\usbip.exe`.

```powershell
# (Administrador) — limpa instalações antigas
.\windows-cleanup.ps1

# Instala o broker e o monitor de bandeja
msiexec /i "windows-usbip-broker-cpp\build\UsbipSuite-2.0.0-x64.msi" `
    THINCLIENTS="192.168.100.31,192.168.100.32" `
    USBIPPATH="C:\usbip\usbip.exe"
```

O assistente de instalação também pode ser aberto com duplo clique no `.msi`.

### 2. Thin clients Linux (deploy remoto a partir do Windows Server)

O script `deploy-linux-manager.ps1` acessa cada thin client via SSH, faz upload dos arquivos, executa o `uninstall.sh` e depois o `install.sh` automaticamente.

**Pré-requisito:** PuTTY instalado no Windows Server.

```powershell
winget install PuTTY.PuTTY
```

#### Opção A — Mesma senha para todas as thin clients

```powershell
.\deploy-linux-manager.ps1 `
    -ThinClients "192.168.100.31","192.168.100.32","192.168.100.33" `
    -Password "senha_root" `
    -ServerIP "192.168.100.10"
```

Se alguns thin clients aceitam SSH com usuario `armbian`, o script tenta `root` primeiro e depois tenta `armbian` automaticamente quando a falha for senha/usuario:

```powershell
.\deploy-linux-manager.ps1 `
    -ThinClients "10.0.64.4","10.0.64.21","10.0.64.22" `
    -Password "armbina" `
    -ServerIP "10.0.64.28" `
    -Force
```

Tambem e possivel forcar o usuario desde o inicio:

```powershell
.\deploy-linux-manager.ps1 `
    -ThinClients "10.0.64.4","10.0.64.22" `
    -User "armbian" `
    -Password "armbina" `
    -ServerIP "10.0.64.28" `
    -Force
```

#### Opção B — Senhas diferentes por host (arquivo CSV)

Copie `hosts.example.csv` para `hosts.csv`, edite os IPs e senhas:

```
192.168.100.31,senha_estacao01
192.168.100.32,senha_estacao02
```

Tambem pode informar usuario por host no formato `ip,usuario,senha`:

```
10.0.64.4,armbian,armbina
10.0.64.22,armbian,armbina
```

```powershell
.\deploy-linux-manager.ps1 -ConfigFile .\hosts.csv -ServerIP "192.168.100.10"
```

#### Opção C — Apenas reinstalar sem apagar configuração

```powershell
.\deploy-linux-manager.ps1 `
    -ThinClients "192.168.100.31" `
    -KeepConfig `
    -Force
```

#### Parâmetros do deploy

| Parâmetro | Descrição | Padrão |
|---|---|---|
| `-ThinClients` | Lista de IPs das thin clients | — |
| `-Password` | Senha root (igual para todos) | Pedida interativamente |
| `-ConfigFile` | CSV `ip,senha` para senhas diferentes por host | — |
| `-ServerIP` | IP do Windows Server (repassado ao `install.sh`) | Detectado automaticamente |
| `-NotifyPort` | Porta TCP do broker Windows | `12000` |
| `-SkipUninstall` | Pula o `uninstall.sh` (somente instala/atualiza) | `false` |
| `-KeepConfig` | Passa `--keep-config` ao `uninstall.sh` | `false` |
| `-Force` | Não pede confirmação antes de iniciar | `false` |

Observacao: `-User` define o usuario SSH inicial, com padrao `root`. `-FallbackUsers` define usuarios alternativos para tentar quando houver falha de senha/usuario, com padrao `armbian`. O `-ConfigFile` aceita tanto `ip,senha` quanto `ip,usuario,senha`.

#### O que o script faz em cada thin client

1. Detecta/valida a host key SSH do PuTTY/Plink com `-hostkey`
2. Testa conexão SSH
3. Faz upload de `linux-usbip-manager/` via SCP para `/tmp/usbip-deploy`
4. Executa `uninstall.sh --force` (opcional)
5. Executa `install.sh --server-ip <IP> --notify-host <IP> --notify-port <PORTA>`
6. Remove os arquivos temporários remotos
7. Exibe resumo de sucesso/falha por IP

### 3. Thin clients Linux (manual)

```bash
# Em cada thin client, como root
sudo bash ./linux-usbip-manager/uninstall.sh --force
sudo bash ./linux-usbip-manager/install.sh --server-ip 192.168.100.10
```

---

## Atualização / limpeza

### Windows

```powershell
# Remove serviço antigo, MSI anterior, processos e entradas de registro
.\windows-cleanup.ps1

# Com -KeepData preserva C:\ProgramData\UsbipBroker (dados do broker Python legado)
.\windows-cleanup.ps1 -KeepData
```

Para atualizar sem apagar a configuracao atual:

```powershell
msiexec /i "windows-usbip-broker-cpp\build\UsbipSuite-2.0.0-x64.msi"
```

O MSI novo roda como upgrade por cima da instalacao existente e preserva
`C:\ProgramData\UsbipBrokerCpp\config.ini`, mantendo alteracoes feitas pelo
usuario. Ele so cria chaves que estiverem faltando.

### Linux

```bash
# Remove completamente (mantendo config.json)
sudo bash ./linux-usbip-manager/uninstall.sh --keep-config

# Remove tudo incluindo configuração
sudo bash ./linux-usbip-manager/uninstall.sh --force
```

---

## Build

### Compilar tudo e gerar o MSI

```powershell
# Requer: Visual Studio Build Tools (C++), Flutter SDK, WiX Toolset v6
cd windows-usbip-broker-cpp
.\build.ps1
```

Etapas do build:

1. `flutter build windows --release` em `windows-tray-monitor/`
2. Compilação C++ do `UsbipBrokerService.exe`
3. Empacotamento WiX → `build\UsbipSuite-2.0.0-x64.msi`

Flags opcionais:

```powershell
.\build.ps1 -SkipFlutter   # pula o build Flutter (usa binário já compilado)
.\build.ps1 -SkipCpp       # pula a compilação C++
.\build.ps1 -SkipFlutter -SkipCpp   # apenas regenera o MSI
```

---

## Trilha de auditoria (COM × estação)

O broker registra cada dispositivo anexado em:

```
C:\ProgramData\UsbipBrokerCpp\logs\audit.csv
```

Colunas: `timestamp`, `station`, `host_ip`, `busid`, `vid`, `pid`, `description`, `com_port`

O estado atual, usado pelo monitor de bandeja, fica em:

```
C:\ProgramData\UsbipBrokerCpp\state.txt
```

Esse arquivo e reescrito a cada varredura com apenas os dispositivos conectados
no momento. Quando um dispositivo sai do `usbip port`, ele tambem sai da
listagem do tray.

Para configurar os nomes das estações, edite `C:\ProgramData\UsbipBrokerCpp\config.ini`:

```ini
[Stations]
192.168.100.31=Estacao-01
192.168.100.32=Estacao-02
```

O monitor de bandeja le o estado atual e exibe a tabela ao clicar no icone na barra de tarefas.

