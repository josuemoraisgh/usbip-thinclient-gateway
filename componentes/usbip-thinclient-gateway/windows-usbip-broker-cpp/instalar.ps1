param(
    [string[]]$ThinClients = (31..52 | ForEach-Object { "192.168.100.$_" }),
    [string]$UsbipPath
)

Set-Location "$PSScriptRoot"

$ips = $ThinClients -join ","

function Find-UsbipExe {
    $candidatos = @(
        "$env:ProgramFiles\usbipd-win\usbip.exe",
        "$env:ProgramFiles\Usbip\usbip.exe",
        "$env:ProgramFiles\usbip-win\usbip.exe",
        "C:\usbip\usbip.exe"
    )
    foreach ($c in $candidatos) {
        if (Test-Path $c) { return $c }
    }
    $cmd = Get-Command usbip.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# 1. usbipd-win - instala silenciosamente se ainda nao estiver presente.
$usbipdInstalado = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match '^usbipd-win' }

if ($usbipdInstalado) {
    Write-Host "[OK] usbipd-win ja esta instalado, pulando."
}
else {
    $usbipdMsi = Resolve-Path "..\usbipd-win_5.1.0_x64.msi"
    Write-Host "Instalando usbipd-win: $usbipdMsi"
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$usbipdMsi`"", '/qn', '/norestart') -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "Falha ao instalar usbipd-win (codigo $($proc.ExitCode))"
    }
}

# 2. Localiza usbip.exe (cliente USB/IP para Windows).
if (-not $UsbipPath) {
    $UsbipPath = Find-UsbipExe
    if (-not $UsbipPath) {
        $UsbipPath = 'C:\Program Files\Usbip\usbip.exe'
        Write-Warning "usbip.exe nao encontrado apos instalar o usbipd-win. Usando caminho padrao '$UsbipPath' - ajuste C:\ProgramData\UsbipBrokerCpp\config.ini depois, se necessario."
    }
}

# 3. Instala o UsbipSuite (servico broker C++ + monitor de bandeja) silenciosamente.
$msi = (Resolve-Path ".\build\UsbipSuite-2.0.0-x64.msi").Path
Write-Host "Instalando UsbipSuite: $msi"
Write-Host "  THINCLIENTS = $ips"
Write-Host "  USBIPPATH   = $UsbipPath"

$proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$msi`"", "THINCLIENTS=`"$ips`"", "USBIPPATH=`"$UsbipPath`"", '/qn', '/norestart') -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "Falha ao instalar UsbipSuite (codigo $($proc.ExitCode))"
}
