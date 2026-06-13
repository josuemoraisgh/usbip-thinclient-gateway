#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$installDir = Join-Path $env:ProgramFiles "UsbipSuite\monitor"
$launcher = Join-Path $installDir "UsbipTrayLauncher.exe"
$monitor = Join-Path $installDir "usbip_monitor.exe"
$repoLauncher = Join-Path $PSScriptRoot "build\UsbipTrayLauncher.exe"
$repoTrayDir = Join-Path $PSScriptRoot "build\tray"
$commonStartup = [Environment]::GetFolderPath("CommonStartup")
$launcherShortcut = Join-Path $commonStartup "USB-IP Tray Launcher.lnk"

if (-not (Test-Path -LiteralPath $repoLauncher)) {
    throw "Launcher nao encontrado em '$repoLauncher'. Execute .\build.ps1 e depois rode este script novamente."
}

if (-not (Test-Path -LiteralPath $installDir)) {
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
}

Write-Host "Encerrando janelas Flutter antigas e launchers anteriores..."
Get-Process -Name "usbip_monitor" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name "UsbipTrayLauncher" -ErrorAction SilentlyContinue | Stop-Process -Force

if (Test-Path -LiteralPath $repoTrayDir) {
    Write-Host "Sincronizando janela Flutter instalada..."
    Copy-Item -Path (Join-Path $repoTrayDir "*") -Destination $installDir -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $installDir "tray_manager_plugin.dll") -Force -ErrorAction SilentlyContinue
} else {
    Write-Warning "Build Flutter nao encontrado em '$repoTrayDir'. Execute .\build.ps1 para gerar a janela atualizada."
}

Write-Host "Atualizando launcher instalado..."
Copy-Item -LiteralPath $repoLauncher -Destination $launcher -Force

Write-Host "Removendo autostart antigo..."
$runKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
)
foreach ($key in $runKeys) {
    if (Test-Path -LiteralPath $key) {
        Remove-ItemProperty -LiteralPath $key -Name "UsbipMonitor" -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $key -Name "usbip_monitor" -ErrorAction SilentlyContinue
    }
}

$oldShortcuts = @(
    (Join-Path $commonStartup "USB-IP Monitor.lnk"),
    (Join-Path $commonStartup "usbip_monitor.lnk")
)
foreach ($shortcut in $oldShortcuts) {
    if (Test-Path -LiteralPath $shortcut) {
        Remove-Item -LiteralPath $shortcut -Force
    }
}

Write-Host "Criando atalho do launcher leve no Startup comum..."
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($launcherShortcut)
$link.TargetPath = $launcher
$link.WorkingDirectory = $installDir
$link.Description = "USB/IP Monitor"
$link.IconLocation = "$launcher,0"
$link.Save()

Write-Host "Iniciando launcher na sessao atual..."
Start-Process -FilePath $launcher -WorkingDirectory $installDir

Write-Host "Pronto. Novos logins usarao o launcher leve; a janela Flutter so abre ao clicar no icone."
Write-Host "Se ainda aparecerem icones duplicados, passe o mouse sobre eles ou reinicie o Windows Explorer."
