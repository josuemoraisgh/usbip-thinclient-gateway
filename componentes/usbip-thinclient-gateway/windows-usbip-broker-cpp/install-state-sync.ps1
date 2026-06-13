param(
    [string]$SourceScript = (Join-Path $PSScriptRoot "sync-state.ps1"),
    [string]$InstallDir = "C:\ProgramData\UsbipBrokerCpp",
    [string]$TaskName = "UsbipBrokerCpp-StateSync",
    [int]$IntervalSeconds = 3
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $SourceScript)) {
    throw "sync-state.ps1 not found at '$SourceScript'."
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$targetScript = Join-Path $InstallDir "sync-state.ps1"
Copy-Item -LiteralPath $SourceScript -Destination $targetScript -Force

Get-CimInstance Win32_Process -Filter "name = 'powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*sync-state.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $targetScript

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Loop -IntervalSeconds {1}' -f $targetScript, $IntervalSeconds)
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
