#requires -Version 3.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Remove VMware vSockets from Winsock catalog after registry cleanup.

.DESCRIPTION
    This script is called by remove_vmware_registry.bat immediately after
    deleting the Services\vsock registry key. It removes any VMware vSockets
    Winsock catalog entries that may have been re-registered or survived
    the initial cleanup.

    Called BEFORE reboot to prevent Windows from re-registering the provider.

.NOTES
    Run AFTER remove_vmware_registry.bat completes.
    This is a focused cleanup - only handles Winsock catalog.
#>

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $ScriptDir "winsock_cleanup_post_registry.log"

# VMware vSockets GUID
$VMwareVsockGUID = "{570ADC4B-67B2-42CE-92B2-ACD33D88D842}"

# Initialize log
"===============================================================" | Out-File $LogFile
"  Winsock Cleanup (Post-Registry) - $(Get-Date)" | Out-File $LogFile -Append
"===============================================================" | Out-File $LogFile -Append
"" | Out-File $LogFile -Append

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  Winsock Cleanup (Post-Registry)" -ForegroundColor Cyan
Write-Host "  Removing VMware vSockets after registry cleanup" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

function Test-ProviderInCatalog {
    $winsockOutput = netsh winsock show catalog 2>&1 | Out-String
    return $winsockOutput -match [regex]::Escape($VMwareVsockGUID)
}

try {
    # Check if VMware vSockets provider is in Winsock catalog
    Write-Host "[INFO] Checking Winsock catalog for VMware vSockets provider..." -ForegroundColor Cyan
    "[INFO] Checking Winsock catalog..." | Out-File $LogFile -Append

    if (Test-ProviderInCatalog) {
        Write-Host "[FOUND] VMware vSockets provider in Winsock catalog" -ForegroundColor Yellow
        Write-Host "[INFO] Removing provider GUID: $VMwareVsockGUID" -ForegroundColor Yellow
        "[FOUND] VMware vSockets provider: $VMwareVsockGUID" | Out-File $LogFile -Append

        # Attempt 1: Try simple removal
        Write-Host "[ATTEMPT 1] Using netsh winsock remove provider..." -ForegroundColor Cyan
        "[ATTEMPT 1] netsh winsock remove provider" | Out-File $LogFile -Append
        $removeOutput = netsh winsock remove provider $VMwareVsockGUID 2>&1
        $exitCode = $LASTEXITCODE

        # Verify removal worked
        Start-Sleep -Milliseconds 500  # Give Windows time to update
        $stillPresent = Test-ProviderInCatalog

        if (-not $stillPresent) {
            Write-Host "[SUCCESS] VMware vSockets provider removed from Winsock" -ForegroundColor Green
            "[SUCCESS] Provider removed successfully (verified)" | Out-File $LogFile -Append
        } else {
            Write-Host "[FAILED] Provider still present after removal attempt!" -ForegroundColor Red
            "[FAILED] Simple removal did not work - provider still present" | Out-File $LogFile -Append

            # Attempt 2: Reset Winsock catalog
            Write-Host "[ATTEMPT 2] Using netsh winsock reset to rebuild catalog..." -ForegroundColor Yellow
            Write-Host "[WARNING] This will reset ALL Winsock providers to defaults!" -ForegroundColor Yellow
            "[ATTEMPT 2] netsh winsock reset" | Out-File $LogFile -Append
            "[WARNING] Full Winsock reset - will restore catalog from registry" | Out-File $LogFile -Append

            $resetOutput = netsh winsock reset 2>&1
            $resetExit = $LASTEXITCODE

            # Verify reset worked
            Start-Sleep -Milliseconds 500
            $stillPresent2 = Test-ProviderInCatalog

            if (-not $stillPresent2) {
                Write-Host "[SUCCESS] Winsock reset removed VMware vSockets provider" -ForegroundColor Green
                Write-Host "[INFO] Other providers will be restored from registry on next boot" -ForegroundColor Cyan
                "[SUCCESS] Winsock reset succeeded (verified clean)" | Out-File $LogFile -Append
            } else {
                Write-Host "[CRITICAL] Provider STILL present after winsock reset!" -ForegroundColor Red
                Write-Host "[ERROR] This means provider is coming from registry we didn't clean!" -ForegroundColor Red
                Write-Host ""
                Write-Host "Manual investigation required - check:" -ForegroundColor Yellow
                Write-Host "  1. Are there other ControlSets we missed?" -ForegroundColor Yellow
                Write-Host "  2. Is there a WOW64 registry location?" -ForegroundColor Yellow
                Write-Host "  3. Is a VMware service still running and re-registering it?" -ForegroundColor Yellow
                ""
                "[CRITICAL] Provider still present after winsock reset!" | Out-File $LogFile -Append
                "[ERROR] Registry cleanup incomplete - unknown source" | Out-File $LogFile -Append
                exit 1
            }
        }
    } else {
        Write-Host "[OK] VMware vSockets provider not found in Winsock catalog" -ForegroundColor Green
        "[OK] Winsock catalog is clean - no VMware vSockets found" | Out-File $LogFile -Append
    }

} catch {
    Write-Host "[ERROR] Winsock catalog check failed: $($_.Exception.Message)" -ForegroundColor Red
    "[ERROR] Exception: $($_.Exception.Message)" | Out-File $LogFile -Append
    exit 1
}

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  Winsock Cleanup Complete" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next step: Reboot to complete locked file deletion" -ForegroundColor Yellow
Write-Host ""

"" | Out-File $LogFile -Append
"[COMPLETE] Winsock cleanup finished at $(Get-Date)" | Out-File $LogFile -Append
"===============================================================" | Out-File $LogFile -Append

exit 0
