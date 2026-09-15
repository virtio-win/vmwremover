@echo off
rem ===============================================================
rem query_vmware_registry.cmd
rem Query all VMware-related registry entries
rem Displays current registry keys and values
rem Read-only operation - does not modify registry
rem Entries are read from vmware_registry_entries.txt (shared with
rem remove_vmware_registry.bat) so both scripts stay in sync.
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
set "ENTRIES_FILE=%SCRIPT_DIR%\vmware_registry_entries.txt"

if not exist "%ENTRIES_FILE%" (
    echo [ERROR] Registry entries file not found: %ENTRIES_FILE%
    exit /b 1
)

echo.
echo ===============================================================
echo   Query VMware Registry Entries Script
echo   Run as Administrator
echo ===============================================================
echo.

rem --- Initialize counters ---
set /a FOUND=0
set /a NOT_FOUND=0

echo ==========================================
echo  Querying registry entries
echo ==========================================
echo.

rem ===============================================================
rem Registry entries are defined in vmware_registry_entries.txt
rem Format: REG_PATH|VALUE_NAME  ('<KEY>' means query the whole key)
rem ===============================================================
for /f "usebackq eol=# tokens=1,2 delims=|" %%A in ("%ENTRIES_FILE%") do (
    call :QueryRegistryEntry "%%A" "%%B"
)

echo.
echo ===============================================================
echo  Registry query process finished
echo ===============================================================
echo.
echo Summary:
echo   Found: %FOUND% entries
echo   Not Found: %NOT_FOUND% entries
echo ===============================================================
goto :EOF

rem --- Subroutine: Query registry entry ---
:QueryRegistryEntry
setlocal enabledelayedexpansion
set "REG_PATH=%~1"
set "VAL_NAME=%~2"
rem Both <KEY> and * mean "the whole key" (see remove_vmware_registry.bat).
if /i "!VAL_NAME!"=="<KEY>" set "VAL_NAME="
if "!VAL_NAME!"=="*" set "VAL_NAME="

rem Handle registry query based on whether Name field is empty
if "!VAL_NAME!"=="" (
    rem Empty name means query entire key
    echo ---------------------------------------------------------------
    echo [KEY] !REG_PATH!
    echo ---------------------------------------------------------------
    reg query "!REG_PATH!" >nul 2>&1
    if !errorlevel! equ 0 (
        reg query "!REG_PATH!" 2>nul
        if !errorlevel! equ 0 (
            echo [FOUND] Key exists
            set "RESULT=FOUND"
        ) else (
            echo [NOT FOUND] Key does not exist
            set "RESULT=NOT_FOUND"
        )
    ) else (
        echo [NOT FOUND] Key does not exist
        set "RESULT=NOT_FOUND"
    )
) else (
    rem Specific value name - query just that value
    echo ---------------------------------------------------------------
    echo [VALUE] !REG_PATH!\!VAL_NAME!
    echo ---------------------------------------------------------------
    reg query "!REG_PATH!" /v "!VAL_NAME!" >nul 2>&1
    if !errorlevel! equ 0 (
        reg query "!REG_PATH!" /v "!VAL_NAME!" 2>nul
        if !errorlevel! equ 0 (
            echo [FOUND] Value exists
            set "RESULT=FOUND"
        ) else (
            echo [NOT FOUND] Value does not exist
            set "RESULT=NOT_FOUND"
        )
    ) else (
        echo [NOT FOUND] Value or key does not exist
        set "RESULT=NOT_FOUND"
    )
)
echo.

rem Update counters in parent scope
for %%R in ("!RESULT!") do (
    endlocal
    if "%%~R"=="FOUND" (
        set /a FOUND+=1
    ) else if "%%~R"=="NOT_FOUND" (
        set /a NOT_FOUND+=1
    )
)
goto :eof
