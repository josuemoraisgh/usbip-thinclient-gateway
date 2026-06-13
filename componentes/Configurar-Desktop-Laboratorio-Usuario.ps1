[CmdletBinding()]
param(
    [string]$ShortcutSource = 'C:\config\desktop-laboratorio\Aplicativos do Laboratorio'
)

$ErrorActionPreference = 'Stop'
$currentUser = $env:USERNAME.ToLowerInvariant()

if ($currentUser -notmatch '^bancada') {
    exit
}

$desktop = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $ShortcutSource)) {
    exit
}

$destination = Join-Path $desktop 'Aplicativos do Laboratorio'
New-Item -ItemType Directory -Path $destination -Force | Out-Null

Get-ChildItem -LiteralPath $ShortcutSource -File -Force |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destination $_.Name) -Force
    }

foreach ($obsoleteName in @(
        'CODESYS V3.5 SP21.lnk',
        'LibreOffice 26.2.lnk',
        'Microsoft Edge.lnk',
        'NVIDIA App.lnk',
        'PACTware 5.0.lnk',
        'Process Simul.lnk',
        'SimulIDE.lnk'
    )) {
    $obsoletePath = Join-Path $desktop $obsoleteName
    if (Test-Path -LiteralPath $obsoletePath) {
        Remove-Item -LiteralPath $obsoletePath -Force
    }
}
