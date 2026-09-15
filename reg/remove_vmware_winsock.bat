@echo off
rem ===============================================================
rem remove_vmware_winsock.bat
rem Remove the VMware vSockets Winsock2 LSP (layered service
rem provider) from the live/current Winsock catalog using netsh.
rem 
rem VMware Tools registers a vSockets transport provider under the
rem Winsock2 catalog (provider GUID {570ADC4B-67B2-42CE-92B2-
rem ACD33D88D842}). If the provider DLL is deleted without first
rem deregistering it from the catalog, applications that enumerate
rem Winsock providers can fail. This script deregisters it first.
rem 
rem This is the pure-batch baseline: it only touches the LIVE
rem catalog (CurrentControlSet). Scrubbing the catalog across ALL
rem ControlSets requires binary-GUID matching that is impractical
rem in batch - that is handled best-effort by the optional
rem reg\delete_winsock_registry.ps1 when PowerShell is available.
rem 
rem Returns 3010 when a provider was removed (winsock changes take
rem full effect after a reboot); 0 when nothing was found.
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

rem --- Script directory / log ---
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "LOG=%SCRIPT_DIR%\remove_vmware_winsock.log"

rem --- VMware vSockets Winsock provider GUID ---
set "VSOCK_GUID={570ADC4B-67B2-42CE-92B2-ACD33D88D842}"

echo =============================================================== > "%LOG%"
echo   VMware Winsock Provider Removal Log - %DATE% %TIME% >> "%LOG%"
echo =============================================================== >> "%LOG%"

echo.
echo ===============================================================
echo   Remove VMware vSockets Winsock Provider
echo   Run as Administrator
echo ===============================================================
echo.

set /a REMOVED=0
set /a FOUND=0

rem ===============================================================
rem Parse "netsh winsock show catalog" and remove any catalog entry
rem whose Provider ID matches the VMware vSockets GUID.
rem 
rem We key off the GUID VALUE (locale-independent) rather than the
rem field LABEL text ("Provider ID", "Catalog Entry ID"), which is
rem localized on non-English Windows. Within each catalog block the
rem Provider ID line precedes the Catalog Entry ID line and no other
rem purely-numeric value appears between them, so: arm on the GUID,
rem then act on the first pure-integer value that follows.
rem ===============================================================
echo [INFO] Scanning Winsock catalog for VMware vSockets provider...
echo [INFO] Scanning Winsock catalog for VMware vSockets provider... >> "%LOG%"

set "ARMED="
for /f "usebackq tokens=1,* delims=:" %%A in (`netsh winsock show catalog`) do (
    set "VAL=%%B"
    rem Trim leading whitespace from the value portion
    for /f "tokens=* " %%V in ("!VAL!") do set "VAL=%%V"

    rem Arm when the VMware vSockets GUID appears anywhere on the line
    echo %%A %%B | findstr /I /C:"%VSOCK_GUID%" >nul && (
        set "ARMED=1"
        set /a FOUND=1
        echo [MATCH] Found VMware vSockets provider entry >> "%LOG%"
    )

    rem Once armed, the first pure-integer value is the Catalog Entry ID
    if defined ARMED if not "!VAL!"=="" (
        echo !VAL!| findstr /R "^[0-9][0-9]*$" >nul && (
            echo [ACTION] Removing Winsock provider - Catalog Entry ID !VAL!
            echo [ACTION] Removing Winsock provider - Catalog Entry ID !VAL! >> "%LOG%"
            netsh winsock remove provider !VAL! >> "%LOG%" 2>&1
            if not errorlevel 1 (
                set /a REMOVED+=1
                echo [SUCCESS] Removed Catalog Entry ID !VAL!
            ) else (
                echo [WARNING] netsh failed to remove Catalog Entry ID !VAL!
                echo [WARNING] netsh failed to remove Catalog Entry ID !VAL! >> "%LOG%"
            )
            set "ARMED="
        )
    )
)

if %FOUND% EQU 0 (
    echo.
    echo [INFO] No VMware vSockets Winsock provider found in the live catalog.
    echo [INFO] No VMware vSockets Winsock provider found. >> "%LOG%"
    echo ===============================================================
    goto :EOF
)

rem ===============================================================
rem The provider WAS present, so reconcile the catalog. The surgical
rem "netsh winsock remove provider" above is best-effort - its exact
rem argument form varies by Windows build - so it must NOT gate the
rem reset. "netsh winsock reset" restores the WHOLE catalog to
rem defaults, which reliably purges the VMware vSockets LSP (and any
rem OTHER third-party LSP - intended for a post-migration cleanup; if
rem you must preserve other LSPs, comment out the reset below). Running
rem it whenever the provider was detected, regardless of whether the
rem surgical remove succeeded, closes the hole where a failed remove
rem left the provider in place.
rem ===============================================================
echo.
echo [ACTION] Resetting Winsock catalog to defaults (netsh winsock reset)...
echo [ACTION] Resetting Winsock catalog (netsh winsock reset)... >> "%LOG%"
netsh winsock reset >> "%LOG%" 2>&1

echo.
echo ===============================================================
echo  VMware Winsock provider removal finished
echo  vSockets provider detected and catalog reset to defaults.
echo  Providers removed surgically: %REMOVED%
echo  Log saved to: %LOG%
echo.
echo  WARNING: A reboot is required to complete the Winsock changes.
echo ===============================================================
echo  vSockets provider detected; catalog reset. Surgical removals: %REMOVED% >> "%LOG%"

exit /b 3010
