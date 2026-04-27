# Executa o diagnóstico usbipd remoto via PuTTY (plink/pscp) e salva o resultado local
# Uso: powershell -ExecutionPolicy Bypass -File .\diagnostic-usbipd-windows.ps1 -Target 10.0.64.5 -Password "senha"

param(
    [string]$Target = "10.0.64.5",
    [string]$Password = "armbian",
    [string]$User = "root",
    [string]$RemoteDir = "/tmp/usbip-deploy",
    [string]$LocalDir = "."
)

$plink = "C:\Program Files\PuTTY\plink.exe"
$pscp  = "C:\Program Files\PuTTY\pscp.exe"

Write-Host "[0/3] Enviando diagnostic-usbipd.sh para $Target..."
& $plink -ssh -pw $Password $User@$Target "mkdir -p $RemoteDir" | Out-Null
& $pscp -pw $Password "linux-usbip-manager/diagnostic-usbipd.sh" ($User + "@" + $Target + ":" + $RemoteDir + "/diagnostic-usbipd.sh")

Write-Host "[1/3] Executando diagnóstico usbipd remoto em $Target..."
& $plink -ssh -pw $Password $User@$Target "cd $RemoteDir && tr -d '\r' < diagnostic-usbipd.sh > diagnostic-usbipd.sh.lf && mv diagnostic-usbipd.sh.lf diagnostic-usbipd.sh && chmod +x diagnostic-usbipd.sh && sudo bash diagnostic-usbipd.sh > diag-usbipd.txt 2>&1" | Out-Null

Write-Host "[2/3] Baixando diag-usbipd.txt para $LocalDir..."
& $pscp -pw $Password ($User + "@" + $Target + ":" + $RemoteDir + "/diag-usbipd.txt") ($LocalDir + "\diag-usbipd-" + $Target + ".txt")

Write-Host "[3/3] Diagnóstico salvo em $LocalDir\diag-usbipd-$Target.txt"
