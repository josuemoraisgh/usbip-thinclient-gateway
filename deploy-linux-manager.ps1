#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Faz deploy do USB/IP Manager em thin clients Linux via SSH a partir do Windows Server.

.DESCRIPTION
    Para cada thin client informado: faz upload do linux-usbip-manager/ via SCP,
    executa uninstall.sh e depois install.sh.
    Requer plink/pscp (PuTTY) em PATH ou no mesmo diretório do script.

.PARAMETER ThinClients
    Lista de IPs das thin clients. Ex: -ThinClients "192.168.100.31","192.168.100.32"
    Ou use -ConfigFile para carregar de um arquivo.

.PARAMETER Password
    Senha root (mesma para todas as thin clients).
    Se omitida, será pedida interativamente.

.PARAMETER ConfigFile
    Arquivo CSV com colunas "ip,password" para senhas diferentes por host.
    Ex:  192.168.100.31,senhaA
         192.168.100.32,senhaB

.PARAMETER ServerIP
    IP do Windows Server enviado ao install.sh como --server-ip e --notify-host.
    Padrão: detectado automaticamente pela interface de rede.

.PARAMETER NotifyPort
    Porta TCP do broker Windows. Padrão: 12000.

.PARAMETER RemoteDir
    Diretório temporário de upload nas thin clients. Padrão: /tmp/usbip-deploy.

.PARAMETER SkipUninstall
    Pula o uninstall.sh (somente instala/atualiza).

.PARAMETER KeepConfig
    Passa --keep-config ao uninstall.sh para preservar config.json.

.PARAMETER Force
    Não pede confirmação antes de iniciar.

.EXAMPLE
    .\deploy-linux-manager.ps1 -ThinClients "192.168.100.31","192.168.100.32" -Password "minhasenha"

.EXAMPLE
    .\deploy-linux-manager.ps1 -ConfigFile .\hosts.csv -ServerIP 192.168.100.10

.EXAMPLE
    .\deploy-linux-manager.ps1 -ThinClients "192.168.100.31" -SkipUninstall -Force
#>

[CmdletBinding()]
param(
    [string[]]$ThinClients,
    [string]$Password,
    [string]$ConfigFile,
    [string]$ServerIP,
    [string]$NotifyPort = "12000",
    [string]$RemoteDir  = "/tmp/usbip-deploy",
    [switch]$SkipUninstall,
    [switch]$KeepConfig,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ─── Cores / helpers ──────────────────────────────────────────────────────────

function Write-Step   { param($m) Write-Host "  --> $m" -ForegroundColor Cyan }
function Write-OK     { param($m) Write-Host "  [OK]  $m" -ForegroundColor Green }
function Write-Fail   { param($m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Warn   { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Header { param($m) Write-Host "`n=== $m ===" -ForegroundColor White }

# ─── Localizar plink / pscp ───────────────────────────────────────────────────

function Find-PuttyTool {
    param([string]$Name)
    $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
    $candidates = @(
        (Join-Path $scriptDir "${Name}.exe"),
        "C:\Program Files\PuTTY\${Name}.exe",
        "C:\Program Files (x86)\PuTTY\${Name}.exe",
        "$env:LOCALAPPDATA\Programs\PuTTY\${Name}.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $inPath = Get-Command "${Name}.exe" -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    return $null
}

$plink = Find-PuttyTool "plink"
$pscp  = Find-PuttyTool "pscp"

if (-not $plink -or -not $pscp) {
    Write-Host @"

ERRO: plink.exe e/ou pscp.exe (PuTTY) nao encontrados.

Instale o PuTTY em: https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html
  ou via winget:  winget install PuTTY.PuTTY

Apos instalar, adicione ao PATH ou coloque plink.exe e pscp.exe na mesma pasta deste script.
"@ -ForegroundColor Red
    exit 1
}

Write-OK "plink : $plink"
Write-OK "pscp  : $pscp"

# ─── Diretório do linux-usbip-manager ─────────────────────────────────────────

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$managerDir  = Join-Path $scriptDir "linux-usbip-manager"

if (-not (Test-Path -LiteralPath (Join-Path $managerDir "install.sh"))) {
    Write-Fail "linux-usbip-manager\install.sh nao encontrado em '$managerDir'."
    exit 1
}

# ─── Carregar lista de hosts ───────────────────────────────────────────────────

$hosts = @()   # array de @{IP=...; Password=...}

if ($ConfigFile) {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        Write-Fail "ConfigFile nao encontrado: $ConfigFile"
        exit 1
    }
    Import-Csv -Path $ConfigFile -Header "ip","password" | ForEach-Object {
        if ($_.ip -match '^\s*#') { return }   # ignora comentarios
        $hosts += @{ IP = $_.ip.Trim(); Password = $_.password.Trim() }
    }
} elseif ($ThinClients) {
    if (-not $Password) {
        $secPwd = Read-Host "Senha root dos thin clients" -AsSecureString
        $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPwd))
    }
    foreach ($ip in $ThinClients) {
        $hosts += @{ IP = $ip.Trim(); Password = $Password }
    }
} else {
    Write-Fail "Informe -ThinClients ou -ConfigFile."
    Write-Host "Use:  .\deploy-linux-manager.ps1 -ThinClients '192.168.100.31','192.168.100.32' -Password 'senha'"
    exit 1
}

if ($hosts.Count -eq 0) {
    Write-Fail "Nenhum host encontrado."
    exit 1
}

# ─── Detectar IP do servidor Windows ──────────────────────────────────────────

if (-not $ServerIP) {
    $ServerIP = (
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
        Select-Object -First 1 -ExpandProperty IPAddress
    )
    if (-not $ServerIP) { $ServerIP = "0.0.0.0" }
    Write-Warn "ServerIP nao informado. Detectado: $ServerIP  (use -ServerIP se estiver errado)"
}

# ─── Resumo e confirmacao ─────────────────────────────────────────────────────

Write-Host "`n=============================================" -ForegroundColor White
Write-Host "  USB/IP Manager - Deploy para thin clients" -ForegroundColor White
Write-Host "=============================================" -ForegroundColor White
Write-Host "  Hosts         : $($hosts.Count)"
Write-Host "  Server IP     : $ServerIP"
Write-Host "  Notify Port   : $NotifyPort"
Write-Host "  Diretorio src : $managerDir"
Write-Host "  Skip uninstall: $SkipUninstall"
Write-Host "  Keep config   : $KeepConfig"
Write-Host ""
$hosts | ForEach-Object { Write-Host "    $($_.IP)" }
Write-Host ""

if (-not $Force) {
    $resp = Read-Host "Continuar? [s/N]"
    if ($resp -notmatch '^[sS]') { Write-Host "Cancelado."; exit 0 }
}

# ─── Funções SSH / SCP ────────────────────────────────────────────────────────

function Invoke-SSH {
    param([string]$IP, [string]$Pwd, [string]$Command, [int]$TimeoutSec = 120)
    $args = @(
        "-ssh", "-pw", $Pwd,
        "-batch",
        "-hostkey", "*",
        "root@${IP}",
        $Command
    )
    $proc = Start-Process -FilePath $plink -ArgumentList $args `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput "$env:TEMP\plink_out_${IP}.txt" `
        -RedirectStandardError  "$env:TEMP\plink_err_${IP}.txt"

    $out = Get-Content "$env:TEMP\plink_out_${IP}.txt" -ErrorAction SilentlyContinue
    $err = Get-Content "$env:TEMP\plink_err_${IP}.txt" -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\plink_out_${IP}.txt","$env:TEMP\plink_err_${IP}.txt" -ErrorAction SilentlyContinue

    return @{ ExitCode = $proc.ExitCode; Stdout = $out; Stderr = $err }
}

function Invoke-SCP {
    param([string]$IP, [string]$Pwd, [string]$LocalPath, [string]$RemotePath)
    $args = @(
        "-pw", $Pwd,
        "-batch",
        "-hostkey", "*",
        "-r",
        $LocalPath,
        "root@${IP}:${RemotePath}"
    )
    $proc = Start-Process -FilePath $pscp -ArgumentList $args `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput "$env:TEMP\pscp_out_${IP}.txt" `
        -RedirectStandardError  "$env:TEMP\pscp_err_${IP}.txt"

    $out = Get-Content "$env:TEMP\pscp_out_${IP}.txt" -ErrorAction SilentlyContinue
    $err = Get-Content "$env:TEMP\pscp_err_${IP}.txt" -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\pscp_out_${IP}.txt","$env:TEMP\pscp_err_${IP}.txt" -ErrorAction SilentlyContinue

    return @{ ExitCode = $proc.ExitCode; Stdout = $out; Stderr = $err }
}

function Show-Result {
    param($result, [string]$label)
    if ($result.Stdout) { $result.Stdout | ForEach-Object { Write-Host "    | $_" } }
    if ($result.Stderr) { $result.Stderr | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host "    ! $_" -ForegroundColor DarkYellow } }
}

# ─── Deploy por host ──────────────────────────────────────────────────────────

$results = @{}

foreach ($node in $hosts) {
    $ip  = $node.IP
    $pwd = $node.Password

    Write-Header "[$ip]"

    # 1. Teste de conectividade
    Write-Step "Testando conexao SSH..."
    $test = Invoke-SSH -IP $ip -Pwd $pwd -Command "echo pong" -TimeoutSec 15
    if ($test.ExitCode -ne 0) {
        Write-Fail "Nao foi possivel conectar em $ip (exit $($test.ExitCode))"
        Show-Result $test "conexao"
        $results[$ip] = "FALHA_CONEXAO"
        continue
    }
    Write-OK "SSH OK"

    # 2. Upload dos arquivos
    Write-Step "Enviando linux-usbip-manager/ para ${ip}:$RemoteDir ..."
    $sshMkdir = Invoke-SSH -IP $ip -Pwd $pwd -Command "rm -rf '$RemoteDir' ; mkdir -p '$RemoteDir'"
    if ($sshMkdir.ExitCode -ne 0) {
        Write-Fail "Erro ao criar diretorio remoto."
        Show-Result $sshMkdir "mkdir"
        $results[$ip] = "FALHA_MKDIR"
        continue
    }

    $scpResult = Invoke-SCP -IP $ip -Pwd $pwd -LocalPath "$managerDir\*" -RemotePath $RemoteDir
    if ($scpResult.ExitCode -ne 0) {
        Write-Fail "Erro no upload SCP (exit $($scpResult.ExitCode))."
        Show-Result $scpResult "scp"
        $results[$ip] = "FALHA_UPLOAD"
        continue
    }
    Write-OK "Upload concluido"

    # Tornar scripts executaveis
    Invoke-SSH -IP $ip -Pwd $pwd -Command "chmod +x '$RemoteDir'/*.sh '$RemoteDir'/bin/* 2>/dev/null || true" | Out-Null

    # 3. Desinstalar (opcional)
    if (-not $SkipUninstall) {
        Write-Step "Executando uninstall.sh..."
        $uninstArgs = "--force"
        if ($KeepConfig) { $uninstArgs += " --keep-config" }
        $uninstResult = Invoke-SSH -IP $ip -Pwd $pwd `
            -Command "bash '$RemoteDir/uninstall.sh' $uninstArgs 2>&1" `
            -TimeoutSec 60
        Show-Result $uninstResult "uninstall"
        if ($uninstResult.ExitCode -ne 0) {
            Write-Warn "uninstall.sh retornou exit $($uninstResult.ExitCode) - continuando mesmo assim."
        } else {
            Write-OK "Desinstalacao concluida"
        }
    }

    # 4. Instalar
    Write-Step "Executando install.sh --server-ip $ServerIP --notify-port $NotifyPort ..."
    $installCmd = "bash '$RemoteDir/install.sh' --server-ip '$ServerIP' --notify-host '$ServerIP' --notify-port '$NotifyPort' 2>&1"
    $installResult = Invoke-SSH -IP $ip -Pwd $pwd -Command $installCmd -TimeoutSec 180
    Show-Result $installResult "install"

    if ($installResult.ExitCode -ne 0) {
        Write-Fail "install.sh falhou com exit $($installResult.ExitCode)."
        $results[$ip] = "FALHA_INSTALL"
    } else {
        Write-OK "Instalacao concluida com sucesso!"
        $results[$ip] = "OK"
    }

    # 5. Limpar arquivos temporarios remotos
    Invoke-SSH -IP $ip -Pwd $pwd -Command "rm -rf '$RemoteDir'" | Out-Null
}

# ─── Resumo final ─────────────────────────────────────────────────────────────

Write-Host "`n=============================================" -ForegroundColor White
Write-Host "  Resultado do deploy" -ForegroundColor White
Write-Host "=============================================" -ForegroundColor White

$ok   = 0
$fail = 0
foreach ($entry in $results.GetEnumerator() | Sort-Object Name) {
    if ($entry.Value -eq "OK") {
        Write-Host ("  {0,-18}  OK" -f $entry.Name) -ForegroundColor Green
        $ok++
    } else {
        Write-Host ("  {0,-18}  {1}" -f $entry.Name, $entry.Value) -ForegroundColor Red
        $fail++
    }
}

Write-Host ""
Write-Host ("  Total: " + $hosts.Count + "  |  Sucesso: $ok  |  Falha: $fail")
Write-Host ""

if ($fail -gt 0) { exit 1 } else { exit 0 }
