#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Audita e otimiza thin clients Linux usados apenas para RDP + USB/IP.

.DESCRIPTION
    Por padrao, roda em modo relatorio e nao altera nada. Use -Apply para
    desabilitar servicos/timers desnecessarios. Use -PurgePackages somente
    depois de validar o relatorio, pois remove pacotes com apt-get purge.

.EXAMPLE
    .\optimize-thinclients.ps1 -ThinClients 10.0.64.8 -TrustHostKey

.EXAMPLE
    .\optimize-thinclients.ps1 -ThinClients 10.0.64.4,10.0.64.5,10.0.64.8 -Apply -TrustHostKey

.EXAMPLE
    .\optimize-thinclients.ps1 -ThinClients 10.0.64.8 -Apply -DisableLegacyUsbip -PurgePackages -TrustHostKey
#>

[CmdletBinding()]
param(
    [string[]]$ThinClients = @(
        "10.0.64.4",
        "10.0.64.5",
        "10.0.64.6",
        "10.0.64.8",
        "10.0.67.196",
        "10.0.67.171",
        "10.0.64.3",
        "10.0.64.10",
        "10.0.64.12",
        "10.0.64.14",
        "10.0.64.17",
        "10.0.64.20",
        "10.0.64.21",
        "10.0.64.23",
        "10.0.64.24",
        "10.0.64.27"
    ),
    [string]$Password = "armbian",
    [string]$User = "root",
    [string[]]$FallbackUsers = @("armbian"),
    [string]$ReportDir,
    [switch]$Apply,
    [switch]$PurgePackages,
    [switch]$DisableLegacyUsbip,
    [switch]$RequireWifi,
    [switch]$DisableVfd,
    [switch]$TrustHostKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ReportDir) {
    $ReportDir = Join-Path $ScriptRoot "reports\thinclient-optimization"
}

function Write-Step { param([string]$Message) Write-Host "  --> $Message" -ForegroundColor Cyan }
function Write-OK { param([string]$Message) Write-Host "  [OK]  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "  [WARN] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

function Find-PuttyTool {
    param([string]$Name)

    $candidates = @(
        (Join-Path $ScriptRoot "$Name.exe"),
        "C:\Program Files\PuTTY\$Name.exe",
        "C:\Program Files (x86)\PuTTY\$Name.exe",
        "$env:LOCALAPPDATA\Programs\PuTTY\$Name.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    $fromPath = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }

    throw "$Name.exe nao encontrado. Instale PuTTY ou coloque $Name.exe ao lado deste script."
}

function Invoke-Plink {
    param(
        [string]$Plink,
        [string]$IP,
        [string]$SshUser,
        [string]$Pwd,
        [string]$Command,
        [string]$HostKey,
        [int]$TimeoutSec = 90,
        [switch]$AllowHostKeyPrompt
    )

    $outFile = Join-Path $env:TEMP "thinclient_opt_${IP}_out.txt"
    $errFile = Join-Path $env:TEMP "thinclient_opt_${IP}_err.txt"
    Remove-Item -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue

    $args = @("-ssh")
    if ($HostKey) {
        $args += @("-hostkey", $HostKey)
    }
    $args += @("-pw", $Pwd)
    if (-not $AllowHostKeyPrompt) {
        $args += "-batch"
    }
    $args += "${SshUser}@${IP}"
    $args += $Command

    $proc = Start-Process -FilePath $Plink -ArgumentList $args -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        $stdout = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue

        return [pscustomobject]@{
            ExitCode = 124
            StdOut = $stdout
            StdErr = ($stderr + "`r`nTimeout after ${TimeoutSec}s")
        }
    }
    $proc.Refresh()

    $stdout = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue
    $exitCode = if ($null -eq $proc.ExitCode) { 0 } else { $proc.ExitCode }

    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Approve-HostKey {
    param(
        [string]$Plink,
        [string]$IP,
        [string]$SshUser,
        [string]$Pwd
    )

    if (-not $TrustHostKey) {
        return
    }

    $command = "echo y | `"$Plink`" -ssh -pw `"$Pwd`" ${SshUser}@${IP} exit"
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/d", "/c", $command) -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $env:TEMP "thinclient_opt_hostkey_${IP}_out.txt") `
        -RedirectStandardError (Join-Path $env:TEMP "thinclient_opt_hostkey_${IP}_err.txt")
    if (-not $proc.WaitForExit(30000)) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath (Join-Path $env:TEMP "thinclient_opt_hostkey_${IP}_out.txt"), `
        (Join-Path $env:TEMP "thinclient_opt_hostkey_${IP}_err.txt") -ErrorAction SilentlyContinue
}

function Resolve-SshUser {
    param(
        [string]$Plink,
        [string]$IP,
        [string]$Pwd
    )

    $users = @($User) + $FallbackUsers | Select-Object -Unique
    foreach ($candidate in $users) {
        $hostKey = $script:HostKeyByIP[$IP]
        $result = Invoke-Plink -Plink $Plink -IP $IP -SshUser $candidate -Pwd $Pwd -Command "echo ok" -HostKey $hostKey
        if (($result.ExitCode -eq 0 -or $null -eq $result.ExitCode) -and $result.StdOut -match "ok") {
            return $candidate
        }

        if ($result.StdErr -match "host key is not cached" -and $TrustHostKey) {
            if ($result.StdErr -match "(SHA256:[A-Za-z0-9+/=]+)") {
                $script:HostKeyByIP[$IP] = $matches[1]
                $retry = Invoke-Plink -Plink $Plink -IP $IP -SshUser $candidate -Pwd $Pwd -Command "echo ok" -HostKey $script:HostKeyByIP[$IP]
                if (($retry.ExitCode -eq 0 -or $null -eq $retry.ExitCode) -and $retry.StdOut -match "ok") {
                    return $candidate
                }
                $retryErr = [string]$retry.StdErr
                Write-Warn "Tentativa com hostkey falhou para ${candidate}@${IP}: exit=$($retry.ExitCode) stdout='$($retry.StdOut)' stderr='$retryErr'"
            } else {
                Write-Warn "Nao consegui extrair fingerprint SSH de ${IP}."
            }
        } else {
            $err = [string]$result.StdErr
            if (-not [string]::IsNullOrWhiteSpace($err)) {
                Write-Warn "SSH falhou para ${candidate}@${IP}: $err"
            }
        }
    }

    return $null
}

function New-RemoteScript {
    $applyValue = if ($Apply) { "1" } else { "0" }
    $purgeValue = if ($PurgePackages) { "1" } else { "0" }
    $legacyValue = if ($DisableLegacyUsbip) { "1" } else { "0" }
    $wifiValue = if ($RequireWifi) { "1" } else { "0" }
    $vfdValue = if ($DisableVfd) { "1" } else { "0" }

@"
set -u
export LANG=C
export LC_ALL=C
export SYSTEMD_COLORS=0
export SYSTEMD_PAGER=cat
APPLY="$applyValue"
PURGE_PACKAGES="$purgeValue"
DISABLE_LEGACY_USBIP="$legacyValue"
REQUIRE_WIFI="$wifiValue"
DISABLE_VFD="$vfdValue"

run() {
  if [ "`$APPLY" = "1" ]; then
    echo "+ `$*"
    sh -c "`$*"
  else
    echo "DRY-RUN: `$*"
  fi
}

exists_unit() {
  systemctl list-unit-files "`$1" >/dev/null 2>&1 || systemctl status "`$1" >/dev/null 2>&1
}

disable_unit() {
  unit="`$1"
  if exists_unit "`$unit"; then
    run "systemctl disable --now '`$unit' >/dev/null 2>&1 || true"
  else
    echo "skip: `$unit nao existe"
  fi
}

echo "### THINCLIENT OPTIMIZATION"
date
hostnamectl 2>/dev/null || true
cat /etc/os-release 2>/dev/null || true
uname -a

echo
echo "### MODE"
echo "Apply=`$APPLY PurgePackages=`$PURGE_PACKAGES DisableLegacyUsbip=`$DISABLE_LEGACY_USBIP RequireWifi=`$REQUIRE_WIFI DisableVfd=`$DISABLE_VFD"

echo
echo "### BEFORE: critical services"
systemctl --no-pager --plain status ssh rdp usbipd usbip-manager 2>/dev/null | sed -n '1,180p' || true

echo
echo "### BEFORE: active services"
systemctl list-units --type=service --state=running --no-pager --plain 2>/dev/null || true

echo
echo "### BEFORE: listening ports"
ss -lntup 2>/dev/null || true

echo
echo "### BEFORE: memory/disk"
free -h || true
df -hT / /var/log /tmp 2>/dev/null || df -hT || true

echo
echo "### Disable peripheral services not required for RDP + USB/IP"
for unit in \
  rpcbind.service rpcbind.socket nfs-client.target remote-fs.target \
  openvpn.service rsync.service smartmontools.service smartd.service \
  vnstat.service sysstat.service unattended-upgrades.service \
  avahi-daemon.service bluetooth.service ModemManager.service cups.service
do
  disable_unit "`$unit"
done

echo
echo "### Disable background maintenance timers"
for unit in \
  apt-daily.timer apt-daily-upgrade.timer man-db.timer \
  sysstat-collect.timer sysstat-summary.timer e2scrub_all.timer
do
  disable_unit "`$unit"
done

if [ "`$REQUIRE_WIFI" != "1" ]; then
  wlan_state="`$(ip -br link show wlan0 2>/dev/null | awk '{print `$2}' || true)"
  if [ "`$wlan_state" != "UP" ]; then
    echo
    echo "### Disable Wi-Fi services because wlan0 is not UP"
    if command -v nmcli >/dev/null 2>&1; then
      run "nmcli radio wifi off >/dev/null 2>&1 || true"
    fi
    disable_unit wpa_supplicant.service
    if exists_unit dbus-fi.w1.wpa_supplicant1.service; then
      run "systemctl mask dbus-fi.w1.wpa_supplicant1.service wpa_supplicant.service >/dev/null 2>&1 || true"
      run "systemctl stop wpa_supplicant.service >/dev/null 2>&1 || true"
    fi
    disable_unit hostapd.service
    run "systemctl stop hostapd.service >/dev/null 2>&1 || true"
  else
    echo "keep: wlan0 esta UP"
  fi
fi

if [ "`$DISABLE_LEGACY_USBIP" = "1" ]; then
  echo
  echo "### Disable legacy USB/IP services replaced by usbip-manager"
  disable_unit usbip-server.service
  disable_unit udev-monitor.service
fi

if [ "`$DISABLE_VFD" = "1" ]; then
  echo
  echo "### Disable front-panel VFD service"
  disable_unit openvfd.service
fi

if [ "`$APPLY" = "1" ]; then
  systemctl daemon-reload || true
  systemctl reset-failed || true
fi

if [ "`$PURGE_PACKAGES" = "1" ]; then
  echo
  echo "### Purge packages not required for RDP + USB/IP"
  run "apt-get update"
  run "DEBIAN_FRONTEND=noninteractive apt-get purge -y nfs-common rpcbind openvpn network-manager-openvpn rsync smartmontools sysstat vnstat unattended-upgrades avahi-autoipd hostapd rdesktop"
  run "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge"
  run "apt-get clean"
fi

echo
echo "### AFTER: critical services"
systemctl --no-pager --plain status ssh rdp usbipd usbip-manager 2>/dev/null | sed -n '1,180p' || true

echo
echo "### AFTER: active services"
systemctl list-units --type=service --state=running --no-pager --plain 2>/dev/null || true

echo
echo "### AFTER: enabled services"
systemctl list-unit-files --type=service --state=enabled --no-pager --plain 2>/dev/null || true

echo
echo "### AFTER: failed services"
systemctl --failed --no-pager --plain 2>/dev/null || true

echo
echo "### AFTER: memory/disk"
free -h || true
df -hT / /var/log /tmp 2>/dev/null || df -hT || true
"@
}

$plink = Find-PuttyTool "plink"
$script:HostKeyByIP = @{}
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

Write-Host ""
Write-Host "Thin client optimization"
Write-Host "  Hosts       : $($ThinClients.Count)"
Write-Host "  Mode        : $(if ($Apply) { 'APPLY' } else { 'DRY-RUN' })"
Write-Host "  Reports     : $ReportDir"
Write-Host "  Purge pkgs  : $PurgePackages"
Write-Host ""

$remoteScript = New-RemoteScript
$encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript))

foreach ($ip in $ThinClients) {
    Write-Host "=== $ip ===" -ForegroundColor White
    $sshUser = Resolve-SshUser -Plink $plink -IP $ip -Pwd $Password
    if (-not $sshUser) {
        Write-Fail "Nao foi possivel autenticar em $ip."
        continue
    }

    Write-OK "SSH OK como $sshUser"
    $command = "printf '%s' '$encodedScript' | base64 -d | sh"
    $result = Invoke-Plink -Plink $plink -IP $ip -SshUser $sshUser -Pwd $Password -Command $command -HostKey $script:HostKeyByIP[$ip] -TimeoutSec 240

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeIp = $ip -replace '[^0-9A-Za-z_.-]', '_'
    $reportPath = Join-Path $ReportDir "optimize-$safeIp-$stamp.txt"
    $reportText = ($result.StdOut + "`r`n" + $result.StdErr)
    $reportText = $reportText -replace '/p:[^ \r\n]+', '/p:***************'
    $reportText | Set-Content -LiteralPath $reportPath -Encoding UTF8

    if ($result.ExitCode -eq 0) {
        Write-OK "Relatorio salvo: $reportPath"
    } else {
        Write-Fail "Falhou com exit code $($result.ExitCode). Relatorio salvo: $reportPath"
    }
}
