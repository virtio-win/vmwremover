@echo off
rem ===============================================================
rem manage_vmware_services.bat
rem Disable, or disable and remove, all VMware-related services
rem Usage: manage_vmware_services.bat disable|remove
rem Called by disable_vmware_services.bat / remove_vmware_services.bat
rem ===============================================================

setlocal enabledelayedexpansion

set "MODE=%~1"
if /i "%MODE%"=="disable" (
    set "MODE=disable"
) else if /i "%MODE%"=="remove" (
    set "MODE=remove"
) else (
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
rem    pause
    exit /b 1
)

rem --- Script directory ---
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "COMPONENT_LIST=%SCRIPT_DIR%\..\vmware_components.txt"

rem --- Log file ---
set "LOG=%SCRIPT_DIR%\vmware_disable.log"
echo =============================================================== > "%LOG%"
echo   VMware Service %MODE% Log - %DATE% %TIME% >> "%LOG%"
echo =============================================================== >> "%LOG%"

echo.
echo ===============================================================
echo   VMware Service Manager - mode: %MODE%
echo   Run as Administrator
echo ===============================================================
echo.
echo [INFO] Log file: %LOG%
echo.

rem ===============================================================
rem Enumerate all services
rem ===============================================================
echo [INFO] Enumerating services...
set "TEMPFILE=%temp%\all_services.txt"
sc query type= service state= all > "%TEMPFILE%"

rem Initialize
set "VMWARE_LIST="
set /a MATCH_COUNT=0

rem ===============================================================
rem Check each service for VMware
rem ===============================================================
for /f "tokens=2 delims=:" %%A in ('findstr /R "^SERVICE_NAME" "%TEMPFILE%"') do (
    set "SVC=%%A"
    rem strip spaces from the parsed service name
    set "SVC=!SVC: =!"
    call :CheckVMwareService !SVC!
)

del "%TEMPFILE%" >nul 2>&1

if %MATCH_COUNT%==0 (
    echo [INFO] No VMware-related services found. >> "%LOG%"
    echo [INFO] No VMware-related services found.
    goto :EOF
)

echo.
echo [INFO] Found %MATCH_COUNT% VMware-related services:
for %%S in (!VMWARE_LIST!) do echo   %%S
echo.

rem ===============================================================
rem Stop and disable (and, in remove mode, delete) VMware services
rem ===============================================================
for %%S in (!VMWARE_LIST!) do (
    call :StopAndDisableService "%%S"
)

echo.
echo ===============================================================
echo VMware services have been processed.
echo See log for details: %LOG%
echo ===============================================================
goto :EOF

rem ===============================================================
rem SUBROUTINES
rem ===============================================================

:CheckVMwareService
setlocal
set "SVC=%~1"
set "IS_VMWARE="

rem Query service configuration
for /f "tokens=*" %%L in ('sc qc "%SVC%" 2^>nul') do (
    echo %%L | findstr /I "VMware" >nul && set "IS_VMWARE=1"
)

rem Cross-check against the canonical known-component list, in case sc qc's
rem output doesn't happen to contain the literal string "VMware"
if not defined IS_VMWARE (
    if exist "%COMPONENT_LIST%" (
        for /f "usebackq eol=# tokens=*" %%N in ("%COMPONENT_LIST%") do (
            if /i "%SVC%"=="%%N" set "IS_VMWARE=1"
        )
    )
)

if defined IS_VMWARE (
    echo [MATCH] %SVC% appears to be VMware-related.
    echo [MATCH] %SVC% appears to be VMware-related. >> "%LOG%"
    endlocal & set "VMWARE_LIST=%VMWARE_LIST% %SVC%" & set /a MATCH_COUNT+=1
) else (
    endlocal
)
goto :eof

:StopAndDisableService
setlocal
set "SVC=%~1"
echo ---------------------------------------------------------------
echo [ACTION] Stopping and disabling %SVC%...
echo [ACTION] Stopping and disabling %SVC%... >> "%LOG%"

rem Stop gracefully
sc stop "%SVC%" >nul 2>&1

rem Wait a few seconds
ping 127.0.0.1 -n 3 >nul

rem Force kill if still running
for /f "tokens=2 delims=:" %%P in ('sc queryex "%SVC%" ^| find "PID"') do (
    set "PID=%%P"
    set "PID=!PID: =!"
    if not "!PID!"=="0" (
        echo [ACTION] Forcibly killing PID !PID!
        echo [ACTION] Forcibly killing PID !PID! >> "%LOG%"
        taskkill /PID !PID! /F >nul 2>&1
    )
)

rem Disable permanently
sc config "%SVC%" start= disabled >nul 2>&1
if errorlevel 1 (
    echo [WARNING] Failed to disable %SVC% >> "%LOG%"
    echo [WARNING] Failed to disable %SVC%
) else (
    echo [SUCCESS] %SVC% disabled successfully >> "%LOG%"
    echo [SUCCESS] %SVC% disabled successfully
)

rem Show current state
sc query "%SVC%" | findstr /I "STATE" 2>nul

if /i "%MODE%"=="remove" (
    rem Uninstall permanently
    sc delete "%SVC%" >nul 2>&1
    if errorlevel 1 (
        echo [WARNING] Failed to delete %SVC% ^(may already be deleted^) >> "%LOG%"
        echo [WARNING] Failed to delete %SVC% ^(may already be deleted^)
    ) else (
        echo [SUCCESS] %SVC% deleted successfully >> "%LOG%"
        echo [SUCCESS] %SVC% deleted successfully
    )
)

echo [INFO] %SVC% processed. >> "%LOG%"
endlocal
goto :eof
