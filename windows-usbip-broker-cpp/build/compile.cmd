@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
cl.exe /nologo /EHsc /std:c++17 /O2 /MT /Fo"C:\SourceCode\ThinClient\windows-usbip-broker-cpp\build\UsbipBrokerService.obj" /Fe"C:\SourceCode\ThinClient\windows-usbip-broker-cpp\build\UsbipBrokerService.exe" "C:\SourceCode\ThinClient\windows-usbip-broker-cpp\UsbipBrokerService.cpp" ws2_32.lib advapi32.lib
exit /b %errorlevel%
