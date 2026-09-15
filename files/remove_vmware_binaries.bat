@echo off
rem ===============================================================
rem remove_vmware_binaries.bat
rem ADVANCED / UNSUPPORTED cleanup: deletes leftover VMware Tools
rem install directories and orphaned driver files left behind after
rem the driver/service/registry cleanup elsewhere in this repo.
rem 
rem Based on Broadcom KB 315629's manual-uninstall file/registry list.
rem Broadcom's own guidance calls this manual procedure unsupported
rem and recommends taking a VM snapshot/backup before running it -
rem there is no undo for deleted files.
rem 
rem Deliberately NOT wired into cleanup_vmware_leftovers.bat, and
rem deliberately does not touch Add/Remove Programs / Windows
rem Installer uninstall registry entries - Broadcom's own KB doesn't
rem either, since clearing those without a real uninstall can leave
rem the Windows Installer database inconsistent.
rem 
rem HYBRID: the batch baseline below always runs, forcibly deleting
rem leftover VMware files. The only PowerShell helper is best-effort
rem Authenticode-gated discovery (discover_vmware_binaries.ps1), which
rem writes a manifest this script then deletes from; if PowerShell is
rem unavailable the manifest step is simply skipped. A PowerShell
rem failure never aborts the batch run.
rem 
rem Locked driver files that cannot be deleted now are scheduled for
rem deletion on the next reboot via PendingFileRenameOperations;
rem the script then returns 3010 to signal a reboot is required.
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
set "LOG=%SCRIPT_DIR%\remove_vmware_binaries.log"
set "COMPONENT_LIST=%SCRIPT_DIR%\..\vmware_components.txt"

rem --- Reboot-deletion scheduling state ---
set "SM_KEY=HKLM\SYSTEM\CurrentControlSet\Control\Session Manager"
set "QUEUE_FILE=%temp%\vmware_pending_deletes.txt"
del "%QUEUE_FILE%" >nul 2>&1
set /a QUEUED=0
set /a REBOOT=0

echo =============================================================== > "%LOG%"
echo   VMware Leftover Binaries Removal Log - %DATE% %TIME% >> "%LOG%"
echo =============================================================== >> "%LOG%"

echo.
echo ===============================================================
echo   Remove VMware Leftover Binaries (ADVANCED / UNSUPPORTED)
echo   Based on Broadcom KB 315629 manual cleanup steps.
echo   This deletes files with no undo - a VM snapshot/backup
echo   beforehand is recommended.
echo   Run as Administrator
echo ===============================================================
echo.

set /a REMOVED_DIRS=0
set /a REMOVED_FILES=0

rem ===============================================================
rem OPTIONAL PowerShell augmentation (best-effort, pre-deletion)
rem Authenticode-gated discovery to build a manifest of confirmed
rem VMware binaries - signature verification is the one thing batch
rem cannot do.
rem ===============================================================
call :DetectPowerShell
set "DISCOVER_PS=%SCRIPT_DIR%\discover_vmware_binaries.ps1"
set "DO_DISCOVER="
if defined PS_OK if exist "%DISCOVER_PS%" set "DO_DISCOVER=1"
if not defined PS_OK (
    echo [INFO] PowerShell unavailable - running batch-only baseline.
    echo [INFO] PowerShell unavailable - batch-only baseline. >> "%LOG%"
)
if defined PS_OK if not exist "%DISCOVER_PS%" (
    echo [SKIP-PS] discover_vmware_binaries.ps1 not found next to this script.
    echo [SKIP-PS] not found: !DISCOVER_PS! >> "%LOG%"
)
rem Discovery is inlined (not a :call) - a stray label-resolution quirk
rem must never be able to silently skip the PowerShell augmentation.
if defined DO_DISCOVER (
    echo [PS] Signature-gated binary discovery
    echo [PS] Signature-gated binary discovery ^(discover_vmware_binaries.ps1^) >> "%LOG%"
    "!PS_EXE!" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "!DISCOVER_PS!" > "%temp%\vmw_ps_out.txt" 2>&1
    type "%temp%\vmw_ps_out.txt"
    type "%temp%\vmw_ps_out.txt" >> "%LOG%"
    del "%temp%\vmw_ps_out.txt" >nul 2>&1
    echo [PS-OK] Signature-gated binary discovery finished. >> "%LOG%"
)

rem ===============================================================
rem Deregister the VMware vSockets Winsock provider BEFORE deleting any
rem binaries. vsock.sys / vsock.dll back a Winsock2 LSP; deleting them
rem while the catalog still references the provider leaves a broken
rem catalog entry that can break Winsock enumeration for other apps.
rem This standalone script has no other Winsock logic (unlike the
rem orchestrator, which runs the reg\ Winsock phases), so call it here.
rem ===============================================================
set "WINSOCK_SCRIPT=%SCRIPT_DIR%\..\reg\remove_vmware_winsock.bat"
if exist "%WINSOCK_SCRIPT%" (
    echo.
    echo [STEP] Deregister VMware vSockets Winsock provider
    echo [STEP] Deregister VMware vSockets Winsock provider >> "%LOG%"
    call "%WINSOCK_SCRIPT%"
    if "!errorlevel!"=="3010" set /a REBOOT=1
)

rem ===============================================================
rem Leftover VMware Tools install directories
rem ===============================================================
call :RemoveDir "%ProgramFiles%\VMware"
call :RemoveDir "%ProgramFiles%\Common Files\VMware"

rem NOTE: %ProgramFiles(x86)% must NOT appear inside a parenthesised
rem ( ... ) block - the ")" in "(x86)" is taken as the end of the block
rem and cmd aborts with "\VMware was unexpected at this time". Calling
rem unconditionally is safe: :RemoveDir is a no-op when the path is
rem absent (on 32-bit Windows the variable is undefined -> empty).
call :RemoveDir "%ProgramFiles(x86)%\VMware"
call :RemoveDir "%ProgramFiles(x86)%\Common Files\VMware"

call :RemoveDir "%ProgramData%\VMware"

rem --- Per-user AppData VMware folders ---
for /d %%U in ("%SystemDrive%\Users\*") do (
    call :RemoveDir "%%U\AppData\Local\VMware"
    call :RemoveDir "%%U\AppData\Roaming\VMware"
    call :RemoveDir "%%U\AppData\LocalLow\VMware"
)

rem ===============================================================
rem Orphaned driver files in System32\drivers, from the canonical
rem component list (vmware_components.txt). Harmless no-op for any
rem component already removed by pnputil or never present as a .sys.
rem ===============================================================
if exist "%COMPONENT_LIST%" (
    for /f "usebackq eol=# tokens=*" %%N in ("%COMPONENT_LIST%") do (
        call :RemoveFile "%SystemRoot%\System32\drivers\%%N.sys"
    )
)

rem ===============================================================
rem Consume the signature-gated discovery manifest (if PowerShell
rem produced one). These are files Authenticode-confirmed to be
rem VMware's that live outside the fixed locations above (e.g. service
rem ImagePath targets). Deletion - including locked-file reboot
rem scheduling - is handled by the same batch :RemoveFile path.
rem ===============================================================
set "MANIFEST=%SCRIPT_DIR%\vmware_binaries.txt"
if exist "%MANIFEST%" (
    for /f "usebackq eol=# tokens=*" %%F in ("%MANIFEST%") do call :RemoveFile "%%F"
)

rem ===============================================================
rem Orphaned DriverStore packages - run here, in the post-reboot deep
rem cleanup, NOT only during cleanup_vmware_leftovers.bat. During cleanup
rem the VMware driver services still exist and their drivers are still
rem loaded, so a package folder whose runtime .sys is hardlinked to the
rem DriverStore copy (e.g. vmmouse - its .sys stays locked while the mouse
rem driver is loaded, and reboot-scheduling races the driver reloading)
rem cannot be deleted. By now the services are gone and the drivers are
rem unloaded, so the sweep clears the folder in-session with a plain rd.
rem ===============================================================
set "ORPHAN_SWEEP=%SCRIPT_DIR%\..\drivers\remove_orphaned_driverstore.bat"
if exist "%ORPHAN_SWEEP%" (
    echo.
    echo [STEP] Orphaned DriverStore sweep
    echo [STEP] Orphaned DriverStore sweep >> "%LOG%"
    call "%ORPHAN_SWEEP%"
    if "!errorlevel!"=="3010" set /a REBOOT=1
)

rem ===============================================================
rem Flush any locked files to PendingFileRenameOperations so they
rem are removed by Session Manager on the next reboot.
rem ===============================================================
call :FlushPendingDeletes

echo.
echo ===============================================================
echo  VMware leftover binaries removal finished
echo  Log saved to: %LOG%
echo  Directories removed: %REMOVED_DIRS%
echo  Driver files removed: %REMOVED_FILES%
if %QUEUED% GTR 0 (
    echo  Locked files scheduled for reboot deletion: %QUEUED%
    echo.
    echo  WARNING: A system reboot is required to complete the removal.
)
echo ===============================================================

echo Directories removed: %REMOVED_DIRS% >> "%LOG%"
echo Driver files removed: %REMOVED_FILES% >> "%LOG%"
echo Files scheduled for reboot deletion: %QUEUED% >> "%LOG%"

if %QUEUED% GTR 0 set /a REBOOT=1
if %REBOOT% EQU 1 (
    exit /b 3010
)
goto :EOF

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

rem --- Subroutine: remove one directory tree if present ---
:RemoveDir
setlocal
set "TARGET=%~1"
if exist "!TARGET!\" (
    echo [DELETE DIR] !TARGET!
    echo [DELETE DIR] !TARGET! >> "%LOG%"
    rd /s /q "!TARGET!" 2>nul
    if exist "!TARGET!\" (
        echo [LOCKED] Could not fully remove !TARGET! - scheduling leftover files and folders for reboot deletion
        echo [LOCKED] Could not fully remove !TARGET! >> "%LOG%"
        rem Queue the still-locked files first, then the folders that hold
        rem them, deepest-first. PendingFileRenameOperations runs its entries
        rem in order and can delete a directory only once it is empty, so the
        rem files must be scheduled before the folders and the folders must go
        rem deepest-first. reverse-sorting the "dir /s /b /ad" list gives that
        rem order: a child path is its parent's path plus more, so it always
        rem sorts after the parent and thus comes first under sort /r. Without
        rem scheduling the folders the locked DLLs would go on reboot but the
        rem empty tree - and so C:\Program Files\VMware - would remain and fail
        rem the removal check.
        for /r "!TARGET!" %%F in (*) do call :QueueRebootDelete "%%F"
        for /f "usebackq delims=" %%D in (`dir /s /b /ad "!TARGET!" 2^>nul ^| sort /r`) do call :QueueRebootDelete "%%D"
        call :QueueRebootDelete "!TARGET!"
        endlocal
        goto :eof
    )
    echo [SUCCESS] Removed !TARGET! >> "%LOG%"
    endlocal & set /a REMOVED_DIRS+=1
    goto :eof
)
endlocal
goto :eof

rem --- Subroutine: remove one file if present ---
:RemoveFile
setlocal
set "TARGET=%~1"
rem Defense in depth: never delete a bare drive root or a top-level system /
rem Program directory, even if a malformed manifest line names one. Files
rem *under* those directories are still allowed.
call :IsSafeToDelete "!TARGET!"
if not defined SAFE (
    echo [SKIP-UNSAFE] Refusing to delete system/root path: !TARGET!
    echo [SKIP-UNSAFE] Refusing to delete: !TARGET! >> "%LOG%"
    endlocal
    goto :eof
)
if exist "!TARGET!" (
    echo [DELETE FILE] !TARGET!
    echo [DELETE FILE] !TARGET! >> "%LOG%"
    del /f /q "!TARGET!" 2>nul
    if exist "!TARGET!" (
        echo [LOCKED] !TARGET! is in use - scheduling for reboot deletion
        echo [LOCKED] !TARGET! scheduled for reboot deletion >> "%LOG%"
        call :QueueRebootDelete "!TARGET!"
        endlocal
        goto :eof
    )
    echo [SUCCESS] Removed !TARGET! >> "%LOG%"
    endlocal & set /a REMOVED_FILES+=1
    goto :eof
)
endlocal
goto :eof

rem --- Subroutine: queue a locked file for deletion on next reboot ---
:QueueRebootDelete
rem %~1 = full path of a file to delete on reboot (appended to queue)
>>"%QUEUE_FILE%" echo %~1
goto :eof

rem --- Subroutine: write the queued files to PendingFileRenameOperations ---
:FlushPendingDeletes
if not exist "%QUEUE_FILE%" goto :eof
for /f %%C in ('type "%QUEUE_FILE%" ^| find /c /v ""') do set /a QUEUED=%%C
if %QUEUED% EQU 0 goto :eof

echo.
echo [INFO] %QUEUED% locked file^(s^) could not be deleted now - scheduling for next reboot.
echo [INFO] %QUEUED% locked file^(s^) scheduled for reboot deletion. >> "%LOG%"

rem PendingFileRenameOperations is a REG_MULTI_SZ where each delete is a
rem PAIR of strings: source "\??\<path>" followed by an EMPTY destination
rem string (empty dest = delete on reboot). reg.exe cannot emit an empty
rem element - "\0\0" in a /d value is rejected as an invalid parameter -
rem so the reliable writer is PowerShell (MultiString handles empty
rem elements natively and preserves any operations already queued).
rem reg.exe is kept only as a best-effort fallback for PowerShell-less
rem guests, where it may still fail on some builds.
if defined PS_OK (
    call :FlushPendingDeletesPS
    goto :eof
)
call :FlushPendingDeletesReg
goto :eof

rem --- Reliable path: schedule reboot deletes via PowerShell ---
rem Write via the .NET registry API, NOT Set-ItemProperty: the PowerShell
rem registry provider silently drops the EMPTY destination element that marks
rem a PendingFileRenameOperations entry as a delete, so Session Manager either
rem ignores the value or treats it as a rename and the locked files survive the
rem reboot. [Microsoft.Win32.Registry]::SetValue preserves empty elements.
rem The probe returns a REAL exit code (0 written+verified, 1 exception,
rem 2 value missing after write) and stderr is captured so a failure is logged
rem instead of masked by a hard-coded "exit 0".
:FlushPendingDeletesPS
"%PS_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try { $p='SYSTEM\CurrentControlSet\Control\Session Manager'; $k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($p,$true); $o=New-Object System.Collections.Generic.List[string]; $e=$k.GetValue('PendingFileRenameOperations'); if($e){$o.AddRange([string[]]$e)}; Get-Content -LiteralPath '%QUEUE_FILE%' | ForEach-Object { if($_.Trim() -ne ''){ $o.Add('\??\'+$_); $o.Add('') } }; $k.SetValue('PendingFileRenameOperations',[string[]]$o.ToArray(),[Microsoft.Win32.RegistryValueKind]::MultiString); $k.Close(); $c=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($p).GetValue('PendingFileRenameOperations'); if(-not $c){ exit 2 }; exit 0 } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }" >nul 2>"%temp%\vmw_pfro_err.txt"
if errorlevel 1 (
    echo [WARNING] Failed to write PendingFileRenameOperations - locked files NOT scheduled.
    echo [WARNING] Failed to write PendingFileRenameOperations ^(PowerShell^): >> "%LOG%"
    type "%temp%\vmw_pfro_err.txt" >> "%LOG%"
    set /a QUEUED=0
) else (
    echo [SUCCESS] Locked files scheduled for reboot deletion.
    echo [SUCCESS] Locked files scheduled for reboot deletion. >> "%LOG%"
)
del "%temp%\vmw_pfro_err.txt" >nul 2>&1
del "%QUEUE_FILE%" >nul 2>&1
goto :eof

rem --- Fallback path (no PowerShell): best-effort reg.exe writer ---
rem One op is  \??\<path>\0\0  (source, then empty dest). Some reg.exe
rem builds reject the empty element; verify on the target with:
rem   reg query "%SM_KEY%" /v PendingFileRenameOperations
:FlushPendingDeletesReg
set "PFRO_DATA="
for /f "usebackq delims=" %%F in ("%QUEUE_FILE%") do (
    set "PFRO_DATA=!PFRO_DATA!\??\%%F\0\0"
)

rem Preserve any operations Windows or another installer already queued
set "PFRO_OLD="
for /f "tokens=1,2,*" %%A in ('reg query "%SM_KEY%" /v PendingFileRenameOperations 2^>nul ^| findstr /I "REG_MULTI_SZ"') do set "PFRO_OLD=%%C"
if defined PFRO_OLD set "PFRO_DATA=!PFRO_OLD!\0!PFRO_DATA!"

reg add "%SM_KEY%" /v PendingFileRenameOperations /t REG_MULTI_SZ /d "!PFRO_DATA!" /f >nul 2>&1
if errorlevel 1 (
    echo [WARNING] Failed to write PendingFileRenameOperations - locked files NOT scheduled.
    echo [WARNING] Failed to write PendingFileRenameOperations ^(reg.exe^). >> "%LOG%"
    set /a QUEUED=0
) else (
    echo [SUCCESS] Locked files scheduled for reboot deletion.
    echo [SUCCESS] Locked files scheduled for reboot deletion. >> "%LOG%"
)
del "%QUEUE_FILE%" >nul 2>&1
goto :eof

rem --- Subroutine: gate catastrophic deletes (defense in depth) ---
rem Sets SAFE=1 when %~1 is a plausible file path to delete, and leaves SAFE
rem undefined otherwise. Rejects empty paths, paths with no backslash, bare
rem drive roots (C:\), and the top-level system / Program directories
rem themselves - a file *under* any of them is still allowed. The discovery
rem manifest is Authenticode-gated, so this is a backstop against a malformed
rem entry, not the primary VMware filter.
:IsSafeToDelete
setlocal enabledelayedexpansion
set "P=%~1"
set "SAFE="
rem Reject empty, or a path that contains no backslash at all.
if "!P!"=="" goto :SafeDone
if "!P:\=!"=="!P!" goto :SafeDone
rem Strip a single trailing backslash for comparison.
if "!P:~-1!"=="\" set "P=!P:~0,-1!"
rem Reject a bare drive root like "C:".
if "!P:~1!"==":" goto :SafeDone
rem Reject exact matches against critical directories. %ProgramFiles(x86)% is
rem expanded into a plain var and checked separately so its ")" cannot
rem terminate this parenthesised block.
set "PF86=%ProgramFiles(x86)%"
for %%C in (
    "%SystemDrive%\"
    "%SystemRoot%"
    "%SystemRoot%\System32"
    "%SystemRoot%\System32\drivers"
    "%SystemRoot%\SysWOW64"
    "%ProgramFiles%"
    "%ProgramData%"
) do (
    if /i "!P!"=="%%~C" goto :SafeDone
)
if defined PF86 if /i "!P!"=="!PF86!" goto :SafeDone
set "SAFE=1"
:SafeDone
endlocal & set "SAFE=%SAFE%"
goto :eof
