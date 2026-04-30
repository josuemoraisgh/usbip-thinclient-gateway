Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$thinClients = @(
    "10.0.64.4",
    "10.0.64.5",
    "10.0.64.6",
    "10.0.64.8",
    "10.0.67.196",
    "10.0.67.171",
    "10.0.64.3",
    "10.0.64.10",
    "10.0.64.12",
    "10.0.64.14",
    "10.0.64.17",
    "10.0.64.20",
    "10.0.64.21",
    "10.0.64.23",
    "10.0.64.24",
    "10.0.64.27"
)

$serverIp = "10.0.64.28"
$password = "armbian"
$usbipPath = "C:\Program Files\Usbip\usbip.exe"
$msiPath = Join-Path $PSScriptRoot "windows-usbip-broker-cpp\build\UsbipSuite-2.0.0-x64.msi"
$thinClientsCsv = $thinClients -join ","

Write-Host ""
Write-Host "==> Instalando USB/IP Suite no Windows Server..."
if (-not (Test-Path -LiteralPath $msiPath)) {
    throw "MSI nao encontrado em '$msiPath'."
}

if (-not (Test-Path -LiteralPath $usbipPath)) {
    Write-Warning "usbip.exe nao encontrado em '$usbipPath'. Ajuste a variavel `$usbipPath antes de continuar, se necessario."
}

$msiArgs = @(
    "/i"
    $msiPath
    "THINCLIENTS=$thinClientsCsv"
    "USBIPPATH=$usbipPath"
)

Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -NoNewWindow

Write-Host ""
Write-Host "==> Instalando sincronizador leve do estado do Tray..."
& (Join-Path $PSScriptRoot "windows-usbip-broker-cpp\install-state-sync.ps1")

Write-Host ""
Write-Host "==> Fazendo deploy do linux-usbip-manager nas thin clients..."
& (Join-Path $PSScriptRoot "deploy-linux-manager.ps1") `
    -ThinClients $thinClients `
    -Password $password `
    -ServerIP $serverIp `
    -Force

Write-Host ""
Write-Host "Processo concluido."
