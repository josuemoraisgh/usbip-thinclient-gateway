param(
    [string]$ConfigPath = "C:\ProgramData\UsbipBrokerCpp\config.ini",
    [string]$LogPath = "C:\ProgramData\UsbipBrokerCpp\logs\autoattach.log",
    [int]$IntervalSeconds = 5
)

$ErrorActionPreference = "Continue"

function Write-Log {
    param([string]$Level, [string]$Message)
    $dir = Split-Path -Parent $LogPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $line = "{0:yyyy-MM-dd HH:mm:ss} {1} {2}" -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding ASCII
}

function Read-IniValue {
    param([string]$Path, [string]$Section, [string]$Key, [string]$Default = "")
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    $inSection = $false
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        $trim = $line.Trim()
        if (-not $trim -or $trim.StartsWith(";") -or $trim.StartsWith("#")) { continue }
        if ($trim -match '^\[(.+)\]$') {
            $inSection = ($matches[1] -ieq $Section)
            continue
        }
        if ($inSection -and $trim -match '^([^=]+)=(.*)$' -and $matches[1].Trim() -ieq $Key) {
            return $matches[2].Trim()
        }
    }
    return $Default
}

function Find-Usbip {
    $configured = Read-IniValue -Path $ConfigPath -Section "Broker" -Key "UsbipPath" -Default ""
    foreach ($candidate in @($configured, "C:\Program Files\Usbip\usbip.exe", "C:\usbip\usbip.exe")) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    $cmd = Get-Command "usbip.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Convert-Rules {
    param([string]$Text)
    $rules = @()
    foreach ($part in ($Text -split ',')) {
        $trim = $part.Trim()
        if ($trim -match '^([0-9a-fA-F*]{1,4}):([0-9a-fA-F*]{1,4})$') {
            $rules += [pscustomobject]@{ Vid = $matches[1].ToLowerInvariant(); Pid = $matches[2].ToLowerInvariant() }
        }
    }
    return $rules
}

function Test-Rule {
    param([string]$Vid, [string]$ProductId, $Rule)
    $vidRule = [string]$Rule.Vid
    $pidRule = [string]$Rule.Pid
    return (($vidRule -eq "*" -or $vidRule -eq $Vid) -and ($pidRule -eq "*" -or $pidRule -eq $ProductId))
}

function Test-Allowed {
    param([string]$Vid, [string]$ProductId, $Allowed, $Blocked)
    foreach ($rule in $Blocked) {
        if (Test-Rule -Vid $Vid -ProductId $ProductId -Rule $rule) { return $false }
    }
    foreach ($rule in $Allowed) {
        if (Test-Rule -Vid $Vid -ProductId $ProductId -Rule $rule) { return $true }
    }
    return $false
}

function Get-Hosts {
    $hosts = @()
    $thinClients = Read-IniValue -Path $ConfigPath -Section "Broker" -Key "ThinClients" -Default ""
    foreach ($hostName in ($thinClients -split ',')) {
        $hostName = $hostName.Trim()
        if ($hostName) { $hosts += $hostName }
    }

    $brokerLog = Read-IniValue -Path $ConfigPath -Section "Broker" -Key "LogPath" -Default "C:\ProgramData\UsbipBrokerCpp\logs\broker.log"
    if (Test-Path -LiteralPath $brokerLog) {
        foreach ($line in Get-Content -LiteralPath $brokerLog -Tail 500 -ErrorAction SilentlyContinue) {
            if ($line -match 'Event from ([0-9.]+) busid=') {
                $hosts += $matches[1]
            }
        }
    }
    return @($hosts | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-AttachedKeys {
    param([string]$UsbipExe)
    $keys = @{}
    $text = & $UsbipExe port 2>&1
    foreach ($line in $text) {
        if ($line -match 'usbip://([^/:]+)(?::[0-9]+)?/(\S+)') {
            $keys["$($matches[1].ToLowerInvariant())/$($matches[2])"] = $true
        }
    }
    return $keys
}

function Get-RemoteDevices {
    param([string]$UsbipExe, [string]$HostName)
    $devices = @()
    $current = $null
    $text = & $UsbipExe list -r $HostName 2>&1
    foreach ($line in $text) {
        if ($line -match '^\s*(?:-\s*)?([0-9]+(?:-[0-9.]+)+)\s*:\s*(.*?)(?:\(([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\))?\s*$') {
            $current = [pscustomobject]@{
                BusId = $matches[1]
                Description = $matches[2].Trim()
                Vid = ""
                Pid = ""
            }
            if ($matches.Count -ge 5 -and $matches[3]) {
                $current.Vid = $matches[3].ToLowerInvariant()
                $current.Pid = $matches[4].ToLowerInvariant()
            }
            $devices += $current
            continue
        }
        if ($current -and $line -match '\(([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\)') {
            $current.Vid = $matches[1].ToLowerInvariant()
            $current.Pid = $matches[2].ToLowerInvariant()
        }
    }
    return $devices
}

Write-Log "INFO" "usbip autoattach starting"

while ($true) {
    try {
        $usbip = Find-Usbip
        if (-not $usbip) {
            Write-Log "ERROR" "usbip.exe not found"
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }

        $allowed = Convert-Rules (Read-IniValue -Path $ConfigPath -Section "Broker" -Key "AllowedDevices" -Default "303a:1001,303a:*,10c4:ea60,1a86:7523,0403:6010,0403:6001")
        $blocked = Convert-Rules (Read-IniValue -Path $ConfigPath -Section "Broker" -Key "BlockedDevices" -Default "1d6b:*,2a7a:9a18,10c4:8105")
        $attached = Get-AttachedKeys -UsbipExe $usbip

        foreach ($hostName in Get-Hosts) {
            foreach ($device in Get-RemoteDevices -UsbipExe $usbip -HostName $hostName) {
                if (-not $device.Vid -or -not $device.Pid) { continue }
                if (-not (Test-Allowed -Vid $device.Vid -ProductId $device.Pid -Allowed $allowed -Blocked $blocked)) { continue }
                $key = "$($hostName.ToLowerInvariant())/$($device.BusId)"
                if ($attached.ContainsKey($key)) { continue }

                $out = & $usbip attach -r $hostName -b $device.BusId 2>&1
                $text = $out -join " "
                if ($LASTEXITCODE -eq 0 -or $text -match 'already|busy|succesfully|successfully') {
                    Write-Log "INFO" "attached $hostName/$($device.BusId) $($device.Vid):$($device.Pid) $($device.Description)"
                    $attached[$key] = $true
                } else {
                    Write-Log "WARN" "attach failed $hostName/$($device.BusId) $($device.Vid):$($device.Pid): $text"
                }
            }
        }
    } catch {
        Write-Log "ERROR" $_.Exception.Message
    }
    Start-Sleep -Seconds $IntervalSeconds
}
