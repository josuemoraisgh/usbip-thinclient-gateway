#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    setup-codesys-bancadas.ps1

    Automatiza a preparacao de multiplas instancias independentes do
    CODESYS Control Win em um laboratorio com 23 thin clients (bancadas
    204a-01 a 204a-07 e 204b-01 a 204b-16).

    Para cada bancada e criada uma copia isolada do runtime CODESYS
    Control Win (CODESYS 3.5.21.0 - GatewayPLC), com:
      - diretorio proprio em C:\config\codesys\<bancada>
      - WorkingDirectory exclusivo (criado pelo proprio runtime na
        primeira execucao, a partir do template AppDataFiles)
      - NodeName exclusivo (nome da bancada)
      - porta de webserver exclusiva (para varias instancias no mesmo servidor)
      - atalho .bat na Area de Trabalho do usuario correspondente para
        iniciar exclusivamente a sua propria instancia
      - atalho do Visual Studio Code copiado para a Area de Trabalho do
        usuario correspondente

    Alem disso, a instalacao base do CODESYS (GatewayPLC, servico
    "CODESYS Control Win V3 - x64") e configurada como mais uma instancia,
    a do professor: NodeName="professor", porta de webserver exclusiva,
    servico em modo manual (parado) e atalho .bat na Area de Trabalho do
    Administrator (apenas) para iniciar a instancia manualmente.

    Executar como Administrador.
#>

# ---------------------------------------------------------------------------
# Configuracao
# ---------------------------------------------------------------------------

# Instalacao base do CODESYS (sempre nesse caminho)
$OrigemCodesys = "C:\Program Files\CODESYS 3.5.21.0\GatewayPLC"

# Pasta raiz onde ficam as instancias de cada bancada
$BaseDestino = "C:\config\codesys"

# Nomes das bancadas / usuarios Windows correspondentes (mesmo padrao
# gerado por Get-LaboratoryUserNames em Configurar-Laboratorio-RDS.ps1)
$Usuarios = @()
1..7  | ForEach-Object { $Usuarios += ('bancada204a-{0:D2}' -f $_) }
1..16 | ForEach-Object { $Usuarios += ('bancada204b-{0:D2}' -f $_) }

# Porta inicial do webserver do CODESYS (cada bancada recebe Base + indice)
$PortaWebServerBase = 8080

# ---------------------------------------------------------------------------
# Funcoes auxiliares
# ---------------------------------------------------------------------------

# Ajusta [SysTarget] NodeName e WebServerPortNr em um CODESYSControl.cfg
function Set-CodesysTarget {
    param(
        [string]$CfgPath,
        [string]$NodeName,
        [int]$Port
    )

    $Conteudo = Get-Content $CfgPath -Raw

    if ($Conteudo -match '(?m)^;?NodeName=.*$') {
        # Chave ja existe (comentada ou nao): substitui e descomenta
        $Conteudo = $Conteudo -replace '(?m)^;?NodeName=.*$', "NodeName=`"$NodeName`""
    }
    elseif ($Conteudo -match '(?m)^\[SysTarget\]\s*$') {
        # Secao [SysTarget] existe mas sem a chave: insere apos o cabecalho da secao
        $Conteudo = $Conteudo -replace '(?m)^\[SysTarget\]\s*$', "[SysTarget]`r`nNodeName=`"$NodeName`""
    }
    else {
        # Nem secao nem chave existem: cria ambos no final do arquivo
        $Conteudo += "`r`n[SysTarget]`r`nNodeName=`"$NodeName`"`r`n"
    }

    # Porta do webserver exclusiva (evita conflito ao rodar varias instancias no mesmo servidor)
    if ($Conteudo -match '(?m)^;?WebServerPortNr=.*$') {
        $Conteudo = $Conteudo -replace '(?m)^;?WebServerPortNr=.*$', "WebServerPortNr=$Port"
    }

    Set-Content -Path $CfgPath -Value $Conteudo -Encoding ASCII
}

# ---------------------------------------------------------------------------
# Validacoes iniciais
# ---------------------------------------------------------------------------

Write-Host "=== Setup CODESYS Control Win por bancada ==="

# 1. Verifica se a instalacao base do CODESYS existe
if (!(Test-Path $OrigemCodesys)) {
    Write-Error "Instalacao do CODESYS nao encontrada em: $OrigemCodesys"
    exit 1
}
Write-Host "Instalacao base do CODESYS localizada em: $OrigemCodesys"

# 2. Garante que a pasta C:\config\codesys exista (cria se necessario, reaproveita se ja existir)
if (!(Test-Path $BaseDestino)) {
    Write-Host "Criando pasta base: $BaseDestino"
    New-Item -ItemType Directory -Path $BaseDestino -Force | Out-Null
}
else {
    Write-Host "Pasta base ja existe, reaproveitando: $BaseDestino"
}

# ---------------------------------------------------------------------------
# Loop principal: uma instancia por bancada
# ---------------------------------------------------------------------------

$indice = 0

foreach ($Usuario in $Usuarios) {

    Write-Host ""
    Write-Host "--- Configurando $Usuario ---"

    try {
        # 3. Pasta da bancada (ex.: C:\config\codesys\bancada01-204a)
        $DestinoUsuario = Join-Path $BaseDestino $Usuario

        # 5. WorkingDirectory exclusivo da bancada
        $WorkingDir = Join-Path $DestinoUsuario "WorkingDirectory"

        # Arquivo de configuracao principal do runtime copiado
        $CfgRaiz = Join-Path $DestinoUsuario "CODESYSControl.cfg"

        # Template de configuracao usado na primeira inicializacao do runtime
        # (e onde fica a secao [SysTarget] com o NodeName)
        $CfgTemplate = Join-Path $DestinoUsuario "AppDataFiles\CODESYSControlWinV3x64\CODESYSControl.cfg"

        # Area de trabalho do usuario correspondente e o .bat de inicializacao
        $Desktop = "C:\Users\$Usuario\Desktop"
        $BatFile = Join-Path $Desktop "Iniciar_ControlWin.bat"

        # Porta de webserver exclusiva desta bancada
        $PortaWebServer = $PortaWebServerBase + $indice

        # 4. Copia integral do runtime base para a pasta da bancada
        if (Test-Path $DestinoUsuario) {
            Write-Host "Pasta $DestinoUsuario ja existe, recriando do zero..."
            Remove-Item $DestinoUsuario -Recurse -Force
        }

        New-Item -ItemType Directory -Path $DestinoUsuario -Force | Out-Null
        Write-Host "Copiando arquivos do runtime para $DestinoUsuario ..."
        Copy-Item "$OrigemCodesys\*" $DestinoUsuario -Recurse -Force

        # 5. WorkingDirectory exclusiva: NAO criar a pasta aqui. O runtime
        # CODESYS a cria na primeira execucao, copiando o conteudo de
        # AppDataFiles\CODESYSControlWinV3x64 (WorkingDirectorySrc) - inclusive
        # o NodeName e a porta configurados abaixo. Se a pasta ja existir
        # (vazia) antes da primeira execucao, essa copia inicial e pulada e o
        # runtime usa valores padrao (NodeName = nome do computador).

        # 6. Ajusta [SysFile] Windows.WorkingDirectory no CODESYSControl.cfg principal
        if (Test-Path $CfgRaiz) {
            $Conteudo = Get-Content $CfgRaiz -Raw

            if ($Conteudo -match '(?m)^Windows\.WorkingDirectory=.*$') {
                # Chave ja existe: substitui o valor
                $Conteudo = $Conteudo -replace '(?m)^Windows\.WorkingDirectory=.*$', "Windows.WorkingDirectory=$WorkingDir"
            }
            elseif ($Conteudo -match '(?m)^\[SysFile\]') {
                # Secao [SysFile] existe mas sem a chave: insere apos o cabecalho da secao
                $Conteudo = $Conteudo -replace '(?m)^\[SysFile\]\s*$', "[SysFile]`r`nWindows.WorkingDirectory=$WorkingDir"
            }
            else {
                # Nem secao nem chave existem: cria ambos no final do arquivo
                $Conteudo += "`r`n[SysFile]`r`nWindows.WorkingDirectory=$WorkingDir`r`n"
            }

            Set-Content -Path $CfgRaiz -Value $Conteudo -Encoding ASCII
            Write-Host "WorkingDirectory configurado: $WorkingDir"
        }
        else {
            Write-Warning "Arquivo nao encontrado: $CfgRaiz"
        }

        # 7. Ajusta [SysTarget] NodeName no template de configuracao do runtime
        if (Test-Path $CfgTemplate) {
            Set-CodesysTarget -CfgPath $CfgTemplate -NodeName $Usuario -Port $PortaWebServer
            Write-Host "NodeName configurado: $Usuario (webserver na porta $PortaWebServer)"
        }
        else {
            Write-Warning "Arquivo nao encontrado: $CfgTemplate"
        }

        # 8 e 9. Cria o atalho .bat na Area de Trabalho do usuario
        if (Test-Path $Desktop) {
            $Exe = Join-Path $DestinoUsuario "CODESYSControlService.exe"

            @"
@echo off
cd /d "$DestinoUsuario"
start "" "$Exe" -d "$CfgRaiz"
exit
"@ | Set-Content -Path $BatFile -Encoding ASCII

            Write-Host "Atalho criado: $BatFile"

            # 10. Copia o atalho do VSCode para a Area de Trabalho da bancada
            $VSCodeLnkOrigem = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Visual Studio Code\Visual Studio Code.lnk"
            $VSCodeLnkDestino = Join-Path $Desktop "Visual Studio Code.lnk"
            if (Test-Path $VSCodeLnkOrigem) {
                Copy-Item $VSCodeLnkOrigem $VSCodeLnkDestino -Force
                Write-Host "Atalho do VSCode copiado: $VSCodeLnkDestino"
            }
            else {
                Write-Warning "Atalho do VSCode nao encontrado em: $VSCodeLnkOrigem"
            }
        }
        else {
            Write-Warning "Area de trabalho nao encontrada para o usuario $Usuario ($Desktop). O perfil so e criado no primeiro logon - execute este script novamente apos o primeiro logon de cada bancada."
        }

        Write-Host "$Usuario configurado com sucesso."
    }
    catch {
        Write-Warning "Falha ao configurar $Usuario : $($_.Exception.Message)"
    }

    $indice++
}

# ---------------------------------------------------------------------------
# Instancia do professor (instalacao base GatewayPLC)
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "--- Configurando instancia do professor (instalacao base) ---"

$PortaProfessor = $PortaWebServerBase + $Usuarios.Count

# Template usado na primeira execucao do servico (cobre tambem maquinas
# novas, onde o servico "CODESYS Control Win V3 - x64" ainda nunca rodou)
$CfgTemplateProfessor = Join-Path $OrigemCodesys "AppDataFiles\CODESYSControlWinV3x64\CODESYSControl.cfg"
if (Test-Path $CfgTemplateProfessor) {
    Set-CodesysTarget -CfgPath $CfgTemplateProfessor -NodeName 'professor' -Port $PortaProfessor
    Write-Host "Template do professor atualizado: NodeName=professor (webserver na porta $PortaProfessor)"
}
else {
    Write-Warning "Arquivo nao encontrado: $CfgTemplateProfessor"
}

# Perfis ja inicializados (maquina onde o servico ja rodou ao menos uma vez)
$PerfisExistentes = Get-ChildItem "$env:windir\System32\config\systemprofile\AppData\Roaming\CODESYS\CODESYSControlWinV3x64" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName "CODESYSControl.cfg" } |
    Where-Object { Test-Path $_ }

foreach ($cfg in $PerfisExistentes) {
    Set-CodesysTarget -CfgPath $cfg -NodeName 'professor' -Port $PortaProfessor
    Write-Host "Perfil ja inicializado atualizado: $cfg"
}

# Ajusta tambem o CODESYSControl.cfg na raiz do GatewayPLC - e o arquivo
# passado via "-d" pelo atalho .bat do professor (Iniciar_ControlWin_Professor.bat).
# Sem isso, o NodeName so seria aplicado depois que o runtime copiar o
# template de AppDataFiles para a WorkingDirectory do usuario que executar
# o .bat (1a execucao), e enquanto isso o Gateway mostra o nome do
# computador (ex.: FEELT-LASEC) em vez de "professor".
$CfgRaizProfessor = Join-Path $OrigemCodesys "CODESYSControl.cfg"
if (Test-Path $CfgRaizProfessor) {
    Set-CodesysTarget -CfgPath $CfgRaizProfessor -NodeName 'professor' -Port $PortaProfessor
    Write-Host "CODESYSControl.cfg (raiz) atualizado: NodeName=professor (webserver na porta $PortaProfessor)"
}
else {
    Write-Warning "Arquivo nao encontrado: $CfgRaizProfessor"
}

# Perfil do Administrator, caso o .bat do professor ja tenha sido executado
# ao menos uma vez (cria C:\Users\Administrator\AppData\Roaming\CODESYS\CODESYSControlWinV3x64\*)
$PerfilAdminProfessor = Get-ChildItem "C:\Users\Administrator\AppData\Roaming\CODESYS\CODESYSControlWinV3x64" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName "CODESYSControl.cfg" } |
    Where-Object { Test-Path $_ }

foreach ($cfg in $PerfilAdminProfessor) {
    Set-CodesysTarget -CfgPath $cfg -NodeName 'professor' -Port $PortaProfessor
    Write-Host "Perfil do Administrator atualizado: $cfg"
}

# Mantem o servico "CODESYS Control Win V3 - x64" como inicializacao manual
# e parado: igual as bancadas, o professor inicia sua instancia pelo atalho
# .bat na Area de Trabalho.
$ServicoControlWin = Get-Service -Name 'CODESYS Control Win V3 - x64' -ErrorAction SilentlyContinue
if ($ServicoControlWin) {
    Set-Service -Name 'CODESYS Control Win V3 - x64' -StartupType Manual
    if ($ServicoControlWin.Status -eq 'Running') {
        Stop-Service -Name 'CODESYS Control Win V3 - x64' -Force
    }
    Write-Host "Servico 'CODESYS Control Win V3 - x64' definido como manual e parado."
}
else {
    Write-Warning "Servico 'CODESYS Control Win V3 - x64' nao encontrado."
}

# Atalho .bat na Area de Trabalho do Administrator (NAO na Area de Trabalho
# Publica - esta e compartilhada por todas as sessoes RDS e o atalho do
# professor apareceria tambem para os alunos), para iniciar a instancia do
# professor manualmente.
$DesktopAdmin = "C:\Users\Administrator\Desktop"
$BatFileProfessor = Join-Path $DesktopAdmin "Iniciar_ControlWin_Professor.bat"
$ExeProfessor = Join-Path $OrigemCodesys "CODESYSControlService.exe"
$CfgProfessor = Join-Path $OrigemCodesys "CODESYSControl.cfg"

if (Test-Path $DesktopAdmin) {
    @"
@echo off
cd /d "$OrigemCodesys"
start "" "$ExeProfessor" -d "$CfgProfessor"
exit
"@ | Set-Content -Path $BatFileProfessor -Encoding ASCII

    Write-Host "Atalho criado: $BatFileProfessor"
}
else {
    Write-Warning "Area de trabalho do Administrator nao encontrada: $DesktopAdmin"
}

# Remove atalho antigo, criado por versoes anteriores deste script na Area de
# Trabalho Publica (ficava visivel para todos os alunos).
$BatFileProfessorPublicoAntigo = "C:\Users\Public\Desktop\Iniciar_ControlWin_Professor.bat"
if (Test-Path $BatFileProfessorPublicoAntigo) {
    Remove-Item $BatFileProfessorPublicoAntigo -Force
    Write-Host "Atalho antigo removido da Area de Trabalho Publica: $BatFileProfessorPublicoAntigo"
}

# ---------------------------------------------------------------------------
# Resumo final
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=== Configuracao concluida ==="
Write-Host "Instancias criadas em: $BaseDestino"
Write-Host "Total de bancadas processadas: $($Usuarios.Count)"
