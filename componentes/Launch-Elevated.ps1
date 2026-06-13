<#
    Launcher do atalho "Instalar tudo - Laboratorio FEELT".

    Garante que Install-All.ps1 (que exige administrador) seja executado
    elevado, mesmo que o atalho tenha sido aberto por um usuario sem
    privilegios: se o processo atual nao for administrador, relanca a si
    mesmo via UAC (Start-Process -Verb RunAs).
#>

$installAll = Join-Path $PSScriptRoot 'Install-All.ps1'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Normal', '-File', "`"$installAll`"") `
        -Verb RunAs
    return
}

& $installAll
