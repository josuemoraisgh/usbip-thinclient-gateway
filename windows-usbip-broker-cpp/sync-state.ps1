param(
    [string]$ConfigPath = "C:\ProgramData\UsbipBrokerCpp\config.ini",
    [switch]$Loop,
    [int]$IntervalSeconds = 3
)

$ErrorActionPreference = "SilentlyContinue"

function Get-IniValue {
    param([string[]]$Lines, [string]$Section, [string]$Key, [string]$Default = "")
    $inside = $false
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') {
            $inside = ($matches[1] -ieq $Section)
            continue
        }
        if ($inside -and $trimmed -match '^([^=]+)=(.*)$') {
            if ($matches[1].Trim() -ieq $Key) {
                return $matches[2].Trim()
            }
        }
    }
    return $Default
}

function Get-Stations {
    param([string[]]$Lines)
    $stations = @{}
    $inside = $false
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') {
            $inside = ($matches[1] -ieq 'Stations')
            continue
        }
        if ($inside -and $trimmed -match '^([^=]+)=(.*)$') {
            $stations[$matches[1].Trim()] = $matches[2].Trim()
        }
    }
    return $stations
}

function Invoke-Usbip {
    param([string]$UsbipPath, [string[]]$Arguments, [int]$TimeoutSeconds = 4)
    return (& $UsbipPath @Arguments 2>&1 | Out-String)
}

function Parse-UsbipPort {
    param([string]$Text)
    $items = New-Object System.Collections.Generic.List[object]
    $port = $null
    $description = $null
    $vid = $null
    $productId = $null

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^Port\s+([0-9]+):') {
            $port = [int]$matches[1]
            $description = $null
            $vid = $null
            $productId = $null
            continue
        }
        if ($line -match '^\s*(.+?)\s+\(([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\)\s*$') {
            $description = $matches[1].Trim()
            $vid = $matches[2].ToLowerInvariant()
            $productId = $matches[3].ToLowerInvariant()
            continue
        }
        if ($line -match 'usbip://([^/:]+)(?::[0-9]+)?/(\S+)') {
            $items.Add([pscustomobject]@{
                Port = $port
                Host = $matches[1]
                BusId = $matches[2]
                Vid = $vid
                Pid = $productId
                Description = $description
            })
        }
    }
    return $items
}

function Get-ComPortMap {
    $exact = @{}
    $byVidPid = @{}
    $ports = Get-PnpDevice -Class Ports -PresentOnly -ErrorAction SilentlyContinue
    foreach ($port in $ports) {
        $friendly = [string]$port.FriendlyName
        $instance = [string]$port.InstanceId
        if ($friendly -notmatch '(COM[0-9]+)') {
            continue
        }
        $comName = $matches[1].ToUpperInvariant()
        $vid = $null
        $productId = $null
        $usbipPort = $null

        if ($instance -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})(?:&MI_[0-9A-Fa-f]{2})?') {
            $vid = $matches[1].ToLowerInvariant()
            $productId = $matches[2].ToLowerInvariant()
        } elseif ($instance -match 'VID_([0-9A-Fa-f]{4})\+PID_([0-9A-Fa-f]{4})') {
            $vid = $matches[1].ToLowerInvariant()
            $productId = $matches[2].ToLowerInvariant()
        }

        if ($vid -and $productId) {
            $addressProperty = Get-PnpDeviceProperty -InstanceId $instance -KeyName 'DEVPKEY_Device_Address' -ErrorAction SilentlyContinue
            if ($addressProperty -and $null -ne $addressProperty.Data) {
                $usbipPort = [int]$addressProperty.Data
            }

            $vidPidKey = ('{0}:{1}' -f $vid, $productId)
            if (-not $byVidPid.ContainsKey($vidPidKey)) {
                $byVidPid[$vidPidKey] = New-Object System.Collections.Generic.List[string]
            }
            if (-not $byVidPid[$vidPidKey].Contains($comName)) {
                $byVidPid[$vidPidKey].Add($comName)
            }
            if ($usbipPort) {
                $key = ('{0}:{1}:{2}' -f $vid, $productId, $usbipPort)
                $exact[$key] = $comName
            }
        }
    }
    return [pscustomobject]@{
        Exact = $exact
        ByVidPid = $byVidPid
    }
}

function Get-AuditComMap {
    param([string]$AuditPath)
    $map = @{}
    if (-not (Test-Path -LiteralPath $AuditPath)) {
        return $map
    }
    foreach ($row in Import-Csv -LiteralPath $AuditPath) {
        if ([string]::IsNullOrWhiteSpace($row.com_port) -or $row.com_port -eq '?') {
            continue
        }
        $key = ('{0}/{1}/{2}:{3}' -f $row.host_ip, $row.busid, $row.vid.ToLowerInvariant(), $row.pid.ToLowerInvariant())
        $map[$key] = $row.com_port.ToUpperInvariant()
    }
    return $map
}

function Write-LiveState {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return
    }

    $lines = Get-Content -LiteralPath $ConfigPath
    $usbipPath = Get-IniValue -Lines $lines -Section 'Broker' -Key 'UsbipPath' -Default 'C:\usbip\usbip.exe'
    $statePath = Get-IniValue -Lines $lines -Section 'Broker' -Key 'StatePath' -Default 'C:\ProgramData\UsbipBrokerCpp\state.txt'
    $auditPath = Get-IniValue -Lines $lines -Section 'Broker' -Key 'AuditLogPath' -Default 'C:\ProgramData\UsbipBrokerCpp\logs\audit.csv'
    $stations = Get-Stations -Lines $lines
    if (-not (Test-Path -LiteralPath $usbipPath)) {
        return
    }

    $portText = Invoke-Usbip -UsbipPath $usbipPath -Arguments @('port') -TimeoutSeconds 4
    $devices = @(Parse-UsbipPort -Text $portText)
    $comPorts = Get-ComPortMap
    $auditComPorts = Get-AuditComMap -AuditPath $auditPath
    $live = New-Object System.Collections.Generic.List[object]

    foreach ($device in $devices) {
        $station = if ($stations.ContainsKey($device.Host)) { $stations[$device.Host] } else { $device.Host }
        $comKey = ('{0}:{1}:{2}' -f $device.Vid, $device.Pid, $device.Port)
        $auditKey = ('{0}/{1}/{2}:{3}' -f $device.Host, $device.BusId, $device.Vid, $device.Pid)
        $vidPidKey = ('{0}:{1}' -f $device.Vid, $device.Pid)
        $comPort = '?'
        if ($comPorts.Exact.ContainsKey($comKey)) {
            $comPort = $comPorts.Exact[$comKey]
        } elseif ($auditComPorts.ContainsKey($auditKey)) {
            $comPort = $auditComPorts[$auditKey]
        } elseif ($comPorts.ByVidPid.ContainsKey($vidPidKey) -and $comPorts.ByVidPid[$vidPidKey].Count -eq 1) {
            $comPort = $comPorts.ByVidPid[$vidPidKey][0]
        }
        $live.Add([pscustomobject]@{
            timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            station = $station
            host_ip = $device.Host
            busid = $device.BusId
            vid = $device.Vid
            pid = $device.Pid
            description = $device.Description
            com_port = $comPort
        })
    }

    $directory = Split-Path -Parent $statePath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temp = "$statePath.tmp"
    $live | Export-Csv -LiteralPath $temp -NoTypeInformation -Encoding ASCII
    if ($live.Count -eq 0) {
        'timestamp,station,host_ip,busid,vid,pid,description,com_port' | Set-Content -LiteralPath $temp -Encoding ASCII
    }
    Move-Item -LiteralPath $temp -Destination $statePath -Force
}

do {
    Write-LiveState
    if ($Loop) {
        Start-Sleep -Seconds $IntervalSeconds
    }
} while ($Loop)
