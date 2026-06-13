#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Configura o servidor AD DS/RDS descrito nos documentos do TCC.

.DESCRIPTION
O script e idempotente e, quando uma reinicializacao e necessaria, ele
proprio registra uma tarefa agendada que o executa novamente na proxima
inicializacao, ate concluir todas as etapas. Ele:

- renomeia o servidor e instala AD DS, DNS/GPMC e os papeis RDS;
- instala o .NET Framework 3.5;
- cria a floresta felt.lasec;
- cria bancada204a-01 ate bancada204a-07 e bancada204b-01 ate bancada204b-16,
  todas com a senha fixa Feelt@lasec123!;
- cria o grupo Bancadas-RDS e autoriza o acesso remoto;
- cria uma implantacao RDS de sessao e a colecao Bancadas;
- configura o servidor de licencas RDS;
- reinicia o periodo de avaliacao de 120 dias do RDS (laboratorio reinstalado com frequencia);
- publica os programas mostrados no documento que estiverem instalados.

A senha DSRM e solicitada como SecureString. Para que a tarefa agendada de
continuacao possa terminar a configuracao sem interacao apos o reboot da
promocao a controlador de dominio, ela e gravada de forma criptografada
(AES, chave local restrita a SYSTEM/Administrators) em
C:\ProgramData\Configurar-Laboratorio-RDS e removida automaticamente quando
o script termina com sucesso.
O mesmo servidor recebe AD DS e todos os papeis RDS para reproduzir o
ambiente de servidor unico do documento.

.EXAMPLE
.\Configurar-Laboratorio-RDS.ps1
Reinicia automaticamente sempre que necessario (comportamento padrao) e
continua sozinho apos cada reboot, ate concluir toda a configuracao.

.EXAMPLE
.\Configurar-Laboratorio-RDS.ps1 -RestartAutomatically:$false
Nao reinicia automaticamente; apenas registra a tarefa de continuacao e
informa quando uma reinicializacao manual e necessaria.

.NOTES
Execute em uma janela do Windows PowerShell 5.1 aberta como Administrador.
Apos cada reinicializacao, a tarefa agendada "Configurar-Laboratorio-RDS-Continuacao"
executa o script novamente como SYSTEM. Garanta que, apos a criacao do
dominio, exista um administrador de dominio disponivel (a propria conta
usada para promover o servidor a controlador de dominio ja serve).

A ativacao do servidor de licencas RDS e a instalacao das CALs, alem da
instalacao/configuracao do VirtualHere, exigem dados externos que nao
constam nos documentos e, portanto, nao sao automatizadas aqui.

O periodo de avaliacao de 120 dias do RDS e reiniciado automaticamente
(chave GracePeriod) a cada execucao, para permitir o reuso continuo do
laboratorio sem licenciamento RDS valido. Use -SkipRDSGracePeriodReset
para desativar esse comportamento caso CALs validas sejam instaladas.
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
    [string]$ComputerName = 'FEELT-LASEC',

    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$DomainName = 'feelt.lasec',

    [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
    [string]$NetBIOSName = 'FEELT',

    [string]$CollectionName = 'Bancadas',

    [string]$CollectionDescription = 'Programas para as bancadas do laboratorio.',

    [string]$AccessGroupName = 'Bancadas-RDS',

    [ValidateSet('PerUser', 'PerDevice')]
    [string]$LicensingMode = 'PerUser',

    [string]$NetFramework35Source,

    [SecureString]$DSRMPassword,

    [SecureString]$UserPassword = (ConvertTo-SecureString -String 'Feelt@lasec123!' -AsPlainText -Force),

    [switch]$ResetExistingUserPasswords,

    [switch]$SkipComputerRename,

    [switch]$SkipRemoteApps,

    [switch]$SkipRDSGracePeriodReset,

    [switch]$RestartAutomatically = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StateDirectory = Join-Path $env:ProgramData 'Configurar-Laboratorio-RDS'
$ContinuationTaskName = 'Configurar-Laboratorio-RDS-Continuacao'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host ''
    Write-Host ('=== {0} ===' -f $Message) -ForegroundColor Cyan
}

function Test-PendingReboot {
    $rebootKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )

    foreach ($key in $rebootKeys) {
        if (Test-Path -LiteralPath $key) {
            return $true
        }
    }

    $activeName = Get-ItemPropertyValue `
        -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' `
        -Name ComputerName `
        -ErrorAction SilentlyContinue
    $pendingName = Get-ItemPropertyValue `
        -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
        -Name ComputerName `
        -ErrorAction SilentlyContinue

    return ($activeName -and $pendingName -and ($activeName -ine $pendingName))
}

function Initialize-StateDirectory {
    if (-not (Test-Path -LiteralPath $StateDirectory)) {
        New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    }

    $acl = Get-Acl -LiteralPath $StateDirectory
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }

    foreach ($identity in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }

    Set-Acl -LiteralPath $StateDirectory -AclObject $acl
}

function Get-StateKey {
    $keyPath = Join-Path $StateDirectory 'state.key'

    if (-not (Test-Path -LiteralPath $keyPath)) {
        Initialize-StateDirectory

        $key = New-Object byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($key)
        [System.IO.File]::WriteAllBytes($keyPath, $key)
    }

    return [System.IO.File]::ReadAllBytes($keyPath)
}

function Save-SecureStringToDisk {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][SecureString]$Value
    )

    Initialize-StateDirectory
    $key = Get-StateKey
    $encrypted = ConvertFrom-SecureString -SecureString $Value -Key $key
    Set-Content -LiteralPath (Join-Path $StateDirectory ('{0}.txt' -f $Name)) -Value $encrypted -Encoding ascii
}

function Get-SecureStringFromDisk {
    param([Parameter(Mandatory)][string]$Name)

    $path = Join-Path $StateDirectory ('{0}.txt' -f $Name)

    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    $key = Get-StateKey
    $encrypted = Get-Content -LiteralPath $path

    return ConvertTo-SecureString -String $encrypted -Key $key
}

function Remove-SavedState {
    if (Test-Path -LiteralPath $StateDirectory) {
        Remove-Item -LiteralPath $StateDirectory -Recurse -Force
    }
}

function Register-ContinuationTask {
    $argumentList = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath

    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]

        if ($value -is [SecureString]) {
            continue
        }

        if ($value -is [switch]) {
            if ($value.IsPresent) {
                $argumentList += (' -{0}' -f $key)
            }
            continue
        }

        $argumentList += (' -{0} "{1}"' -f $key, $value)
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argumentList
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    Register-ScheduledTask `
        -TaskName $ContinuationTaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force |
        Out-Null

    Write-Host 'Tarefa de continuacao automatica registrada para a proxima inicializacao.'
}

function Unregister-ContinuationTask {
    Unregister-ScheduledTask -TaskName $ContinuationTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Stop-ForRestart {
    param([Parameter(Mandatory)][string]$Reason)

    Write-Warning $Reason

    Register-ContinuationTask

    if ($RestartAutomatically) {
        Write-Host 'Reiniciando o servidor em 10 segundos...' -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        Restart-Computer -Force
        exit
    }

    Write-Host ''
    Write-Host 'Reinicie o servidor quando estiver pronto.' -ForegroundColor Yellow
    Write-Host 'A configuracao continuara automaticamente na proxima inicializacao do sistema.' -ForegroundColor Yellow
    Write-Host 'Se preferir continuar manualmente, execute novamente:'
    Write-Host ('  powershell.exe -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
    exit 3010
}

function Get-RequiredSecureString {
    param(
        [SecureString]$Value,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -ne $Value -and $Value.Length -gt 0) {
        Save-SecureStringToDisk -Name $Name -Value $Value
        return $Value
    }

    $savedValue = Get-SecureStringFromDisk -Name $Name
    if ($null -ne $savedValue -and $savedValue.Length -gt 0) {
        return $savedValue
    }

    if (-not [Environment]::UserInteractive) {
        throw ('A senha "{0}" e necessaria, mas esta sessao nao e interativa (provavelmente a tarefa de continuacao) e nenhum valor foi salvo de uma execucao anterior. Execute o script manualmente uma vez em um console interativo para informar essa senha.' -f $Name)
    }

    do {
        $secureString = Read-Host -Prompt $Prompt -AsSecureString

        if ($secureString.Length -eq 0) {
            Write-Warning 'A senha nao pode ser vazia.'
        }
    } while ($secureString.Length -eq 0)

    Save-SecureStringToDisk -Name $Name -Value $secureString
    return $secureString
}

function Reset-RDSGracePeriod {
    $gracePeriodKeyPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod'

    if (-not (Test-Path -LiteralPath $gracePeriodKeyPath)) {
        Write-Host 'O periodo de avaliacao do RDS ja esta zerado (chave GracePeriod inexistente).'
        return
    }

    Write-Warning 'Reiniciando o periodo de avaliacao de 120 dias do RDS para reuso do laboratorio.'

    # Por padrao, apenas NT AUTHORITY\SYSTEM tem acesso a esta chave (nem
    # BUILTIN\Administrators consegue abri-la, mesmo com SeTakeOwnershipPrivilege,
    # dependendo de como a sessao atual foi iniciada). Em vez de manipular
    # ACL/ownership, a remocao e feita por uma tarefa agendada executada como
    # SYSTEM, que tem acesso direto a chave.
    Initialize-StateDirectory

    $taskName = 'Configurar-Laboratorio-RDS-GracePeriod'
    $scriptPath = Join-Path $StateDirectory 'reset-grace-period.ps1'
    $resultPath = Join-Path $StateDirectory 'reset-grace-period.result'

    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue

    $innerScript = @'
$path = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod"
try {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
    "OK" | Set-Content -LiteralPath "__RESULT_PATH__"
}
catch {
    ("ERROR: " + $_.Exception.Message) | Set-Content -LiteralPath "__RESULT_PATH__"
}
'@.Replace('__RESULT_PATH__', $resultPath)

    Set-Content -LiteralPath $scriptPath -Value $innerScript -Encoding UTF8

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath)
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(2)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

    $timeout = (Get-Date).AddSeconds(30)
    while (-not (Test-Path -LiteralPath $resultPath) -and (Get-Date) -lt $timeout) {
        Start-Sleep -Seconds 1
    }

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $resultPath)) {
        throw 'Nao foi possivel remover a chave GracePeriod: a tarefa executada como SYSTEM nao concluiu a tempo.'
    }

    $result = (Get-Content -LiteralPath $resultPath -Raw).Trim()
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue

    if ($result -notmatch '^OK') {
        throw ('Nao foi possivel remover a chave GracePeriod: {0}' -f $result)
    }

    Restart-Service -Name TermService -Force

    Write-Host 'Periodo de avaliacao do RDS reiniciado para 120 dias.'
}

function Get-ThinClientServerAliases {
    return @('server-204a', 'server-204b')
}

function Set-ThinClientDnsAliases {
    param(
        [Parameter(Mandatory)][string]$ZoneName
    )

    Import-Module DnsServer

    $serverRecord = Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $env:COMPUTERNAME -RRType A -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $serverRecord) {
        throw ('Nao foi possivel localizar o registro DNS A do proprio servidor ({0}) na zona {1}.' -f $env:COMPUTERNAME, $ZoneName)
    }
    $serverIp = $serverRecord.RecordData.IPv4Address.IPAddressToString

    foreach ($alias in (Get-ThinClientServerAliases)) {
        $existing = Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $alias -RRType A -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if (-not $existing) {
            Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $alias -IPv4Address $serverIp
            Write-Host ('Registro DNS criado: {0}.{1} -> {2}' -f $alias, $ZoneName, $serverIp)
        }
        elseif ($existing.RecordData.IPv4Address.IPAddressToString -ne $serverIp) {
            $newRecord = $existing.Clone()
            $newRecord.RecordData.IPv4Address = [System.Net.IPAddress]::Parse($serverIp)
            Set-DnsServerResourceRecord -ZoneName $ZoneName -OldInputObject $existing -NewInputObject $newRecord
            Write-Host ('Registro DNS atualizado: {0}.{1} -> {2}' -f $alias, $ZoneName, $serverIp)
        }
        else {
            Write-Host ('Registro DNS ja correto: {0}.{1} -> {2}' -f $alias, $ZoneName, $serverIp)
        }
    }
}

function Grant-RemoteInteractiveLogonRight {
    param(
        [Parameter(Mandatory)][Microsoft.ActiveDirectory.Management.ADGroup]$Group,
        [Parameter(Mandatory)][string]$DomainDistinguishedName
    )

    # Em um controlador de dominio, "Allow log on through Remote Desktop
    # Services" (SeRemoteInteractiveLogonRight) e definido pela GPO "Default
    # Domain Controllers Policy" e, por padrao, contem apenas Administrators.
    # Ser membro de "Remote Desktop Users" (S-1-5-32-555) NAO concede esse
    # direito em um DC - por isso o grupo das bancadas precisa ser adicionado
    # diretamente nessa GPO, ou o RDP fica com handshake ok porem a sessao e
    # encerrada imediatamente (evento de Seguranca 4625, status 0xC000015B).
    $gpoGuid = '6AC1786C-016F-11D2-945F-00C04FB984F9'
    $gptTmplPath = "C:\Windows\SYSVOL\domain\Policies\{$gpoGuid}\Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf"
    $gptIniPath = "C:\Windows\SYSVOL\domain\Policies\{$gpoGuid}\GPT.INI"
    $gpoDN = "CN={$gpoGuid},CN=Policies,CN=System,$DomainDistinguishedName"

    $groupSidEntry = ('*{0}' -f $Group.SID.Value)
    $content = Get-Content -Path $gptTmplPath -Raw -Encoding Unicode
    $existingLine = ([regex]::Match($content, '(?m)^SeRemoteInteractiveLogonRight\s*=.*$')).Value

    if ($existingLine -and ($existingLine -match [regex]::Escape($groupSidEntry) -or $existingLine -match [regex]::Escape($Group.Name))) {
        Write-Host ('SeRemoteInteractiveLogonRight ja inclui {0}; nenhuma alteracao necessaria.' -f $Group.Name)
        return
    }

    if ($existingLine) {
        $content = $content.Replace($existingLine, ('{0},{1}' -f $existingLine, $groupSidEntry))
    }
    else {
        $newLine = ('SeRemoteInteractiveLogonRight = *S-1-5-32-544,{0}{1}' -f $groupSidEntry, "`r`n")
        $content = $content -replace '(\[Privilege Rights\]\r\n)', ('$1' + $newLine)
    }

    Set-Content -Path $gptTmplPath -Value $content -Encoding Unicode -NoNewline

    $iniContent = Get-Content -Path $gptIniPath -Raw
    $currentVersion = [int]([regex]::Match($iniContent, 'Version=(\d+)').Groups[1].Value)
    $newVersion = $currentVersion + 65536
    $iniContent = $iniContent -replace 'Version=\d+', "Version=$newVersion"
    Set-Content -Path $gptIniPath -Value $iniContent -Encoding ASCII -NoNewline
    Set-ADObject -Identity $gpoDN -Replace @{versionNumber = $newVersion }

    gpupdate /force /target:computer | Out-Null
    Write-Host ('Permissao "Allow log on through Remote Desktop Services" concedida ao grupo {0} via Default Domain Controllers Policy.' -f $Group.Name)
}

function Get-LaboratoryUserNames {
    $names = [System.Collections.Generic.List[string]]::new()

    foreach ($number in 1..7) {
        $names.Add(('bancada204a-{0:D2}' -f $number))
    }

    foreach ($number in 1..16) {
        $names.Add(('bancada204b-{0:D2}' -f $number))
    }

    return $names.ToArray()
}

function Test-StringSetEqual {
    param(
        [AllowEmptyCollection()][string[]]$Actual,
        [AllowEmptyCollection()][string[]]$Expected
    )

    $actualValues = @($Actual | Where-Object { $_ } | Sort-Object -Unique)
    $expectedValues = @($Expected | Where-Object { $_ } | Sort-Object -Unique)

    if ($actualValues.Count -ne $expectedValues.Count) {
        return $false
    }

    foreach ($expectedValue in $expectedValues) {
        if ($actualValues -inotcontains $expectedValue) {
            return $false
        }
    }

    return $true
}

function Get-ExistingProgramPath {
    param(
        [string[]]$Candidates,
        [string[]]$SearchRoots,
        [string[]]$FileNames
    )

    foreach ($candidate in @($Candidates)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    foreach ($root in @($SearchRoots)) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        foreach ($fileName in @($FileNames)) {
            $match = Get-ChildItem `
                -LiteralPath $root `
                -Filter $fileName `
                -File `
                -Recurse `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($match) {
                return $match.FullName
            }
        }
    }

    return $null
}

function Get-DocumentRemoteApps {
    $programFiles = $env:ProgramFiles
    $programFilesX86 = ${env:ProgramFiles(x86)}
    $system32 = [Environment]::GetFolderPath('System')
    $sysWow64 = Join-Path $env:windir 'SysWOW64'

    $officeRoots = @(
        (Join-Path $programFiles 'Microsoft Office'),
        (Join-Path $programFilesX86 'Microsoft Office')
    )
    $niRoots = @(
        (Join-Path $programFiles 'National Instruments'),
        (Join-Path $programFilesX86 'National Instruments')
    )

    return @(
        [pscustomobject]@{
            DisplayName = 'Access'
            Alias = 'access'
            Candidates = @(
                (Join-Path $programFiles 'Microsoft Office\root\Office16\MSACCESS.EXE'),
                (Join-Path $programFilesX86 'Microsoft Office\root\Office16\MSACCESS.EXE')
            )
            SearchRoots = $officeRoots
            FileNames = @('MSACCESS.EXE')
        }
        [pscustomobject]@{
            DisplayName = 'Arduino'
            Alias = 'arduino'
            Candidates = @(
                (Join-Path $programFilesX86 'Arduino\arduino.exe'),
                (Join-Path $programFiles 'Arduino IDE\Arduino IDE.exe'),
                (Join-Path $programFilesX86 'Arduino IDE\Arduino IDE.exe')
            )
            SearchRoots = @(
                (Join-Path $programFiles 'Arduino IDE'),
                (Join-Path $programFilesX86 'Arduino')
            )
            FileNames = @('arduino.exe', 'Arduino IDE.exe')
        }
        [pscustomobject]@{
            DisplayName = 'Calculator'
            Alias = 'calculator'
            Candidates = @((Join-Path $system32 'calc.exe'))
            SearchRoots = @()
            FileNames = @()
        }
        [pscustomobject]@{
            DisplayName = 'DataSocket Server'
            Alias = 'datasocket-server'
            Candidates = @()
            SearchRoots = $niRoots
            FileNames = @('cwdss.exe')
        }
        [pscustomobject]@{
            DisplayName = 'DataSocket Server Manager'
            Alias = 'datasocket-server-manager'
            Candidates = @()
            SearchRoots = $niRoots
            FileNames = @('cwdssmgr.exe')
        }
        [pscustomobject]@{
            DisplayName = 'Excel'
            Alias = 'excel'
            Candidates = @(
                (Join-Path $programFiles 'Microsoft Office\root\Office16\EXCEL.EXE'),
                (Join-Path $programFilesX86 'Microsoft Office\root\Office16\EXCEL.EXE')
            )
            SearchRoots = $officeRoots
            FileNames = @('EXCEL.EXE')
        }
        [pscustomobject]@{
            DisplayName = 'Google Chrome'
            Alias = 'chrome'
            Candidates = @(
                (Join-Path $programFiles 'Google\Chrome\Application\chrome.exe'),
                (Join-Path $programFilesX86 'Google\Chrome\Application\chrome.exe')
            )
            SearchRoots = @()
            FileNames = @()
        }
        [pscustomobject]@{
            DisplayName = 'LabVIEW 2013 (32-bit)'
            Alias = 'labview'
            Candidates = @(
                (Join-Path $programFilesX86 'National Instruments\LabVIEW 2013\LabVIEW.exe')
            )
            SearchRoots = $niRoots
            FileNames = @('LabVIEW.exe')
        }
        [pscustomobject]@{
            DisplayName = 'NI MAX'
            Alias = 'ni-max'
            Candidates = @()
            SearchRoots = $niRoots
            FileNames = @('NIMax.exe')
        }
        [pscustomobject]@{
            DisplayName = 'ODBC Data Sources (32-bit)'
            Alias = 'odbc-32'
            Candidates = @((Join-Path $sysWow64 'odbcad32.exe'))
            SearchRoots = @()
            FileNames = @()
        }
        [pscustomobject]@{
            DisplayName = 'OneNote 2016'
            Alias = 'onenote'
            Candidates = @(
                (Join-Path $programFiles 'Microsoft Office\root\Office16\ONENOTE.EXE'),
                (Join-Path $programFilesX86 'Microsoft Office\root\Office16\ONENOTE.EXE')
            )
            SearchRoots = $officeRoots
            FileNames = @('ONENOTE.EXE')
        }
        [pscustomobject]@{
            DisplayName = 'Outlook'
            Alias = 'outlook'
            Candidates = @(
                (Join-Path $programFiles 'Microsoft Office\root\Office16\OUTLOOK.EXE'),
                (Join-Path $programFilesX86 'Microsoft Office\root\Office16\OUTLOOK.EXE')
            )
            SearchRoots = $officeRoots
            FileNames = @('OUTLOOK.EXE')
        }
        [pscustomobject]@{
            DisplayName = 'Paint'
            Alias = 'paint'
            Candidates = @((Join-Path $system32 'mspaint.exe'))
            SearchRoots = @()
            FileNames = @()
        }
        [pscustomobject]@{
            DisplayName = 'PowerPoint'
            Alias = 'powerpoint'
            Candidates = @(
                (Join-Path $programFiles 'Microsoft Office\root\Office16\POWERPNT.EXE'),
                (Join-Path $programFilesX86 'Microsoft Office\root\Office16\POWERPNT.EXE')
            )
            SearchRoots = $officeRoots
            FileNames = @('POWERPNT.EXE')
        }
        [pscustomobject]@{
            DisplayName = 'Publisher'
            Alias = 'publisher'
            Candidates = @(
                (Join-Path $programFiles 'Microsoft Office\root\Office16\MSPUB.EXE'),
                (Join-Path $programFilesX86 'Microsoft Office\root\Office16\MSPUB.EXE')
            )
            SearchRoots = $officeRoots
            FileNames = @('MSPUB.EXE')
        }
        [pscustomobject]@{
            DisplayName = 'Python (command line)'
            Alias = 'python'
            Candidates = @(
                'C:\Python27\amd64\python.exe',
                'C:\Python27\python.exe',
                (Join-Path $programFiles 'Python312\python.exe'),
                (Join-Path $programFiles 'Python311\python.exe')
            )
            SearchRoots = @()
            FileNames = @()
        }
        [pscustomobject]@{
            DisplayName = 'Remote Desktop Connection'
            Alias = 'remote-desktop-connection'
            Candidates = @((Join-Path $system32 'mstsc.exe'))
            SearchRoots = @()
            FileNames = @()
        }
        [pscustomobject]@{
            DisplayName = 'Word'
            Alias = 'word'
            Candidates = @(
                (Join-Path $programFiles 'Microsoft Office\root\Office16\WINWORD.EXE'),
                (Join-Path $programFilesX86 'Microsoft Office\root\Office16\WINWORD.EXE')
            )
            SearchRoots = $officeRoots
            FileNames = @('WINWORD.EXE')
        }
        [pscustomobject]@{
            DisplayName = 'WordPad'
            Alias = 'wordpad'
            Candidates = @((Join-Path $system32 'write.exe'))
            SearchRoots = @()
            FileNames = @()
        }
        [pscustomobject]@{
            DisplayName = 'Notepad'
            Alias = 'notepad'
            Candidates = @((Join-Path $system32 'notepad.exe'))
            SearchRoots = @()
            FileNames = @()
        }
    )
}

Initialize-StateDirectory
try {
    Start-Transcript -Path (Join-Path $StateDirectory 'execucao.log') -Append | Out-Null
}
catch {
    Write-Warning ('Nao foi possivel iniciar o log de execucao: {0}' -f $_.Exception.Message)
}

Write-Step 'Validando o sistema operacional'
$operatingSystem = Get-CimInstance Win32_OperatingSystem
if ([int]$operatingSystem.ProductType -eq 1) {
    throw 'Este script deve ser executado no Windows Server.'
}

Write-Host ('Sistema: {0} ({1})' -f $operatingSystem.Caption, $operatingSystem.Version)

Write-Step 'Instalando .NET Framework 3.5, funcoes e preparando o nome do servidor'
Import-Module ServerManager

$restartRequired = $false
$computerSystem = Get-CimInstance Win32_ComputerSystem

if (-not $SkipComputerRename -and $computerSystem.Name -ine $ComputerName) {
    if ($computerSystem.PartOfDomain) {
        throw ('O servidor ja pertence ao dominio {0}; o nome nao sera alterado automaticamente.' -f $computerSystem.Domain)
    }

    Write-Host ('Renomeando {0} para {1}...' -f $computerSystem.Name, $ComputerName)
    Rename-Computer -NewName $ComputerName -Force
    $restartRequired = $true
}

$requiredFeatures = @(
    'NET-Framework-Core',
    'AD-Domain-Services',
    'GPMC',
    'RDS-RD-Server',
    'RDS-Licensing',
    'RDS-Connection-Broker',
    'RDS-Web-Access'
)

$missingFeatures = @(
    Get-WindowsFeature -Name $requiredFeatures |
        Where-Object { $_.InstallState -ne 'Installed' }
)

if ($missingFeatures.Count -gt 0) {
    Write-Host ('Instalando: {0}' -f ($missingFeatures.Name -join ', '))

    $featureInstallParameters = @{
        Name                   = $missingFeatures.Name
        IncludeManagementTools = $true
    }

    if ($NetFramework35Source) {
        if (-not (Test-Path -LiteralPath $NetFramework35Source -PathType Container)) {
            throw ('A fonte do .NET Framework 3.5 nao foi encontrada: {0}' -f $NetFramework35Source)
        }

        $featureInstallParameters.Source = $NetFramework35Source
    }

    $featureResult = Install-WindowsFeature @featureInstallParameters

    if (-not $featureResult.Success) {
        throw 'Uma ou mais funcoes do Windows Server nao puderam ser instaladas. Para o .NET 3.5, informe -NetFramework35Source apontando para a pasta sources\sxs da midia do Windows Server.'
    }

    if ($featureResult.RestartNeeded -eq 'Yes') {
        $restartRequired = $true
    }
}
else {
    Write-Host 'O .NET Framework 3.5 e as funcoes necessarias ja estao instalados.'
}

if ($restartRequired -or (Test-PendingReboot)) {
    Stop-ForRestart -Reason 'A preparacao inicial foi concluida e requer reinicializacao.'
}

Write-Step 'Validando ou criando o dominio'
$computerSystem = Get-CimInstance Win32_ComputerSystem

if (-not $computerSystem.PartOfDomain) {
    Import-Module ADDSDeployment
    $DSRMPassword = Get-RequiredSecureString `
        -Value $DSRMPassword `
        -Name 'DSRMPassword' `
        -Prompt 'Digite a senha do modo de restauracao do Active Directory (DSRM)'

    Write-Host ('Criando a floresta {0} com NetBIOS {1}...' -f $DomainName, $NetBIOSName)
    Install-ADDSForest `
        -DomainName $DomainName `
        -DomainNetbiosName $NetBIOSName `
        -InstallDns:$true `
        -SafeModeAdministratorPassword $DSRMPassword `
        -NoRebootOnCompletion:$true `
        -Force

    Stop-ForRestart -Reason 'A floresta do Active Directory foi criada e requer reinicializacao.'
}

Import-Module ActiveDirectory
$domain = Get-ADDomain
$computerSystem = Get-CimInstance Win32_ComputerSystem

if ($domain.DNSRoot -ine $DomainName) {
    throw ('Este servidor pertence a {0}, mas o script foi configurado para {1}.' -f $domain.DNSRoot, $DomainName)
}

if ([int]$computerSystem.DomainRole -lt 4) {
    throw 'Este servidor pertence ao dominio, mas nao e um controlador de dominio.'
}

Write-Host ('Dominio validado: {0} ({1})' -f $domain.DNSRoot, $domain.NetBIOSName)

Write-Step 'Configurando registros DNS para os thin clients (server-204a / server-204b)'
Set-ThinClientDnsAliases -ZoneName $domain.DNSRoot

Write-Step 'Criando grupo e usuarios das bancadas'
$accessGroup = $null
try {
    $accessGroup = Get-ADGroup -Identity $AccessGroupName -ErrorAction Stop
}
catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    $accessGroup = $null
}

if (-not $accessGroup) {
    $accessGroup = New-ADGroup `
        -Name $AccessGroupName `
        -SamAccountName $AccessGroupName `
        -GroupCategory Security `
        -GroupScope Global `
        -Path $domain.UsersContainer `
        -Description 'Usuarios autorizados a acessar a colecao RDS das bancadas.' `
        -PassThru

    Write-Host ('Grupo criado: {0}' -f $AccessGroupName)
}

$userNames = Get-LaboratoryUserNames

$existingLabUserNames = @(
    Get-ADUser -Filter "Name -like 'bancada*'" -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Name
)

if ($ResetExistingUserPasswords -or -not (Test-StringSetEqual -Actual $existingLabUserNames -Expected $userNames)) {
    if ($existingLabUserNames.Count -gt 0) {
        Write-Warning 'Usuarios das bancadas nao correspondem ao padrao esperado; removendo todos para recriar.'

        foreach ($userName in $existingLabUserNames) {
            Remove-ADUser -Identity $userName -Confirm:$false
            Write-Host ('Usuario removido: {0}' -f $userName)
        }
    }

    foreach ($userName in $userNames) {
        $userPrincipalName = ('{0}@{1}' -f $userName, $domain.DNSRoot)

        New-ADUser `
            -Name $userName `
            -DisplayName $userName `
            -SamAccountName $userName `
            -UserPrincipalName $userPrincipalName `
            -Path $domain.UsersContainer `
            -AccountPassword $UserPassword `
            -Enabled $true `
            -ChangePasswordAtLogon $false `
            -CannotChangePassword $true `
            -PasswordNeverExpires $true

        Add-ADGroupMember -Identity $accessGroup -Members $userName

        Write-Host ('Usuario criado: {0}' -f $userName)
    }
}
else {
    Write-Host 'Usuarios das bancadas ja estao corretos; nenhuma alteracao necessaria.'
}

$remoteDesktopUsersGroup = Get-ADGroup -Identity 'S-1-5-32-555'
$remoteDesktopMembers = @(
    Get-ADGroupMember -Identity $remoteDesktopUsersGroup -ErrorAction SilentlyContinue |
        ForEach-Object { $_.DistinguishedName }
)

if ($remoteDesktopMembers -notcontains $accessGroup.DistinguishedName) {
    Add-ADGroupMember -Identity $remoteDesktopUsersGroup -Members $accessGroup
}

Grant-RemoteInteractiveLogonRight -Group $accessGroup -DomainDistinguishedName $domain.DistinguishedName

Write-Host ('Usuarios preparados: {0}' -f ($userNames -join ', '))

Write-Step 'Configurando a implantacao RDS'
Import-Module RemoteDesktop

$serverFqdn = ('{0}.{1}' -f $env:COMPUTERNAME, $domain.DNSRoot).ToLowerInvariant()
$rdServers = @()
$requiredDeploymentRoles = @(
    'RDS-CONNECTION-BROKER',
    'RDS-WEB-ACCESS',
    'RDS-RD-SERVER',
    'RDS-LICENSING'
)

try {
    $rdServers = @(Get-RDServer -ConnectionBroker $serverFqdn -ErrorAction Stop)
}
catch {
    Write-Host 'Nenhuma implantacao RDS existente foi encontrada.'
}

if (-not ($rdServers | Where-Object { $_.Server -ieq $serverFqdn })) {
    Write-Warning 'Configurando AD DS e todos os papeis RDS no mesmo servidor, conforme o documento.'
    New-RDSessionDeployment `
        -ConnectionBroker $serverFqdn `
        -WebAccessServer $serverFqdn `
        -SessionHost $serverFqdn
}
else {
    Write-Host 'A implantacao RDS ja existe.'
}

$rdServers = @(Get-RDServer -ConnectionBroker $serverFqdn -ErrorAction Stop)
$deploymentServer = $rdServers |
    Where-Object { $_.Server -ieq $serverFqdn } |
    Select-Object -First 1

if (-not $deploymentServer) {
    throw ('O servidor {0} nao foi encontrado na implantacao RDS apos a configuracao.' -f $serverFqdn)
}

$currentDeploymentRoles = @($deploymentServer.Roles)

foreach ($role in $requiredDeploymentRoles) {
    if ($currentDeploymentRoles -icontains $role) {
        Write-Host ('Funcao RDS ja configurada na implantacao: {0}' -f $role)
        continue
    }

    Add-RDServer `
        -Server $serverFqdn `
        -Role $role `
        -ConnectionBroker $serverFqdn

    Write-Host ('Funcao RDS adicionada a implantacao: {0}' -f $role)
}

$currentLicenseConfiguration = Get-RDLicenseConfiguration `
    -ConnectionBroker $serverFqdn `
    -ErrorAction SilentlyContinue
$currentLicenseServers = @()
if ($currentLicenseConfiguration) {
    $currentLicenseServers = @($currentLicenseConfiguration.LicenseServer)
}

$licenseConfigurationNeedsUpdate = (
    -not $currentLicenseConfiguration -or
    ('{0}' -f $currentLicenseConfiguration.Mode) -ine $LicensingMode -or
    -not (Test-StringSetEqual -Actual $currentLicenseServers -Expected @($serverFqdn))
)

if ($licenseConfigurationNeedsUpdate) {
    Set-RDLicenseConfiguration `
        -Mode $LicensingMode `
        -LicenseServer $serverFqdn `
        -ConnectionBroker $serverFqdn `
        -Force

    Write-Host 'Configuracao de licenciamento RDS atualizada.'
}
else {
    Write-Host 'A configuracao de licenciamento RDS ja esta correta.'
}

if (-not $SkipRDSGracePeriodReset) {
    Write-Step 'Reiniciando o periodo de avaliacao do RDS'
    try {
        Reset-RDSGracePeriod
    }
    catch {
        Write-Warning ('Nao foi possivel reiniciar o periodo de avaliacao do RDS: {0}' -f $_.Exception.Message)
    }
}

$collection = @(
    Get-RDSessionCollection -ConnectionBroker $serverFqdn -ErrorAction SilentlyContinue |
        Where-Object { $_.CollectionName -eq $CollectionName }
)

if ($collection.Count -eq 0) {
    New-RDSessionCollection `
        -CollectionName $CollectionName `
        -CollectionDescription $CollectionDescription `
        -SessionHost $serverFqdn `
        -ConnectionBroker $serverFqdn

    Write-Host ('Colecao criada: {0}' -f $CollectionName)
}

$domainGroupReference = ('{0}\{1}' -f $domain.NetBIOSName, $AccessGroupName)
$generalConfiguration = Get-RDSessionCollectionConfiguration `
    -CollectionName $CollectionName `
    -ConnectionBroker $serverFqdn
$userGroupConfiguration = Get-RDSessionCollectionConfiguration `
    -CollectionName $CollectionName `
    -UserGroup `
    -ConnectionBroker $serverFqdn
$securityConfiguration = Get-RDSessionCollectionConfiguration `
    -CollectionName $CollectionName `
    -Security `
    -ConnectionBroker $serverFqdn

$collectionConfigurationNeedsUpdate = (
    -not $generalConfiguration -or
    $generalConfiguration.CollectionDescription -cne $CollectionDescription -or
    -not $userGroupConfiguration -or
    -not (Test-StringSetEqual -Actual @($userGroupConfiguration.UserGroup) -Expected @($domainGroupReference)) -or
    -not $securityConfiguration -or
    -not [bool]$securityConfiguration.AuthenticateUsingNLA
)

if ($collectionConfigurationNeedsUpdate) {
    Set-RDSessionCollectionConfiguration `
        -CollectionName $CollectionName `
        -CollectionDescription $CollectionDescription `
        -UserGroup @($domainGroupReference) `
        -AuthenticateUsingNLA $true `
        -ConnectionBroker $serverFqdn

    Write-Host ('Configuracao da colecao atualizada: {0}' -f $CollectionName)
}
else {
    Write-Host ('A colecao ja esta configurada: {0}' -f $CollectionName)
}

if (-not $SkipRemoteApps) {
    Write-Step 'Publicando os programas encontrados no servidor'

    $existingRemoteApps = @(
        Get-RDRemoteApp `
            -CollectionName $CollectionName `
            -ConnectionBroker $serverFqdn `
            -ErrorAction SilentlyContinue
    )
    $publishedAliases = @($existingRemoteApps | ForEach-Object { $_.Alias })
    $missingPrograms = [System.Collections.Generic.List[string]]::new()

    foreach ($app in Get-DocumentRemoteApps) {
        if ($publishedAliases -contains $app.Alias) {
            Write-Host ('Ja publicado: {0}' -f $app.DisplayName)
            continue
        }

        $filePath = Get-ExistingProgramPath `
            -Candidates $app.Candidates `
            -SearchRoots $app.SearchRoots `
            -FileNames $app.FileNames

        if (-not $filePath) {
            $missingPrograms.Add($app.DisplayName)
            continue
        }

        New-RDRemoteApp `
            -CollectionName $CollectionName `
            -DisplayName $app.DisplayName `
            -Alias $app.Alias `
            -FilePath $filePath `
            -ShowInWebAccess $true `
            -UserGroups @($domainGroupReference) `
            -ConnectionBroker $serverFqdn

        Write-Host ('Publicado: {0} -> {1}' -f $app.DisplayName, $filePath)
    }

    if ($missingPrograms.Count -gt 0) {
        Write-Warning ('Programas do documento nao instalados e, portanto, nao publicados: {0}' -f ($missingPrograms -join ', '))
    }
}

Write-Step 'Configuracao concluida'
Write-Host ('Dominio: {0}' -f $domain.DNSRoot)
Write-Host ('Servidor RDS: {0}' -f $serverFqdn)
Write-Host ('Colecao: {0}' -f $CollectionName)
Write-Host ('Grupo autorizado: {0}' -f $domainGroupReference)
Write-Host ('Usuarios criados/configurados: {0}' -f $userNames.Count)
Write-Warning 'Senha comum, senha sem expiracao e bloqueio de troca reproduzem o documento, mas reduzem a seguranca.'
if (-not $SkipRDSGracePeriodReset) {
    Write-Warning 'O periodo de avaliacao do RDS foi reiniciado para 120 dias (uso exclusivo de laboratorio de testes).'
}
else {
    Write-Warning 'Ainda e necessario ativar o servidor de licencas RDS e instalar CALs validas.'
}
Write-Warning 'O VirtualHere e os aplicativos laboratoriais precisam ser instalados/configurados separadamente.'

Unregister-ContinuationTask
try {
    Stop-Transcript | Out-Null
}
catch {
    # Nenhuma transcricao ativa.
}
Remove-SavedState
