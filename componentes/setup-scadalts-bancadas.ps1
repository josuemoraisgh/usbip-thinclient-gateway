#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Cria uma instancia isolada do Scada-LTS para cada bancada do laboratorio.

.DESCRIPTION
Mantem um unico MySQL e uma unica copia compartilhada do aplicativo, mas cria
para cada bancada:

- um schema e usuario MySQL exclusivos;
- um CATALINA_BASE em C:\config\scadalts\instances\<bancada>;
- um servico Windows Tomcat com porta HTTP exclusiva;
- logs, temporarios, uploads e configuracoes exclusivos.

O Scada-LTS original, normalmente publicado na porta 8080, nao e alterado.
O script e idempotente: pode ser executado novamente para reparar ou verificar
as instancias existentes.
#>

[CmdletBinding()]
param(
    [string]$BasePath = 'C:\config\scadalts',

    [string]$ScadaInstallPath = 'C:\Program Files\Scada-LTS',

    [int]$HttpPortBase = 8101,

    [int]$ShutdownPortBase = 18101,

    [string]$ServiceNamePrefix = 'ScadaLTS-',

    [string]$TemplateDatabase = 'scadalts',

    [int]$JvmMinMemoryMB = 64,

    [int]$JvmMaxMemoryMB = 256,

    [string[]]$Users,

    [SecureString]$MySqlRootPassword,

    [switch]$SkipStart,

    [switch]$SkipVerification,

    [switch]$LeaveRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MySqlHost = '127.0.0.1'
$MySqlPort = 3306
$MySqlServiceName = 'MySQL Community Server 8.0'
$SourceTomcat = Join-Path $ScadaInstallPath 'tomcat'
$SourceWebApp = Join-Path $SourceTomcat 'webapps\Scada-LTS'
$SourceContext = Join-Path $SourceTomcat 'conf\context.xml'
$MySqlBin = Join-Path $ScadaInstallPath 'mysql\bin'
$MySqlExe = Join-Path $MySqlBin 'mysql.exe'
$MySqlDumpExe = Join-Path $MySqlBin 'mysqldump.exe'
$CatalinaHome = Join-Path $BasePath 'catalina-home'
$SharedAppDirectory = Join-Path $BasePath 'app'
$SharedWebApp = Join-Path $SharedAppDirectory 'Scada-LTS'
$InstancesDirectory = Join-Path $BasePath 'instances'
$TempDirectory = Join-Path $BasePath 'temp'
$ReportsDirectory = Join-Path $BasePath 'reports'
$LaunchersDirectory = Join-Path $BasePath 'launchers'
$VerificationReport = Join-Path $ReportsDirectory 'last-verification.json'
$TemplateDump = Join-Path $TempDirectory 'scadalts-template.sql'
$RootDefaultsFile = Join-Path $TempDirectory 'mysql-root.cnf'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host ''
    Write-Host ('=== {0} ===' -f $Message) -ForegroundColor Cyan
}

function Get-LaboratoryUsers {
    $result = [System.Collections.Generic.List[string]]::new()

    1..7 | ForEach-Object { $result.Add(('bancada204a-{0:D2}' -f $_)) }

    return $result.ToArray()
}

function ConvertFrom-SecureStringPlainText {
    param([Parameter(Mandatory)][SecureString]$Value)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function ConvertTo-XmlAttribute {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    return [Security.SecurityElement]::Escape($Value)
}

function New-RandomHexPassword {
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Write-AsciiFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    [IO.File]::WriteAllText($Path, $Content, [Text.Encoding]::ASCII)
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$RedirectStandardInput,
        [string]$RedirectStandardOutput
    )

    $parameters = @{
        FilePath     = $FilePath
        ArgumentList = $ArgumentList
        Wait         = $true
        PassThru     = $true
        NoNewWindow  = $true
    }

    if ($RedirectStandardInput) {
        $parameters.RedirectStandardInput = $RedirectStandardInput
    }
    if ($RedirectStandardOutput) {
        $parameters.RedirectStandardOutput = $RedirectStandardOutput
    }

    $process = Start-Process @parameters
    if ($process.ExitCode -ne 0) {
        throw ('Comando falhou com codigo {0}: {1}' -f $process.ExitCode, $FilePath)
    }
}

function Sync-Directory {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "Falha ao sincronizar $Source para $Destination. Codigo robocopy: $LASTEXITCODE"
    }
}

function Invoke-MySql {
    param(
        [Parameter(Mandatory)][string]$Sql,
        [switch]$CaptureOutput
    )

    $arguments = @(
        ('--defaults-extra-file={0}' -f $RootDefaultsFile),
        '--batch',
        '--skip-column-names',
        ('--execute={0}' -f $Sql)
    )

    if ($CaptureOutput) {
        $output = & $MySqlExe @arguments
        if ($LASTEXITCODE -ne 0) {
            throw 'Falha ao executar comando no MySQL.'
        }
        return @($output)
    }

    & $MySqlExe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw 'Falha ao executar comando no MySQL.'
    }
}

function Get-DatabaseTableCount {
    param([Parameter(Mandatory)][string]$DatabaseName)

    $sql = "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DatabaseName';"
    return [int](Invoke-MySql -Sql $sql -CaptureOutput | Select-Object -First 1)
}

function Get-ExistingDatabasePassword {
    param([Parameter(Mandatory)][string]$ContextDescriptor)

    if (-not (Test-Path -LiteralPath $ContextDescriptor)) {
        return $null
    }

    try {
        $xml = [xml](Get-Content -LiteralPath $ContextDescriptor -Raw)
        return [string]$xml.Context.Resource.password
    }
    catch {
        return $null
    }
}

function Get-InstanceName {
    param([Parameter(Mandatory)][string]$UserName)

    return ($UserName -replace '[^A-Za-z0-9-]', '-')
}

function Get-DatabaseName {
    param([Parameter(Mandatory)][string]$UserName)

    return ('scadalts_{0}' -f ($UserName -replace '[^A-Za-z0-9]', '_').ToLowerInvariant())
}

function Get-DatabaseUserName {
    param([Parameter(Mandatory)][string]$UserName)

    return ('scada_{0}' -f ($UserName -replace '[^A-Za-z0-9]', '_').ToLowerInvariant())
}

function New-ServerXml {
    param(
        [Parameter(Mandatory)][int]$HttpPort,
        [Parameter(Mandatory)][int]$ShutdownPort
    )

    return @"
<?xml version="1.0" encoding="UTF-8"?>
<Server port="$ShutdownPort" shutdown="SHUTDOWN">
  <Listener className="org.apache.catalina.startup.VersionLoggerListener" />
  <Listener className="org.apache.catalina.core.JreMemoryLeakPreventionListener" />
  <Listener className="org.apache.catalina.mbeans.GlobalResourcesLifecycleListener" />
  <Listener className="org.apache.catalina.core.ThreadLocalLeakPreventionListener" />
  <Service name="Catalina">
    <Connector address="127.0.0.1"
               port="$HttpPort"
               protocol="HTTP/1.1"
               connectionTimeout="20000"
               maxThreads="50"
               minSpareThreads="2"
               compression="on" />
    <Engine name="Catalina" defaultHost="localhost">
      <Host name="localhost"
            appBase="webapps"
            unpackWARs="false"
            autoDeploy="false"
            deployOnStartup="true">
        <Valve className="org.apache.catalina.valves.AccessLogValve"
               directory="logs"
               prefix="access."
               suffix=".log"
               pattern="%h %l %u %t &quot;%r&quot; %s %b" />
      </Host>
    </Engine>
  </Service>
</Server>
"@
}

function New-ContextDescriptor {
    param(
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$DatabaseUser,
        [Parameter(Mandatory)][string]$DatabasePassword
    )

    $webApp = ConvertTo-XmlAttribute -Value $SharedWebApp
    $db = ConvertTo-XmlAttribute -Value $DatabaseName
    $user = ConvertTo-XmlAttribute -Value $DatabaseUser
    $password = ConvertTo-XmlAttribute -Value $DatabasePassword

    return @"
<?xml version="1.0" encoding="UTF-8"?>
<Context docBase="$webApp">
  <Resource name="jdbc/scadalts"
            auth="Container"
            type="javax.sql.DataSource"
            factory="org.apache.tomcat.jdbc.pool.DataSourceFactory"
            testWhileIdle="true"
            testOnBorrow="true"
            testOnReturn="false"
            validationQuery="SELECT 1"
            validationInterval="30000"
            timeBetweenEvictionRunsMillis="30000"
            maxActive="10"
            minIdle="1"
            maxIdle="3"
            initialSize="1"
            maxWait="10000"
            removeAbandonedTimeout="300"
            removeAbandoned="true"
            logAbandoned="false"
            minEvictableIdleTimeMillis="60000"
            jmxEnabled="false"
            username="$user"
            password="$password"
            driverClassName="com.mysql.jdbc.Driver"
            defaultTransactionIsolation="READ_COMMITTED"
            connectionProperties="useSSL=false;allowPublicKeyRetrieval=true"
            url="jdbc:mysql://localhost:$MySqlPort/$db" />
</Context>
"@
}

function Install-OrUpdate-TomcatService {
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$InstanceBase
    )

    $serviceExecutable = Join-Path $CatalinaHome 'bin\Scada-LTS.exe'
    $jvm = Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'bin\server\jvm.dll' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if (-not $jvm) {
        $jvm = 'auto'
    }

    $classPath = '{0};{1}' -f
        (Join-Path $CatalinaHome 'bin\bootstrap.jar'),
        (Join-Path $CatalinaHome 'bin\tomcat-juli.jar')
    $jvmOptions = @(
        ('-Dcatalina.home={0}' -f $CatalinaHome),
        ('-Dcatalina.base={0}' -f $InstanceBase),
        ('-Djava.io.tmpdir={0}' -f (Join-Path $InstanceBase 'temp')),
        '-Djava.util.logging.manager=org.apache.juli.ClassLoaderLogManager',
        ('-Djava.util.logging.config.file={0}' -f (Join-Path $InstanceBase 'conf\logging.properties'))
    ) -join '#'
    $jvmOptions9 = @(
        '--add-opens=java.base/java.lang=ALL-UNNAMED',
        '--add-opens=java.base/java.io=ALL-UNNAMED',
        '--add-opens=java.base/java.util=ALL-UNNAMED',
        '--add-opens=java.base/java.util.concurrent=ALL-UNNAMED',
        '--add-opens=java.rmi/sun.rmi.transport=ALL-UNNAMED'
    ) -join '#'

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $operation = if ($service) { '//US//' } else { '//IS//' }

    & $serviceExecutable "$operation$ServiceName" `
        "--Description=Scada-LTS isolado da bancada. Base: $InstanceBase" `
        "--DisplayName=$DisplayName" `
        "--Install=$serviceExecutable" `
        "--LogPath=$(Join-Path $InstanceBase 'logs')" `
        '--StdOutput=auto' `
        '--StdError=auto' `
        "--Classpath=$classPath" `
        "--Jvm=$jvm" `
        '--StartMode=jvm' `
        '--StopMode=jvm' `
        "--StartPath=$InstanceBase" `
        "--StopPath=$InstanceBase" `
        '--StartClass=org.apache.catalina.startup.Bootstrap' `
        '--StopClass=org.apache.catalina.startup.Bootstrap' `
        '--StartParams=start' `
        '--StopParams=stop' `
        "--JvmOptions=$jvmOptions" `
        "--JvmOptions9=$jvmOptions9" `
        '--Startup=manual' `
        "--JvmMs=$JvmMinMemoryMB" `
        "--JvmMx=$JvmMaxMemoryMB"

    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao instalar ou atualizar o servico $ServiceName."
    }

    & sc.exe config $ServiceName start= demand obj= 'NT AUTHORITY\LocalService' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao configurar a conta do servico $ServiceName."
    }

    Set-ItemProperty `
        -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" `
        -Name DependOnService `
        -Value @('Tcpip', 'Afd', $MySqlServiceName) `
        -Type MultiString
}

function Set-DirectoryPermissions {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Read', 'Modify')]
        [string]$LocalServiceAccess = 'Read'
    )

    $localServicePermission = if ($LocalServiceAccess -eq 'Modify') { 'M' } else { 'RX' }

    & icacls.exe $Path /inheritance:r `
        /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' `
        "*S-1-5-19:(OI)(CI)$localServicePermission" /Q |
        Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao aplicar permissoes na raiz $Path."
    }

    & icacls.exe (Join-Path $Path '*') /reset /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao propagar permissoes em $Path."
    }
}

function Set-BaseDirectoryPermissions {
    param([Parameter(Mandatory)][string]$Path)

    & icacls.exe $Path /inheritance:r `
        /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-19:(OI)(CI)RX' /Q |
        Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao aplicar permissoes na raiz $Path."
    }
}

function Set-LauncherPermissions {
    & icacls.exe $LaunchersDirectory /inheritance:r `
        /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /Q |
        Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao aplicar permissoes em $LaunchersDirectory."
    }

    & icacls.exe (Join-Path $LaunchersDirectory '*') /reset /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao propagar permissoes em $LaunchersDirectory."
    }
}

function New-Launcher {
    $launcherPath = Join-Path $LaunchersDirectory 'Abrir-ScadaLTS-Minha-Bancada.ps1'
    $launcher = @'
$ErrorActionPreference = 'Stop'
$name = $env:USERNAME.ToLowerInvariant()
$users = @()
1..7 | ForEach-Object { $users += ('bancada204a-{0:D2}' -f $_) }
$index = [Array]::IndexOf($users, $name)
if ($index -lt 0) {
    Add-Type -AssemblyName PresentationFramework
    [Windows.MessageBox]::Show("O usuario '$name' nao possui uma instancia Scada-LTS associada.", 'Scada-LTS') | Out-Null
    exit 1
}
$port = $HttpPortBase + $index
Start-Process ('http://localhost:{0}/Scada-LTS/' -f $port)
'@
    $launcher = $launcher.Replace('$HttpPortBase', [string]$HttpPortBase)
    Write-AsciiFile -Path $launcherPath -Content $launcher
}

if (-not $Users -or $Users.Count -eq 0) {
    $Users = Get-LaboratoryUsers
}

$allLaboratoryUsers = @(Get-LaboratoryUsers)
$Users = @($Users | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)

foreach ($userName in $Users) {
    if ([Array]::IndexOf($allLaboratoryUsers, $userName) -lt 0) {
        throw "Usuario fora do conjunto ativo das 7 bancadas: $userName"
    }
}

foreach ($requiredPath in @($SourceTomcat, $SourceWebApp, $SourceContext, $MySqlExe, $MySqlDumpExe)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Arquivo ou diretorio necessario nao encontrado: $requiredPath"
    }
}

$mysqlService = Get-Service -Name $MySqlServiceName -ErrorAction SilentlyContinue
if (-not $mysqlService) {
    throw "Servico MySQL nao encontrado: $MySqlServiceName"
}
Set-Service -Name $MySqlServiceName -StartupType Manual

$originalScadaService = Get-Service -Name 'Scada-LTS' -ErrorAction SilentlyContinue
if ($originalScadaService) {
    if ($originalScadaService.Status -ne 'Stopped') {
        Stop-Service -Name 'Scada-LTS' -Force
        $originalScadaService.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    }
    Set-Service -Name 'Scada-LTS' -StartupType Disabled
}

if ($mysqlService.Status -ne 'Running') {
    Start-Service -Name $MySqlServiceName
    $mysqlService.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
}

Write-Step 'Preparando estrutura compartilhada em C:\config'
foreach ($directory in @(
        $BasePath,
        $CatalinaHome,
        $SharedAppDirectory,
        $InstancesDirectory,
        $TempDirectory,
        $ReportsDirectory,
        $LaunchersDirectory
    )) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

Set-BaseDirectoryPermissions -Path $BasePath

foreach ($directoryName in @('bin', 'lib')) {
    $source = Join-Path $SourceTomcat $directoryName
    $destination = Join-Path $CatalinaHome $directoryName
    Sync-Directory -Source $source -Destination $destination
}
Sync-Directory -Source $SourceWebApp -Destination $SharedWebApp
$obsoleteSharedWar = Join-Path $SharedAppDirectory 'Scada-LTS.war'
if (Test-Path -LiteralPath $obsoleteSharedWar) {
    Remove-Item -LiteralPath $obsoleteSharedWar -Force
}

Set-DirectoryPermissions -Path $CatalinaHome -LocalServiceAccess Read
Set-DirectoryPermissions -Path $SharedAppDirectory -LocalServiceAccess Read

Write-Step 'Obtendo acesso administrativo temporario ao MySQL'
$rootPasswordPlain = if ($MySqlRootPassword) {
    ConvertFrom-SecureStringPlainText -Value $MySqlRootPassword
}
else {
    $sourceContextXml = [xml](Get-Content -LiteralPath $SourceContext -Raw)
    [string]$sourceContextXml.Context.Resource.password
}

if ([string]::IsNullOrEmpty($rootPasswordPlain)) {
    throw 'Nao foi possivel obter a senha administrativa do MySQL.'
}

$escapedRootPassword = $rootPasswordPlain.Replace('\', '\\').Replace('"', '\"')
$rootDefaults = @"
[client]
host=$MySqlHost
port=$MySqlPort
user=root
password="$escapedRootPassword"
protocol=TCP
"@
Write-AsciiFile -Path $RootDefaultsFile -Content $rootDefaults
& icacls.exe $RootDefaultsFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' /Q | Out-Null

try {
    $null = Invoke-MySql -Sql 'SELECT 1;' -CaptureOutput

    Write-Step "Criando dump-base do banco $TemplateDatabase"
    Invoke-Native `
        -FilePath $MySqlDumpExe `
        -ArgumentList @(
            ('--defaults-extra-file={0}' -f $RootDefaultsFile),
            '--single-transaction',
            '--routines',
            '--triggers',
            '--events',
            '--no-tablespaces',
            '--skip-comments',
            $TemplateDatabase
        ) `
        -RedirectStandardOutput $TemplateDump

    Write-Step 'Configurando bancos, instancias Tomcat e servicos'
    $instances = [System.Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt $Users.Count; $index++) {
        $userName = $Users[$index]
        $instanceName = Get-InstanceName -UserName $userName
        $databaseName = Get-DatabaseName -UserName $userName
        $databaseUser = Get-DatabaseUserName -UserName $userName
        $serviceName = '{0}{1}' -f $ServiceNamePrefix, $instanceName
        $laboratoryIndex = [Array]::IndexOf($allLaboratoryUsers, $userName)
        $httpPort = $HttpPortBase + $laboratoryIndex
        $shutdownPort = $ShutdownPortBase + $laboratoryIndex
        $instanceBase = Join-Path $InstancesDirectory $instanceName
        $contextDescriptor = Join-Path $instanceBase 'conf\Catalina\localhost\Scada-LTS.xml'

        Write-Host ('[{0}/{1}] {2} - porta {3}, banco {4}' -f
            ($index + 1), $Users.Count, $userName, $httpPort, $databaseName)

        $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $wasRunning = $existingService -and $existingService.Status -ne 'Stopped'
        if ($existingService -and $existingService.Status -ne 'Stopped') {
            Stop-Service -Name $serviceName -Force
            $existingService.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
        }

        $databasePassword = Get-ExistingDatabasePassword -ContextDescriptor $contextDescriptor
        if ([string]::IsNullOrEmpty($databasePassword)) {
            $databasePassword = New-RandomHexPassword
        }

        $sql = @"
CREATE DATABASE IF NOT EXISTS ``$databaseName`` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '$databaseUser'@'localhost' IDENTIFIED BY '$databasePassword';
ALTER USER '$databaseUser'@'localhost' IDENTIFIED BY '$databasePassword';
GRANT ALL PRIVILEGES ON ``$databaseName``.* TO '$databaseUser'@'localhost';
"@
        Invoke-MySql -Sql $sql

        if ((Get-DatabaseTableCount -DatabaseName $databaseName) -eq 0) {
            Invoke-Native `
                -FilePath $MySqlExe `
                -ArgumentList @(
                    ('--defaults-extra-file={0}' -f $RootDefaultsFile),
                    $databaseName
                ) `
                -RedirectStandardInput $TemplateDump
        }

        foreach ($directoryName in @(
                'conf',
                'conf\Catalina\localhost',
                'logs',
                'temp',
                'work',
                'webapps',
                'lib',
                'static',
                'static\uploads',
                'static\graphics'
            )) {
            New-Item -ItemType Directory -Path (Join-Path $instanceBase $directoryName) -Force | Out-Null
        }

        Copy-Item -Path (Join-Path $SourceTomcat 'conf\*') -Destination (Join-Path $instanceBase 'conf') -Recurse -Force
        New-Item -ItemType Directory -Path (Join-Path $instanceBase 'conf\Catalina\localhost') -Force | Out-Null

        Write-AsciiFile `
            -Path (Join-Path $instanceBase 'conf\server.xml') `
            -Content (New-ServerXml -HttpPort $httpPort -ShutdownPort $shutdownPort)
        Write-AsciiFile `
            -Path (Join-Path $instanceBase 'conf\context.xml') `
            -Content '<?xml version="1.0" encoding="UTF-8"?><Context><Manager pathname="" /></Context>'
        Write-AsciiFile `
            -Path $contextDescriptor `
            -Content (New-ContextDescriptor `
                -DatabaseName $databaseName `
                -DatabaseUser $databaseUser `
                -DatabasePassword $databasePassword)

        Set-DirectoryPermissions -Path $instanceBase -LocalServiceAccess Modify
        Install-OrUpdate-TomcatService `
            -ServiceName $serviceName `
            -DisplayName "Scada-LTS - $userName" `
            -InstanceBase $instanceBase

        $instances.Add([pscustomobject]@{
                UserName      = $userName
                ServiceName   = $serviceName
                DatabaseName  = $databaseName
                DatabaseUser  = $databaseUser
                HttpPort      = $httpPort
                ShutdownPort  = $shutdownPort
                InstanceBase  = $instanceBase
                Url           = "http://localhost:$httpPort/Scada-LTS/"
                WasRunning    = $wasRunning
            })
    }

    New-Launcher
    Set-LauncherPermissions

    $shortcutSetup = Join-Path $PSScriptRoot 'setup-scadalts-shortcuts.ps1'
    if (Test-Path -LiteralPath $shortcutSetup) {
        & $shortcutSetup -BasePath $BasePath
    }

    $servicesToStart = @(
        if ($SkipStart) {
            $instances | Where-Object WasRunning
        }
        else {
            $instances
        }
    )

    if ($servicesToStart.Count -gt 0) {
        Write-Step 'Iniciando servicos Scada-LTS'
        foreach ($instance in $servicesToStart) {
            $service = Get-Service -Name $instance.ServiceName
            if ($service.Status -ne 'Running') {
                Start-Service -Name $instance.ServiceName
                Start-Sleep -Milliseconds 500
            }
        }
    }

    if (-not $SkipVerification) {
        Write-Step 'Verificando bancos, servicos, portas e HTTP'
        $deadline = (Get-Date).AddMinutes(8)

        do {
            $notRunning = @(
                $instances | Where-Object {
                    (Get-Service -Name $_.ServiceName).Status -ne 'Running'
                }
            )
            if ($notRunning.Count -eq 0) {
                break
            }
            Start-Sleep -Seconds 3
        } while ((Get-Date) -lt $deadline)

        $results = @(
            foreach ($instance in $instances) {
            $service = Get-Service -Name $instance.ServiceName
            $tableCount = Get-DatabaseTableCount -DatabaseName $instance.DatabaseName
            $httpOk = $false
            $httpStatus = $null
            $httpError = $null

            for ($attempt = 1; $attempt -le 20 -and -not $httpOk; $attempt++) {
                try {
                    $response = Invoke-WebRequest `
                        -Uri $instance.Url.Replace('localhost', '127.0.0.1') `
                        -UseBasicParsing `
                        -MaximumRedirection 5 `
                        -TimeoutSec 15
                    $httpStatus = [int]$response.StatusCode
                    $httpOk = $httpStatus -ge 200 -and $httpStatus -lt 400
                }
                catch {
                    $httpError = $_.Exception.Message
                    Start-Sleep -Seconds 3
                }
            }

            $listening = $null -ne (
                Get-NetTCPConnection `
                    -LocalPort $instance.HttpPort `
                    -State Listen `
                    -ErrorAction SilentlyContinue |
                Select-Object -First 1
            )

            [pscustomobject]@{
                UserName     = $instance.UserName
                ServiceName  = $instance.ServiceName
                ServiceState = [string]$service.Status
                HttpPort     = $instance.HttpPort
                PortListening = $listening
                HttpOk       = $httpOk
                HttpStatus   = $httpStatus
                HttpError    = if ($httpOk) { $null } else { $httpError }
                DatabaseName = $instance.DatabaseName
                TableCount   = $tableCount
                InstanceBase = $instance.InstanceBase
                Url          = $instance.Url
            }
        }
        )

        $report = [pscustomobject]@{
            GeneratedAt = (Get-Date).ToString('o')
            BasePath = $BasePath
            CatalinaHome = $CatalinaHome
            SharedWebApp = $SharedWebApp
            InstanceCount = $results.Count
            SuccessfulCount = @(
                $results | Where-Object {
                    $_.ServiceState -eq 'Running' -and
                    $_.PortListening -and
                    $_.HttpOk -and
                    $_.TableCount -gt 0
                }
            ).Count
            Instances = $results
        }
        $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $VerificationReport -Encoding UTF8

        $results |
            Select-Object UserName, ServiceState, HttpPort, PortListening, HttpOk, TableCount |
            Format-Table -AutoSize

        if ($report.SuccessfulCount -ne $report.InstanceCount) {
            throw ('Verificacao falhou: {0} de {1} instancias estao corretas. Consulte {2}' -f
                $report.SuccessfulCount, $report.InstanceCount, $VerificationReport)
        }

        Write-Host ''
        Write-Host ('Todas as {0} instancias foram verificadas com sucesso.' -f $report.InstanceCount) -ForegroundColor Green
        Write-Host ('Relatorio: {0}' -f $VerificationReport)
    }

    if (-not $LeaveRunning) {
        Write-Step 'Deixando o laboratorio Scada-LTS parado'
        foreach ($instance in $instances) {
            $service = Get-Service -Name $instance.ServiceName -ErrorAction SilentlyContinue
            if ($service -and $service.Status -ne 'Stopped') {
                Stop-Service -Name $instance.ServiceName -Force
                $service.WaitForStatus('Stopped', [TimeSpan]::FromMinutes(3))
            }
            if ($service) {
                Set-Service -Name $instance.ServiceName -StartupType Manual
            }
        }

        $mysqlService = Get-Service -Name $MySqlServiceName
        if ($mysqlService.Status -ne 'Stopped') {
            Stop-Service -Name $MySqlServiceName -Force
            $mysqlService.WaitForStatus('Stopped', [TimeSpan]::FromMinutes(3))
        }
        Set-Service -Name $MySqlServiceName -StartupType Manual
        Write-Host 'MySQL e instancias das bancadas estao parados e com inicializacao manual.' -ForegroundColor Green
    }
}
finally {
    $rootPasswordPlain = $null
    if (Test-Path -LiteralPath $RootDefaultsFile) {
        Remove-Item -LiteralPath $RootDefaultsFile -Force
    }
}
