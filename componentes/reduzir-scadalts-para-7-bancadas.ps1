#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Remove as instancias Scada-LTS das 16 bancadas 204b e deixa somente 204a-01..07.

.DESCRIPTION
Esta operacao remove permanentemente os servicos, schemas MySQL, usuarios
MySQL e diretorios das bancadas 204b. As sete bancadas 204a sao preservadas.
Ao final, MySQL e todos os servicos Scada-LTS ficam parados e manuais.
#>

[CmdletBinding()]
param(
    [string]$BasePath = 'C:\config\scadalts',
    [string]$ScadaInstallPath = 'C:\Program Files\Scada-LTS'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mysqlName = 'MySQL Community Server 8.0'
$instanceRoot = Join-Path $BasePath 'instances'
$mysqlExe = Join-Path $ScadaInstallPath 'mysql\bin\mysql.exe'
$sourceContext = Join-Path $ScadaInstallPath 'tomcat\conf\context.xml'
$defaultsFile = Join-Path $BasePath 'temp\mysql-root-prune.cnf'
$inactiveUsers = @(1..16 | ForEach-Object { 'bancada204b-{0:D2}' -f $_ })
$activeServices = @(1..7 | ForEach-Object { 'ScadaLTS-bancada204a-{0:D2}' -f $_ })

function Write-AsciiFile {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.Encoding]::ASCII)
}

function Get-DatabaseName {
    param([string]$UserName)
    return ('scadalts_{0}' -f ($UserName -replace '[^A-Za-z0-9]', '_').ToLowerInvariant())
}

function Get-DatabaseUserName {
    param([string]$UserName)
    return ('scada_{0}' -f ($UserName -replace '[^A-Za-z0-9]', '_').ToLowerInvariant())
}

$mysqlService = Get-Service -Name $mysqlName -ErrorAction Stop
Set-Service -Name $mysqlName -StartupType Manual
if ($mysqlService.Status -ne 'Running') {
    Start-Service -Name $mysqlName
    $mysqlService.WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
}

$contextXml = [xml](Get-Content -LiteralPath $sourceContext -Raw)
$rootPassword = [string]$contextXml.Context.Resource.password
$escapedPassword = $rootPassword.Replace('\', '\\').Replace('"', '\"')
Write-AsciiFile -Path $defaultsFile -Content @"
[client]
host=127.0.0.1
port=3306
user=root
password="$escapedPassword"
protocol=TCP
"@
& icacls.exe $defaultsFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' /Q | Out-Null

try {
    foreach ($userName in $inactiveUsers) {
        $serviceName = "ScadaLTS-$userName"
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

        if ($service) {
            Write-Host "Removendo servico $serviceName..."
            if ($service.Status -ne 'Stopped') {
                Stop-Service -Name $serviceName -Force
                $service.WaitForStatus('Stopped', [TimeSpan]::FromMinutes(3))
            }
            & sc.exe delete $serviceName | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Falha ao remover o servico $serviceName."
            }
        }

        $databaseName = Get-DatabaseName -UserName $userName
        $databaseUser = Get-DatabaseUserName -UserName $userName
        $sql = "DROP DATABASE IF EXISTS ``$databaseName``; DROP USER IF EXISTS '$databaseUser'@'localhost';"
        & $mysqlExe "--defaults-extra-file=$defaultsFile" "--execute=$sql"
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao remover banco/usuario de $userName."
        }

        $instancePath = Join-Path $instanceRoot $userName
        if (Test-Path -LiteralPath $instancePath) {
            $resolvedRoot = (Resolve-Path -LiteralPath $instanceRoot).Path.TrimEnd('\')
            $resolvedInstance = (Resolve-Path -LiteralPath $instancePath).Path
            if (-not $resolvedInstance.StartsWith("$resolvedRoot\", [StringComparison]::OrdinalIgnoreCase)) {
                throw "Diretorio fora da raiz esperada: $resolvedInstance"
            }
            Remove-Item -LiteralPath $resolvedInstance -Recurse -Force
        }
    }

    foreach ($serviceName in $activeServices) {
        $service = Get-Service -Name $serviceName -ErrorAction Stop
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name $serviceName -Force
            $service.WaitForStatus('Stopped', [TimeSpan]::FromMinutes(3))
        }
        Set-Service -Name $serviceName -StartupType Manual
    }

    $originalService = Get-Service -Name 'Scada-LTS' -ErrorAction SilentlyContinue
    if ($originalService) {
        if ($originalService.Status -ne 'Stopped') {
            Stop-Service -Name 'Scada-LTS' -Force
            $originalService.WaitForStatus('Stopped', [TimeSpan]::FromMinutes(3))
        }
        Set-Service -Name 'Scada-LTS' -StartupType Disabled
    }

    $mysqlService = Get-Service -Name $mysqlName
    if ($mysqlService.Status -ne 'Stopped') {
        Stop-Service -Name $mysqlName -Force
        $mysqlService.WaitForStatus('Stopped', [TimeSpan]::FromMinutes(3))
    }
    Set-Service -Name $mysqlName -StartupType Manual
}
finally {
    $rootPassword = $null
    if (Test-Path -LiteralPath $defaultsFile) {
        Remove-Item -LiteralPath $defaultsFile -Force
    }
}

Write-Host 'Reducao concluida: somente bancada204a-01 ate bancada204a-07 permanecem.' -ForegroundColor Green
Write-Host 'MySQL e todas as instancias Scada-LTS estao parados e manuais.'
