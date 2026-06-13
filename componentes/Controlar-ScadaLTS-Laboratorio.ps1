[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('StartAula', 'StopAula', 'Status')]
    [string]$Action,

    [switch]$Pause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-Elevated {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-Action', $Action
    )
    if ($Pause) {
        $arguments += '-Pause'
    }

    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
}

function Wait-ServiceState {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Running', 'Stopped')][string]$State
    )

    (Get-Service -Name $Name).WaitForStatus($State, [TimeSpan]::FromMinutes(3))
}

if (-not (Test-IsAdministrator)) {
    Start-Elevated
    exit
}

$mysqlName = 'MySQL Community Server 8.0'
$professorName = 'Scada-LTS'
$activeServiceNames = @(1..7 | ForEach-Object { 'ScadaLTS-bancada204a-{0:D2}' -f $_ })
$bancadaServices = @(
    Get-Service -Name $activeServiceNames -ErrorAction Stop |
        Sort-Object Name
)

switch ($Action) {
    'StartAula' {
        if ((Get-Service -Name $mysqlName).Status -ne 'Running') {
            Start-Service -Name $mysqlName
            Wait-ServiceState -Name $mysqlName -State Running
        }

        foreach ($service in $bancadaServices) {
            if ($service.Status -ne 'Running') {
                Write-Host "Iniciando $($service.DisplayName)..."
                Start-Service -Name $service.Name
            }
        }

        foreach ($service in $bancadaServices) {
            Wait-ServiceState -Name $service.Name -State Running
        }

        Start-Process 'http://localhost:8101/Scada-LTS/'
        Write-Host "Aula iniciada: MySQL e as $($bancadaServices.Count) instancias estao ativos." -ForegroundColor Green
        Write-Host 'A instancia aberta para o professor e a mesma da bancada204a-01.'
    }

    'StopAula' {
        foreach ($service in $bancadaServices) {
            if ($service.Status -ne 'Stopped') {
                Write-Host "Parando $($service.DisplayName)..."
                Stop-Service -Name $service.Name -Force
            }
        }

        foreach ($service in $bancadaServices) {
            Wait-ServiceState -Name $service.Name -State Stopped
        }

        if ((Get-Service -Name $professorName).Status -ne 'Stopped') {
            Stop-Service -Name $professorName -Force
            Wait-ServiceState -Name $professorName -State Stopped
        }

        if ((Get-Service -Name $mysqlName).Status -ne 'Stopped') {
            Write-Host 'Parando MySQL...'
            Stop-Service -Name $mysqlName -Force
            Wait-ServiceState -Name $mysqlName -State Stopped
        }

        Write-Host 'Aula encerrada: todas as instancias e o MySQL estao parados.' -ForegroundColor Yellow
    }

    'Status' {
        Get-Service -Name (@($mysqlName, $professorName) + $activeServiceNames) |
            Sort-Object Name |
            Select-Object Name, DisplayName, Status, StartType |
            Format-Table -AutoSize
    }
}

if ($Pause) {
    Write-Host ''
    Read-Host 'Pressione Enter para fechar'
}
