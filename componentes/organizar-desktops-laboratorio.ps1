#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Deixa o Desktop do professor minimo e agrupa aplicativos nos Desktops das bancadas.
#>

[CmdletBinding()]
param(
    [string]$BasePath = 'C:\config\desktop-laboratorio',
    [string]$AdministratorDesktop = 'C:\Users\Administrator\Desktop'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
$shortcutStore = Join-Path $BasePath 'Aplicativos do Laboratorio'
$userSetupSource = Join-Path $PSScriptRoot 'Configurar-Desktop-Laboratorio-Usuario.ps1'
$userSetupDestination = Join-Path $BasePath 'Configurar-Desktop-Laboratorio-Usuario.ps1'
$usefulPublicShortcuts = @(
    'CODESYS V3.5 SP21.lnk',
    'LibreOffice 26.2.lnk',
    'Microsoft Edge.lnk',
    'PACTware 5.0.lnk',
    'Process Simul.lnk',
    'SimulIDE.lnk'
)
$unnecessaryPublicShortcuts = @(
    'NVIDIA App.lnk'
)

foreach ($path in @($BasePath, $shortcutStore, $AdministratorDesktop)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $userSetupSource)) {
    throw "Script de configuracao por usuario nao encontrado: $userSetupSource"
}

Copy-Item -LiteralPath $userSetupSource -Destination $userSetupDestination -Force

foreach ($name in $usefulPublicShortcuts) {
    $source = Join-Path $publicDesktop $name
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $shortcutStore $name) -Force
        Remove-Item -LiteralPath $source -Force
    }
}

foreach ($name in $unnecessaryPublicShortcuts) {
    $path = Join-Path $publicDesktop $name
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

Get-ChildItem 'C:\Users' -Directory -Filter 'bancada*' -ErrorAction SilentlyContinue |
    ForEach-Object {
        $desktop = Join-Path $_.FullName 'Desktop'
        if (-not (Test-Path -LiteralPath $desktop)) {
            return
        }

        $destination = Join-Path $desktop 'Aplicativos do Laboratorio'
        New-Item -ItemType Directory -Path $destination -Force | Out-Null

        Get-ChildItem -LiteralPath $shortcutStore -File -Force |
            ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destination $_.Name) -Force
            }

        foreach ($name in @($usefulPublicShortcuts + $unnecessaryPublicShortcuts)) {
            $obsoletePath = Join-Path $desktop $name
            if (Test-Path -LiteralPath $obsoletePath) {
                Remove-Item -LiteralPath $obsoletePath -Force
            }
        }
    }

$runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runCommand = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f
    $userSetupDestination
New-ItemProperty -Path $runKey -Name 'Desktop-Laboratorio-Usuario' -Value $runCommand -PropertyType String -Force |
    Out-Null

& icacls.exe $BasePath /inheritance:r `
    /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /Q |
    Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao proteger $BasePath."
}
& icacls.exe (Join-Path $BasePath '*') /reset /T /Q | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao propagar permissoes em $BasePath."
}

Write-Host 'Desktop do Administrator preservado com seus atalhos proprios.'
Write-Host 'Atalhos gerais agrupados em Aplicativos do Laboratorio para as bancadas.'
