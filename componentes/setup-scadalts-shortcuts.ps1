#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$BasePath = 'C:\config\scadalts',
    [string]$AdministratorDesktop = 'C:\Users\Administrator\Desktop'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
$adminDirectory = Join-Path $BasePath 'admin'
$launcherDirectory = Join-Path $BasePath 'launchers'
$controlSource = Join-Path $PSScriptRoot 'Controlar-ScadaLTS-Laboratorio.ps1'
$controlDestination = Join-Path $adminDirectory 'Controlar-ScadaLTS-Laboratorio.ps1'
$studentShortcutSetupSource = Join-Path $PSScriptRoot 'Configurar-Atalho-ScadaLTS-Usuario.ps1'
$studentShortcutSetupDestination = Join-Path $launcherDirectory 'Configurar-Atalho-ScadaLTS-Usuario.ps1'
$studentLauncher = Join-Path $launcherDirectory 'Abrir-ScadaLTS-Minha-Bancada.ps1'
$allUsersScadaStartMenu = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Scada-LTS'
$administratorScadaStartMenu = 'C:\Users\Administrator\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Scada-LTS'

foreach ($path in @($publicDesktop, $AdministratorDesktop, $adminDirectory, $administratorScadaStartMenu)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $controlSource)) {
    throw "Script de controle nao encontrado: $controlSource"
}
if (-not (Test-Path -LiteralPath $studentShortcutSetupSource)) {
    throw "Script de atalho por usuario nao encontrado: $studentShortcutSetupSource"
}

Copy-Item -LiteralPath $controlSource -Destination $controlDestination -Force
Copy-Item -LiteralPath $studentShortcutSetupSource -Destination $studentShortcutSetupDestination -Force
& icacls.exe $adminDirectory /inheritance:r `
    /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /Q |
    Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao proteger $adminDirectory."
}
& icacls.exe (Join-Path $adminDirectory '*') /reset /T /Q | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao propagar permissoes em $adminDirectory."
}

function Move-PublicShortcutToAdministrator {
    param(
        [Parameter(Mandatory)][string]$SourceName,
        [Parameter(Mandatory)][string]$DestinationName
    )

    $source = Join-Path $publicDesktop $SourceName
    $destination = Join-Path $AdministratorDesktop $DestinationName

    if (-not (Test-Path -LiteralPath $source)) {
        return
    }

    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $source -Force
    }
    else {
        Move-Item -LiteralPath $source -Destination $destination
    }
}

function New-ControlShortcut {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Action
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $AdministratorDesktop $Name))
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1} -Pause' -f
        $controlDestination, $Action
    $shortcut.WorkingDirectory = $adminDirectory
    $shortcut.IconLocation = 'C:\Program Files\Scada-LTS\scadalts.ico'
    $shortcut.Save()
}

function New-StudentShortcut {
    param([Parameter(Mandatory)][string]$Desktop)

    New-Item -ItemType Directory -Path $Desktop -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $Desktop 'Scada-LTS - Minha Bancada.lnk'))
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $studentLauncher
    $shortcut.WorkingDirectory = $launcherDirectory
    $shortcut.IconLocation = 'C:\Program Files\Scada-LTS\scadalts.ico'
    $shortcut.Save()
}

Move-PublicShortcutToAdministrator `
    -SourceName 'Start MySQL Community Server 8.0.lnk' `
    -DestinationName 'Start MySQL Community Server 8.0.lnk'
Move-PublicShortcutToAdministrator `
    -SourceName 'Stop MySQL Community Server 8.0.lnk' `
    -DestinationName 'Stop MySQL Community Server 8.0.lnk'
Move-PublicShortcutToAdministrator `
    -SourceName 'Scada-LTS service manager.lnk' `
    -DestinationName 'Scada-LTS - Professor - Gerenciador de Servico.lnk'
Move-PublicShortcutToAdministrator `
    -SourceName 'Scada-LTS.url' `
    -DestinationName 'Scada-LTS - Professor.url'

foreach ($startMenuItem in @(
        @{
            Source = 'Scada-LTS service manager.lnk'
            Destination = 'Scada-LTS - Professor - Gerenciador de Servico.lnk'
        },
        @{
            Source = 'Scada-LTS.url'
            Destination = 'Scada-LTS - Professor.url'
        }
    )) {
    $source = Join-Path $allUsersScadaStartMenu $startMenuItem.Source
    $destination = Join-Path $administratorScadaStartMenu $startMenuItem.Destination

    if (Test-Path -LiteralPath $source) {
        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $source -Force
        }
        else {
            Move-Item -LiteralPath $source -Destination $destination
        }
    }
}

if (Test-Path -LiteralPath $allUsersScadaStartMenu) {
    Remove-Item -LiteralPath $allUsersScadaStartMenu -Recurse -Force
}

foreach ($obsoleteName in @(
        'Iniciar Scada-LTS - Todas as Bancadas.lnk',
        'Parar Scada-LTS - Todas as Bancadas.lnk',
        'Iniciar Scada-LTS - Professor.lnk',
        'Parar Scada-LTS - Professor.lnk',
        'Scada-LTS - Professor - Gerenciador de Servico.lnk',
        'Scada-LTS - Professor.url',
        'Start MySQL Community Server 8.0.lnk',
        'Stop MySQL Community Server 8.0.lnk',
        'Status Scada-LTS - Laboratorio.lnk',
        'Scada-LTS - Minha Bancada.lnk'
    )) {
    $obsoletePath = Join-Path $AdministratorDesktop $obsoleteName
    if (Test-Path -LiteralPath $obsoletePath) {
        Remove-Item -LiteralPath $obsoletePath -Force
    }
}

if (Test-Path -LiteralPath $administratorScadaStartMenu) {
    Remove-Item -LiteralPath $administratorScadaStartMenu -Recurse -Force
}

$publicStudentShortcut = Join-Path $publicDesktop 'Scada-LTS - Minha Bancada.lnk'
if (Test-Path -LiteralPath $publicStudentShortcut) {
    Remove-Item -LiteralPath $publicStudentShortcut -Force
}

Get-ChildItem 'C:\Users' -Directory -Filter 'bancada*' -ErrorAction SilentlyContinue |
    ForEach-Object {
        $desktop = Join-Path $_.FullName 'Desktop'
        $shortcut = Join-Path $desktop 'Scada-LTS - Minha Bancada.lnk'
        if (Test-Path -LiteralPath $shortcut) {
            Remove-Item -LiteralPath $shortcut -Force
        }
    }

1..7 | ForEach-Object {
    $userName = 'bancada204a-{0:D2}' -f $_
    $profilePath = Join-Path 'C:\Users' $userName
    if (Test-Path -LiteralPath $profilePath) {
        New-StudentShortcut -Desktop (Join-Path $profilePath 'Desktop')
    }
    else {
        Write-Warning "Perfil ainda nao existe para $userName; o atalho sera criado no primeiro logon pelo provisionador."
    }
}

$runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runCommand = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f
    $studentShortcutSetupDestination
New-ItemProperty -Path $runKey -Name 'ScadaLTS-Atalho-Usuario' -Value $runCommand -PropertyType String -Force |
    Out-Null

New-ControlShortcut -Name 'Iniciar Aula Scada-LTS - 7 Bancadas.lnk' -Action StartAula
New-ControlShortcut -Name 'Encerrar Aula Scada-LTS - 7 Bancadas.lnk' -Action StopAula

Write-Host 'Desktop Publico: nenhum atalho Scada-LTS.'
Write-Host "Controles administrativos criados em: $AdministratorDesktop"
Write-Host 'O professor usa a mesma instancia da bancada204a-01 durante a aula.'
