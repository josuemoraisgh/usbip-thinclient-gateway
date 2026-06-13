#Requires -RunAsAdministrator
<#
    setup-platformio-shared.ps1

    Configura o PlatformIO para uso compartilhado em um servidor RDS com
    varias bancadas (sessoes) simultaneas:

      - PLATFORMIO_CORE_DIR / PLATFORMIO_PACKAGES_DIR / PLATFORMIO_PLATFORMS_DIR
        ficam compartilhados em C:\config\platformio (toolchains, frameworks,
        penv - itens grandes, GBs - instalados uma unica vez para todas as
        bancadas, evitando copias repetidas).

      - PLATFORMIO_CACHE_DIR fica POR USUARIO, em %LOCALAPPDATA%\platformio\cache
        (pequeno: cache de download/registry e o banco usado pelo Package/
        Library Manager). Compartilhar esse cache entre sessoes e a causa do
        erro "nao aceita dois VSCodes rodando o PlatformIO ao mesmo tempo"
        (conflitos de lock/banco quando duas sessoes escrevem no mesmo
        cache.db simultaneamente).

      - Desativa a inicializacao automatica do PIO Home
        (platformio-ide.disablePIOHomeStartup=true) no VSCode de cada
        bancada e no perfil "Default" (usado para novos usuarios), reduzindo
        processos/escritas em background que tambem disputavam o core
        compartilhado.
#>

$platformioDir = "C:\config\platformio"

# Itens GRANDES, compartilhados por todas as bancadas (instalados uma vez)
$sharedDirs = @{
    "PLATFORMIO_CORE_DIR"      = $platformioDir
    "PLATFORMIO_PACKAGES_DIR"  = Join-Path $platformioDir "packages"
    "PLATFORMIO_PLATFORMS_DIR" = Join-Path $platformioDir "platforms"
}

# Item pequeno (cache/registry/lock do Package Manager), exclusivo de cada
# usuario - evita conflitos quando varias bancadas usam o PlatformIO ao
# mesmo tempo no mesmo servidor.
$cacheDirPerUser = '%LOCALAPPDATA%\platformio\cache'

if (-not (Test-Path $platformioDir)) {
    New-Item -ItemType Directory -Path $platformioDir -Force | Out-Null
    Write-Host "Pasta criada: $platformioDir"
} else {
    Write-Host "Pasta ja existe: $platformioDir"
}

foreach ($dir in $sharedDirs.Values) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "Subpasta criada: $dir"
    }
}

foreach ($pair in $sharedDirs.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($pair.Key, $pair.Value, "Machine")
    Write-Host "Variavel de ambiente $($pair.Key) definida para todos os usuarios (compartilhado): $($pair.Value)"
}

# PLATFORMIO_CACHE_DIR precisa ser gravada como REG_EXPAND_SZ para que
# %LOCALAPPDATA% seja expandido para a pasta de cada usuario (e nao para a
# pasta literal "%LOCALAPPDATA%"). [Environment]::SetEnvironmentVariable nao
# cria esse tipo de valor, por isso usamos a API de registro diretamente.
[Microsoft.Win32.Registry]::SetValue(
    "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment",
    "PLATFORMIO_CACHE_DIR",
    $cacheDirPerUser,
    [Microsoft.Win32.RegistryValueKind]::ExpandString) | Out-Null
Write-Host "Variavel de ambiente PLATFORMIO_CACHE_DIR definida para todos os usuarios (por usuario): $cacheDirPerUser"

icacls $platformioDir /grant "Users:(OI)(CI)M" /T | Out-Null
Write-Host "Permissoes de modificacao concedidas ao grupo Users em $platformioDir"

# ---------------------------------------------------------------------------
# Evita que cada sessao do VSCode inicie automaticamente o servidor PIO Home
# (reduz conflitos/escritas concorrentes no core compartilhado quando varias
# bancadas usam o PlatformIO ao mesmo tempo).
# ---------------------------------------------------------------------------

function Set-VSCodeSetting {
    param(
        [string]$SettingsPath,
        [string]$Key,
        $Value
    )

    $dir = Split-Path $SettingsPath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path $SettingsPath) {
        $raw = (Get-Content $SettingsPath -Raw).Trim()
        try {
            $json = if ($raw) { $raw | ConvertFrom-Json } else { New-Object PSObject }
        }
        catch {
            Write-Warning "Nao foi possivel interpretar $SettingsPath como JSON, pulando."
            return
        }
    }
    else {
        $json = New-Object PSObject
    }

    if ($json.PSObject.Properties.Name -contains $Key) {
        $json.$Key = $Value
    }
    else {
        $json | Add-Member -MemberType NoteProperty -Name $Key -Value $Value
    }

    ($json | ConvertTo-Json -Depth 10) | Set-Content -Path $SettingsPath -Encoding UTF8
}

# Perfil "Default" - usado como base para usuarios que ainda nao fizeram logon
Set-VSCodeSetting -SettingsPath "C:\Users\Default\AppData\Roaming\Code\User\settings.json" `
    -Key 'platformio-ide.disablePIOHomeStartup' -Value $true
Write-Host "Perfil Default: platformio-ide.disablePIOHomeStartup=true"

# Perfis de usuarios ja existentes (Administrator e as bancadas que ja fizeram logon)
Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'Administrator' -or $_.Name -like 'bancada*' } |
    ForEach-Object {
        $settingsPath = Join-Path $_.FullName "AppData\Roaming\Code\User\settings.json"
        Set-VSCodeSetting -SettingsPath $settingsPath -Key 'platformio-ide.disablePIOHomeStartup' -Value $true
        Write-Host "Perfil $($_.Name): platformio-ide.disablePIOHomeStartup=true"
    }

Write-Host "Concluido. Os usuarios precisam abrir uma nova sessao/terminal para as variaveis de ambiente fazerem efeito."
