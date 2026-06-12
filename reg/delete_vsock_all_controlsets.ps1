#requires -Version 3.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Delete vsock service entries from ALL registry ControlSets.

.DESCRIPTION
    Windows maintains multiple ControlSets (ControlSet001, ControlSet002, etc.)
    and CurrentControlSet is just a symbolic link to the active one.

    When we delete only CurrentControlSet\Services\vsock, the provider info
    may still exist in the inactive ControlSets, which Windows reads during
    boot and can trigger Winsock re-registration.

    This script finds and deletes vsock service entries from ALL ControlSets
    to prevent re-registration after reboot.

.NOTES
    Called by remove_vmware_registry.bat AFTER deleting CurrentControlSet entry.
    This ensures complete cleanup across all registry control sets.
#>

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $ScriptDir "delete_vsock_controlsets.log"

# Initialize log
"===============================================================" | Out-File $LogFile
"  Delete vsock from ALL ControlSets - $(Get-Date)" | Out-File $LogFile -Append
"===============================================================" | Out-File $LogFile -Append
"" | Out-File $LogFile -Append

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  Deleting vsock from ALL Registry ControlSets" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

$TotalDeleted = 0
$TotalNotFound = 0

try {
    # Find all ControlSet* keys under HKLM\SYSTEM
    Write-Host "[INFO] Searching for ControlSet keys..." -ForegroundColor Cyan
    "[INFO] Searching for ControlSet keys..." | Out-File $LogFile -Append

    $ControlSets = Get-ChildItem -Path "HKLM:\SYSTEM" -ErrorAction SilentlyContinue |
                   Where-Object { $_.PSChildName -match '^ControlSet\d{3}$' }

    if ($ControlSets.Count -eq 0) {
        Write-Host "[WARNING] No ControlSet keys found - unexpected!" -ForegroundColor Yellow
        "[WARNING] No ControlSet keys found" | Out-File $LogFile -Append
        exit 1
    }

    Write-Host "[INFO] Found $($ControlSets.Count) ControlSet(s)" -ForegroundColor Cyan
    "[INFO] Found $($ControlSets.Count) ControlSet(s):" | Out-File $LogFile -Append

    foreach ($cs in $ControlSets) {
        "  - $($cs.PSChildName)" | Out-File $LogFile -Append
        Write-Host "  - $($cs.PSChildName)"
    }

    Write-Host ""

    # Process each ControlSet
    foreach ($controlSet in $ControlSets) {
        $controlSetName = $controlSet.PSChildName
        $vsockPath = "HKLM:\SYSTEM\$controlSetName\Services\vsock"

        Write-Host "[PROCESSING] $controlSetName..." -ForegroundColor Cyan
        "[PROCESSING] $controlSetName" | Out-File $LogFile -Append

        if (Test-Path $vsockPath) {
            Write-Host "  [FOUND] vsock service entry in $controlSetName" -ForegroundColor Yellow
            "  [FOUND] $vsockPath exists" | Out-File $LogFile -Append

            try {
                # Delete the entire vsock key recursively
                Remove-Item -Path $vsockPath -Recurse -Force -ErrorAction Stop

                Write-Host "  [SUCCESS] Deleted vsock from $controlSetName" -ForegroundColor Green
                "  [SUCCESS] Deleted $vsockPath" | Out-File $LogFile -Append
                $TotalDeleted++
            }
            catch {
                Write-Host "  [ERROR] Failed to delete from $controlSetName : $($_.Exception.Message)" -ForegroundColor Red
                "  [ERROR] Failed to delete $vsockPath : $($_.Exception.Message)" | Out-File $LogFile -Append
            }
        }
        else {
            Write-Host "  [OK] vsock not found in $controlSetName (already clean)" -ForegroundColor Green
            "  [OK] $vsockPath does not exist" | Out-File $LogFile -Append
            $TotalNotFound++
        }
    }

} catch {
    Write-Host "[ERROR] Failed to enumerate ControlSets: $($_.Exception.Message)" -ForegroundColor Red
    "[ERROR] Exception: $($_.Exception.Message)" | Out-File $LogFile -Append
    exit 1
}

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  ControlSet Cleanup Summary" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  ControlSets scanned:  $($ControlSets.Count)"
Write-Host "  vsock entries deleted: $TotalDeleted"
Write-Host "  vsock entries not found: $TotalNotFound"
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

"" | Out-File $LogFile -Append
"[SUMMARY] Scanned: $($ControlSets.Count), Deleted: $TotalDeleted, Not Found: $TotalNotFound" | Out-File $LogFile -Append
"[COMPLETE] ControlSet cleanup finished at $(Get-Date)" | Out-File $LogFile -Append
"===============================================================" | Out-File $LogFile -Append

if ($TotalDeleted -gt 0) {
    Write-Host "[SUCCESS] Deleted vsock from $TotalDeleted ControlSet(s)" -ForegroundColor Green
} else {
    Write-Host "[OK] All ControlSets were already clean" -ForegroundColor Green
}

Write-Host ""
Write-Host "Log file: $LogFile"
Write-Host ""

exit 0
