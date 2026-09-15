@echo off
rem ===============================================================
rem manage_vmware_pnp_devices.bat
rem Disable or remove all VMware-related PnP devices (present and
rem non-present/ghost) via manage_vmware_pnp_devices.ps1. Uses only
rem built-in Windows facilities - Get-PnpDevice / Disable-PnpDevice
rem and, for removal, Remove-PnpDevice, "pnputil /remove-device", or
rem a SetupAPI (DiUninstallDevice) call - so no external binary ships.
rem Usage: manage_vmware_pnp_devices.bat disable^|remove
rem Called by disable_vmware_drivers.bat / remove_vmware_drivers.bat
rem ===============================================================

setlocal enabledelayedexpansion

set "MODE=%~1"
if /i not "%MODE%"=="disable" if /i not "%MODE%"=="remove" (
    echo Usage: %~nx0 disable^|remove
    exit /b 1
)

rem =============================
rem Check for admin privileges
rem =============================
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: This script must be run as Administrator!
    echo Please right-click and select "Run as administrator"
    exit /b 1
)

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "PNP_PS=%SCRIPT_DIR%\manage_vmware_pnp_devices.ps1"

echo.
echo ===============================================================
echo   VMware PnP device %MODE%
echo   Run as Administrator
echo ===============================================================
echo.

rem PnP device disable/remove has no batch-native equivalent, so this phase
rem needs PowerShell. If PowerShell is unavailable, skip cleanly (exit 0) so
rem the remaining cleanup phases still run - driver-package, service and
rem registry removal do not depend on this one.
call :DetectPowerShell
if not defined PS_OK (
    echo [SKIP] PnP device %MODE% requires PowerShell, which is unavailable here.
    echo [SKIP] Continuing - other cleanup phases still run.
    exit /b 0
)
if not exist "%PNP_PS%" (
    echo [ERROR] Helper not found: %PNP_PS%
    exit /b 1
)

"%PS_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PNP_PS%" -Mode %MODE%
exit /b %errorlevel%

rem ===============================================================
rem SUBROUTINES
rem ===============================================================

rem --- Detect whether PowerShell can actually run on this guest ---
:DetectPowerShell
rem Resolve powershell.exe explicitly rather than trusting it to be on PATH:
rem some hardened/customised guests drop the WindowsPowerShell dir from the
rem system PATH. Search PATH first, then the fixed System32 location, then
rem confirm it actually runs.
set "PS_OK="
set "PS_EXE="
for %%P in (powershell.exe) do if not defined PS_EXE if exist "%%~$PATH:P" set "PS_EXE=%%~$PATH:P"
if not defined PS_EXE if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PS_EXE goto :eof
"%PS_EXE%" -NoProfile -NonInteractive -Command "exit 0" >nul 2>&1
if errorlevel 1 goto :eof
set "PS_OK=1"
goto :eof
