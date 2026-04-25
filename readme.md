# Windows (rodar como Administrador)
.\windows-cleanup.ps1
msiexec /i .\windows-usbip-broker-cpp\build\UsbipSuite-2.0.0-x64.msi

# Linux (em cada thin client, rodar como root)
sudo ./linux-usbip-manager/uninstall.sh
sudo ./linux-usbip-manager/install.sh
