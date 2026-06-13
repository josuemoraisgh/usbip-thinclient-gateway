#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes old USB/IP Broker installations before installing the current MSI.

.DESCRIPTION
    Removes legacy Python service, previous C++ service, old Program Files
    folders, legacy firewall rules, tray monitor autostart entries, and older
    USB/IP MSI products found by display name.

    It does not remove C:\usbip\usbip.exe, device drivers, or current
    C:\ProgramData\UsbipBrokerCpp configuration.
#>
param(
    [switch]$KeepData,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step {
    param([string]$Message)
    Write-Host "`n[CLEANUP] $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "  OK  $Message" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Message)
    Write-Host "  --  $Message" -ForegroundColor Gray
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  !!  $Message" -ForegroundColor Yellow
}

function Confirm-Step {
    param([string]$Message)
    if ($Force) {
        return $true
    }
    $answer = Read-Host "$Message [S/N]"
    return ($answer -imatch '^s')
}

function Stop-And-Delete-Service {
    param([string]$Name)
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Skip "Service '$Name' not found"
        return
    }

    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Service -Name $Name -ErrorAction SilentlyContinue).Status -ne 'Stopped' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
        }
    }

    & sc.exe delete $Name | Out-Null
    Write-OK "Service '$Name' removed"
}

function Remove-FirewallRuleSafe {
    param([string]$DisplayName)
    $rules = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
    if ($rules) {
        $rules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Write-OK "Firewall rule '$DisplayName' removed"
    } else {
        Write-Skip "Firewall rule '$DisplayName' not found"
    }
}

function Remove-DirectorySafe {
    param([string]$Path, [string]$Label)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        Write-OK "Directory '$Label' removed"
    } else {
        Write-Skip "Directory '$Label' not found"
    }
}

function Stop-ProcessSafe {
    param([string]$Name)
    $processes = Get-Process -Name $Name -ErrorAction SilentlyContinue
    if ($processes) {
        $processes | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-OK "Process '$Name' stopped"
    } else {
        Write-Skip "Process '$Name' not running"
    }
}

function Remove-StartupEntry {
    param([string]$Name)
    $paths = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )

    $found = $false
    foreach ($path in $paths) {
        if (-not (Test-Path $path)) {
            continue
        }
        $value = Get-ItemProperty -Path $path -Name $Name -ErrorAction SilentlyContinue
        if ($value) {
            Remove-ItemProperty -Path $path -Name $Name -ErrorAction SilentlyContinue
            Write-OK "Startup entry '$Name' removed from $path"
            $found = $true
        }
    }

    if (-not $found) {
        Write-Skip "Startup entry '$Name' not found"
    }
}

function Remove-MsiByDisplayName {
    param([string]$Pattern)
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $products = @()
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) {
            continue
        }
        $products += Get-ChildItem $root -ErrorAction SilentlyContinue |
            ForEach-Object {
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($props.DisplayName -and $props.DisplayName -like $Pattern) {
                    [pscustomobject]@{
                        ProductCode = $_.PSChildName
                        DisplayName = $props.DisplayName
                    }
                }
            }
    }

    if (-not $products) {
        Write-Skip "No MSI product matching '$Pattern' found"
        return
    }

    foreach ($product in $products) {
        Write-Host "  Removing MSI '$($product.DisplayName)'..."
        $result = Start-Process -FilePath 'msiexec.exe' `
            -ArgumentList "/x `"$($product.ProductCode)`" /qn /norestart" `
            -Wait -PassThru -NoNewWindow
        if ($result.ExitCode -eq 0 -or $result.ExitCode -eq 1605) {
            Write-OK "MSI '$($product.DisplayName)' removed"
        } else {
            Write-Warn "msiexec returned $($result.ExitCode) for '$($product.DisplayName)'"
        }
    }
}

if (-not $Force) {
    Write-Host "This will remove legacy USB/IP services, old broker files, old firewall rules, and tray autostart entries." -ForegroundColor Yellow
    Write-Host "It will not remove C:\usbip\usbip.exe, device drivers, or C:\ProgramData\UsbipBrokerCpp." -ForegroundColor Yellow
    if (-not (Confirm-Step "Continue cleanup?")) {
        Write-Host "Canceled." -ForegroundColor Red
        exit 0
    }
}

Write-Step "1/7 Windows services"
Stop-And-Delete-Service -Name 'UsbipBroker'
Stop-And-Delete-Service -Name 'UsbipBrokerCpp'

Write-Step "2/7 Old MSI products"
Remove-MsiByDisplayName -Pattern 'USB/IP Broker*'
Remove-MsiByDisplayName -Pattern 'USB/IP Suite*'

Write-Step "3/7 Tray monitor process and autostart"
Stop-ProcessSafe -Name 'usbip_monitor'
Stop-ProcessSafe -Name 'UsbipMonitor'
Remove-StartupEntry -Name 'UsbipMonitor'
Remove-StartupEntry -Name 'usbip_monitor'

Write-Step "4/7 Legacy Program Files directories"
Remove-DirectorySafe -Path "$env:ProgramFiles\UsbipBroker" -Label 'Program Files\UsbipBroker'
Remove-DirectorySafe -Path "${env:ProgramFiles(x86)}\UsbipBroker" -Label 'Program Files (x86)\UsbipBroker'
Remove-DirectorySafe -Path "$env:ProgramFiles\UsbipMonitor" -Label 'Program Files\UsbipMonitor'
Remove-DirectorySafe -Path "$env:ProgramFiles\usbip_monitor" -Label 'Program Files\usbip_monitor'

Write-Step "5/7 Legacy ProgramData"
if ($KeepData) {
    Write-Skip "Keeping ProgramData\UsbipBroker because -KeepData was provided"
} else {
    Remove-DirectorySafe -Path "$env:ProgramData\UsbipBroker" -Label 'ProgramData\UsbipBroker'
}

Write-Step "6/7 Firewall rules"
Remove-FirewallRuleSafe -DisplayName 'USB/IP Broker Event Listener'
Remove-FirewallRuleSafe -DisplayName 'USB/IP Broker C++ Event Listener'
Remove-FirewallRuleSafe -DisplayName 'UsbipBroker TCP 12000'
Remove-FirewallRuleSafe -DisplayName 'UsbipBroker'

Write-Step "7/7 Residual registry keys"
$regKeys = @(
    'HKLM:\SYSTEM\CurrentControlSet\Services\UsbipBroker',
    'HKLM:\SYSTEM\CurrentControlSet\Services\UsbipBrokerCpp',
    'HKLM:\SOFTWARE\UsbipBroker',
    'HKLM:\SOFTWARE\UsbipBrokerCpp'
)

foreach ($key in $regKeys) {
    if (Test-Path $key) {
        Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
        Write-OK "Registry key '$key' removed"
    } else {
        Write-Skip "Registry key '$key' not found"
    }
}

Write-Host "`nCleanup complete. You can install UsbipSuite-2.0.0-x64.msi now." -ForegroundColor Green
