#requires -Version 3.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Remove VMware binary files discovered by discover_vmware_binaries.ps1

.DESCRIPTION
    Reads the vmware_binaries.txt file and removes each binary.
    Handles locked files by scheduling deletion on reboot.
    Includes safety validation to prevent accidental deletion of system directories.

.NOTES
    Must be run as Administrator
    Converted from remove_vmware_binaries.bat for better safety and error handling
#>

$ErrorActionPreference = "Continue"

# ===============================================================
# Configuration
# ===============================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InputFile = Join-Path $ScriptDir "vmware_binaries.txt"
$LogFile = Join-Path $ScriptDir "removal.log"

# ===============================================================
# P/Invoke: MoveFileEx for Reboot Deletion
# ===============================================================
# Define the Windows API function once at script initialization.
# MoveFileEx with MOVEFILE_DELAY_UNTIL_REBOOT schedules file deletion
# on next boot via the Session Manager (smss.exe) running as SYSTEM.
# This bypasses TrustedInstaller ownership issues in System32.
# ===============================================================

if (-not ([System.Management.Automation.PSTypeName]'FileOperations').Type) {
    Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;

        public class FileOperations {
            [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)]
            public static extern bool MoveFileEx(
                string lpExistingFileName,
                string lpNewFileName,
                int dwFlags
            );

            [DllImport("kernel32.dll")]
            public static extern int GetLastError();

            public const int MOVEFILE_DELAY_UNTIL_REBOOT = 0x4;
        }

        public class TokenManipulator {
            [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
            internal static extern bool AdjustTokenPrivileges(
                IntPtr htok,
                bool disall,
                ref TokPriv1Luid newst,
                int len,
                IntPtr prev,
                IntPtr relen
            );

            [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
            internal static extern bool OpenProcessToken(
                IntPtr h,
                int acc,
                ref IntPtr phtok
            );

            [DllImport("advapi32.dll", SetLastError=true)]
            internal static extern bool LookupPrivilegeValue(
                string host,
                string name,
                ref long pluid
            );

            [DllImport("kernel32.dll", ExactSpelling=true)]
            internal static extern IntPtr GetCurrentProcess();

            [StructLayout(LayoutKind.Sequential, Pack=1)]
            internal struct TokPriv1Luid {
                public int Count;
                public long Luid;
                public int Attr;
            }

            internal const int SE_PRIVILEGE_ENABLED = 0x00000002;
            internal const int TOKEN_QUERY = 0x00000008;
            internal const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;

            public static bool EnablePrivilege(string privilege) {
                IntPtr hproc = GetCurrentProcess();
                IntPtr htok = IntPtr.Zero;

                if (!OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok)) {
                    return false;
                }

                TokPriv1Luid tp;
                tp.Count = 1;
                tp.Luid = 0;
                tp.Attr = SE_PRIVILEGE_ENABLED;

                if (!LookupPrivilegeValue(null, privilege, ref tp.Luid)) {
                    return false;
                }

                return AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            }
        }
"@
}

# ===============================================================
# Helper Functions
# ===============================================================

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $Message -ErrorAction SilentlyContinue
}

function Remove-VMwareWinsockProvider {
    <#
    .SYNOPSIS
        Remove VMware vSockets provider from Windows Winsock catalog.

    .DESCRIPTION
        VMware vsock.sys registers AF_VSOCK (Address Family 28) in the Winsock
        catalog pointing to vsocklib.dll. If we delete vsocklib.dll without first
        removing the catalog entry, Windows will have a broken reference that
        prevents virtio-vsock (Red Hat KVM) from working.

        This function safely removes ONLY the VMware vSockets provider while
        preserving virtio-vsock (AF 40) entries.

    .RETURNS
        $true if cleanup was performed or not needed, $false on critical error
    #>

    $VMwareVsockProviderGUID = "{570ADC4B-67B2-42CE-92B2-ACD33D88D842}"

    Write-Log ""
    Write-Log "==========================================" "Yellow"
    Write-Log " Winsock Catalog Pre-Flight Check" "Yellow"
    Write-Log "==========================================" "Yellow"

    try {
        # Check if VMware vSockets provider exists
        $winsockOutput = netsh winsock show catalog 2>&1

        if ($winsockOutput -match [regex]::Escape($VMwareVsockProviderGUID)) {
            Write-Log "[FOUND] VMware vSockets provider registered in Winsock catalog" "Yellow"
            Write-Log "[INFO] Removing provider to prevent conflicts with virtio-vsock" "Cyan"

            # Remove the provider
            $removeOutput = netsh winsock remove provider $VMwareVsockProviderGUID 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-Log "[SUCCESS] VMware vSockets provider removed from Winsock" "Green"
                return $true
            } else {
                Write-Log "[WARNING] netsh returned exit code: $LASTEXITCODE" "Yellow"
                Write-Log "[WARNING] Provider removal may require reboot to complete" "Yellow"
                return $true  # Non-fatal - continue with binary removal
            }
        } else {
            Write-Log "[OK] VMware vSockets provider not found - no Winsock cleanup needed" "Green"
            return $true
        }
    }
    catch {
        Write-Log "[ERROR] Winsock catalog check failed: $($_.Exception.Message)" "Red"
        Write-Log "[WARNING] Continuing with binary removal despite Winsock error" "Yellow"
        return $true  # Non-fatal - don't block binary removal
    }
}

function Test-SafePath {
    <#
    .SYNOPSIS
        Validates that a path is safe to delete.

    .DESCRIPTION
        Prevents accidental deletion of:
        - Root drives (C:, D:\)
        - Critical system directories (C:\Windows, C:\Program Files)
        - Empty or malformed paths
        - Paths without file extensions (unless deep enough)

    .PARAMETER Path
        Path to validate

    .RETURNS
        $true if safe to delete, $false otherwise
    #>
    param([string]$Path)

    # Check for empty or too-short paths
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -lt 4) {
        return $false
    }

    # Normalize path: remove whitespace and trailing backslashes
    # Critical: prevents "C:\Windows\System32\" from bypassing the safety check
    $Path = $Path.Trim().TrimEnd('\')

    # Reject root drive paths (C:, D:, C:\, D:\)
    if ($Path -match '^[A-Z]:\\?$') {
        return $false
    }

    # Reject critical system directories (exact match)
    $criticalPaths = @(
        "$env:SystemRoot",
        "$env:SystemRoot\System32",
        "$env:ProgramFiles",
        "${env:ProgramFiles(x86)}"
    )

    foreach ($criticalPath in $criticalPaths) {
        if ($Path -eq $criticalPath) {
            return $false
        }
    }

    # Require path to contain a file extension OR be deep enough
    if ($Path -match '\.[a-zA-Z]{2,}$') {
        # Has file extension - valid
        return $true
    }

    # No extension - must be at least 3 levels deep
    # (Reduced from 4 to accommodate C:\Windows\Installer\{GUID} MSI files)
    $depth = ($Path -split '\\').Count
    if ($depth -lt 3) {
        return $false
    }

    return $true
}

function Remove-Binary {
    <#
    .SYNOPSIS
        Attempts to remove a binary file, scheduling reboot deletion if locked.

    .PARAMETER FilePath
        Full path to the file to remove

    .RETURNS
        PSCustomObject with Status ("Deleted", "Locked", "NotFound", "Error") and Message
    #>
    param([string]$FilePath)

    $fileName = Split-Path -Leaf $FilePath

    # Check if file exists
    if (-not (Test-Path $FilePath)) {
        return [PSCustomObject]@{
            Status = "NotFound"
            Message = "File not found"
        }
    }

    try {
        # Attempt immediate deletion
        Remove-Item -Path $FilePath -Force -ErrorAction Stop

        # Verify deletion
        if (-not (Test-Path $FilePath)) {
            return [PSCustomObject]@{
                Status = "Deleted"
                Message = "Successfully deleted"
            }
        }

        # File still exists after deletion attempt - likely locked
        throw "File still exists after deletion attempt"
    }
    catch {
        # File is locked or protected - schedule for reboot deletion
        Write-Log "[LOCKED] $fileName - File is in use, scheduling for reboot deletion" "Yellow"

        try {
            # Call MoveFileEx (already defined at script initialization)
            # Pass null as second parameter to delete (not move) the file
            $result = [FileOperations]::MoveFileEx($FilePath, [NullString]::Value, 0x4)

            if ($result) {
                return [PSCustomObject]@{
                    Status = "Locked"
                    Message = "Scheduled for deletion on reboot"
                }
            } else {
                $lastError = [FileOperations]::GetLastError()
                throw "MoveFileEx failed with error code: $lastError"
            }
        }
        catch {
            Write-Log "[ERROR] Failed to schedule reboot deletion: $($_.Exception.Message)" "Red"
            return [PSCustomObject]@{
                Status = "Error"
                Message = "Failed to delete or schedule: $($_.Exception.Message)"
            }
        }
    }
}

# ===============================================================
# Initialize
# ===============================================================

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  VMware Binary Removal Tool" -ForegroundColor Cyan
Write-Host "  Run as Administrator" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

# Check if input file exists
if (-not (Test-Path $InputFile)) {
    Write-Host "ERROR: Binary list file not found: $InputFile" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please run discover_vmware_binaries.ps1 first to generate the list." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Host "[INFO] Reading binary list from: $InputFile" -ForegroundColor White
Write-Host "[INFO] Log file: $LogFile" -ForegroundColor White
Write-Host ""

# Initialize log file
"===============================================================" | Out-File $LogFile
"  VMware Binary Removal Log - $(Get-Date)" | Out-File $LogFile -Append
"===============================================================" | Out-File $LogFile -Append

# ===============================================================
# Pre-Flight: Clean VMware vSockets from Winsock Catalog
# ===============================================================
# CRITICAL: Remove AF_VSOCK registration BEFORE deleting vsocklib.dll
# Otherwise Windows Winsock catalog will have broken references that
# prevent virtio-vsock (Red Hat KVM) from working after migration.
# ===============================================================

Remove-VMwareWinsockProvider | Out-Null

# ===============================================================
# Enable SeRestorePrivilege for MoveFileEx Reboot Deletion
# ===============================================================
# MoveFileEx with MOVEFILE_DELAY_UNTIL_REBOOT writes to the registry key:
# HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations
# This requires SeRestorePrivilege even when running as Administrator.
# ===============================================================

Write-Host ""
Write-Host "[INFO] Enabling SeRestorePrivilege for reboot deletion..." -ForegroundColor Cyan
$privilegeEnabled = [TokenManipulator]::EnablePrivilege("SeRestorePrivilege")

if ($privilegeEnabled) {
    Write-Log "[SUCCESS] SeRestorePrivilege enabled - reboot deletion available"
} else {
    Write-Log "[WARNING] Failed to enable SeRestorePrivilege - reboot deletion may fail" "Yellow"
    Write-Log "[WARNING] Locked files may need manual deletion or cleanup_protected_files.ps1" "Yellow"
}
Write-Host ""

# Initialize counters
$TotalCount = 0
$DeletedCount = 0
$LockedCount = 0
$NotFoundCount = 0
$SkippedCount = 0
$ErrorCount = 0

# ===============================================================
# Pre-Flight: Terminate Running VMware Processes
# ===============================================================
# Stop VMware services and processes before attempting file deletion.
# This significantly reduces the number of locked files that require
# reboot deletion, improving the user experience.
# ===============================================================

Write-Host "==========================================" -ForegroundColor Yellow
Write-Host " Terminating VMware Processes" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "[INFO] Stopping VMware services..." -ForegroundColor Cyan
$vmwareServices = Get-Service -Name "VMTools", "VMware*" -ErrorAction SilentlyContinue
if ($vmwareServices) {
    foreach ($service in $vmwareServices) {
        try {
            Stop-Service -Name $service.Name -Force -ErrorAction Stop
            Write-Host "  [STOPPED] Service: $($service.Name)" -ForegroundColor Green
            Write-Log "[STOPPED] Service: $($service.Name)"
        } catch {
            Write-Host "  [INFO] Could not stop service: $($service.Name)" -ForegroundColor Yellow
            Write-Log "[INFO] Service stop failed: $($service.Name) - $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "  No VMware services found (already stopped or removed)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "[INFO] Terminating VMware processes..." -ForegroundColor Cyan
$vmwareProcesses = Get-Process -Name "vmtoolsd", "vmacthlp", "vmware*", "vm3d*" -ErrorAction SilentlyContinue
if ($vmwareProcesses) {
    foreach ($process in $vmwareProcesses) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            Write-Host "  [KILLED] Process: $($process.Name) (PID: $($process.Id))" -ForegroundColor Green
            Write-Log "[KILLED] Process: $($process.Name) (PID: $($process.Id))"
        } catch {
            Write-Host "  [INFO] Could not kill process: $($process.Name)" -ForegroundColor Yellow
            Write-Log "[INFO] Process kill failed: $($process.Name) - $($_.Exception.Message)"
        }
    }

    # Give the OS a moment to release file handles
    Write-Host ""
    Write-Host "[INFO] Waiting 2 seconds for file handles to release..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
} else {
    Write-Host "  No VMware processes found running" -ForegroundColor Gray
}

Write-Host ""

# ===============================================================
# Process each binary from the list
# ===============================================================

Write-Host "==========================================" -ForegroundColor Yellow
Write-Host " Processing binaries for removal" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""

$lines = Get-Content $InputFile
$ProcessedPaths = @{}  # Track already-processed paths to handle duplicates

foreach ($line in $lines) {
    # Skip comments and empty lines
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
        $SkippedCount++
        continue
    }

    $filePath = $line.Trim()

    # Skip duplicates silently (file discovered by multiple methods)
    if ($ProcessedPaths.ContainsKey($filePath.ToLowerInvariant())) {
        $SkippedCount++
        continue
    }
    $ProcessedPaths[$filePath.ToLowerInvariant()] = $true

    # Validate path safety
    if (-not (Test-SafePath -Path $filePath)) {
        Write-Log "[INVALID PATH] Skipping dangerous/malformed path: $filePath" "Red"
        $SkippedCount++
        continue
    }

    $TotalCount++
    Write-Host "[PROCESSING] $filePath" -ForegroundColor Cyan

    # Attempt removal
    $result = Remove-Binary -FilePath $filePath

    switch ($result.Status) {
        "Deleted" {
            Write-Log "[SUCCESS] Deleted: $filePath" "Green"
            $DeletedCount++
        }
        "Locked" {
            Write-Log "[LOCKED] Scheduled for reboot: $filePath" "Yellow"
            $LockedCount++
        }
        "NotFound" {
            Write-Log "[NOT FOUND] $filePath" "Gray"
            $NotFoundCount++
        }
        "Error" {
            Write-Log "[ERROR] $filePath - $($result.Message)" "Red"
            $ErrorCount++
        }
    }
}

# ===============================================================
# Clean up orphaned FileRepository directories
# ===============================================================
# pnputil removes drivers from the database, but sometimes leaves
# FileRepository directories behind. Now that drivers are unloaded
# (after REBOOT #1), we can remove these directories.
# ===============================================================

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Yellow
Write-Host " Cleaning up Driver FileRepository" -ForegroundColor Yellow
Write-Host "===============================================================" -ForegroundColor Yellow
Write-Host ""

$fileRepoPath = Join-Path $env:SystemRoot "System32\DriverStore\FileRepository"

if (Test-Path $fileRepoPath) {
    Write-Host "Scanning for VMware directories in FileRepository..." -ForegroundColor Cyan

    $vmwareDirs = Get-ChildItem -Path $fileRepoPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'vmware|vmci|vmxnet|vmmouse|vsock' }

    if ($vmwareDirs) {
        foreach ($dir in $vmwareDirs) {
            Write-Host "Found orphaned directory: $($dir.Name)" -ForegroundColor Yellow
            Write-Log "Removing FileRepository directory: $($dir.FullName)"

            try {
                Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction Stop
                Write-Host "  [SUCCESS] Removed: $($dir.Name)" -ForegroundColor Green
                Write-Log "  [SUCCESS] Removed FileRepository: $($dir.Name)"
            }
            catch {
                Write-Host "  [FAILED] Could not remove: $($dir.Name) - $($_.Exception.Message)" -ForegroundColor Red
                Write-Log "  [FAILED] FileRepository removal: $($dir.Name) - $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host "No orphaned VMware directories found in FileRepository." -ForegroundColor Green
    }
} else {
    Write-Host "FileRepository path not found (older Windows version)." -ForegroundColor Gray
}

# ===============================================================
# Clean up empty VMware directories
# ===============================================================
# After removing all files, clean up any empty directories that remain.
# Customer requirement: directories should not exist even if empty.
# ===============================================================

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Yellow
Write-Host " Cleaning up empty VMware directories" -ForegroundColor Yellow
Write-Host "===============================================================" -ForegroundColor Yellow
Write-Host ""

$vmwareRootDirs = @(
    "$env:ProgramFiles\VMware",
    "${env:ProgramFiles(x86)}\VMware",
    "$env:ProgramFiles\Common Files\VMware",
    "${env:ProgramFiles(x86)}\Common Files\VMware",
    "$env:ProgramData\VMware"
)

foreach ($rootDir in $vmwareRootDirs) {
    if (Test-Path $rootDir) {
        Write-Host "Found VMware directory: $rootDir" -ForegroundColor Yellow
        Write-Log "Attempting to remove directory: $rootDir"

        try {
            # Remove directory and all subdirectories (even if empty)
            Remove-Item -Path $rootDir -Recurse -Force -ErrorAction Stop
            Write-Host "  [SUCCESS] Removed directory: $rootDir" -ForegroundColor Green
            Write-Log "  [SUCCESS] Removed directory: $rootDir"
        }
        catch {
            # Directory may still contain files we couldn't delete
            $remainingItems = Get-ChildItem -Path $rootDir -Recurse -ErrorAction SilentlyContinue
            if ($remainingItems) {
                Write-Host "  [INFO] Directory not empty, contains $($remainingItems.Count) items" -ForegroundColor Yellow
                Write-Log "  [INFO] Directory contains $($remainingItems.Count) remaining items: $rootDir"
            } else {
                Write-Host "  [WARNING] Could not remove empty directory: $rootDir - $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Log "  [WARNING] Could not remove directory: $rootDir - $($_.Exception.Message)"
            }
        }
    }
}

# ===============================================================
# Summary
# ===============================================================

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host " Removal Complete" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor White
Write-Host "  Total items processed:     $TotalCount" -ForegroundColor White
Write-Host "  Successfully deleted:      $DeletedCount" -ForegroundColor Green
Write-Host "  Locked (reboot required):  $LockedCount" -ForegroundColor Yellow
Write-Host "  Not found:                 $NotFoundCount" -ForegroundColor Gray
Write-Host "  Skipped (comments/invalid):$SkippedCount" -ForegroundColor Gray
Write-Host "  Errors:                    $ErrorCount" -ForegroundColor Red
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "[SUMMARY] Total: $TotalCount, Deleted: $DeletedCount, Locked: $LockedCount, Not Found: $NotFoundCount, Skipped: $SkippedCount, Errors: $ErrorCount"

if ($LockedCount -gt 0) {
    Write-Host "===============================================================" -ForegroundColor Yellow
    Write-Host "WARNING: $LockedCount file(s) were locked and scheduled for deletion" -ForegroundColor Yellow
    Write-Host "on next reboot. Please restart your computer to complete removal." -ForegroundColor Yellow
    Write-Host "===============================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Log "[WARNING] Reboot required for $LockedCount locked files"
}

Write-Host "Log file: $LogFile" -ForegroundColor Cyan
Write-Host ""

exit 0
