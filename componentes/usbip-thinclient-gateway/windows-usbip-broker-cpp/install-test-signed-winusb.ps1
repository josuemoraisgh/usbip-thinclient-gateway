$ErrorActionPreference = "Stop"

$driverDir = Join-Path $PSScriptRoot "drivers"
$infPath = Join-Path $driverDir "usbip-winusb.inf"
$catPath = Join-Path $driverDir "usbip-winusb.cat"
$certPath = Join-Path $driverDir "UsbipSuiteTestDriverSigning.cer"

if (-not (Test-Path -LiteralPath $infPath)) {
    throw "INF nao encontrado: $infPath"
}
if (-not (Test-Path -LiteralPath $catPath)) {
    throw "CAT nao encontrado: $catPath"
}
if (-not (Test-Path -LiteralPath $certPath)) {
    throw "Certificado nao encontrado: $certPath"
}

Write-Host "Importando certificado de teste..." -ForegroundColor Cyan
Import-Certificate -FilePath $certPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $certPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null

Write-Host "Habilitando Windows test-signing..." -ForegroundColor Cyan
& bcdedit /set testsigning on
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao habilitar testsigning."
}

Write-Host "Instalando driver WinUSB test-signed..." -ForegroundColor Cyan
& pnputil /add-driver $infPath /install
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao instalar driver test-signed."
}

Write-Host ""
Write-Host "Concluido. Se o Windows ainda nao estava em test-signing, reinicie a maquina." -ForegroundColor Yellow
