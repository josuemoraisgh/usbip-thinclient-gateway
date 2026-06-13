[CmdletBinding()]
param(
    [string]$LauncherPath = 'C:\config\scadalts\launchers\Abrir-ScadaLTS-Minha-Bancada.ps1'
)

$ErrorActionPreference = 'Stop'
$activeUsers = @(1..7 | ForEach-Object { 'bancada204a-{0:D2}' -f $_ })
$currentUser = $env:USERNAME.ToLowerInvariant()
$desktop = [Environment]::GetFolderPath('Desktop')

if ([string]::IsNullOrWhiteSpace($desktop)) {
    exit
}

$shortcutPath = Join-Path $desktop 'Scada-LTS - Minha Bancada.lnk'

if ([Array]::IndexOf($activeUsers, $currentUser) -lt 0) {
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
    exit
}

if (-not (Test-Path -LiteralPath $LauncherPath)) {
    exit
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = 'powershell.exe'
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $LauncherPath
$shortcut.WorkingDirectory = Split-Path -Parent $LauncherPath
$shortcut.IconLocation = 'C:\Program Files\Scada-LTS\scadalts.ico'
$shortcut.Save()
