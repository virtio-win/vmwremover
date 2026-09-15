@echo off
rem ===============================================================
rem clean_legacy_drvstore.bat
rem Remove leftover VMware driver folders from the LEGACY driver store
rem   %SystemRoot%\System32\DRVSTORE
rem
rem This is the old co-installer-era store and is NOT the modern
rem   %SystemRoot%\System32\DriverStore\FileRepository
rem which pnputil owns and which must never be deleted by hand. pnputil
rem does not manage DRVSTORE, so nothing else in this toolset cleans it
rem and VMware component folders (e.g. vsock_<hash>, vmci_<hash>) linger
rem there after the packages are removed. Deleting them directly here is
rem safe precisely because no driver database tracks this location.
rem
rem Folder names are always <component>_<hash>, so matching on
rem "<name>_*" (with the trailing underscore) is precise and will not
rem catch an unrelated folder that merely starts with the same letters.
rem The component list is the canonical vmware_components.txt.
rem
rem Returns 3010 when a folder was deleted (a reboot lets any file that
rem was locked at delete time finish releasing); 0 when nothing matched.
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

rem --- Script directory / log / inputs ---
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "COMPONENT_LIST=%SCRIPT_DIR%\..\vmware_components.txt"
set "DRVSTORE=%SystemRoot%\System32\DRVSTORE"
set "LOG=%SCRIPT_DIR%\clean_legacy_drvstore.log"

echo =============================================================== > "%LOG%"
echo   Legacy DRVSTORE Cleanup Log - %DATE% %TIME% >> "%LOG%"
echo =============================================================== >> "%LOG%"

echo.
echo ===============================================================
echo   Clean legacy VMware folders from System32\DRVSTORE
echo   Run as Administrator
echo ===============================================================
echo.

set /a DELETED=0
set /a FAILED=0

if not exist "%DRVSTORE%\" (
    echo [INFO] No legacy DRVSTORE present - nothing to clean.
    echo [INFO] No legacy DRVSTORE present - nothing to clean. >> "%LOG%"
    exit /b 0
)

if not exist "%COMPONENT_LIST%" (
    echo [ERROR] Component list not found: %COMPONENT_LIST%
    echo [ERROR] Component list not found: %COMPONENT_LIST% >> "%LOG%"
    exit /b 1
)

rem ===============================================================
rem For each known VMware component, delete every DRVSTORE folder
rem named <component>_*. for /d does not iterate when the pattern
rem matches nothing, so absent components are simply skipped.
rem ===============================================================
for /f "usebackq eol=# tokens=*" %%N in ("%COMPONENT_LIST%") do (
    for /d %%D in ("%DRVSTORE%\%%N_*") do (
        echo [DELETE DIR] %%D
        echo [DELETE DIR] %%D >> "%LOG%"
        rd /s /q "%%D" 2>nul
        if exist "%%D" (
            echo [WARNING] Failed to fully delete %%D ^(files may be in use^)
            echo [WARNING] Failed to fully delete %%D >> "%LOG%"
            set /a FAILED+=1
        ) else (
            echo [SUCCESS] Deleted %%D >> "%LOG%"
            set /a DELETED+=1
        )
    )
)

echo.
echo ===============================================================
echo  Legacy DRVSTORE cleanup finished
echo  Folders deleted: %DELETED%   Folders failed: %FAILED%
echo  Log saved to: %LOG%
echo ===============================================================
echo  Folders deleted: %DELETED%   Folders failed: %FAILED% >> "%LOG%"

if %DELETED% GTR 0 (
    exit /b 3010
)
exit /b 0
