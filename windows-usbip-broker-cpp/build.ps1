param(
    [string]$Configuration = "Release",
    [string]$Platform = "x64",
    [switch]$SkipFlutter,
    [switch]$SkipCpp
)

$ErrorActionPreference = "Stop"

function Find-VsDevCmd {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "vswhere.exe not found. Install Visual Studio Build Tools with C++ tools."
    }
    $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installPath) {
        throw "Visual Studio C++ Build Tools not found."
    }
    $devCmd = Join-Path $installPath "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path -LiteralPath $devCmd)) {
        throw "VsDevCmd.bat not found at $devCmd."
    }
    return $devCmd
}

$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $root                         # C:\SourceCode\ThinClient
$buildDir = Join-Path $root "build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

# ─── Etapa 1: Flutter (System Tray Monitor) ──────────────────────────────────

$trayProjectDir = Join-Path $repoRoot "windows-tray-monitor"
$trayBuildDir   = Join-Path $trayProjectDir "build\windows\x64\runner\Release"
$trayDestDir    = Join-Path $buildDir "tray"

if ($SkipFlutter) {
    Write-Host "Pulando build Flutter (--SkipFlutter)."
} elseif (-not (Test-Path -LiteralPath $trayProjectDir)) {
    Write-Warning "Projeto Flutter não encontrado em '$trayProjectDir'. Pulando etapa Flutter."
} else {
    Write-Host "`n==> Compilando Flutter (windows-tray-monitor)..."
    Push-Location $trayProjectDir
    try {
        flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "Flutter build falhou." }
    } finally {
        Pop-Location
    }

    # Copia todos os arquivos do release Flutter para build\tray\
    if (Test-Path -LiteralPath $trayBuildDir) {
        if (Test-Path -LiteralPath $trayDestDir) {
            Remove-Item -LiteralPath $trayDestDir -Recurse -Force
        }
        Copy-Item -LiteralPath $trayBuildDir -Destination $trayDestDir -Recurse -Force
        Write-Host "Flutter release copiado para: $trayDestDir"
    } else {
        throw "Diretório de saída Flutter não encontrado: $trayBuildDir"
    }
}

# ─── Etapa 2: C++ Broker ──────────────────────────────────────────────────────

$source = Join-Path $root "UsbipBrokerService.cpp"
$exe    = Join-Path $buildDir "UsbipBrokerService.exe"
$obj    = Join-Path $buildDir "UsbipBrokerService.obj"

if ($SkipCpp) {
    Write-Host "`nPulando compilação C++ (--SkipCpp)."
} else {
    Write-Host "`n==> Compilando broker C++..."
    $devCmd = Find-VsDevCmd
    $cmdFile = Join-Path $buildDir "compile.cmd"
@"
@echo off
call "$devCmd" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
cl.exe /nologo /EHsc /std:c++17 /O2 /MT /Fo"$obj" /Fe"$exe" "$source" ws2_32.lib advapi32.lib
exit /b %errorlevel%
"@ | Set-Content -LiteralPath $cmdFile -Encoding ASCII

    cmd.exe /d /c "`"$cmdFile`""
    if ($LASTEXITCODE -ne 0) { throw "Compilação C++ falhou." }
    Write-Host "Compilado: $exe"
}

# ─── Etapa 3: WiX MSI unificado ───────────────────────────────────────────────

Write-Host "`n==> Gerando MSI unificado (USB/IP Suite)..."

if (-not (Test-Path -LiteralPath $exe)) {
    throw "UsbipBrokerService.exe não encontrado em '$buildDir'. Compile o C++ primeiro."
}

$trayExeForWix = Join-Path $trayDestDir "usbip_monitor.exe"
if (-not (Test-Path -LiteralPath $trayExeForWix)) {
    Write-Warning "usbip_monitor.exe não encontrado em '$trayDestDir'."
    throw "O MSI exige o monitor de bandeja. Execute sem --SkipFlutter ou compile o projeto Flutter primeiro."
}

$msi = Join-Path $buildDir "UsbipSuite-2.0.0-x64.msi"
wix build (Join-Path $root "Product.wxs") `
    -arch x64 `
    -d "SourceDir=$buildDir" `
    -d "SourceRoot=$root" `
    -d "TrayDir=$trayDestDir" `
    -ext WixToolset.UI.wixext `
    -ext WixToolset.Firewall.wixext `
    -out $msi

if ($LASTEXITCODE -ne 0) { throw "WiX build falhou." }

Write-Host "`nPronto!"
Write-Host "  Broker exe : $exe"
Write-Host "  MSI        : $msi"
Write-Host ""
Write-Host "Para instalar:"
Write-Host "  msiexec /i `"$msi`" THINCLIENTS=`"192.168.x.x`" USBIPPATH=`"C:\usbip\usbip.exe`""
