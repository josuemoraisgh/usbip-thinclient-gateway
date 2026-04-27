# Executa o diagnóstico remoto via PuTTY (plink/pscp) e salva o resultado local
# Uso: powershell -ExecutionPolicy Bypass -File .\diagnostic-windows.ps1 -Host 10.0.64.5 -Password "senha"


param(
    [string]$Target = "10.0.64.5",
    [string]$Password = "armbian",
    [string]$User = "root",
    [string]$RemoteDir = "/tmp/usbip-deploy",
    [string]$LocalDir = "."
)

$plink = "C:\Program Files\PuTTY\plink.exe"
$pscp  = "C:\Program Files\PuTTY\pscp.exe"

Write-Host "[0/3] Enviando diagnostic.sh para $Target..."
& $plink -ssh -pw $Password $User@$Target "mkdir -p $RemoteDir" | Out-Null
& $pscp -pw $Password "linux-usbip-manager/diagnostic.sh" ($User + "@" + $Target + ":" + $RemoteDir + "/diagnostic.sh")

Write-Host "[1/3] Executando diagnóstico remoto em $Target..."
& $plink -ssh -pw $Password $User@$Target "cd $RemoteDir && tr -d '\r' < diagnostic.sh > diagnostic.sh.lf && mv diagnostic.sh.lf diagnostic.sh && chmod +x diagnostic.sh && sudo bash diagnostic.sh" | Out-Null

Write-Host "[2/3] Baixando diag.txt para $LocalDir..."
& $pscp -pw $Password ($User + "@" + $Target + ":" + $RemoteDir + "/diag.txt") ($LocalDir + "\diag-" + $Target + ".txt")

Write-Host "[3/3] Diagnóstico salvo em $LocalDir\diag-$Target.txt"
