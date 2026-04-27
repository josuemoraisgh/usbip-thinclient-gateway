<#
.SYNOPSIS
    Deploy em massa do UsbipSuite-2.0.0-x64.msi para múltiplos thin clients Windows.

.DESCRIPTION
    Copia o MSI para cada máquina e executa a instalação remota via PowerShell Remoting (WinRM).
    Requer que o WinRM esteja habilitado nos thin clients (Enable-PSRemoting).

.EXAMPLE
    # Deploy padrão (usa IPs do bloco definido em $ThinClients)
    .\deploy-thinclients.ps1

.EXAMPLE
    # Testar conectividade antes de instalar
    .\deploy-thinclients.ps1 -TestOnly

.EXAMPLE
    # Forçar reinstalação mesmo que já instalado
    .\deploy-thinclients.ps1 -Force
#>

param(
    [switch]$TestOnly,
    [switch]$Force,
    [string]$UsbipPath = "C:\usbip\usbip.exe",
    [int]$MaxParallel = 5
)

$ErrorActionPreference = "Stop"

# ═══════════════════════════════════════════════════════════════
#  CONFIGURAÇÃO — ajuste aqui os IPs e credenciais
# ═══════════════════════════════════════════════════════════════

# Opção A: Range contínuo (ex: .31 até .52 = 22 máquinas)
$IpBase  = "192.168.100"
$IpStart = 31
$IpEnd   = 52   # ajuste para o último IP

$ThinClients = $IpStart..$IpEnd | ForEach-Object { "$IpBase.$_" }

# Opção B: Lista manual — descomente e edite se os IPs não forem sequenciais
# $ThinClients = @(
#     "192.168.100.31",
#     "192.168.100.35",
#     "192.168.100.40",
#     "192.168.100.45"
# )

# Credencial de administrador local dos thin clients
# Deixe $null para usar a sessão atual (domínio / conta logada)
$AdminUser     = "Administrator"   # ou "DOMINIO\usuario"
$AdminPassword = "SuaSenhaAqui"    # altere ou use $null para credencial atual

# Caminho do MSI nesta máquina (de onde o script é executado)
$MsiSource = Join-Path $PSScriptRoot "build\UsbipSuite-2.0.0-x64.msi"

# Destino temporário em cada thin client
$MsiRemotePath = "C:\Temp\UsbipSuite-2.0.0-x64.msi"

# ═══════════════════════════════════════════════════════════════

if (-not (Test-Path -LiteralPath $MsiSource)) {
    Write-Error "MSI não encontrado em: $MsiSource`nExecute .\build.ps1 antes."
}

$Credential = $null
if ($AdminPassword -and $AdminPassword -ne "SuaSenhaAqui") {
    $SecPass    = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
    $Credential = New-Object System.Management.Automation.PSCredential ($AdminUser, $SecPass)
}

$Results = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

Write-Host "`n=== Deploy UsbipSuite para $($ThinClients.Count) thin clients ===" -ForegroundColor Cyan
Write-Host "MSI: $MsiSource"
Write-Host "UsbipPath remoto: $UsbipPath"
Write-Host "Paralelismo: $MaxParallel jobs`n"

# ── Função executada em cada job paralelo ───────────────────────
$DeployBlock = {
    param($ip, $msiSource, $msiRemote, $usbipPath, $cred, $force)

    $status = [PSCustomObject]@{ IP = $ip; Status = ""; Detalhes = "" }

    try {
        # 1. Verificar ping
        if (-not (Test-Connection -ComputerName $ip -Count 1 -Quiet)) {
            $status.Status   = "OFFLINE"
            $status.Detalhes = "Ping falhou"
            return $status
        }

        if ($using:TestOnly) {
            $status.Status = "ONLINE"
            return $status
        }

        # 2. Copiar MSI via compartilhamento admin$
        $copyParams = @{ Path = $msiSource; Destination = "\\$ip\C$\Temp\" }
        if ($cred) { $copyParams.Credential = $cred }

        New-Item -Path "\\$ip\C$\Temp" -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item @copyParams -Force

        # 3. Instalar remotamente via WinRM
        $invokeParams = @{
            ComputerName = $ip
            ScriptBlock  = {
                param($msi, $usbip, $force)
                $logFile = "C:\Temp\usbip_install.log"
                $args = @("/i", $msi, "USBIPPATH=$usbip", "/qn", "/l*v", $logFile)
                if ($force) { $args += "REINSTALL=ALL" ; $args += "REINSTALLMODE=vomus" }
                $p = Start-Process msiexec -ArgumentList $args -Wait -PassThru
                return @{ ExitCode = $p.ExitCode; Log = $logFile }
            }
            ArgumentList = $msiRemote, $usbipPath, $force
        }
        if ($cred) { $invokeParams.Credential = $cred }

        $result = Invoke-Command @invokeParams

        if ($result.ExitCode -eq 0 -or $result.ExitCode -eq 3010) {
            $status.Status   = if ($result.ExitCode -eq 3010) { "OK (reboot)" } else { "OK" }
            $status.Detalhes = "Log: $($result.Log)"
        } else {
            $status.Status   = "ERRO"
            $status.Detalhes = "msiexec ExitCode=$($result.ExitCode) | Log: $($result.Log)"
        }
    }
    catch {
        $status.Status   = "ERRO"
        $status.Detalhes = $_.Exception.Message
    }

    return $status
}

# ── Execução paralela com throttle ──────────────────────────────
$jobs = @()
foreach ($ip in $ThinClients) {
    # Aguardar slot livre
    while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxParallel) {
        Start-Sleep -Milliseconds 500
    }

    Write-Host "  Iniciando: $ip" -ForegroundColor Gray
    $jobs += Start-Job -ScriptBlock $DeployBlock -ArgumentList `
        $ip, $MsiSource, $MsiRemotePath, $UsbipPath, $Credential, $Force.IsPresent
}

Write-Host "`nAguardando todos os jobs..." -ForegroundColor Yellow
$jobs | Wait-Job | Out-Null

# ── Coletar resultados ───────────────────────────────────────────
$allResults = $jobs | Receive-Job
$jobs | Remove-Job

Write-Host "`n═══════════════ RESULTADO ═══════════════" -ForegroundColor Cyan
$allResults | Sort-Object IP | Format-Table -AutoSize -Property `
    @{L="IP";          E={$_.IP}},
    @{L="Status";      E={$_.Status}; Width=12},
    @{L="Detalhes";    E={$_.Detalhes}}

$ok    = ($allResults | Where-Object Status -like "OK*").Count
$error = ($allResults | Where-Object Status -eq "ERRO").Count
$off   = ($allResults | Where-Object Status -eq "OFFLINE").Count

Write-Host "Sucesso: $ok  |  Erro: $error  |  Offline: $off  |  Total: $($ThinClients.Count)" -ForegroundColor Cyan

# ── Salvar relatório CSV ─────────────────────────────────────────
$csvPath = Join-Path $PSScriptRoot "deploy-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$allResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "Relatório salvo em: $csvPath`n"
