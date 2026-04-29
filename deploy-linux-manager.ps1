#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Faz deploy do USB/IP Manager em thin clients Linux via SSH a partir do Windows Server.

.DESCRIPTION
    Para cada thin client informado: faz upload do linux-usbip-manager/ via SCP,
    executa uninstall.sh e depois install.sh.
    Requer plink/pscp (PuTTY) em PATH ou no mesmo diretório do script.

.PARAMETER ThinClients
    Lista de IPs das thin clients. Ex: -ThinClients "192.168.100.31","192.168.100.32"
    Ou use -ConfigFile para carregar de um arquivo.

.PARAMETER Password
    Senha root (mesma para todas as thin clients).
    Se omitida, será pedida interativamente.

.PARAMETER ConfigFile
    Arquivo CSV com colunas "ip,password" para senhas diferentes por host.
    Ex:  192.168.100.31,senhaA
         192.168.100.32,senhaB

.PARAMETER ServerIP
    IP do Windows Server enviado ao install.sh como --server-ip e --notify-host.
    Padrão: detectado automaticamente pela interface de rede.

.PARAMETER NotifyPort
    Porta TCP do broker Windows. Padrão: 12000.

.PARAMETER RemoteDir
    Diretório temporário de upload nas thin clients. Padrão: /tmp/usbip-deploy.

.PARAMETER SkipUninstall
    Pula o uninstall.sh (somente instala/atualiza).

.PARAMETER KeepConfig
    Passa --keep-config ao uninstall.sh para preservar config.json.

.PARAMETER Force
    Não pede confirmação antes de iniciar.

.EXAMPLE
    .\deploy-linux-manager.ps1 -ThinClients "192.168.100.31","192.168.100.32" -Password "minhasenha"

.EXAMPLE
    .\deploy-linux-manager.ps1 -ConfigFile .\hosts.csv -ServerIP 192.168.100.10

.EXAMPLE
    .\deploy-linux-manager.ps1 -ThinClients "192.168.100.31" -SkipUninstall -Force
#>

[CmdletBinding()]
param(
    [string[]]$ThinClients,
    [string]$Password,
    [string]$User = "root",
    [string[]]$FallbackUsers = @("armbian"),
    [string]$ConfigFile,
    [string]$ServerIP,
    [string]$NotifyPort = "12000",
    [string]$RemoteDir  = "/tmp/usbip-deploy",
    [string]$UsbipPath,
    [ValidateSet("allowlist","allow_all")]
    [string]$BindPolicy = "allowlist",
    [switch]$SkipWindowsAttach,
    [switch]$SkipUninstall,
    [switch]$KeepConfig,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ─── Cores / helpers ──────────────────────────────────────────────────────────

function Write-Step   { param($m) Write-Host "  --> $m" -ForegroundColor Cyan }
function Write-OK     { param($m) Write-Host "  [OK]  $m" -ForegroundColor Green }
function Write-Fail   { param($m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Warn   { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Header { param($m) Write-Host "`n=== $m ===" -ForegroundColor White }

# ─── Localizar plink / pscp ───────────────────────────────────────────────────

function Find-PuttyTool {
    param([string]$Name)
    $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
    $candidates = @(
        (Join-Path $scriptDir "${Name}.exe"),
        "C:\Program Files\PuTTY\${Name}.exe",
        "C:\Program Files (x86)\PuTTY\${Name}.exe",
        "$env:LOCALAPPDATA\Programs\PuTTY\${Name}.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $inPath = Get-Command "${Name}.exe" -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    return $null
}

$plink = Find-PuttyTool "plink"
$pscp  = Find-PuttyTool "pscp"

function Find-UsbipTool {
    param([string]$ExplicitPath)
    $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
    $candidates = @()
    if ($ExplicitPath) {
        $candidates += $ExplicitPath
    }
    $candidates += @(
        "C:\Program Files\Usbip\usbip.exe",
        "C:\Program Files\usbip\usbip.exe",
        "C:\usbip\usbip.exe",
        (Join-Path $scriptDir "usbip.exe")
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    $inPath = Get-Command "usbip.exe" -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    return $null
}

$usbip = Find-UsbipTool $UsbipPath

if (-not $plink -or -not $pscp) {
    Write-Host @"

ERRO: plink.exe e/ou pscp.exe (PuTTY) nao encontrados.

Instale o PuTTY em: https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html
  ou via winget:  winget install PuTTY.PuTTY

Apos instalar, adicione ao PATH ou coloque plink.exe e pscp.exe na mesma pasta deste script.
"@ -ForegroundColor Red
    exit 1
}

Write-OK "plink : $plink"
Write-OK "pscp  : $pscp"
if ($usbip) {
    Write-OK "usbip : $usbip"
} elseif (-not $SkipWindowsAttach) {
    Write-Warn "usbip.exe nao encontrado; o deploy continuara sem attach automatico no Windows."
}

$script:HostKeyByIP = @{}
$script:LastHostKeyError = ""

# ─── Diretório do linux-usbip-manager ─────────────────────────────────────────

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$managerDir  = Join-Path $scriptDir "linux-usbip-manager"

if (-not (Test-Path -LiteralPath (Join-Path $managerDir "install.sh"))) {
    Write-Fail "linux-usbip-manager\install.sh nao encontrado em '$managerDir'."
    exit 1
}

# ─── Carregar lista de hosts ───────────────────────────────────────────────────

$hosts = @()   # array de @{IP=...; User=...; Password=...}

if ($ConfigFile) {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        Write-Fail "ConfigFile nao encontrado: $ConfigFile"
        exit 1
    }
    Get-Content -LiteralPath $ConfigFile | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line -match '^\s*#') { return }
        if ($line -match '^\s*ip\s*,') { return }

        $parts = $line.Split(',', 3)
        if ($parts.Count -eq 2) {
            $hosts += @{ IP = $parts[0].Trim(); User = $User; Password = $parts[1].Trim() }
        } elseif ($parts.Count -eq 3) {
            $hosts += @{ IP = $parts[0].Trim(); User = $parts[1].Trim(); Password = $parts[2].Trim() }
        } else {
            Write-Warn "Linha ignorada no ConfigFile: $line"
        }
    }
} elseif ($ThinClients) {
    if (-not $Password) {
        $secPwd = Read-Host "Senha SSH dos thin clients" -AsSecureString
        $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPwd))
    }
    foreach ($ip in $ThinClients) {
        $hosts += @{ IP = $ip.Trim(); User = $User; Password = $Password }
    }
} else {
    Write-Fail "Informe -ThinClients ou -ConfigFile."
    Write-Host "Use:  .\deploy-linux-manager.ps1 -ThinClients '192.168.100.31','192.168.100.32' -Password 'senha'"
    exit 1
}

if ($hosts.Count -eq 0) {
    Write-Fail "Nenhum host encontrado."
    exit 1
}

# ─── Detectar IP do servidor Windows ──────────────────────────────────────────

if (-not $ServerIP) {
    $ServerIP = (
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
        Select-Object -First 1 -ExpandProperty IPAddress
    )
    if (-not $ServerIP) { $ServerIP = "0.0.0.0" }
    Write-Warn "ServerIP nao informado. Detectado: $ServerIP  (use -ServerIP se estiver errado)"
}

# ─── Resumo e confirmacao ─────────────────────────────────────────────────────

Write-Host "`n=============================================" -ForegroundColor White
Write-Host "  USB/IP Manager - Deploy para thin clients" -ForegroundColor White
Write-Host "=============================================" -ForegroundColor White
Write-Host "  Hosts         : $($hosts.Count)"
Write-Host "  Server IP     : $ServerIP"
Write-Host "  Notify Port   : $NotifyPort"
Write-Host "  Usuario padrao: $User"
Write-Host "  Diretorio src : $managerDir"
Write-Host "  Bind policy   : $BindPolicy"
Write-Host "  Windows attach: $(-not $SkipWindowsAttach)"
Write-Host "  Skip uninstall: $SkipUninstall"
Write-Host "  Keep config   : $KeepConfig"
Write-Host ""
$hosts | ForEach-Object { Write-Host "    $($_.User)@$($_.IP)" }
Write-Host ""

if (-not $Force) {
    $resp = Read-Host "Continuar? [s/N]"
    if ($resp -notmatch '^[sS]') { Write-Host "Cancelado."; exit 0 }
}

# ─── Funções SSH / SCP ────────────────────────────────────────────────────────

function Safe-TempName {
    param([string]$Value)
    return ($Value -replace '[^A-Za-z0-9_.-]', '_')
}

function Get-HostKeyArgs {
    param([string]$IP)
    if ($script:HostKeyByIP.ContainsKey($IP)) {
        return @("-hostkey", $script:HostKeyByIP[$IP])
    }
    return @()
}

function Invoke-PlinkProbe {
    param([string]$IP, [string]$User, [string]$Pwd, [string[]]$ExtraArgs = @())

    $safe = Safe-TempName $IP
    $outFile = Join-Path $env:TEMP "plink_probe_out_${safe}.txt"
    $errFile = Join-Path $env:TEMP "plink_probe_err_${safe}.txt"
    Remove-Item $outFile,$errFile -ErrorAction SilentlyContinue

    $args = @(
        "-ssh", "-pw", $Pwd
    ) + $ExtraArgs + @(
        "-batch",
        "${User}@${IP}",
        "echo ok"
    )

    $proc = Start-Process -FilePath $plink -ArgumentList $args `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $outFile `
        -RedirectStandardError  $errFile

    $out = Get-Content $outFile -ErrorAction SilentlyContinue
    $err = Get-Content $errFile -ErrorAction SilentlyContinue
    Remove-Item $outFile,$errFile -ErrorAction SilentlyContinue

    return @{ ExitCode = $proc.ExitCode; Stdout = $out; Stderr = $err }
}

function Test-AuthFailureText {
    param([string]$Text)
    return $Text -match 'Configured password was not accepted|Access denied|Permission denied|Authentication failed'
}

function Test-NetworkFailureText {
    param([string]$Text)
    return $Text -match 'Network error: Connection timed out|Network error: Connection refused|Host does not exist|No route to host|Connection failed'
}

function Accept-HostKey {
    # Primeiro tenta conexao em batch. Se a host key ainda nao estiver no cache
    # do PuTTY, o Plink retorna o fingerprint no stderr; entao reutilizamos esse
    # SHA256 com -hostkey em todos os comandos seguintes, sem prompt interativo.
    param([string]$IP, [string]$User, [string]$Pwd)
    $script:LastHostKeyError = ""

    if ($script:HostKeyByIP.ContainsKey($IP)) {
        $cachedProbe = Invoke-PlinkProbe -IP $IP -User $User -Pwd $Pwd -ExtraArgs (Get-HostKeyArgs -IP $IP)
        if ($cachedProbe.ExitCode -eq 0) {
            return $true
        }

        $cachedText = (($cachedProbe.Stdout + $cachedProbe.Stderr) -join "`n")
        if (Test-NetworkFailureText $cachedText) {
            $script:LastHostKeyError = "NETWORK"
            Write-Warn "Nao foi possivel abrir conexao SSH TCP em ${User}@${IP}."
            Show-Result $cachedProbe "network"
            return $false
        }
        if (Test-AuthFailureText $cachedText) {
            $script:LastHostKeyError = "AUTH"
            Write-Warn "SSH respondeu, mas a senha/usuario foi rejeitada em ${User}@${IP}."
            Show-Result $cachedProbe "auth"
            return $false
        }

        $script:LastHostKeyError = "HOSTKEY"
        Write-Warn "Host key em cache para $IP, mas a validacao falhou."
        Show-Result $cachedProbe "hostkey"
        return $false
    }

    $probe = Invoke-PlinkProbe -IP $IP -User $User -Pwd $Pwd
    if ($probe.ExitCode -eq 0) {
        return $true
    }

    $text = (($probe.Stdout + $probe.Stderr) -join "`n")
    if (Test-NetworkFailureText $text) {
        $script:LastHostKeyError = "NETWORK"
        Write-Warn "Nao foi possivel abrir conexao SSH TCP em ${User}@${IP}."
        Show-Result $probe "network"
        return $false
    }

    if (Test-AuthFailureText $text) {
        $script:LastHostKeyError = "AUTH"
        Write-Warn "SSH respondeu, mas a senha/usuario foi rejeitada em ${User}@${IP}."
        Show-Result $probe "auth"
        return $false
    }

    $match = [regex]::Match($text, 'SHA256:[A-Za-z0-9+/=]+')
    if (-not $match.Success) {
        $script:LastHostKeyError = "HOSTKEY"
        Write-Warn "Nao foi possivel detectar fingerprint da host key de $IP."
        Show-Result $probe "hostkey"
        return $false
    }

    $fingerprint = $match.Value
    $script:HostKeyByIP[$IP] = $fingerprint

    $verify = Invoke-PlinkProbe -IP $IP -User $User -Pwd $Pwd -ExtraArgs (Get-HostKeyArgs -IP $IP)
    if ($verify.ExitCode -ne 0) {
        $verifyText = (($verify.Stdout + $verify.Stderr) -join "`n")
        if (Test-AuthFailureText $verifyText) {
            $script:LastHostKeyError = "AUTH"
            Write-Warn "Host key detectada ($fingerprint), mas a senha/usuario foi rejeitada em ${User}@${IP}."
            Show-Result $verify "auth"
            return $false
        }
        $script:LastHostKeyError = "HOSTKEY"
        Write-Warn "Fingerprint detectado ($fingerprint), mas a validacao com -hostkey falhou."
        Show-Result $verify "hostkey"
        return $false
    }

    Write-OK "Host key aceita para esta execucao: $fingerprint"
    return $true
}

function Invoke-SSH {
    param([string]$IP, [string]$User, [string]$Pwd, [string]$Command, [int]$TimeoutSec = 120)
    $plinkArgs = @(
        "-ssh", "-pw", $Pwd
    ) + (Get-HostKeyArgs -IP $IP) + @(
        "-batch",
        "${User}@${IP}",
        $Command
    )
    $proc = Start-Process -FilePath $plink -ArgumentList $plinkArgs `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput "$env:TEMP\plink_out_${IP}.txt" `
        -RedirectStandardError  "$env:TEMP\plink_err_${IP}.txt"

    $out = Get-Content "$env:TEMP\plink_out_${IP}.txt" -ErrorAction SilentlyContinue
    $err = Get-Content "$env:TEMP\plink_err_${IP}.txt" -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\plink_out_${IP}.txt","$env:TEMP\plink_err_${IP}.txt" -ErrorAction SilentlyContinue

    return @{ ExitCode = $proc.ExitCode; Stdout = $out; Stderr = $err }
}

function Invoke-SCP {
    param([string]$IP, [string]$User, [string]$Pwd, [string]$LocalPath, [string]$RemotePath)
    $scpArgs = @(
        "-pw", $Pwd
    ) + (Get-HostKeyArgs -IP $IP) + @(
        "-batch",
        "-r",
        $LocalPath,
        "${User}@${IP}:${RemotePath}"
    )
    $proc = Start-Process -FilePath $pscp -ArgumentList $scpArgs `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput "$env:TEMP\pscp_out_${IP}.txt" `
        -RedirectStandardError  "$env:TEMP\pscp_err_${IP}.txt"

    $out = Get-Content "$env:TEMP\pscp_out_${IP}.txt" -ErrorAction SilentlyContinue
    $err = Get-Content "$env:TEMP\pscp_err_${IP}.txt" -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\pscp_out_${IP}.txt","$env:TEMP\pscp_err_${IP}.txt" -ErrorAction SilentlyContinue

    return @{ ExitCode = $proc.ExitCode; Stdout = $out; Stderr = $err }
}

function Test-SSHUser {
    param([string]$IP, [string]$User, [string]$Pwd)
    $previousError = $script:LastHostKeyError
    if (Accept-HostKey -IP $IP -User $User -Pwd $Pwd) {
        return @{ Success = $true; User = $User; Error = "" }
    }
    $errorKind = $script:LastHostKeyError
    $script:LastHostKeyError = $previousError
    return @{ Success = $false; User = $User; Error = $errorKind }
}

function Resolve-SSHUser {
    param([string]$IP, [string]$PreferredUser, [string]$Pwd)

    $primary = Test-SSHUser -IP $IP -User $PreferredUser -Pwd $Pwd
    if ($primary.Success) {
        $script:LastHostKeyError = ""
        return $primary
    }

    if ($primary.Error -eq "AUTH") {
        foreach ($candidate in $FallbackUsers) {
            if (-not $candidate -or $candidate -eq $PreferredUser) {
                continue
            }
            Write-Warn "Falhou como ${PreferredUser}@${IP}; tentando ${candidate}@${IP} com a mesma senha..."
            $attempt = Test-SSHUser -IP $IP -User $candidate -Pwd $Pwd
            if ($attempt.Success) {
                Write-OK "Usuario alternativo aceito: ${candidate}@${IP}"
                $script:LastHostKeyError = ""
                return $attempt
            }
            if ($attempt.Error -ne "AUTH") {
                $script:LastHostKeyError = $attempt.Error
                return $attempt
            }
        }
    }

    $script:LastHostKeyError = $primary.Error
    return $primary
}

function Show-Result {
    param($result, [string]$label)
    if ($result.Stdout) { $result.Stdout | ForEach-Object { Write-Host "    | $_" } }
    if ($result.Stderr) { $result.Stderr | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host "    ! $_" -ForegroundColor DarkYellow } }
}

function ConvertTo-ShSingleQuoted {
    param([string]$Value)
    $escaped = $Value -replace "'", "'`"`"'`"`"'"
    return "'$escaped'"
}

function New-RootCommand {
    param([string]$User, [string]$Pwd, [string]$Command)

    $normalizedCommand = $Command -replace "`r`n", "`n" -replace "`r", "`n"
    $quotedCommand = ConvertTo-ShSingleQuoted $normalizedCommand
    if ($User -eq "root") {
        return "/bin/bash -c $quotedCommand"
    }

    $quotedPassword = ConvertTo-ShSingleQuoted $Pwd
    return "printf '%s\n' $quotedPassword | sudo -S -p '' /bin/bash -c $quotedCommand"
}

function Get-BindPolicyInstallArg {
    param([string]$Policy)
    if ($Policy -eq "allow_all") {
        return "--allow-all"
    }
    return "--allowlist-only"
}

function Get-ReleaseLocalInputScript {
    return @'
set +e
modprobe usbhid 2>/dev/null || true
for dev in /sys/bus/usb/devices/[0-9]*-[0-9]*; do
  [ -d "$dev" ] || continue
  busid="$(basename "$dev")"
  is_hid=0
  for iface in "$dev":*; do
    [ -f "$iface/bInterfaceClass" ] || continue
    cls="$(tr '[:upper:]' '[:lower:]' < "$iface/bInterfaceClass" 2>/dev/null)"
    [ "$cls" = "03" ] && is_hid=1
  done
  [ "$is_hid" = "1" ] || continue

  usbip unbind -b "$busid" >/dev/null 2>&1 || true

  for iface in "$dev":*; do
    [ -f "$iface/bInterfaceClass" ] || continue
    cls="$(tr '[:upper:]' '[:lower:]' < "$iface/bInterfaceClass" 2>/dev/null)"
    [ "$cls" = "03" ] || continue
    iface_name="$(basename "$iface")"
    [ -L "$iface/driver" ] && continue
    [ -w /sys/bus/usb/drivers/usbhid/bind ] && echo "$iface_name" > /sys/bus/usb/drivers/usbhid/bind 2>/dev/null || true
  done
done
udevadm trigger --subsystem-match=usb --action=change 2>/dev/null || true
udevadm settle 2>/dev/null || true
'@
}

$script:UsbipAllowedRules = @(
    @{ Vid = "303a"; Pid = "1001" },
    @{ Vid = "303a"; Pid = "*" },
    @{ Vid = "10c4"; Pid = "ea60" },
    @{ Vid = "1a86"; Pid = "7523" },
    @{ Vid = "0403"; Pid = "6010" },
    @{ Vid = "0403"; Pid = "6001" }
)

$script:UsbipBlockedRules = @(
    @{ Vid = "1d6b"; Pid = "*" },
    @{ Vid = "2a7a"; Pid = "9a18" },
    @{ Vid = "10c4"; Pid = "8105" }
)

function Test-VidPidRule {
    param([string]$Vid, [string]$ProductId, $Rule)
    $vidNorm = $Vid.ToLowerInvariant()
    $pidNorm = $ProductId.ToLowerInvariant()
    $ruleVid = ([string]$Rule.Vid).ToLowerInvariant()
    $rulePid = ([string]$Rule.Pid).ToLowerInvariant()
    return (($ruleVid -eq "*" -or $ruleVid -eq $vidNorm) -and ($rulePid -eq "*" -or $rulePid -eq $pidNorm))
}

function Test-UsbipAllowed {
    param([string]$Vid, [string]$ProductId)
    foreach ($rule in $script:UsbipBlockedRules) {
        if (Test-VidPidRule -Vid $Vid -ProductId $ProductId -Rule $rule) {
            return $false
        }
    }
    foreach ($rule in $script:UsbipAllowedRules) {
        if (Test-VidPidRule -Vid $Vid -ProductId $ProductId -Rule $rule) {
            return $true
        }
    }
    return $false
}

function Get-AttachedUsbipKeys {
    param([string]$UsbipExe)
    $keys = @{}
    $portText = & $UsbipExe port 2>&1
    foreach ($line in $portText) {
        if ($line -match 'usbip://([^/:]+)(?::[0-9]+)?/(\S+)') {
            $keys["$($matches[1].ToLowerInvariant())/$($matches[2])"] = $true
        }
    }
    return $keys
}

function Get-RemoteUsbipDevices {
    param([string]$UsbipExe, [string]$IP)
    $devices = @()
    $current = $null
    $listText = & $UsbipExe list -r $IP 2>&1
    foreach ($line in $listText) {
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

function Invoke-WindowsUsbipAttach {
    param([string]$IP)
    if ($SkipWindowsAttach -or -not $usbip) {
        return
    }

    Write-Step "Anexando no Windows dispositivos USB/IP permitidos de $IP ..."
    $sawAllowedDevice = $false
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $attached = Get-AttachedUsbipKeys -UsbipExe $usbip
        $devices = Get-RemoteUsbipDevices -UsbipExe $usbip -IP $IP
        foreach ($device in $devices) {
            if (-not $device.Vid -or -not $device.Pid) {
                Write-Warn "Ignorando $IP/$($device.BusId): VID/PID nao detectado."
                continue
            }
            if (-not (Test-UsbipAllowed -Vid $device.Vid -ProductId $device.Pid)) {
                if ($attempt -eq 1) {
                    Write-Step "Ignorando $IP/$($device.BusId) $($device.Vid):$($device.Pid) ($($device.Description))."
                }
                continue
            }
            $sawAllowedDevice = $true
            $key = "$($IP.ToLowerInvariant())/$($device.BusId)"
            if ($attached.ContainsKey($key)) {
                Write-OK "Ja anexado: $IP/$($device.BusId) $($device.Vid):$($device.Pid)"
                continue
            }
            $attachOut = & $usbip attach -r $IP -b $device.BusId 2>&1
            $attachText = ($attachOut -join "`n")
            if ($LASTEXITCODE -eq 0 -or $attachText -match 'already|busy|succesfully|successfully') {
                Write-OK "Anexado: $IP/$($device.BusId) $($device.Vid):$($device.Pid)"
                continue
            }
            Write-Warn "Falha ao anexar $IP/$($device.BusId) $($device.Vid):$($device.Pid)."
            $attachOut | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host "    ! $_" -ForegroundColor DarkYellow }
        }
        if ($sawAllowedDevice) {
            return
        }
        Start-Sleep -Seconds 3
    }
    Write-Warn "Nenhum dispositivo USB/IP permitido exportado por $IP apos aguardar."
}

function Update-WindowsBrokerConfig {
    $cfg = "C:\ProgramData\UsbipBrokerCpp\config.ini"
    if (-not (Test-Path -LiteralPath $cfg)) {
        return
    }
    $text = Get-Content -LiteralPath $cfg -Raw
    $changed = $false
    $allowed = "AllowedDevices=303a:1001,303a:*,10c4:ea60,1a86:7523,0403:6010,0403:6001"
    $blocked = "BlockedDevices=1d6b:*,2a7a:9a18,10c4:8105"
    if ($text -match '(?m)^AllowedDevices=') {
        $newText = $text -replace '(?m)^AllowedDevices=.*$', $allowed
    } else {
        $newText = $text -replace '(?m)^\[Broker\]\s*$', "[Broker]`r`n$allowed"
    }
    if ($newText -ne $text) { $changed = $true; $text = $newText }

    if ($text -match '(?m)^BlockedDevices=') {
        $newText = $text -replace '(?m)^BlockedDevices=.*$', $blocked
    } else {
        $newText = $text -replace '(?m)^AllowedDevices=.*$', "$allowed`r`n$blocked"
    }
    if ($newText -ne $text) { $changed = $true; $text = $newText }

    if ($changed) {
        Set-Content -LiteralPath $cfg -Value $text -Encoding ASCII
        Write-OK "Config do UsbipBrokerCpp atualizada: AllowedDevices/BlockedDevices"
        $svc = Get-Service -Name "UsbipBrokerCpp" -ErrorAction SilentlyContinue
        if ($svc) {
            Restart-Service -Name "UsbipBrokerCpp" -ErrorAction SilentlyContinue
            Write-OK "Servico UsbipBrokerCpp reiniciado"
        }
    }
}

Update-WindowsBrokerConfig

function Install-WindowsAutoAttachService {
    if ($SkipWindowsAttach) {
        return
    }

    $source = Join-Path $scriptDir "windows-usbip-autoattach.ps1"
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Warn "windows-usbip-autoattach.ps1 nao encontrado; hotplug automatico no Windows nao sera instalado."
        return
    }

    $destDir = "C:\ProgramData\UsbipBrokerCpp"
    $dest = Join-Path $destDir "usbip-autoattach.ps1"
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Copy-Item -LiteralPath $source -Destination $dest -Force

    $nssm = "C:\Program Files\Nssm\win64\nssm.exe"
    if (-not (Test-Path -LiteralPath $nssm)) {
        Write-Warn "nssm.exe nao encontrado; hotplug automatico no Windows nao sera instalado como servico."
        return
    }

    $old = Get-Service -Name "UsbipPythonService" -ErrorAction SilentlyContinue
    if ($old) {
        Stop-Service -Name "UsbipPythonService" -ErrorAction SilentlyContinue
        & $nssm set UsbipPythonService Start SERVICE_DISABLED | Out-Null
        Write-OK "Servico antigo UsbipPythonService desabilitado"
    }

    $svc = Get-Service -Name "UsbipAutoAttach" -ErrorAction SilentlyContinue
    if (-not $svc) {
        & $nssm install UsbipAutoAttach "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File `"$dest`"" | Out-Null
        & $nssm set UsbipAutoAttach AppDirectory $destDir | Out-Null
        & $nssm set UsbipAutoAttach Start SERVICE_AUTO_START | Out-Null
        Write-OK "Servico UsbipAutoAttach instalado"
    } else {
        & $nssm set UsbipAutoAttach Application "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" | Out-Null
        & $nssm set UsbipAutoAttach AppParameters "-NoProfile -ExecutionPolicy Bypass -File `"$dest`"" | Out-Null
        & $nssm set UsbipAutoAttach AppDirectory $destDir | Out-Null
        & $nssm set UsbipAutoAttach Start SERVICE_AUTO_START | Out-Null
    }

    Restart-Service -Name "UsbipAutoAttach" -ErrorAction SilentlyContinue
    Write-OK "Servico UsbipAutoAttach ativo"
}

function Update-WindowsBrokerThinClients {
    param($Hosts)
    $cfg = "C:\ProgramData\UsbipBrokerCpp\config.ini"
    if (-not (Test-Path -LiteralPath $cfg)) {
        return
    }

    $existing = @()
    $text = Get-Content -LiteralPath $cfg -Raw
    if ($text -match '(?m)^ThinClients=(.*)$') {
        $existing = $matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    $all = @($existing + ($Hosts | ForEach-Object { $_.IP })) | Where-Object { $_ } | Sort-Object -Unique
    $line = "ThinClients=$($all -join ',')"
    if ($text -match '(?m)^ThinClients=') {
        $newText = $text -replace '(?m)^ThinClients=.*$', $line
    } else {
        $newText = $text -replace '(?m)^\[Broker\]\s*$', "[Broker]`r`n$line"
    }
    if ($newText -ne $text) {
        Set-Content -LiteralPath $cfg -Value $newText -Encoding ASCII
        Write-OK "ThinClients atualizado no broker Windows"
        Restart-Service -Name "UsbipAutoAttach" -ErrorAction SilentlyContinue
    }
}

Install-WindowsAutoAttachService
Update-WindowsBrokerThinClients -Hosts $hosts

# ─── Deploy por host ──────────────────────────────────────────────────────────

$results = @{}

foreach ($node in $hosts) {
    $ip  = $node.IP
    $sshUser = $node.User
    $pwd = $node.Password

    Write-Header "[$sshUser@$ip]"

    # 0. Aceitar host key (primeira conexao)
    Write-Step "Aceitando host key SSH..."
    $userResolution = Resolve-SSHUser -IP $ip -PreferredUser $sshUser -Pwd $pwd
    if ($userResolution.Success) {
        $sshUser = $userResolution.User
    } else {
        if ($script:LastHostKeyError -eq "AUTH") {
            Write-Fail "Senha/usuario rejeitada em ${sshUser}@${ip}."
            $results[$ip] = "FALHA_AUTH"
        } elseif ($script:LastHostKeyError -eq "NETWORK") {
            Write-Fail "Nao foi possivel conectar na porta SSH em ${sshUser}@${ip}."
            $results[$ip] = "FALHA_REDE"
        } else {
            Write-Fail "Nao foi possivel validar host key SSH em $ip."
            $results[$ip] = "FALHA_HOSTKEY"
        }
        continue
    }

    # 1. Teste de conectividade
    Write-Step "Testando conexao SSH..."
    $test = Invoke-SSH -IP $ip -User $sshUser -Pwd $pwd -Command "echo pong" -TimeoutSec 15
    if ($test.ExitCode -ne 0) {
        Write-Fail "Nao foi possivel conectar em $ip (exit $($test.ExitCode))"
        Show-Result $test "conexao"
        $results[$ip] = "FALHA_CONEXAO"
        continue
    }
    Write-OK "SSH OK"

    # 2. Upload dos arquivos
    Write-Step "Enviando linux-usbip-manager/ para ${ip}:$RemoteDir ..."
    $sshMkdir = Invoke-SSH -IP $ip -User $sshUser -Pwd $pwd -Command "rm -rf '$RemoteDir' ; mkdir -p '$RemoteDir'"
    if ($sshMkdir.ExitCode -ne 0) {
        Write-Fail "Erro ao criar diretorio remoto."
        Show-Result $sshMkdir "mkdir"
        $results[$ip] = "FALHA_MKDIR"
        continue
    }

    $scpResult = Invoke-SCP -IP $ip -User $sshUser -Pwd $pwd -LocalPath "$managerDir\*" -RemotePath $RemoteDir
    if ($scpResult.ExitCode -ne 0) {
        Write-Fail "Erro no upload SCP (exit $($scpResult.ExitCode))."
        Show-Result $scpResult "scp"
        $results[$ip] = "FALHA_UPLOAD"
        continue
    }
    Write-OK "Upload concluido"

    # Normalizar line endings (CRLF -> LF) e tornar scripts executaveis
    $normalizeCmd = "for f in '$RemoteDir'/*.sh; do sed -i 's/\r$//' `"`$f`"; done; chmod +x '$RemoteDir'/*.sh '$RemoteDir'/bin/* 2>/dev/null || true"
    Invoke-SSH -IP $ip -User $sshUser -Pwd $pwd -Command $normalizeCmd | Out-Null

    # Se uma instalacao anterior exportou teclado/mouse, devolve HID ao Linux local.
    Write-Step "Garantindo que teclado/mouse USB fiquem locais..."
    $releaseInputResult = Invoke-SSH -IP $ip -User $sshUser -Pwd $pwd `
        -Command (New-RootCommand -User $sshUser -Pwd $pwd -Command (Get-ReleaseLocalInputScript)) `
        -TimeoutSec 60
    Show-Result $releaseInputResult "release-input"

    # 3. Limpeza do servico usbipd antigo; o install.sh cuida da instalacao do runtime.
    Write-Step "Removendo servico usbipd antigo e matando processos..."
    $cleanupScript = @'
systemctl stop usbipd 2>/dev/null || true
systemctl stop usbip-manager 2>/dev/null || true
systemctl disable usbipd 2>/dev/null || true
systemctl disable usbip-manager 2>/dev/null || true
# Mata todos os processos usbipd remanescentes
pkill usbipd 2>/dev/null || true
killall usbipd 2>/dev/null || true
for pid in $(pidof usbipd 2>/dev/null || true); do kill -9 "$pid" 2>/dev/null || true; done
# Garante liberação da porta 3240
fuser -k 3240/tcp 2>/dev/null || true
rm -f /etc/systemd/system/usbipd.service
rm -f /lib/systemd/system/usbipd.service
rm -f /etc/systemd/system/usbip-manager.service
rm -f /etc/systemd/system/usbip-manager-udev@.service
rm -f /lib/systemd/system/usbip-manager.service
rm -f /lib/systemd/system/usbip-manager-udev@.service
systemctl daemon-reload
systemctl reset-failed usbipd usbip-manager 2>/dev/null || true
modprobe -r usbip_host 2>/dev/null || true
modprobe -r usbip_core 2>/dev/null || true
# Reinicia o serviço usbipd após deploy
systemctl start usbipd 2>/dev/null || true
systemctl status usbipd 2>/dev/null || true
'@
    $cleanupResult = Invoke-SSH -IP $ip -User $sshUser -Pwd $pwd -Command (New-RootCommand -User $sshUser -Pwd $pwd -Command $cleanupScript) -TimeoutSec 180
    Show-Result $cleanupResult "cleanup"

    # 3b. Desinstalar (opcional)
    if (-not $SkipUninstall) {
        Write-Step "Executando uninstall.sh..."
        $uninstArgs = "--force"
        if ($KeepConfig) { $uninstArgs += " --keep-config" }
        $uninstallCmd = "bash '$RemoteDir/uninstall.sh' $uninstArgs 2>&1"
        $uninstResult = Invoke-SSH -IP $ip -User $sshUser -Pwd $pwd `
            -Command (New-RootCommand -User $sshUser -Pwd $pwd -Command $uninstallCmd) `
            -TimeoutSec 60
        Show-Result $uninstResult "uninstall"
        if ($uninstResult.ExitCode -ne 0) {
            Write-Warn "uninstall.sh retornou exit $($uninstResult.ExitCode) - continuando mesmo assim."
        } else {
            Write-OK "Desinstalacao concluida"
        }
    }

    # 4. Instalar
    $bindPolicyArg = Get-BindPolicyInstallArg -Policy $BindPolicy
    Write-Step "Executando install.sh $bindPolicyArg --server-ip $ServerIP --notify-port $NotifyPort ..."
    $installCmd = "bash '$RemoteDir/install.sh' $bindPolicyArg --server-ip '$ServerIP' --notify-host '$ServerIP' --notify-port '$NotifyPort' 2>&1"
    $installResult = Invoke-SSH -IP $ip -User $sshUser -Pwd $pwd -Command (New-RootCommand -User $sshUser -Pwd $pwd -Command $installCmd) -TimeoutSec 180
    Show-Result $installResult "install"

    if ($installResult.ExitCode -ne 0) {
        Write-Fail "install.sh falhou com exit $($installResult.ExitCode)."
        $results[$ip] = "FALHA_INSTALL"
    } else {
        Write-OK "Instalacao concluida com sucesso!"
        $results[$ip] = "OK"
    }

    # Garante novamente apos o udev trigger do instalador.
    Invoke-SSH -IP $ip -User $sshUser -Pwd $pwd `
        -Command (New-RootCommand -User $sshUser -Pwd $pwd -Command (Get-ReleaseLocalInputScript)) `
        -TimeoutSec 60 | Out-Null

    Invoke-WindowsUsbipAttach -IP $ip

    # 5. Limpar arquivos temporarios remotos
    Invoke-SSH -IP $ip -User $sshUser -Pwd $pwd -Command "rm -rf '$RemoteDir'" | Out-Null
}

# ─── Resumo final ─────────────────────────────────────────────────────────────

Write-Host "`n=============================================" -ForegroundColor White
Write-Host "  Resultado do deploy" -ForegroundColor White
Write-Host "=============================================" -ForegroundColor White

$ok   = 0
$fail = 0
foreach ($entry in $results.GetEnumerator() | Sort-Object Name) {
    if ($entry.Value -eq "OK") {
        Write-Host ("  {0,-18}  OK" -f $entry.Name) -ForegroundColor Green
        $ok++
    } else {
        Write-Host ("  {0,-18}  {1}" -f $entry.Name, $entry.Value) -ForegroundColor Red
        $fail++
    }
}

Write-Host ""
Write-Host ("  Total: " + $hosts.Count + "  |  Sucesso: $ok  |  Falha: $fail")
Write-Host ""

if ($fail -gt 0) { exit 1 } else { exit 0 }
