@echo off
rem ===============================================================
rem remove_vmware_services.bat
rem Thin wrapper around manage_vmware_services.bat (mode: remove)
rem ===============================================================
call "%~dp0manage_vmware_services.bat" remove
exit /b %errorlevel%
