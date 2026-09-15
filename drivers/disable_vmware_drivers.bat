@echo off
rem ===============================================================
rem disable_vmware_drivers.bat
rem Thin wrapper around manage_vmware_pnp_devices.bat (mode: disable)
rem ===============================================================
call "%~dp0manage_vmware_pnp_devices.bat" disable
exit /b %errorlevel%
