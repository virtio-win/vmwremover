@echo off
rem ===============================================================
rem cleanup_vmware_leftovers.bat
rem Orchestrates the full VMware leftover cleanup after a V2V/CNV
rem migration: disables and removes PnP devices, driver packages,
rem registry entries, the Winsock provider, and services, in a safe,
rem unattended order.
rem Runs best-effort - a problem in one phase does not stop the rest.
rem 
rem HYBRID: nearly every phase is pure batch and always runs, so
rem PowerShell-locked guests are still cleaned up. The one remaining
rem PowerShell phase (Winsock catalog scrub across ALL ControlSets)
rem needs binary-GUID matching that batch cannot do; it is best-effort
rem and, if PowerShell is unavailable, is simply skipped - the batch
rem netsh Winsock phase still handles the live catalog. A PowerShell
rem phase failure is logged as a warning and never aborts the run.
rem 
rem NOTE: advanced/unsupported binary file deletion
rem (files\remove_vmware_binaries.bat) is deliberately NOT run here -
rem it deletes files with no undo and is kept as an opt-in step.
rem ===============================================================

setlocal enabledelayedexpansion

rem =============================
rem Check for admin privileges
rem =============================
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: This script must be run as Administrator!
    echo Please right-click and select "Run as administrator"
rem    pause
    exit /b 1
)

rem --- Script directory ---
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "LOG=%SCRIPT_DIR%\cleanup_vmware_leftovers.log"

echo =============================================================== > "%LOG%"
echo   VMware Leftover Cleanup - %DATE% %TIME% >> "%LOG%"
echo =============================================================== >> "%LOG%"

echo.
echo ===============================================================
echo   VMware Leftover Cleanup (full run)
echo   Run as Administrator
echo ===============================================================
echo.

set /a REBOOT_REQUIRED=0
set /a FAILED_PHASES=0

rem --- Detect whether PowerShell can actually run on this guest ---
call :DetectPowerShell
if defined PS_OK (
    echo [INFO] PowerShell available - enhanced phases enabled.
    echo [INFO] PowerShell available - enhanced phases enabled. >> "%LOG%"
) else (
    echo [INFO] PowerShell unavailable - running batch-only baseline.
    echo [INFO] PowerShell unavailable - running batch-only baseline. >> "%LOG%"
)

rem ===============================================================
rem Phase order: disable/quiesce first, remove devices and driver
rem packages next, clean up the registry and Winsock, and delete
rem services last (earlier phases may still query them). PowerShell
rem augment phases run alongside their batch counterparts.
rem ===============================================================
call :RunPhase   "Disable PnP devices"          "drivers\disable_vmware_drivers.bat"
call :RunPhase   "Disable services"             "services\disable_vmware_services.bat"
rem "Remove PnP device instances" removes present AND non-present (ghost) VMware
rem nodes in one pass, so no separate ghost-removal phase is needed. The
rem standalone drivers\remove_ghost_devices.ps1 remains for the verifier's
rem remediation hint and delegates to the same manager.
call :RunPhase   "Remove PnP device instances"  "drivers\remove_vmware_drivers.bat"
call :RunPhase   "Remove driver packages"       "drivers\remove_vmware_driver_packages.bat"
call :RunPhase   "Clean legacy DRVSTORE"        "drivers\clean_legacy_drvstore.bat"
call :RunPhase   "Remove orphaned DriverStore packages" "drivers\remove_orphaned_driverstore.bat"
call :RunPhase   "Remove registry entries"      "reg\remove_vmware_registry.bat"
call :RunPhase   "Remove Winsock provider"      "reg\remove_vmware_winsock.bat"
call :RunPhase   "Remove services (all ControlSets)" "reg\delete_services_all_controlsets.bat"
call :RunPSPhase "Remove Winsock catalog (all ControlSets)" "reg\delete_winsock_registry.ps1"
call :RunPhase   "Remove services"              "services\remove_vmware_services.bat"

echo.
echo ===============================================================
echo  VMware leftover cleanup finished
echo  Log saved to: %LOG%
if %FAILED_PHASES% GTR 0 (
    echo  %FAILED_PHASES% phase^(s^) reported a non-zero exit code - see log/console output above.
)
if %REBOOT_REQUIRED% EQU 1 (
    echo.
    echo WARNING: A system reboot is required to complete the cleanup.
    echo Please restart your computer when convenient.
)
echo ===============================================================

echo =============================================================== >> "%LOG%"
echo  Failed phases: %FAILED_PHASES% >> "%LOG%"
echo  Reboot required: %REBOOT_REQUIRED% >> "%LOG%"
echo =============================================================== >> "%LOG%"

if %REBOOT_REQUIRED% EQU 1 (
    exit /b 3010
)
exit /b 0

rem ===============================================================
rem SUBROUTINES
rem ===============================================================

rem --- Detect whether PowerShell can actually run on this guest ---
:DetectPowerShell
rem Resolve powershell.exe explicitly rather than trusting it to be on
rem PATH: some hardened/customised guests drop the WindowsPowerShell dir
rem from the system PATH, so a bare "powershell" is not found and every
rem PS step is silently skipped. Search PATH first, then fall back to the
rem fixed System32 location, then confirm it actually runs. PS_EXE is
rem reused by all later PS calls so they resolve identically.
set "PS_OK="
set "PS_EXE="
for %%P in (powershell.exe) do if not defined PS_EXE if exist "%%~$PATH:P" set "PS_EXE=%%~$PATH:P"
if not defined PS_EXE if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PS_EXE (
    echo [INFO] powershell.exe not found - batch-only baseline.
    echo [INFO] powershell.exe not found - batch-only baseline. >> "%LOG%"
    goto :eof
)
"%PS_EXE%" -NoProfile -NonInteractive -Command "exit 0" >nul 2>&1
if errorlevel 1 (
    echo [INFO] powershell.exe found but probe failed - batch-only baseline.
    echo [INFO] powershell.exe found ^(!PS_EXE!^) but probe failed. >> "%LOG%"
    goto :eof
)
set "PS_OK=1"
echo [INFO] PowerShell resolved: !PS_EXE!
echo [INFO] PowerShell resolved: !PS_EXE! >> "%LOG%"
goto :eof

rem --- Subroutine: run one batch cleanup phase and record its result ---
:RunPhase
setlocal enabledelayedexpansion
set "PHASE_LABEL=%~1"
set "PHASE_SCRIPT=%SCRIPT_DIR%\%~2"

echo ---------------------------------------------------------------
echo [PHASE] !PHASE_LABEL!
echo ---------------------------------------------------------------
echo [PHASE] !PHASE_LABEL! >> "%LOG%"

if not exist "!PHASE_SCRIPT!" (
    echo [ERROR] Script not found: !PHASE_SCRIPT!
    echo [ERROR] Script not found: !PHASE_SCRIPT! >> "%LOG%"
    endlocal & set /a FAILED_PHASES+=1
    goto :eof
)

call "!PHASE_SCRIPT!"
set "PHASE_RESULT=%errorlevel%"

if "!PHASE_RESULT!"=="3010" (
    echo [OK] !PHASE_LABEL! completed - reboot required
    echo [OK] !PHASE_LABEL! completed - reboot required >> "%LOG%"
    endlocal & set /a REBOOT_REQUIRED=1
    goto :eof
)

if "!PHASE_RESULT!"=="0" (
    echo [OK] !PHASE_LABEL! completed
    echo [OK] !PHASE_LABEL! completed >> "%LOG%"
    endlocal
    goto :eof
)

echo [WARNING] !PHASE_LABEL! exited with code !PHASE_RESULT!
echo [WARNING] !PHASE_LABEL! exited with code !PHASE_RESULT! >> "%LOG%"
endlocal & set /a FAILED_PHASES+=1
goto :eof

rem --- Subroutine: run one best-effort PowerShell augment phase ---
rem Skipped when PowerShell is unavailable or the script is missing.
rem A non-zero (non-3010) exit is a warning only - it does NOT count
rem as a failed phase, since these phases are optional augmentation.
:RunPSPhase
setlocal enabledelayedexpansion
set "PHASE_LABEL=%~1"
set "PHASE_SCRIPT=%SCRIPT_DIR%\%~2"

if not defined PS_OK (
    echo [SKIP] !PHASE_LABEL! ^(PowerShell unavailable^) >> "%LOG%"
    endlocal
    goto :eof
)

echo ---------------------------------------------------------------
echo [PHASE:PS] !PHASE_LABEL!
echo ---------------------------------------------------------------
echo [PHASE:PS] !PHASE_LABEL! >> "%LOG%"

if not exist "!PHASE_SCRIPT!" (
    echo [SKIP] Script not found: !PHASE_SCRIPT!
    echo [SKIP] Script not found: !PHASE_SCRIPT! >> "%LOG%"
    endlocal
    goto :eof
)

"!PS_EXE!" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "!PHASE_SCRIPT!" > "%temp%\vmw_ps_out.txt" 2>&1
set "PHASE_RESULT=%errorlevel%"
type "%temp%\vmw_ps_out.txt"
type "%temp%\vmw_ps_out.txt" >> "%LOG%"
del "%temp%\vmw_ps_out.txt" >nul 2>&1

if "!PHASE_RESULT!"=="3010" (
    echo [OK] !PHASE_LABEL! completed - reboot required
    echo [OK] !PHASE_LABEL! completed - reboot required >> "%LOG%"
    endlocal & set /a REBOOT_REQUIRED=1
    goto :eof
)

if "!PHASE_RESULT!"=="0" (
    echo [OK] !PHASE_LABEL! completed
    echo [OK] !PHASE_LABEL! completed >> "%LOG%"
    endlocal
    goto :eof
)

echo [WARNING] !PHASE_LABEL! (PowerShell) exited with code !PHASE_RESULT! - continuing
echo [WARNING] !PHASE_LABEL! (PowerShell) exited with code !PHASE_RESULT! >> "%LOG%"
endlocal
goto :eof
