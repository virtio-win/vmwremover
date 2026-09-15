@echo off
rem ===============================================================
rem disable_vmware_services.bat
rem Thin wrapper around manage_vmware_services.bat (mode: disable)
rem ===============================================================
call "%~dp0manage_vmware_services.bat" disable
exit /b %errorlevel%
