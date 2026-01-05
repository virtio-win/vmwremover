@echo off
:: ===============================================================
:: disable_vmware_drivers.cmd
:: Disable all VMware-related PnP devices using devcon.exe
:: Works on both 32-bit and 64-bit Windows
:: Uses local ./x86/ and ./x64/ subdirectories
:: Prompts for confirmation before disabling each device
:: Adds '@' before device instance ID (per MSDN convention)
:: ===============================================================

setlocal enabledelayedexpansion

REM =============================
REM Check for admin privileges
REM =============================
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: This script must be run as Administrator!
    echo Please right-click and select "Run as administrator"
REM    pause
    exit /b 1
)

:: --- Get script directory ---
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

:: --- Define local devcon paths ---
set "DEVCON_X64=%SCRIPT_DIR%\x64\devcon.exe"
set "DEVCON_X86=%SCRIPT_DIR%\x86\devcon.exe"

echo.
echo ===============================================================
echo   Disable VMware Drivers Script (Interactive)
echo   Run as Administrator
echo ===============================================================
echo.

:: --- Detect OS architecture ---
set "ARCH="
if defined PROCESSOR_ARCHITEW6432 (
    set "ARCH=64"
) else (
    if "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
        set "ARCH=64"
    ) else (
        set "ARCH=32"
    )
)

:: --- Select correct devcon binary ---
if "%ARCH%"=="64" (
    if exist "%DEVCON_X64%" (
        set "DEVCON=%DEVCON_X64%"
    ) else (
        echo [ERROR] x64 devcon.exe not found in "%DEVCON_X64%"
        exit /b 1
    )
) else (
    if exist "%DEVCON_X86%" (
        set "DEVCON=%DEVCON_X86%"
    ) else (
        echo [ERROR] x86 devcon.exe not found in "%DEVCON_X86%"
        exit /b 1
    )
)

echo Using devcon: %DEVCON%
echo.

:: --- Enumerate VMware devices ---
echo Searching for VMware devices...
"%DEVCON%" findall * | findstr /I "VMware" > "%temp%\vmware_devices.txt"

if %errorlevel% neq 0 (
    echo No VMware devices found.
    del "%temp%\vmware_devices.txt" >nul 2>&1
    goto :EOF
)

echo.
echo VMware devices found:
type "%temp%\vmware_devices.txt"
echo.

REM choice /m "Proceed to review and optionally disable these devices?"
REM if errorlevel 2 (
REM     echo Operation cancelled.
REM     del "%temp%\vmware_devices.txt" >nul 2>&1
REM     exit /b
REM )

:: --- Process each device safely ---
for /f "usebackq delims=" %%L in ("%temp%\vmware_devices.txt") do (
    set "LINE=%%L"
    for /f "tokens=1,* delims=:" %%A in ("!LINE!") do (
        set "DEVID=%%A"
        set "DEVDESC=%%B"
        call :DisableDevice
    )
)

del "%temp%\vmware_devices.txt" >nul 2>&1
echo.
echo ===============================================================
echo All VMware devices processed.
echo ===============================================================
goto :EOF

:: --- Subroutine: confirm and disable one device ---
:DisableDevice
setlocal enabledelayedexpansion
set "DEVID=!DEVID:~0!"
set "DEVDESC=!DEVDESC:~1!"
set "ATDEVID=@!DEVID!"
echo.
echo ---------------------------------------------------------------
echo Device: !DEVDESC!
echo ID: !ATDEVID!
echo ---------------------------------------------------------------
REM choice /m "Disable this device?"
REM if errorlevel 2 (
REM     echo Skipped !DEVDESC!
REM     endlocal
REM     goto :eof
REM )
echo Disabling device: !DEVDESC!
"%DEVCON%" disable !ATDEVID!
endlocal
goto :eof
