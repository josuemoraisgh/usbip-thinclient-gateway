# WinFullInstall - Laboratorio FEELT

Instalador "tudo em um" do laboratorio FEELT/LASEC. Um unico `.msi`
(`WinFullInstall.msi`, na raiz deste repositorio) instala todos os programas
do laboratorio, configura o servidor (Active Directory + Remote Desktop
Services) e prepara o ambiente CODESYS para as 23 bancadas, executando uma
sequencia de scripts e instaladores presentes na pasta `componentes/`.

## Estrutura do repositorio

```text
WinFullInstall.msi          <- instalador geral (gerado a partir de msi-installer/Product.wxs)
README.md                   <- este arquivo
componentes/                <- TUDO que e instalado/executado fica aqui
  Install-All.ps1            <- orquestrador: roda tudo, na ordem certa
  Launch-Elevated.ps1         <- garante que o atalho do menu Iniciar rode com UAC
  setup-platformio-shared.ps1 <- configura pastas/variaveis compartilhadas do PlatformIO
  setup-codesys-bancadas.ps1  <- cria 1 instancia CODESYS Control Win por bancada
  Configurar-Laboratorio-RDS.ps1 <- configura AD DS + RDS + usuarios das bancadas
  usbip-thinclient-gateway/    <- gateway USB/IP para os thin clients (ver readme.md proprio)
  581.29-desktop-win10-win11-64bit-international-dch-whql.exe  <- driver NVIDIA GeForce GTX 1650
  amd_chipset_software_8.05.04.516.exe  <- driver de chipset AMD (B550/AM4)
  7z2601-x64.exe
  Anaconda3-2025.12-2-Windows-x86_64.exe
  CODESYS 64 3.5.21.0.exe
  Scada-LTS_v2.7.8.1_Installer_v2.1.0_Setup.exe
  process_simul-v0.0.7-windows.msi
  ININDUFU-Setup.exe
  OpenJDK21U-jdk_x64_windows_hotspot_21.0.7_6.msi
msi-installer/               <- fonte do WinFullInstall.msi (WiX Toolset)
  Product.wxs
```

> O `Install-All.ps1` referencia os arquivos de `componentes/` pelo caminho
> absoluto `C:\Prof_Jouse\00Instal\WinFullInstall\componentes`. Por isso, para
> o instalador funcionar, **este repositorio precisa estar clonado exatamente
> nesse caminho** no servidor.

> **Instaladores grandes (nao versionados)**: os arquivos abaixo excedem o
> limite de 100MB do GitHub e estao listados no `.gitignore` - precisam ser
> copiados manualmente para `componentes/` antes de rodar `Install-All.ps1`:
> - `581.29-desktop-win10-win11-64bit-international-dch-whql.exe` (driver NVIDIA)
> - `Anaconda3-2025.12-2-Windows-x86_64.exe`
> - `CODESYS 64 3.5.21.0.exe`
> - `ININDUFU-Setup.exe`
> - `OpenJDK21U-jdk_x64_windows_hotspot_21.0.7_6.msi`
> - `Scada-LTS_v2.7.8.1_Installer_v2.1.0_Setup.exe`

## Como instalar

1. Execute `WinFullInstall.msi` (pede elevacao UAC automaticamente).
2. O instalador cria:
   - um atalho **"Instalar tudo - Laboratorio FEELT"** no menu Iniciar, que
     sempre pede elevacao UAC (`Launch-Elevated.ps1`);
   - ao final da propria instalacao do `.msi`, dispara automaticamente
     `Install-All.ps1` em uma janela visivel (executando no contexto de quem
     instalou o `.msi`, que ja precisa ser administrador).
3. `Install-All.ps1` executa, em sequencia, todos os passos descritos abaixo.
   Pode reiniciar o servidor varias vezes (por causa da etapa de AD DS/RDS) -
   ele continua sozinho apos cada reboot.

Se preferir, e possivel rodar tudo manualmente a qualquer momento, sem o
`.msi`:

```powershell
cd C:\Prof_Jouse\00Instal\WinFullInstall\componentes
.\Install-All.ps1
```

## O que o `Install-All.ps1` faz (ordem de execucao)

`Install-All.ps1` e o orquestrador: executa cada item abaixo de forma
interativa (janela visivel), aguardando a conclusao de um antes de iniciar o
proximo. Erros em um item sao registrados no log e **nao interrompem** os
itens seguintes - exceto o ultimo (RDS), que controla seus proprios reboots.

Log completo de cada execucao:
`C:\ProgramData\WinFullInstall\install-all.log`.

1. **Configuracao compartilhada do PlatformIO** - roda
   `setup-platformio-shared.ps1`.
2. **Driver NVIDIA GeForce GTX 1650** - instala
   `581.29-desktop-win10-win11-64bit-international-dch-whql.exe`
   silenciosamente (`/s /noreboot /clean`), substituindo o "Microsoft Basic
   Display Adapter" pelo driver oficial da NVIDIA.
3. **Driver de chipset AMD (B550/AM4)** - instala
   `amd_chipset_software_8.05.04.516.exe` silenciosamente (`/S`).
4. **OpenJDK 21 (MSI)** - instala `OpenJDK21U-jdk_x64_windows_hotspot_21.0.7_6.msi`
   (necessario para o Scada-LTS).
5. **7-Zip** - instala `7z2601-x64.exe` silenciosamente (`/S`).
6. **Anaconda3** - instala `Anaconda3-2025.12-2-Windows-x86_64.exe`
   silenciosamente, para todos os usuarios, em `C:\ProgramData\Anaconda3`
   (`/InstallationType=AllUsers /AddToPath=1 /RegisterPython=1 /S /D=...`).
7. **CODESYS 64 3.5.21.0** - executa `CODESYS 64 3.5.21.0.exe` (instalador
   interativo da IDE + runtime "Control Win V3 x64").
8. **Scada-LTS Setup** - executa
   `Scada-LTS_v2.7.8.1_Installer_v2.1.0_Setup.exe`.
9. **process_simul (MSI)** - instala `process_simul-v0.0.7-windows.msi`.
10. **ININDUFU Setup** - executa `ININDUFU-Setup.exe`.
11. **USB/IP ThinClient Gateway** - roda
    `usbip-thinclient-gateway\windows-usbip-broker-cpp\instalar.ps1`
    (instala `usbipd-win` + o broker/monitor de bandeja do gateway USB/IP).
12. **Configurar-Laboratorio-RDS** - roda `Configurar-Laboratorio-RDS.ps1`
    (configura AD DS + RDS e cria os 23 usuarios das bancadas). E o **ultimo**
    passo porque pode reiniciar o servidor varias vezes.
13. **CODESYS Control Win por bancada** - roda
    `setup-codesys-bancadas.ps1` (cria uma instancia isolada do runtime
    CODESYS para cada uma das 23 bancadas).

Itens 7, 8 e 10 (instaladores `.exe` interativos sem argumentos) e os MSIs
(item 4 e 9) sao executados via `Invoke-Installer`/`Invoke-Msi` com
`Start-Process -Wait`, aguardando o usuario concluir o assistente na tela.

> **Nota sobre o driver NVIDIA em Windows Server**: drivers GeForce sao
> homologados oficialmente para Windows 10/11; em Windows Server o instalador
> pode recusar a instalacao por checagem de SO. Se isso ocorrer, o passo
> falha de forma isolada (o restante do `Install-All.ps1` continua) e o
> driver deve ser instalado manualmente em modo de compatibilidade.

---

## Scripts PowerShell - o que cada um faz

### `Launch-Elevated.ps1`

Launcher usado pelo atalho do menu Iniciar **"Instalar tudo - Laboratorio
FEELT"**. `Install-All.ps1` exige administrador
(`#Requires -RunAsAdministrator`), mas um atalho pode ser clicado por um
usuario sem privilegios. Este script:

1. Verifica se o processo atual e administrador
   (`WindowsPrincipal.IsInRole(Administrator)`).
2. Se **nao for**, relanca a si mesmo (na verdade, relanca
   `Install-All.ps1`) via `Start-Process -Verb RunAs`, o que forca o prompt
   de elevacao UAC.
3. Se **ja for** administrador, chama `Install-All.ps1` diretamente.

Resultado: o atalho **sempre** pede elevacao UAC quando usado, independente
de quem o clicou.

### `Install-All.ps1`

O orquestrador principal (ver [seção acima](#o-que-o-install-allps1-faz-ordem-de-execucao)
para a ordem completa). Detalhes de implementacao:

- `#Requires -RunAsAdministrator` - precisa rodar elevado.
- `$SourceDir = 'C:\Prof_Jouse\00Instal\WinFullInstall\componentes'` -
  caminho fixo de onde tudo e lido.
- Abre uma transcricao (`Start-Transcript`) em
  `C:\ProgramData\WinFullInstall\install-all.log` (modo `-Append`), entao
  cada execucao acumula no mesmo arquivo.
- `Invoke-Step` - executa um bloco de codigo, imprime um cabecalho com o
  nome do passo, e em caso de erro grava um `Write-Warning` com
  `[FALHA] <nome> : <mensagem>` mas **continua** para o proximo passo
  (`try`/`catch` sem `throw`).
- `Invoke-Installer` - roda um `.exe` de `componentes/` com
  `Start-Process -Wait`. So passa `-ArgumentList` se houver argumentos (um
  array vazio faz o `Start-Process` lancar erro).
- `Invoke-Msi` - roda `msiexec /i "<caminho>" <argumentos>` com `-Wait`.
- `Invoke-Script` - executa outro `.ps1` de `componentes/` (com `&`),
  passando argumentos adicionais se houver.
- No final, imprime um resumo, encerra a transcricao e espera uma tecla
  antes de fechar a janela.

### `setup-platformio-shared.ps1`

Prepara o **PlatformIO** para uso compartilhado por varias bancadas (sessoes
RDS) simultaneas no mesmo servidor, usado pelo ININDUFU e por projetos
Arduino/ESP do laboratorio:

1. Cria (se nao existir) `C:\config\platformio` e as subpastas `packages` e
   `platforms`.
2. Define, **para toda a maquina** (`[Environment]::SetEnvironmentVariable`
   com escopo `Machine`), as variaveis de ambiente dos itens **grandes e
   compartilhados** (toolchains, frameworks, `penv` - instalados uma unica
   vez para todas as bancadas, evitando GBs de copias repetidas):
   - `PLATFORMIO_CORE_DIR` = `C:\config\platformio`
   - `PLATFORMIO_PACKAGES_DIR` = `C:\config\platformio\packages`
   - `PLATFORMIO_PLATFORMS_DIR` = `C:\config\platformio\platforms`
3. Define `PLATFORMIO_CACHE_DIR` = `%LOCALAPPDATA%\platformio\cache` como
   variavel **expansivel** (`REG_EXPAND_SZ`, via API de registro - o
   `[Environment]::SetEnvironmentVariable` nao cria esse tipo), para que cada
   usuario tenha seu **proprio** cache do PlatformIO (pequeno: cache de
   download/registry do Package/Library Manager). Compartilhar esse cache
   entre sessoes era a causa do erro "nao aceita dois VSCodes rodando o
   PlatformIO ao mesmo tempo" (conflitos de lock/banco quando duas bancadas
   escrevem no mesmo cache simultaneamente).
4. Concede permissao de modificacao ao grupo `Users` em toda a arvore de
   `C:\config\platformio` (`icacls ... /grant "Users:(OI)(CI)M" /T`), para
   que qualquer bancada possa ler/escrever nos pacotes/plataformas
   compartilhados.
5. Define `platformio-ide.disablePIOHomeStartup=true` no `settings.json` do
   VSCode do perfil `Default` (novos usuarios) e de cada usuario existente
   (`Administrator` e `bancada*`), evitando que cada sessao inicie seu
   proprio servidor PIO Home em segundo plano.

E idempotente: se a pasta ja existe, apenas garante subpastas, variaveis e
permissoes. Usuarios precisam abrir uma nova sessao para as variaveis de
ambiente surtirem efeito.

### `setup-codesys-bancadas.ps1`

Cria, para cada uma das **23 bancadas**
(`bancada204a-01`..`bancada204a-07` e `bancada204b-01`..`bancada204b-16` -
os mesmos 23 usuarios criados por `Configurar-Laboratorio-RDS.ps1`), uma
copia isolada e configurada do runtime **CODESYS Control Win V3 x64**.

Pre-requisito: a instalacao base do CODESYS em
`C:\Program Files\CODESYS 3.5.21.0\GatewayPLC` (passo 5 do `Install-All.ps1`).

Para cada bancada, em `C:\config\codesys\<bancada>`:

1. **Copia integral** do conteudo de `GatewayPLC` para
   `C:\config\codesys\<bancada>` (se a pasta ja existir, e removida e
   recriada do zero).
2. **Nao cria** a subpasta `WorkingDirectory` - o proprio runtime CODESYS a
   cria na primeira execucao, copiando o conteudo de
   `AppDataFiles\CODESYSControlWinV3x64` (incluindo o `NodeName` e a porta
   configurados no passo 4). Se essa pasta ja existir (mesmo vazia) antes da
   primeira execucao, o runtime pula essa copia inicial e usa valores padrao
   (NodeName = nome do computador) - por isso o script nunca a pre-cria.
3. Edita `CODESYSControl.cfg` (na raiz da copia) - secao `[SysFile]`,
   chave `Windows.WorkingDirectory`, apontando para o
   `WorkingDirectory` exclusivo dessa bancada (cria a secao/chave se nao
   existir).
4. Edita `AppDataFiles\CODESYSControlWinV3x64\CODESYSControl.cfg` (template
   usado na primeira inicializacao):
   - define `[SysTarget] NodeName="<bancada>"` - e o nome que aparece para
     essa instancia ao escanear a rede pela IDE do CODESYS (cria a
     secao/chave se nao existir, ou descomenta/substitui se ja existir);
   - define `WebServerPortNr=<porta>` (8080 + indice da bancada, uma porta
     exclusiva por bancada) para evitar conflito de porta quando varias
     instancias rodam no mesmo servidor.
5. Cria, em `C:\Users\<bancada>\Desktop\Iniciar_ControlWin.bat`, um atalho
   que inicia **apenas** a instancia daquela bancada:
   ```bat
   @echo off
   cd /d "C:\config\codesys\<bancada>"
   start "" "C:\config\codesys\<bancada>\CODESYSControlService.exe" -d "C:\config\codesys\<bancada>\CODESYSControl.cfg"
   exit
   ```
   Se a pasta `Desktop` do usuario ainda nao existir (perfil so e criado no
   primeiro logon), o script avisa e segue para a proxima bancada - basta
   reexecutar depois do primeiro logon de cada bancada.
6. Copia o atalho **Visual Studio Code** (de
   `C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Visual Studio Code\Visual Studio Code.lnk`)
   para `C:\Users\<bancada>\Desktop\Visual Studio Code.lnk`.

Validacoes/erros: aborta no inicio se `GatewayPLC` nao existir; cada bancada
e processada dentro de um `try/catch` proprio, entao falha em uma bancada nao
impede as demais. `#Requires -RunAsAdministrator`.

> **Atencao (custo de disco/licenca)**: cada bancada recebe uma copia
> completa de `GatewayPLC` (centenas de MB, incluindo os arquivos de licenca
> `.SoftContainer_CmRuntime.wbb` / `.UFC_SoftContainer_CmRuntime.WibuCmLif`).
> Com 23 bancadas isso representa varios GB extras de disco, e todas as
> copias compartilham a mesma licenca da instalacao original.

Ao final, o script tambem configura a **instancia do professor**, que e a
propria instalacao base (`GatewayPLC`, servico Windows
"CODESYS Control Win V3 - x64"):

- define `[SysTarget] NodeName="professor"` e `WebServerPortNr=8103`
  (8080 + 23, a primeira porta livre apos as 23 bancadas) - tanto no template
  `AppDataFiles\CODESYSControlWinV3x64\CODESYSControl.cfg` (cobre maquinas
  novas, onde o servico nunca rodou) quanto em qualquer perfil ja
  inicializado em
  `C:\Windows\System32\config\systemprofile\AppData\Roaming\CODESYS\CODESYSControlWinV3x64\*`;
- deixa o servico "CODESYS Control Win V3 - x64" como inicializacao
  **manual** e parado;
- cria, em `C:\Users\Administrator\Desktop\Iniciar_ControlWin_Professor.bat`, um
  atalho que inicia essa instancia manualmente (mesmo padrao do atalho de
  cada bancada), apontando para
  `C:\Program Files\CODESYS 3.5.21.0\GatewayPLC\CODESYSControlService.exe`.
  Esse atalho fica **apenas** na Area de Trabalho do Administrator - e
  remove uma copia antiga deixada por versoes anteriores do script em
  `C:\Users\Public\Desktop`, que e compartilhada por todas as sessoes RDS e
  por isso aparecia tambem na Area de Trabalho de cada aluno.

### `Configurar-Laboratorio-RDS.ps1`

Configura, do zero e de forma idempotente, o servidor de laboratorio
completo: controlador de dominio (`feelt.lasec` / `FEELT`), implantacao RDS
de sessao em servidor unico, colecao `Bancadas`, os 23 usuarios das bancadas
e os RemoteApps publicados. Pode reiniciar o servidor automaticamente varias
vezes e continua sozinho apos cada reboot.

Resumo rapido das etapas (ver a documentacao completa, abaixo, em
[Detalhes - Configurar-Laboratorio-RDS.ps1](#detalhes---configurar-laboratorio-rdsps1)):

1. Valida que e um Windows Server.
2. Renomeia o servidor para `FEELT-LASEC` e instala as funcoes do Windows
   necessarias (AD DS, RDS, GPMC, .NET 3.5) - reinicia se preciso.
3. Cria/valida a floresta AD `feelt.lasec` (promove a controlador de
   dominio) - reinicia apos a promocao.
4. Cria/atualiza os registros DNS `server-204a` e `server-204b` (zona
   `feelt.lasec`), apontando para o IP do proprio servidor - sao os nomes que
   os thin clients usam (`/v:server-204a` / `/v:server-204b`) para conectar
   via RDP.
5. Cria o grupo `Bancadas-RDS` e os 23 usuarios `bancada*` (recria todos se a
   lista nao corresponder exatamente ao esperado), garante que o grupo seja
   membro de `Remote Desktop Users` e concede a permissao "Allow log on
   through Remote Desktop Services" ao grupo via GPO (necessario porque o
   servidor RDS e tambem controlador de dominio).
6. Configura a implantacao RDS (Connection Broker, Web Access,
   RD Session Host, Licensing) e configura o licenciamento.
7. Reseta o periodo de avaliacao de 120 dias do RDS (uso exclusivo de
   laboratorio).
8. Cria/configura a colecao de sessao `Bancadas`.
9. Publica os RemoteApps encontrados (Office, Chrome, LabVIEW, Notepad,
   etc.).
10. Imprime um resumo final.
11. Remove a tarefa agendada de continuacao e os arquivos de estado
    temporarios.

### `usbip-thinclient-gateway\windows-usbip-broker-cpp\instalar.ps1`

Instala o gateway USB/IP completo, usado para compartilhar portas USB dos
thin clients com as sessoes RDS das bancadas:

1. **usbipd-win** - verifica no registro
   (`HKLM:\...\Uninstall`, padrao `^usbipd-win`) se ja esta instalado; se
   nao, instala `..\usbipd-win_5.1.0_x64.msi` silenciosamente
   (`msiexec /i ... /qn /norestart`).
2. Localiza `usbip.exe` (`Find-UsbipExe`) em caminhos comuns de instalacao do
   usbipd-win, ou usa um caminho padrao se nao encontrar.
3. Instala `.\build\UsbipSuite-2.0.0-x64.msi` (servico broker C++ + monitor
   de bandeja), passando:
   - `THINCLIENTS` - lista de IPs dos thin clients (parametro
     `-ThinClients`, padrao `192.168.100.31`..`192.168.100.52`);
   - `USBIPPATH` - caminho do `usbip.exe` encontrado (ou informado via
     `-UsbipPath`).

Demais scripts dentro de `usbip-thinclient-gateway/` (`deploy-linux-manager.ps1`,
`windows-cleanup.ps1`, etc.) sao utilitarios de manutencao/implantacao do
gateway e nao fazem parte do fluxo do `Install-All.ps1` - veja
`usbip-thinclient-gateway\readme.md` para detalhes.

---

## Demais componentes instalados

| Arquivo | O que e |
| --- | --- |
| `OpenJDK21U-jdk_x64_windows_hotspot_21.0.7_6.msi` | OpenJDK 21 (Java), requerido pelo Scada-LTS. |
| `7z2601-x64.exe` | 7-Zip (compactador de arquivos). |
| `Anaconda3-2025.12-2-Windows-x86_64.exe` | Distribuicao Python Anaconda3, instalada para todos os usuarios. |
| `CODESYS 64 3.5.21.0.exe` | IDE + runtime CODESYS 3.5.21.0 (Control Win V3 x64). |
| `Scada-LTS_v2.7.8.1_Installer_v2.1.0_Setup.exe` | Plataforma SCADA Scada-LTS. |
| `process_simul-v0.0.7-windows.msi` | Simulador de processos do laboratorio. |
| `ININDUFU-Setup.exe` | Aplicativo ININDUFU (inclui SimulIDE). |

---

## Detalhes - Configurar-Laboratorio-RDS.ps1

Script PowerShell para configurar, do zero, o servidor de laboratorio
(AD DS + RDS) descrito no documento do TCC. Ele foi pensado para um
laboratorio que e **formatado e reconfigurado com frequencia**: pode ser
executado repetidas vezes sem causar duplicidade ou erro, e e capaz de
sobreviver aos varios reboots que a promocao a controlador de dominio e a
instalacao das funcoes do Windows exigem.

### Visao geral

Em uma unica execucao (com reinicializacoes automaticas pelo meio), o
script transforma um Windows Server "limpo" em:

- um controlador de dominio da floresta `feelt.lasec` (NetBIOS `FEELT`);
- um host de sessao RDS com implantacao completa (Connection Broker, Web
  Access, RD Session Host, Licensing) em um unico servidor;
- uma colecao de sessao `Bancadas` com os usuarios e RemoteApps do
  laboratorio.

O script e **idempotente**: pode ser executado novamente a qualquer momento
(por exemplo, apos reformatar a maquina) e ele detecta o que ja existe,
pulando etapas ja concluidas e corrigindo o que estiver fora do padrao
esperado.

### Pre-requisitos

- Windows Server (testado em Windows Server 2025 Standard), seja como
  servidor membro (`ProductType = 3`) ou ja como controlador de dominio
  (`ProductType = 2`). O script so aborta se detectar uma instalacao
  "Workstation" (`ProductType = 1`).
- Windows PowerShell 5.1.
- Executar o script **como Administrador** (`#Requires -RunAsAdministrator`).
- Para instalar o .NET Framework 3.5 em servidores sem acesso a internet,
  informe `-NetFramework35Source` apontando para a pasta `sources\sxs` da
  midia de instalacao do Windows Server.

### Como executar

```powershell
.\Configurar-Laboratorio-RDS.ps1
```

Isso e **suficiente**: o script reinicia automaticamente sempre que
necessario e volta a executar sozinho apos cada reboot (veja
[Continuacao automatica apos reboots](#continuacao-automatica-apos-reboots)),
ate concluir toda a configuracao - sem necessidade de digitar nada e sem
precisar rodar o script novamente manualmente.

Se preferir controlar manualmente os reboots (por exemplo, para acompanhar
cada etapa):

```powershell
.\Configurar-Laboratorio-RDS.ps1 -RestartAutomatically:$false
```

Nesse modo, o script registra a tarefa de continuacao, avisa que e preciso
reiniciar e encerra com codigo de saida `3010`. Apos o reboot (manual ou
automatico do Windows), a tarefa agendada continua a configuracao por conta
propria; tambem e possivel reexecutar o script manualmente a qualquer
momento.

### O que o script faz, passo a passo

1. **Valida o sistema operacional** - confirma que e um Windows Server
   (`Win32_OperatingSystem.ProductType -eq 3`) e exibe a versao.

2. **Renomeia o servidor e instala papeis do Windows**
   - Renomeia o computador para `FEELT-LASEC` (parametro `-ComputerName`),
     a menos que `-SkipComputerRename` seja usado ou o nome ja esteja
     correto. Se o servidor ja faz parte de um dominio com outro nome, o
     script lanca um erro (renomear um DC exige procedimento especial).
   - Instala, via `Install-WindowsFeature`, as seguintes funcoes/recursos
     (somente os que ainda nao estiverem instalados):
     - `NET-Framework-Core` (.NET Framework 3.5)
     - `AD-Domain-Services`
     - `GPMC` (Group Policy Management Console)
     - `RDS-RD-Server`
     - `RDS-Licensing`
     - `RDS-Connection-Broker`
     - `RDS-Web-Access`
   - Se alguma instalacao/renomeacao exigir reinicializacao (ou se ja
     houver uma reinicializacao pendente no registro), o script **registra
     a tarefa de continuacao e reinicia o servidor** (ou apenas avisa, no
     modo `-RestartAutomatically:$false`).

3. **Valida ou cria o dominio**
   - Se o servidor ainda nao pertence a um dominio, importa
     `ADDSDeployment`, solicita (uma unica vez, e so de forma interativa) a
     **senha do modo de restauracao do AD (DSRM)** e executa
     `Install-ADDSForest` para criar a floresta `feelt.lasec` (NetBIOS
     `FEELT`), com DNS integrado e sem reiniciar automaticamente
     (`-NoRebootOnCompletion:$true`).
   - Em seguida, registra a continuacao e reinicia o servidor (a promocao a
     controlador de dominio sempre exige reboot).
   - Apos o reboot, o script valida que o dominio do servidor
     (`Get-ADDomain`) corresponde a `feelt.lasec` e que o servidor e
     realmente um controlador de dominio (`DomainRole -ge 4`); caso
     contrario, aborta com erro.

4. **Cria/atualiza os registros DNS dos thin clients** (`Set-ThinClientDnsAliases`)
   - Le o registro A do proprio servidor (`<COMPUTERNAME>`) na zona
     `feelt.lasec` para obter o IP atual.
   - Para cada alias em `Get-ThinClientServerAliases` (`server-204a`,
     `server-204b`), cria o registro A se nao existir, atualiza se apontar
     para um IP diferente, ou nao faz nada se ja estiver correto.
   - Esses nomes sao usados pelo `rdp.service` dos thin clients
     (`/v:server-204a`, `/v:server-204b`) para encontrar o servidor RDS via
     RDP - sem eles, os thin clients nao conseguem resolver o nome e a
     conexao falha.

5. **Cria o grupo e os usuarios das bancadas**
   - Cria o grupo de seguranca `Bancadas-RDS` (parametro
     `-AccessGroupName`), caso ainda nao exista.
   - Calcula a lista de usuarios esperada (ver
     [Usuarios das bancadas](#usuarios-das-bancadas)) e compara com os
     usuarios `bancada*` existentes no AD.
     - **Se a lista existente for exatamente igual a esperada** (mesmos 23
       nomes, em qualquer ordem), o script **nao faz nada** com os
       usuarios - apenas informa que ja estao corretos.
     - **Se houver qualquer diferenca** (nomes antigos, faltando, sobrando,
       etc.) **ou** se `-ResetExistingUserPasswords` for usado, o script
       **remove TODOS** os usuarios cujo nome comeca com `bancada` e recria
       do zero os 23 usuarios esperados, cada um com a senha fixa definida
       em `-UserPassword`, e adiciona cada um ao grupo `Bancadas-RDS`.
   - Garante que o grupo `Bancadas-RDS` seja membro do grupo embutido
     `Remote Desktop Users` (acesso RDP).
   - Concede a permissao **"Allow log on through Remote Desktop Services"**
     (`SeRemoteInteractiveLogonRight`) ao grupo `Bancadas-RDS`
     (`Grant-RemoteInteractiveLogonRight`):
     - Como o servidor RDS e tambem o controlador de dominio, essa permissao
       e controlada pela GPO **"Default Domain Controllers Policy"** e, por
       padrao, contem apenas `Administrators` - ser membro de
       `Remote Desktop Users` **nao** e suficiente em um DC.
     - O script edita o `GptTmpl.inf` dessa GPO em
       `SYSVOL\<dominio>\Policies\{6AC1786C-...}\Machine\...\SecEdit\`,
       adiciona o SID do grupo `Bancadas-RDS` a
       `SeRemoteInteractiveLogonRight`, incrementa a versao da GPO (`GPT.INI`
       e o atributo `versionNumber` no AD) e executa `gpupdate /force`.
     - Sem isso, a conexao RDP do thin client chega a autenticar (evento
       4624, Logon Type 3) mas a sessao RDP (Logon Type 10) e recusada com
       o erro `0xC000015B` e a conexao cai imediatamente
       (`ERRINFO_LOGOFF_BY_USER`), ficando em loop de reconexao no
       `rdp.service`.
     - Operacao idempotente: se o grupo ja estiver na lista, nada e
       alterado.

6. **Configura a implantacao RDS**
   - Importa `RemoteDesktop` e calcula o FQDN do servidor
     (`<COMPUTERNAME>.feelt.lasec`).
   - Se ainda nao existir uma implantacao RDS, cria uma implantacao de
     servidor unico com `New-RDSessionDeployment`, usando o proprio
     servidor como Connection Broker, Web Access Server e Session Host -
     reproduzindo o cenario "tudo em um servidor" do documento.
   - Garante que o servidor tenha, na implantacao, as funcoes
     `RDS-CONNECTION-BROKER`, `RDS-WEB-ACCESS`, `RDS-RD-SERVER` e
     `RDS-LICENSING` (adiciona as que faltarem via `Add-RDServer`).
   - Configura o servidor de licenciamento RDS
     (`Set-RDLicenseConfiguration`) com o modo definido em
     `-LicensingMode` (padrao `PerUser`), usando o proprio servidor como
     license server - apenas se a configuracao atual ainda nao estiver
     correta.

7. **Reinicia o periodo de avaliacao de 120 dias do RDS** (a menos que
   `-SkipRDSGracePeriodReset` seja usado) - ver
   [Reset do grace period do RDS](#reset-do-grace-period-do-rds-120-dias).

8. **Cria/configura a colecao de sessao `Bancadas`**
   - Cria a colecao `Bancadas` (parametro `-CollectionName`, descricao em
     `-CollectionDescription`) caso ainda nao exista.
   - Garante que a colecao esteja configurada com:
     - a descricao definida em `-CollectionDescription`;
     - o grupo `FEELT\Bancadas-RDS` como unico grupo autorizado
       (`UserGroup`);
     - autenticacao por NLA habilitada (`AuthenticateUsingNLA = $true`).
   - So aplica `Set-RDSessionCollectionConfiguration` se algo estiver
     diferente do esperado.

9. **Publica os RemoteApps encontrados** (a menos que `-SkipRemoteApps`
   seja usado) - ver [RemoteApps publicados](#remoteapps-publicados).

10. **Resumo final** - imprime um resumo (dominio, servidor RDS, colecao,
   grupo autorizado, quantidade de usuarios) e avisos importantes (senha
   compartilhada, grace period reiniciado ou necessidade de CALs, e que o
   VirtualHere/apps especificos do laboratorio precisam ser configurados
   separadamente).

11. **Limpeza** - remove a tarefa agendada de continuacao
    (`Configurar-Laboratorio-RDS-Continuacao`), encerra a transcricao de
    execucao e remove o diretorio de estado
    `C:\ProgramData\Configurar-Laboratorio-RDS` (inclusive a senha DSRM
    salva, se houver).

### Continuacao automatica apos reboots

Como a criacao do dominio e a instalacao de algumas funcoes do Windows
exigem reinicializacao, o script usa o seguinte mecanismo para "se lembrar"
de continuar de onde parou:

- Antes de reiniciar, o script registra (ou atualiza) uma **tarefa
  agendada** chamada `Configurar-Laboratorio-RDS-Continuacao`, configurada
  para:
  - disparar **na inicializacao do sistema** (`AtStartup`);
  - executar como `SYSTEM`, com privilegio maximo (`Highest`/
    `ServiceAccount`);
  - reexecutar `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
    "Configurar-Laboratorio-RDS.ps1"` com os mesmos parametros (exceto
    `SecureString`s, que sao persistidas separadamente - ver abaixo) da
    execucao original.
- Se `-RestartAutomatically` (padrao `$true`) estiver ativo, o script
  aguarda 10 segundos e executa `Restart-Computer -Force` imediatamente.
  Caso contrario, ele apenas avisa que uma reinicializacao e necessaria
  (saindo com codigo `3010`) e a tarefa de continuacao cuidara do resto no
  proximo boot - seja ele manual ou automatico (Windows Update, etc.).
- Ao terminar com sucesso, o script **remove a tarefa de continuacao**
  (`Unregister-ContinuationTask`) e o diretorio de estado, para nao deixar
  nada agendado em uma maquina ja configurada.

#### Persistencia segura da senha DSRM

A senha do modo de restauracao do Active Directory (DSRM) e necessaria
apenas na etapa de criacao da floresta, mas como a tarefa de continuacao
roda como `SYSTEM` em uma sessao **nao interativa**, o script:

1. Na primeira execucao interativa, pergunta a senha DSRM via `Read-Host
   -AsSecureString` (rejeitando senha vazia).
2. Criptografa essa senha com AES, usando uma chave aleatoria de 32 bytes
   gerada na primeira execucao (`state.key`).
3. Grava o resultado em
   `C:\ProgramData\Configurar-Laboratorio-RDS\DSRMPassword.txt`.
4. O diretorio `C:\ProgramData\Configurar-Laboratorio-RDS` tem suas
   permissoes restritas (`SetAccessRuleProtection`) a apenas
   `NT AUTHORITY\SYSTEM` e `BUILTIN\Administrators` (FullControl).
5. Ao final da execucao (sucesso), todo o diretorio de estado - chave,
   senha criptografada e log de execucao - e removido
   (`Remove-SavedState`).

Se a tarefa de continuacao precisar dessa senha mas nada tiver sido salvo
(situacao anormal), o script lanca um erro explicativo em vez de travar em
um `Read-Host` que nunca retornaria em uma sessao do `SYSTEM`.

> A senha dos usuarios das bancadas (`-UserPassword`) **nao** passa por
> esse mecanismo: ela tem um valor fixo padrao (`Feelt@lasec123!`) definido
> diretamente no parametro, entao nunca precisa ser perguntada nem
> persistida.

#### Log de execucao

Cada execucao (incluindo as automaticas via tarefa agendada) grava uma
transcricao em
`C:\ProgramData\Configurar-Laboratorio-RDS\execucao.log` (modo `-Append`),
util para diagnosticar falhas em execucoes nao interativas. Esse arquivo
tambem e removido na limpeza final.

### Usuarios das bancadas

O script cria/garante exatamente estes 23 usuarios no AD (container
`Users` do dominio):

- `bancada204a-01` a `bancada204a-07` (bancada 204a, 7 usuarios)
- `bancada204b-01` a `bancada204b-16` (bancada 204b, 16 usuarios)

Todos sao criados com:

- senha fixa `Feelt@lasec123!` (parametro `-UserPassword`, por padrao um
  `SecureString` com esse valor);
- `Enabled = $true`;
- `ChangePasswordAtLogon = $false`;
- `CannotChangePassword = $true`;
- `PasswordNeverExpires = $true`;
- membros do grupo `Bancadas-RDS` (que por sua vez e membro de
  `Remote Desktop Users` e e o unico grupo autorizado na colecao
  `Bancadas`).

> **Atencao**: senha compartilhada, sem expiracao e sem permissao de troca
> reduzem a seguranca do ambiente. Isso reproduz intencionalmente o cenario
> do documento do TCC para um laboratorio de testes - **nao recomendado**
> para ambientes de producao.

#### Comportamento "tudo ou nada"

- Se os 23 usuarios `bancada*` existentes no AD **forem exatamente** esses
  23 nomes (em qualquer ordem), **nada e alterado** (nem mesmo a senha,
  a menos que `-ResetExistingUserPasswords` seja usado).
- Se houver **qualquer diferenca** - usuarios de uma convencao de nomes
  antiga, usuarios extras, usuarios faltando - **todos** os usuarios cujo
  nome comeca com `bancada` sao removidos e os 23 usuarios corretos sao
  recriados do zero.

Esse comportamento foi pensado para o ciclo "formatar -> reconfigurar" do
laboratorio: nao importa o que existia antes, o script sempre garante o
conjunto correto de usuarios.

### Reset do grace period do RDS (120 dias)

Por padrao (a menos que `-SkipRDSGracePeriodReset` seja usado), o script
executa `Reset-RDSGracePeriod`, que:

1. Verifica se a chave de registro
   `HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod`
   existe. Se nao existir, considera o periodo ja zerado e nao faz nada.
2. Caso exista, como normalmente apenas `NT AUTHORITY\SYSTEM` tem acesso a
   essa chave (mesmo `BUILTIN\Administrators` costuma ser negado), o script
   registra uma tarefa agendada temporaria, executada uma unica vez como
   `SYSTEM`, que remove a chave `GracePeriod` (e suas subchaves) e grava o
   resultado em
   `C:\ProgramData\Configurar-Laboratorio-RDS\reset-grace-period.result`. A
   tarefa e desregistrada automaticamente apos a execucao.
3. Reinicia o servico `Terminal Services` (`TermService`) com
   `Restart-Service -Name TermService -Force` para que o Windows recrie o
   contador de avaliacao do zero (mais 120 dias).

Se essa etapa falhar por qualquer motivo, o script registra um aviso e
**continua** com o restante da configuracao (colecao, RemoteApps, limpeza),
em vez de abortar tudo - afinal, isso e uma conveniencia extra para o
laboratorio, nao um requisito da implantacao RDS em si.

> **Uso exclusivo de laboratorio**: isso "reseta" o contador de avaliacao
> de licenciamento RDS, permitindo reutilizar o servidor sem licenciamento
> RDS valido. **Nao use isso fora de um ambiente de laboratorio/teste.** Se
> CALs (licencas) validas forem instaladas, execute o script com
> `-SkipRDSGracePeriodReset` para nao interferir na licenca real.

Como esse passo reinicia o `TermService`, sessoes RDP ativas no momento da
execucao serao desconectadas.

### RemoteApps publicados

Se `-SkipRemoteApps` nao for usado, o script percorre a lista de programas
do documento e, para cada um, procura o executavel em locais conhecidos
(`Candidates`) ou faz uma busca recursiva em pastas comuns
(`SearchRoots`/`FileNames`). Se encontrado e ainda nao publicado na colecao
`Bancadas`, publica com `New-RDRemoteApp` (visivel no RD Web Access,
autorizado para o grupo `Bancadas-RDS`). Programas nao encontrados sao
listados em um aviso no final, mas nao interrompem a execucao.

Lista de programas considerados:

| Nome exibido | Onde o script procura |
| --- | --- |
| Access | Microsoft Office (Office16) |
| Arduino | Arduino IDE / Arduino classico (`Program Files` e `Program Files (x86)`) |
| Calculator | `calc.exe` (System32) |
| DataSocket Server | `cwdss.exe` em `National Instruments` |
| DataSocket Server Manager | `cwdssmgr.exe` em `National Instruments` |
| Excel | Microsoft Office (Office16) |
| Google Chrome | `Program Files`/`Program Files (x86)`\Google\Chrome |
| LabVIEW 2013 (32-bit) | `National Instruments\LabVIEW 2013\LabVIEW.exe` |
| NI MAX | `NIMax.exe` em `National Instruments` |
| ODBC Data Sources (32-bit) | `odbcad32.exe` (SysWOW64) |
| OneNote 2016 | Microsoft Office (Office16) |
| Outlook | Microsoft Office (Office16) |
| Paint | `mspaint.exe` (System32) |
| PowerPoint | Microsoft Office (Office16) |
| Publisher | Microsoft Office (Office16) |
| Python (command line) | `C:\Python27\...`, `Program Files\Python31x\python.exe` |
| Remote Desktop Connection | `mstsc.exe` (System32) |
| Word | Microsoft Office (Office16) |
| WordPad | `write.exe` (System32) |
| Notepad | `notepad.exe` (System32) |

### Parametros

| Parametro | Tipo | Padrao | Descricao |
| --- | --- | --- | --- |
| `-ComputerName` | string | `FEELT-LASEC` | Nome desejado para o servidor (regex `^[A-Za-z0-9-]{1,15}$`). |
| `-DomainName` | string | `feelt.lasec` | FQDN da floresta AD a criar/validar. |
| `-NetBIOSName` | string | `FEELT` | Nome NetBIOS do dominio. |
| `-CollectionName` | string | `Bancadas` | Nome da colecao de sessao RDS. |
| `-CollectionDescription` | string | `Programas para as bancadas do laboratorio.` | Descricao da colecao. |
| `-AccessGroupName` | string | `Bancadas-RDS` | Grupo de seguranca autorizado a usar a colecao/RemoteApps. |
| `-LicensingMode` | `PerUser` ou `PerDevice` | `PerUser` | Modo de licenciamento RDS. |
| `-NetFramework35Source` | string | (vazio) | Caminho para `sources\sxs` da midia do Windows Server, para instalar o .NET 3.5 offline. |
| `-DSRMPassword` | SecureString | (vazio) | Senha do modo de restauracao do AD. Se omitida, e solicitada interativamente (uma unica vez) quando necessaria. |
| `-UserPassword` | SecureString | `Feelt@lasec123!` | Senha fixa usada para todos os usuarios das bancadas. |
| `-ResetExistingUserPasswords` | switch | `$false` | Forca a remocao/recriacao de todos os usuarios `bancada*`, mesmo que os nomes ja estejam corretos. |
| `-SkipComputerRename` | switch | `$false` | Nao renomeia o computador. |
| `-SkipRemoteApps` | switch | `$false` | Nao publica RemoteApps. |
| `-SkipRDSGracePeriodReset` | switch | `$false` | Nao reinicia o periodo de avaliacao do RDS (use se houver CALs validas instaladas). |
| `-RestartAutomatically` | switch | `$true` | Reinicia o servidor automaticamente quando necessario. Use `-RestartAutomatically:$false` para apenas avisar e deixar a tarefa de continuacao (ou um reboot manual) cuidar do resto. |

### Exemplos

```powershell
# Uso padrao: configura tudo, reiniciando automaticamente quando preciso,
# e continuando sozinho apos cada reboot.
.\Configurar-Laboratorio-RDS.ps1
```

```powershell
# Nao reiniciar automaticamente; apenas avisar quando um reboot for
# necessario (a tarefa de continuacao ainda e registrada e cuidara do
# restante no proximo boot).
.\Configurar-Laboratorio-RDS.ps1 -RestartAutomatically:$false
```

```powershell
# .NET Framework 3.5 a partir da midia de instalacao (servidor sem
# internet), sem reset do grace period do RDS (ha CALs validas).
.\Configurar-Laboratorio-RDS.ps1 `
    -NetFramework35Source 'D:\sources\sxs' `
    -SkipRDSGracePeriodReset
```

```powershell
# Forcar a recriacao de todos os usuarios das bancadas (ex.: trocar a senha
# de todo mundo), mesmo que os nomes ja estejam corretos.
.\Configurar-Laboratorio-RDS.ps1 -ResetExistingUserPasswords
```

### Limitacoes conhecidas

- A ativacao do servidor de licencas RDS e a instalacao de CALs validas nao
  sao automatizadas (dependem de dados/licencas externas ao documento).
- VirtualHere e os aplicativos especificos do laboratorio (alem dos
  listados em [RemoteApps publicados](#remoteapps-publicados)) precisam ser
  instalados/configurados separadamente.
- Renomear um servidor que ja e controlador de dominio nao e suportado pelo
  script (ele aborta com erro nesse caso).
- `setup-codesys-bancadas.ps1` copia o runtime completo do CODESYS para cada
  uma das 23 bancadas (ver aviso de disco/licenca na secao
  [setup-codesys-bancadas.ps1](#setup-codesys-bancadasps1)).
