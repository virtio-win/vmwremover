@echo off
rem ===============================================================
rem remove_vmware_registry.cmd
rem Remove all VMware-related registry entries
rem Entries are read from vmware_registry_entries.txt (shared with
rem query_vmware_registry.bat) so both scripts stay in sync.
rem Maps all entries to HKEY_LOCAL_MACHINE (HKLM)
rem Handles both key deletions and individual value deletions
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
echo   Remove VMware Registry Entries Script
echo   Run as Administrator
echo ===============================================================
echo.

rem --- Initialize counters ---
set /a DELETED=0
set /a NOT_FOUND=0
set /a ERRORS=0

echo ==========================================
echo  Processing registry entries
echo ==========================================
echo.

rem ===============================================================
rem Registry entries are defined in vmware_registry_entries.txt
rem Format: REG_PATH|VALUE_NAME  ('<KEY>' means delete the whole key)
rem Entries are ordered value-deletes-before-key-deletes so a key is
rem only removed once its individually listed values are gone.
rem ===============================================================
for /f "usebackq eol=# tokens=1,2 delims=|" %%A in ("%ENTRIES_FILE%") do (
    call :DeleteRegistryEntry "%%A" "%%B"
)

echo.
echo ===============================================================
echo  Registry cleanup process finished
echo ===============================================================
echo.
echo Summary:
echo   Deleted: %DELETED% entries
echo   Not Found: %NOT_FOUND% entries
echo   Errors: %ERRORS% entries
echo ===============================================================

rem Exit deterministically off the real ERRORS counter. Without an explicit
rem exit, a bare "goto :EOF" would return whatever errorlevel the loop's last
rem command left behind - typically 1 from the final entry's "reg query" when
rem it was NOT FOUND - so a clean run (Errors: 0) would still report failure.
if %ERRORS% gtr 0 (
    exit /b 1
)
exit /b 0

rem --- Subroutine: Delete registry entry ---
:DeleteRegistryEntry
setlocal enabledelayedexpansion
set "REG_PATH=%~1"
set "VAL_NAME=%~2"
rem Both <KEY> and * mean "delete the whole key". * cannot be a literal
rem value delete: reg query /v * matches all values (wildcard) so it looks
rem present, but reg delete /v * has no wildcard and fails - the key is what
rem was always meant. Normalise both to the empty-name (whole-key) path.
if /i "!VAL_NAME!"=="<KEY>" set "VAL_NAME="
if "!VAL_NAME!"=="*" set "VAL_NAME="

rem Handle registry deletion based on whether Name field is empty
if "!VAL_NAME!"=="" (
    rem Empty name means delete the entire key. Pre-check existence first,
    rem mirroring the value-delete branch: an absent key is the desired end
    rem state (usually already removed recursively by an earlier parent-key
    rem delete), so report it as NOT FOUND rather than a spurious ERROR.
    rem Only a key that exists but refuses to delete is a real ERROR.
    echo [DELETE KEY] !REG_PATH!
    reg query "!REG_PATH!" >nul 2>&1
    if !errorlevel! neq 0 (
        echo [NOT FOUND] Key does not exist: !REG_PATH!
        set "RESULT=NOT_FOUND"
    ) else (
        reg delete "!REG_PATH!" /f >nul 2>&1
        if !errorlevel! equ 0 (
            echo [SUCCESS] Deleted key: !REG_PATH!
            set "RESULT=DELETED"
        ) else (
            echo [ERROR] Failed to delete key: !REG_PATH!
            set "RESULT=ERROR"
        )
    )
) else (
    rem Specific value name - delete just that value (never escalate to the parent key)
    echo [DELETE VALUE] !REG_PATH!\!VAL_NAME!
    reg query "!REG_PATH!" /v "!VAL_NAME!" >nul 2>&1
    if !errorlevel! neq 0 (
        echo [NOT FOUND] Value does not exist: !REG_PATH!\!VAL_NAME!
        set "RESULT=NOT_FOUND"
    ) else (
        reg delete "!REG_PATH!" /v "!VAL_NAME!" /f >nul 2>&1
        if !errorlevel! equ 0 (
            echo [SUCCESS] Deleted value: !REG_PATH!\!VAL_NAME!
            set "RESULT=DELETED"
        ) else (
            echo [ERROR] Failed to delete: !REG_PATH!\!VAL_NAME!
            set "RESULT=ERROR"
        )
    )
)

rem Return result to parent scope and update counters
for %%R in ("!RESULT!") do (
    endlocal
    if "%%~R"=="DELETED" (
        set /a DELETED+=1
    ) else if "%%~R"=="NOT_FOUND" (
        set /a NOT_FOUND+=1
    ) else if "%%~R"=="ERROR" (
        set /a ERRORS+=1
    )
)
goto :eof
