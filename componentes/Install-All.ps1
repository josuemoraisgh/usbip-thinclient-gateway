#Requires -RunAsAdministrator
<#
    Orquestra a instalacao/execucao de tudo que esta na pasta
    c:\Prof_Jouse\00Instal\WinFullInstall\componentes, na ordem abaixo:

      1. setup-platformio-shared.ps1
      2. Driver NVIDIA GeForce GTX 1650
      3. Driver de chipset AMD (B550/AM4)
      4. OpenJDK 21 (MSI)
      5. 7-Zip
      6. Anaconda3
      7. CODESYS 64 3.5.21.0
      8. Scada-LTS Setup
      9. setup-scadalts-bancadas.ps1 (cria Scada-LTS isolado para 7 bancadas e professor)
      10. process_simul (MSI)
      11. ININDUFU-Setup
      12. USB/IP ThinClient Gateway (usbipd-win + broker C++ + monitor de bandeja)
      13. Configurar-Laboratorio-RDS.ps1 (pode reiniciar o servidor varias vezes)
      14. setup-codesys-bancadas.ps1 (cria uma instancia do CODESYS Control Win por bancada)
      15. organizar-desktops-laboratorio.ps1 (limpa o Desktop do professor e agrupa atalhos)

    Cada item e executado de forma interativa (janela visivel) e o script
    aguarda a conclusao de um antes de iniciar o proximo. Erros em um item
    sao registrados no log, mas nao impedem a execucao dos itens seguintes
    (exceto o ultimo, que controla seus proprios reboots).
#>

$SourceDir = 'C:\Prof_Jouse\00Instal\WinFullInstall\componentes'
$LogFile   = Join-Path $env:ProgramData 'WinFullInstall\install-all.log'

New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null
Start-Transcript -Path $LogFile -Append | Out-Null

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    Write-Host ""
    Write-Host "==================================================================="
    Write-Host " $Name"
    Write-Host "==================================================================="

    try {
        & $Action
        Write-Host "[OK] $Name concluido."
    }
    catch {
        Write-Warning "[FALHA] $Name : $($_.Exception.Message)"
    }
}

function Invoke-Installer {
    param(
        [string]$RelativePath,
        [string[]]$Arguments = @()
    )

    $path = Join-Path $SourceDir $RelativePath
    if (-not (Test-Path $path)) {
        throw "Arquivo nao encontrado: $path"
    }

    if ($Arguments.Count -gt 0) {
        Start-Process -FilePath $path -ArgumentList $Arguments -Wait
    } else {
        Start-Process -FilePath $path -Wait
    }
}

function Invoke-Msi {
    param(
        [string]$RelativePath,
        [string[]]$Arguments = @()
    )

    $path = Join-Path $SourceDir $RelativePath
    if (-not (Test-Path $path)) {
        throw "Arquivo nao encontrado: $path"
    }

    Start-Process -FilePath 'msiexec.exe' -ArgumentList (@('/i', "`"$path`"") + $Arguments) -Wait
}

function Invoke-Script {
    param(
        [string]$RelativePath,
        [string[]]$Arguments = @()
    )

    $path = Join-Path $SourceDir $RelativePath
    if (-not (Test-Path $path)) {
        throw "Arquivo nao encontrado: $path"
    }

    & $path @Arguments
}

Write-Host "Instalador WinFullInstall - pasta de origem: $SourceDir"
Write-Host "Log: $LogFile"

Invoke-Step 'Configuracao compartilhada do PlatformIO' {
    Invoke-Script 'setup-platformio-shared.ps1'
}

Invoke-Step 'OpenJDK 21 (MSI)' {
    Invoke-Msi 'OpenJDK21U-jdk_x64_windows_hotspot_21.0.7_6.msi'
}

Invoke-Step 'Driver NVIDIA GeForce GTX 1650' {
    Invoke-Installer '581.29-desktop-win10-win11-64bit-international-dch-whql.exe' @('/s', '/noreboot', '/clean')
}

Invoke-Step 'Driver de chipset AMD (B550/AM4)' {
    Invoke-Installer 'amd_chipset_software_8.05.04.516.exe' @('/S')
}

Invoke-Step '7-Zip' {
    Invoke-Installer '7z2601-x64.exe' @('/S')
}

Invoke-Step 'Anaconda3' {
    Invoke-Installer 'Anaconda3-2025.12-2-Windows-x86_64.exe' @('/InstallationType=AllUsers', '/AddToPath=1', '/RegisterPython=1', '/S', '/D=C:\ProgramData\Anaconda3')
}

Invoke-Step 'CODESYS 64 3.5.21.0' {
    Invoke-Installer 'CODESYS 64 3.5.21.0.exe'
}

Invoke-Step 'Scada-LTS Setup' {
    Invoke-Installer 'Scada-LTS_v2.7.8.1_Installer_v2.1.0_Setup.exe'
}

Invoke-Step 'Scada-LTS isolado por bancada' {
    Invoke-Script 'setup-scadalts-bancadas.ps1'
}

Invoke-Step 'process_simul (MSI)' {
    Invoke-Msi 'process_simul-v0.0.7-windows.msi'
}

Invoke-Step 'ININDUFU Setup' {
    Invoke-Installer 'ININDUFU-Setup.exe'
}

Invoke-Step 'USB/IP ThinClient Gateway (usbipd-win + broker + monitor de bandeja)' {
    Invoke-Script 'usbip-thinclient-gateway\windows-usbip-broker-cpp\instalar.ps1'
}

Invoke-Step 'Configurar-Laboratorio-RDS (AD DS + RDS) - pode reiniciar o servidor' {
    Invoke-Script 'Configurar-Laboratorio-RDS.ps1'
}

Invoke-Step 'CODESYS Control Win por bancada' {
    Invoke-Script 'setup-codesys-bancadas.ps1'
}

Invoke-Step 'Organizar Desktops do laboratorio' {
    Invoke-Script 'organizar-desktops-laboratorio.ps1'
}

Write-Host ""
Write-Host "==================================================================="
Write-Host " Todos os itens foram processados. Veja o log em: $LogFile"
Write-Host "==================================================================="

Stop-Transcript | Out-Null

Write-Host ""
Write-Host "Pressione qualquer tecla para fechar..."
[void][System.Console]::ReadKey($true)
