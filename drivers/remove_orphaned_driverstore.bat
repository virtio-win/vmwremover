@echo off
rem ===============================================================
rem remove_orphaned_driverstore.bat
rem Remove ORPHANED VMware driver-package folders left in the modern
rem driver store:
rem   %SystemRoot%\System32\DriverStore\FileRepository\<inf>_<arch>_<hash>
rem
rem pnputil owns FileRepository and normally deletes a package folder
rem when the driver is deregistered. But if a package file (e.g.
rem vmxnet3.sys) is still locked at removal time, pnputil deregisters
rem the package yet leaves the on-disk folder behind. Once deregistered
rem the package no longer appears in "pnputil /enum-drivers", so the
rem pnputil-based remover never revisits it and the folder lingers.
rem
rem This deletes ONLY such orphans, behind two independent safety gates:
rem   1) the folder name must carry a VMware-specific token, and
rem   2) the package inf must NOT be registered in "pnputil /enum-drivers"
rem      (a still-registered driver is left for pnputil to own).
rem Because FileRepository is owned by TrustedInstaller, "rd" alone fails
rem with Access denied, so ownership is taken (takeown /a) and Administrators
rem granted FullControl (icacls) before deletion. This is the one place the
rem toolset deletes inside FileRepository, and only for deregistered orphans.
rem
rem Returns 3010 when a folder was deleted OR a locked folder was scheduled
rem for reboot deletion; 0 when nothing matched. A deregistered folder whose
rem files are still locked (e.g. vmmouse while its mouse driver is loaded) is
rem queued to PendingFileRenameOperations so the next reboot clears it without
rem needing this script to be re-run.
rem ===============================================================

setlocal enabledelayedexpansion

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: This script must be run as Administrator!
    echo Please right-click and select "Run as administrator"
    exit /b 1
)

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "REPO=%SystemRoot%\System32\DriverStore\FileRepository"
set "LOG=%SCRIPT_DIR%\remove_orphaned_driverstore.log"
set "REGISTERED=%temp%\vmw_registered_infs.txt"
set "SM_KEY=HKLM\SYSTEM\CurrentControlSet\Control\Session Manager"
set "QUEUE_FILE=%temp%\vmw_ds_pending_deletes.txt"
del "%QUEUE_FILE%" >nul 2>&1

rem Resolve PowerShell for reliable reboot-delete scheduling (reg.exe cannot
rem emit the empty destination element PendingFileRenameOperations needs).
call :DetectPowerShell

echo =============================================================== > "%LOG%"
echo   Orphaned DriverStore cleanup - %DATE% %TIME% >> "%LOG%"
echo =============================================================== >> "%LOG%"

echo.
echo ===============================================================
echo   Remove orphaned VMware driver packages from DriverStore
echo   Run as Administrator
echo ===============================================================
echo.

set /a DELETED=0
set /a FAILED=0
set /a SCHEDULED=0

if not exist "%REPO%\" (
    echo [INFO] FileRepository not present - nothing to clean.
    echo [INFO] FileRepository not present. >> "%LOG%"
    exit /b 0
)

rem --- Snapshot the currently REGISTERED packages (Original Name lines). ---
rem A folder whose inf is still listed here is left alone for pnputil to own.
pnputil /enum-drivers 2>nul | findstr /I /C:"Original Name" > "%REGISTERED%"

rem --- VMware-specific folder tokens. Folder names look like
rem     vmxnet3.inf_amd64_<hash>, so matching "<tok>*.inf_*" is precise.
rem     Each token is a confirmed VMware driver; none collide with the
rem     virtio (netkvm/vio*) or Hyper-V replacement package names.
for %%T in (vmxnet3 vmci vsock vmmouse vmusbmouse vmrawdsk vmhgfs vmmemctl pvscsi vm3dmp vmwefifw vmaudio vmvss svga_wddm vsepflt vnetwfp vmware) do (
    for /d %%D in ("%REPO%\%%T*.inf_*") do call :ConsiderOrphan "%%~fD"
)

del "%REGISTERED%" >nul 2>&1

rem Flush any locked-but-deregistered folders to PendingFileRenameOperations.
if %SCHEDULED% GTR 0 call :FlushPendingDeletes

echo.
echo ===============================================================
echo  Orphaned DriverStore cleanup finished
echo  Folders removed: %DELETED%   Scheduled for reboot: %SCHEDULED%   Failed: %FAILED%
echo  Log saved to: %LOG%
echo ===============================================================
echo  Folders removed: %DELETED%   Scheduled for reboot: %SCHEDULED%   Failed: %FAILED% >> "%LOG%"

if %DELETED% GTR 0 (
    exit /b 3010
)
if %SCHEDULED% GTR 0 (
    exit /b 3010
)
exit /b 0

rem ---------------------------------------------------------------
rem Consider one candidate FileRepository folder for orphan deletion
rem ---------------------------------------------------------------
:ConsiderOrphan
setlocal enabledelayedexpansion
set "DIR=%~1"
for %%F in ("!DIR!") do set "FOLDER=%%~nxF"
rem Folder name is <inf>_<arch>_<hash>; the first _-delimited token is <inf>.inf
for /f "tokens=1 delims=_" %%A in ("!FOLDER!") do set "INFNAME=%%A"

rem SAFETY GATE 2: skip if this inf is still registered in pnputil. The
rem Original Name lines read "Original Name: vmxnet3.inf", so a literal
rem substring search for the inf file name is sufficient and precise.
findstr /I /C:"!INFNAME!" "%REGISTERED%" >nul 2>&1
if not errorlevel 1 (
    echo [SKIP] Still registered, leaving for pnputil: !FOLDER!
    echo [SKIP] Still registered: !FOLDER! >> "%LOG%"
    endlocal
    goto :eof
)

echo [DELETE DIR] !DIR!
echo [DELETE DIR] !DIR! >> "%LOG%"
rem Take ownership for Administrators, grant FullControl, then delete.
takeown /f "!DIR!" /r /a /d y >nul 2>&1
icacls "!DIR!" /grant *S-1-5-32-544:(OI)(CI)F /t >nul 2>&1
rd /s /q "!DIR!" 2>nul

if exist "!DIR!\" (
    rem A file inside is still locked (e.g. vmmouse.sys while the mouse driver
    rem is loaded). Ownership/ACLs were already taken above, so SYSTEM can
    rem delete it at boot: queue the remaining files, then the folders
    rem deepest-first (a directory only reboot-deletes once empty), then the
    rem folder itself. The next reboot clears it - no re-run needed.
    echo [SCHEDULE] Locked, scheduling for reboot deletion: !FOLDER!
    echo [SCHEDULE] Locked, scheduling for reboot deletion: !DIR! >> "%LOG%"
    for /r "!DIR!" %%F in (*) do call :QueueRebootDelete "%%F"
    for /f "usebackq delims=" %%S in (`dir /s /b /ad "!DIR!" 2^>nul ^| sort /r`) do call :QueueRebootDelete "%%S"
    call :QueueRebootDelete "!DIR!"
    endlocal & set /a SCHEDULED+=1
    goto :eof
)
echo [SUCCESS] Removed !FOLDER! >> "%LOG%"
endlocal & set /a DELETED+=1
goto :eof

rem --- Detect whether PowerShell can actually run on this guest ---
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

rem --- Subroutine: queue a locked path for deletion on next reboot ---
:QueueRebootDelete
rem %~1 = full path (file or directory) to delete on reboot
>>"%QUEUE_FILE%" echo %~1
goto :eof

rem --- Subroutine: write the queued paths to PendingFileRenameOperations ---
:FlushPendingDeletes
if not exist "%QUEUE_FILE%" goto :eof
rem PendingFileRenameOperations is a REG_MULTI_SZ of PAIRS: source "\??\<path>"
rem then an EMPTY destination (empty dest = delete on reboot). reg.exe cannot
rem emit an empty element, so PowerShell is the reliable writer; reg.exe is a
rem best-effort fallback for PowerShell-less guests.
if defined PS_OK (
    call :FlushPendingDeletesPS
    goto :eof
)
call :FlushPendingDeletesReg
goto :eof

rem --- Reliable path: schedule reboot deletes via PowerShell ---
rem Write via the .NET registry API, NOT Set-ItemProperty: the PowerShell
rem registry provider silently drops the EMPTY destination element that marks
rem a PendingFileRenameOperations entry as a delete, so Session Manager ignores
rem the value and the locked folder survives the reboot. SetValue preserves
rem empty elements; the probe returns a real exit code (0 ok, 1 exception,
rem 2 value missing after write) and stderr is captured so failures are logged.
:FlushPendingDeletesPS
"%PS_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try { $p='SYSTEM\CurrentControlSet\Control\Session Manager'; $k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($p,$true); $o=New-Object System.Collections.Generic.List[string]; $e=$k.GetValue('PendingFileRenameOperations'); if($e){$o.AddRange([string[]]$e)}; Get-Content -LiteralPath '%QUEUE_FILE%' | ForEach-Object { if($_.Trim() -ne ''){ $o.Add('\??\'+$_); $o.Add('') } }; $k.SetValue('PendingFileRenameOperations',[string[]]$o.ToArray(),[Microsoft.Win32.RegistryValueKind]::MultiString); $k.Close(); $c=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($p).GetValue('PendingFileRenameOperations'); if(-not $c){ exit 2 }; exit 0 } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }" >nul 2>"%temp%\vmw_ds_pfro_err.txt"
if errorlevel 1 (
    echo [WARNING] Failed to schedule reboot deletion - locked folders NOT scheduled. >> "%LOG%"
    type "%temp%\vmw_ds_pfro_err.txt" >> "%LOG%"
) else (
    echo [SUCCESS] Locked folders scheduled for reboot deletion. >> "%LOG%"
)
del "%temp%\vmw_ds_pfro_err.txt" >nul 2>&1
del "%QUEUE_FILE%" >nul 2>&1
goto :eof

rem --- Fallback path (no PowerShell): best-effort reg.exe writer ---
:FlushPendingDeletesReg
set "PFRO_DATA="
for /f "usebackq delims=" %%F in ("%QUEUE_FILE%") do (
    set "PFRO_DATA=!PFRO_DATA!\??\%%F\0\0"
)
set "PFRO_OLD="
for /f "tokens=1,2,*" %%A in ('reg query "%SM_KEY%" /v PendingFileRenameOperations 2^>nul ^| findstr /I "REG_MULTI_SZ"') do set "PFRO_OLD=%%C"
if defined PFRO_OLD set "PFRO_DATA=!PFRO_OLD!\0!PFRO_DATA!"
reg add "%SM_KEY%" /v PendingFileRenameOperations /t REG_MULTI_SZ /d "!PFRO_DATA!" /f >nul 2>&1
if errorlevel 1 (
    echo [WARNING] Failed to schedule reboot deletion ^(reg.exe^) - locked folders NOT scheduled. >> "%LOG%"
) else (
    echo [SUCCESS] Locked folders scheduled for reboot deletion ^(reg.exe^). >> "%LOG%"
)
del "%QUEUE_FILE%" >nul 2>&1
goto :eof
