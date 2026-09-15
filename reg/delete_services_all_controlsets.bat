@echo off
rem ===============================================================
rem delete_services_all_controlsets.bat
rem Delete VMware service/driver keys from EVERY numbered control set,
rem not just CurrentControlSet.
rem
rem The data-driven registry cleanup (remove_vmware_registry.bat)
rem targets CurrentControlSet. Windows keeps additional control sets
rem (ControlSet001, ControlSet002, ...) that can retain a VMware
rem service definition and let it reappear after a reboot. This sweeps
rem HKLM\SYSTEM\<ControlSetNNN>\Services\<name> for every VMware
rem service, including vsock and the balloon driver vmmemctl.
rem
rem Returns 3010 when a key was deleted (reboot recommended so any
rem still-loaded driver is released); 0 when nothing was present.
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
set "LOG=%SCRIPT_DIR%\delete_services_all_controlsets.log"

echo =============================================================== > "%LOG%"
echo   VMware services all-ControlSets Removal Log - %DATE% %TIME% >> "%LOG%"
echo =============================================================== >> "%LOG%"

echo.
echo ===============================================================
echo   Delete VMware service keys across all ControlSets
echo   Run as Administrator
echo ===============================================================
echo.

set /a DELETED=0

rem --- Detect PowerShell availability for ownership-takeover fallback ---
call :DetectPowerShell

rem --- ACL-protected keys that reg delete /f cannot remove get logged here ---
set "PROTECTED_KEYS=%temp%\vmware_protected_service_keys.txt"
del "%PROTECTED_KEYS%" >nul 2>&1

rem ===============================================================
rem Enumerate the numbered control sets under HKLM\SYSTEM and delete
rem each VMware service key within them. reg query prints subkeys as
rem full HKEY_LOCAL_MACHINE\... paths; we keep only those ending in
rem ControlSetNNN (three digits). The service list mirrors the
rem verifier's all-ControlSet sweep so a clean run leaves nothing
rem behind. vmwTimeProvider lives under W32Time\TimeProviders rather
rem than directly under Services, so it is listed with its full
rem relative path.
rem
rem Names are matched EXACTLY, never as substrings. Several co-resident
rem drivers share a "vm" prefix but are NOT VMware and must survive:
rem   netkvm / NETKVMP        -> virtio-net (the replacement NIC)
rem   vmbus, VMBusHID, vmgid,
rem   vmic* (Hyper-V ICs)     -> Microsoft Hyper-V Integration Services
rem   stornvme               -> Microsoft NVMe storage driver
rem Add only confirmed VMware service key names below.
rem ===============================================================
for /f "usebackq delims=" %%K in (`reg query "HKLM\SYSTEM" 2^>nul ^| findstr /I /R "\\ControlSet[0-9][0-9][0-9]$"`) do (
    for %%S in (
        "Services\vmci"
        "Services\vsock"
        "Services\vmhgfs"
        "Services\vmmouse"
        "Services\vmusbmouse"
        "Services\vmrawdsk"
        "Services\vmmemctl"
        "Services\vmxnet3"
        "Services\vmxnet3ndis6"
        "Services\pvscsi"
        "Services\vm3dmp"
        "Services\vm3dmp-debug"
        "Services\vm3dmp-stats"
        "Services\vm3dmp_loader"
        "Services\vmwefifw"
        "Services\vsepflt"
        "Services\vnetWFP"
        "Services\vmStatsProvider"
        "Services\W32Time\TimeProviders\vmwTimeProvider"
    ) do (
        set "TARGET=%%K\%%~S"
        reg query "!TARGET!" >nul 2>&1
        if not errorlevel 1 (
            echo [DELETE KEY] !TARGET!
            echo [DELETE KEY] !TARGET! >> "%LOG%"
            reg delete "!TARGET!" /f >nul 2>&1
            if errorlevel 1 (
                echo [WARNING] Failed to delete !TARGET! - may be ACL-protected
                echo [WARNING] Failed to delete !TARGET! - may be ACL-protected >> "%LOG%"
                >>"%PROTECTED_KEYS%" echo !TARGET!
            ) else (
                echo [SUCCESS] Deleted !TARGET! >> "%LOG%"
                set /a DELETED+=1
            )
        ) else (
            echo [INFO] Not present: !TARGET! >> "%LOG%"
        )
    )
)

rem ===============================================================
rem ACL-protected key fallback: for keys that reg delete /f could
rem not remove (Access is denied), invoke a PowerShell helper that
rem seizes ownership, grants Administrators FullControl, and retries.
rem This is ONLY called for the exact VMware service names swept above.
rem ===============================================================
if exist "%PROTECTED_KEYS%" if defined PS_OK (
    echo.
    echo [PS] Attempting ownership takeover for ACL-protected keys...
    echo [PS] Ownership takeover for ACL-protected keys. >> "%LOG%"
    set "FORCE_DELETE_PS=%SCRIPT_DIR%\force_delete_protected_service.ps1"
    if exist "!FORCE_DELETE_PS!" (
        "!PS_EXE!" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "!FORCE_DELETE_PS!" "%PROTECTED_KEYS%" > "%temp%\vmw_ps_force.txt" 2>&1
        set PS_EXIT=!errorlevel!
        type "%temp%\vmw_ps_force.txt"
        type "%temp%\vmw_ps_force.txt" >> "%LOG%"
        del "%temp%\vmw_ps_force.txt" >nul 2>&1
        if !PS_EXIT! EQU 3010 (
            echo [PS-OK] Ownership takeover succeeded - keys removed.
            echo [PS-OK] Ownership takeover succeeded - keys removed. >> "%LOG%"
            set /a DELETED+=1
        )
    ) else (
        echo [SKIP-PS] force_delete_protected_service.ps1 not found.
        echo [SKIP-PS] force_delete_protected_service.ps1 not found. >> "%LOG%"
    )
)
del "%PROTECTED_KEYS%" >nul 2>&1

echo.
echo ===============================================================
echo  VMware services all-ControlSets cleanup finished
echo  Keys deleted: %DELETED%
echo  Log saved to: %LOG%
echo ===============================================================
echo  Keys deleted: %DELETED% >> "%LOG%"

if %DELETED% GTR 0 (
    exit /b 3010
)
exit /b 0

rem ===============================================================
rem SUBROUTINE: detect PowerShell availability
rem ===============================================================
:DetectPowerShell
set "PS_OK="
set "PS_EXE="
for %%P in (powershell.exe) do if not defined PS_EXE if exist "%%~$PATH:P" set "PS_EXE=%%~$PATH:P"
if not defined PS_EXE if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PS_EXE goto :eof
"%PS_EXE%" -NoProfile -NonInteractive -Command "exit 0" >nul 2>&1
if errorlevel 1 goto :eof
set "PS_OK=1"
goto :eof
