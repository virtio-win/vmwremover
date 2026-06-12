#requires -Version 3.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Delete VMware vSockets Winsock registry entries from ALL ControlSets.

.DESCRIPTION
    Windows stores Winsock provider information in TWO places:
    1. Runtime catalog (accessed by netsh winsock show catalog)
    2. Registry (HKLM\SYSTEM\ControlSetXXX\Services\WinSock2\Parameters)

    When we use "netsh winsock remove provider", it removes from the runtime
    catalog. But if the registry entries still exist, Windows can REBUILD
    the catalog from registry on boot!

    This script deletes the Winsock registry entries for VMware vSockets
    from ALL ControlSets to prevent catalog rebuild on boot.

.NOTES
    Called by remove_vmware_registry.bat AFTER ControlSet cleanup and
    BEFORE netsh Winsock cleanup.

    VMware vSockets GUID: {570ADC4B-67B2-42CE-92B2-ACD33D88D842}
#>

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $ScriptDir "delete_winsock_registry.log"

# VMware vSockets GUID
$VMwareVsockGUID = "570ADC4B-67B2-42CE-92B2-ACD33D88D842"

# Initialize log
"===============================================================" | Out-File $LogFile
"  Delete Winsock Registry Entries - $(Get-Date)" | Out-File $LogFile -Append
"===============================================================" | Out-File $LogFile -Append
"" | Out-File $LogFile -Append

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  Deleting VMware vSockets Winsock Registry Entries" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

$TotalDeleted = 0
$TotalNotFound = 0

try {
    # Find all ControlSet* keys
    Write-Host "[INFO] Searching for ControlSet keys..." -ForegroundColor Cyan
    "[INFO] Searching for ControlSet keys..." | Out-File $LogFile -Append

    $ControlSets = Get-ChildItem -Path "HKLM:\SYSTEM" -ErrorAction SilentlyContinue |
                   Where-Object { $_.PSChildName -match '^ControlSet\d{3}$' }

    if ($ControlSets.Count -eq 0) {
        Write-Host "[WARNING] No ControlSet keys found!" -ForegroundColor Yellow
        "[WARNING] No ControlSet keys found" | Out-File $LogFile -Append
        exit 1
    }

    Write-Host "[INFO] Found $($ControlSets.Count) ControlSet(s)" -ForegroundColor Cyan
    "[INFO] Found $($ControlSets.Count) ControlSet(s)" | Out-File $LogFile -Append
    Write-Host ""

    # Process each ControlSet
    foreach ($controlSet in $ControlSets) {
        $controlSetName = $controlSet.PSChildName

        Write-Host "[PROCESSING] $controlSetName..." -ForegroundColor Cyan
        "[PROCESSING] $controlSetName" | Out-File $LogFile -Append

        # Winsock2 namespace providers path
        $namespacePath = "HKLM:\SYSTEM\$controlSetName\Services\WinSock2\Parameters\NameSpace_Catalog5\Catalog_Entries"

        if (Test-Path $namespacePath) {
            Write-Host "  [INFO] Checking namespace providers..." -ForegroundColor Cyan
            "  [INFO] Checking namespace providers at $namespacePath" | Out-File $LogFile -Append

            # Enumerate all catalog entries
            $entries = Get-ChildItem -Path $namespacePath -ErrorAction SilentlyContinue
            $found = $false

            foreach ($entry in $entries) {
                try {
                    $providerId = (Get-ItemProperty -Path $entry.PSPath -Name "ProviderId" -ErrorAction SilentlyContinue).ProviderId

                    if ($providerId -and ($providerId -replace '[{}]','') -eq $VMwareVsockGUID) {
                        Write-Host "  [FOUND] VMware vSockets namespace entry: $($entry.PSChildName)" -ForegroundColor Yellow
                        "  [FOUND] VMware vSockets in $($entry.PSPath)" | Out-File $LogFile -Append

                        # Delete the entire catalog entry
                        Remove-Item -Path $entry.PSPath -Recurse -Force -ErrorAction Stop

                        Write-Host "  [SUCCESS] Deleted namespace entry: $($entry.PSChildName)" -ForegroundColor Green
                        "  [SUCCESS] Deleted $($entry.PSPath)" | Out-File $LogFile -Append
                        $TotalDeleted++
                        $found = $true
                    }
                } catch {
                    Write-Host "  [ERROR] Failed to process entry $($entry.PSChildName): $($_.Exception.Message)" -ForegroundColor Red
                    "  [ERROR] Failed to process $($entry.PSPath): $($_.Exception.Message)" | Out-File $LogFile -Append
                }
            }

            if (-not $found) {
                Write-Host "  [OK] No VMware vSockets namespace entries found" -ForegroundColor Green
                "  [OK] No VMware vSockets found in namespace catalog" | Out-File $LogFile -Append
                $TotalNotFound++
            }
        } else {
            Write-Host "  [INFO] Namespace catalog not found (may not exist)" -ForegroundColor Gray
            "  [INFO] $namespacePath does not exist" | Out-File $LogFile -Append
            $TotalNotFound++
        }

        # Protocol providers path
        $protocolPath = "HKLM:\SYSTEM\$controlSetName\Services\WinSock2\Parameters\Protocol_Catalog9\Catalog_Entries"

        if (Test-Path $protocolPath) {
            Write-Host "  [INFO] Checking protocol providers..." -ForegroundColor Cyan
            "  [INFO] Checking protocol providers at $protocolPath" | Out-File $LogFile -Append

            # Enumerate all protocol entries
            $entries = Get-ChildItem -Path $protocolPath -ErrorAction SilentlyContinue
            $found = $false

            foreach ($entry in $entries) {
                try {
                    $providerId = (Get-ItemProperty -Path $entry.PSPath -Name "ProviderId" -ErrorAction SilentlyContinue).ProviderId

                    if ($providerId -and ($providerId -replace '[{}]','') -eq $VMwareVsockGUID) {
                        Write-Host "  [FOUND] VMware vSockets protocol entry: $($entry.PSChildName)" -ForegroundColor Yellow
                        "  [FOUND] VMware vSockets in $($entry.PSPath)" | Out-File $LogFile -Append

                        # Delete the entire catalog entry
                        Remove-Item -Path $entry.PSPath -Recurse -Force -ErrorAction Stop

                        Write-Host "  [SUCCESS] Deleted protocol entry: $($entry.PSChildName)" -ForegroundColor Green
                        "  [SUCCESS] Deleted $($entry.PSPath)" | Out-File $LogFile -Append
                        $TotalDeleted++
                        $found = $true
                    }
                } catch {
                    Write-Host "  [ERROR] Failed to process entry $($entry.PSChildName): $($_.Exception.Message)" -ForegroundColor Red
                    "  [ERROR] Failed to process $($entry.PSPath): $($_.Exception.Message)" | Out-File $LogFile -Append
                }
            }

            if (-not $found) {
                Write-Host "  [OK] No VMware vSockets protocol entries found" -ForegroundColor Green
                "  [OK] No VMware vSockets found in protocol catalog" | Out-File $LogFile -Append
            }
        } else {
            Write-Host "  [INFO] Protocol catalog not found (may not exist)" -ForegroundColor Gray
            "  [INFO] $protocolPath does not exist" | Out-File $LogFile -Append
        }

        Write-Host ""
    }

} catch {
    Write-Host "[ERROR] Failed to enumerate ControlSets: $($_.Exception.Message)" -ForegroundColor Red
    "[ERROR] Exception: $($_.Exception.Message)" | Out-File $LogFile -Append
    exit 1
}

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  Winsock Registry Cleanup Summary" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  ControlSets scanned:  $($ControlSets.Count)"
Write-Host "  Registry entries deleted: $TotalDeleted"
Write-Host "  ControlSets with no entries: $TotalNotFound"
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

"" | Out-File $LogFile -Append
"[SUMMARY] Scanned: $($ControlSets.Count), Deleted: $TotalDeleted, Not Found: $TotalNotFound" | Out-File $LogFile -Append
"[COMPLETE] Winsock registry cleanup finished at $(Get-Date)" | Out-File $LogFile -Append
"===============================================================" | Out-File $LogFile -Append

if ($TotalDeleted -gt 0) {
    Write-Host "[SUCCESS] Deleted VMware vSockets from $TotalDeleted registry location(s)" -ForegroundColor Green
} else {
    Write-Host "[OK] All Winsock registry entries were already clean" -ForegroundColor Green
}

Write-Host ""
Write-Host "Log file: $LogFile"
Write-Host ""

exit 0
