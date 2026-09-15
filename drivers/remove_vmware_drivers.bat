@echo off
rem ===============================================================
rem remove_vmware_drivers.bat
rem Thin wrapper around manage_vmware_pnp_devices.bat (mode: remove)
rem ===============================================================
call "%~dp0manage_vmware_pnp_devices.bat" remove
exit /b %errorlevel%
