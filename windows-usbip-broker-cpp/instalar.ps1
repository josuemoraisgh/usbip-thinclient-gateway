Set-Location "$PSScriptRoot"

$ips = (31..52 | ForEach-Object { "192.168.100.$_" }) -join ","
$msi = (Resolve-Path ".\build\UsbipSuite-2.0.0-x64.msi").Path

msiexec /i "$msi" THINCLIENTS="$ips" "USBIPPATH=C:\Program Files\Usbip\usbip.exe"
