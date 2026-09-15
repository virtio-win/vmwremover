@echo off
rem ===============================================================
rem remove_vmware_driver_packages.cmd
rem Remove all VMware-related driver packages using pnputil.exe
rem Enumerates all drivers, filters for VMware providers, and removes them
rem More aggressive than remove_vmware_drivers.bat - removes driver packages
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

rem --- Get script directory ---
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "COMPONENT_LIST=%SCRIPT_DIR%\..\vmware_components.txt"

echo.
echo ===============================================================
echo   Remove VMware Driver Packages Script
echo   Run as Administrator
echo ===============================================================
echo.

echo ==========================================
echo  Searching for VMware drivers and packages
echo ==========================================
echo.

rem --- Enumerate all drivers ---
pnputil /enum-drivers > "%temp%\all_drivers.txt"

rem --- Filter for VMware drivers ---
echo Filtering lines with Published Name and VMware...
findstr /i /c:"Published Name" /c:"Original Name" /c:"Provider Name" "%temp%\all_drivers.txt" > "%temp%\vmware_drivers.txt"

echo.
echo ===== VMware Drivers Found =====

rem --- Initialize variables ---
set COUNT=0
set LAST_PUBLISHED=
set LAST_ORIGINAL=

rem --- Parse driver list for VMware providers ---
for /f "usebackq tokens=1,* delims=:" %%A in ("%temp%\vmware_drivers.txt") do (
    set LINE=%%A
    set VALUE=%%B
    set VALUE=!VALUE: =!

    if /i "!LINE!"=="Published Name" (
        set LAST_PUBLISHED=!VALUE!
    )

    if /i "!LINE!"=="Original Name" (
        set LAST_ORIGINAL=!VALUE!
    )

    if /i "!LINE!"=="Provider Name" (
        set "IS_VMWARE="
        rem Match the provider string first (covers "VMware, Inc." packages).
        echo !VALUE! | findstr /i "VMware" >nul && set "IS_VMWARE=1"
        rem After the Broadcom acquisition, current VMware Tools driver packages
        rem are published under provider "Broadcom Inc.", so provider-string
        rem matching alone misses them. Cross-check the Original Name against the
        rem canonical VMware component list (e.g. vmci.inf -> vmci). This is
        rem provider-agnostic yet still precise, so genuine non-VMware Broadcom
        rem NIC/RAID drivers are NOT matched just because Broadcom signed them.
        if not defined IS_VMWARE if defined LAST_ORIGINAL if exist "%COMPONENT_LIST%" (
            for /f "usebackq eol=# tokens=*" %%N in ("%COMPONENT_LIST%") do (
                echo !LAST_ORIGINAL! | findstr /i "%%N" >nul && set "IS_VMWARE=1"
            )
        )
        if defined IS_VMWARE (
            rem This Published Name belongs to VMware
            if not "!LAST_PUBLISHED!"=="" (
                echo Found VMware driver: !LAST_ORIGINAL! ^(!LAST_PUBLISHED!^)
                set INF_LIST[!COUNT!]=!LAST_PUBLISHED!
                set /a COUNT+=1
            )
        )
        set LAST_PUBLISHED=
        set LAST_ORIGINAL=
    )
)

rem --- Check if any drivers were found ---
if %COUNT% EQU 0 (
    echo No VMware drivers found to remove.
    echo.
    echo ===============================================================
    echo No VMware driver packages found.
    echo ===============================================================
rem    pause
    exit /b 0
)

echo.
echo ===============================
echo  Removing VMware Driver Packages
echo ===============================
echo.

rem --- Remove each VMware driver package ---
set "LOG_FILE=%SCRIPT_DIR%\removal_log.txt"
set "REBOOT_REQUIRED=0"
rem for /l does not evaluate arithmetic in its range, so compute the last index
rem first ("%COUNT%-1" would otherwise be treated as a malformed bound).
set /a LAST_INDEX=COUNT-1
for /l %%I in (0,1,%LAST_INDEX%) do (
    set INF=!INF_LIST[%%I]!
    if not "!INF!"=="" call :RemovePackage "!INF!"
)
del "%temp%\pnputil_output.txt" >nul 2>&1

rem --- Clean up temporary files ---
del "%temp%\all_drivers.txt" >nul 2>&1
del "%temp%\vmware_drivers.txt" >nul 2>&1

echo.
echo ===============================================================
echo  VMware driver removal process finished
echo  Log saved to: %LOG_FILE%
if %REBOOT_REQUIRED% EQU 1 (
    echo.
    echo WARNING: A system reboot is required to complete the removal.
    echo Please restart your computer when convenient.
)
echo ===============================================================
rem pause
if %REBOOT_REQUIRED% EQU 1 (
    exit /b 3010
)
exit /b 0

rem ---------------------------------------------------------------
rem Remove one driver package, tolerating older pnputil versions.
rem Prefer /uninstall so the package is also stripped from any device
rem still referencing it. Windows Server 2016's pnputil does NOT support
rem /uninstall on /delete-driver and fails with "The request is not
rem supported", so on any failure fall back to a plain /delete-driver
rem /force (which 2016 accepts and which 2019/2022 also honour).
rem ---------------------------------------------------------------
:RemovePackage
set "INF=%~1"
echo Removing !INF! ...
pnputil /delete-driver "!INF!" /uninstall /force > "%temp%\pnputil_output.txt" 2>&1
if !errorlevel! neq 0 (
    echo   [INFO] /uninstall unsupported here - retrying without it
    echo [INFO] /uninstall unsupported for !INF! - retried without it >> "%LOG_FILE%"
    pnputil /delete-driver "!INF!" /force > "%temp%\pnputil_output.txt" 2>&1
)
type "%temp%\pnputil_output.txt" >> "%LOG_FILE%"
findstr /i "reboot restart" "%temp%\pnputil_output.txt" >nul && set "REBOOT_REQUIRED=1"
echo Done.
goto :eof
