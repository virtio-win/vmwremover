# Remove Ghost VMware Devices from Device Manager
# Removes hidden/disconnected VMware devices that persist after driver removal
# Run as Administrator after completing driver package removal

$ErrorActionPreference = "Continue"
$LogFile = ".\ghost_device_removal.log"

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  VMware Ghost Device Removal" -ForegroundColor Cyan
Write-Host "  Removing hidden devices from Device Manager" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

"[START] Ghost device removal - $(Get-Date)" | Out-File $LogFile

$TotalDevices = 0
$RemovedDevices = 0
$FailedDevices = 0

# Get all PnP devices (including hidden/disconnected)
Write-Host "[INFO] Scanning for VMware devices in all states..."
"[INFO] Scanning for VMware devices" | Out-File $LogFile -Append

try {
    # Get hidden VMware devices with problematic status (Unknown or Error)
    $GhostDevices = Get-PnpDevice -Status Unknown,Error -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FriendlyName -like '*VMware*' -or
            $_.FriendlyName -like '*vmxnet*' -or
            $_.FriendlyName -like '*pvscsi*' -or
            $_.InstanceId -like '*VEN_15AD*'  # VMware vendor ID
        }

    # Also check for network adapters that are not present (hidden/ghost devices)
    $AllNetDevices = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue
    $HiddenNet = $AllNetDevices | Where-Object {
        ($_.FriendlyName -like '*VMware*' -or $_.FriendlyName -like '*vmxnet*') -and
        ($_.Status -eq 'Unknown' -or $_.Status -eq 'Error')
    }

    # Combine and deduplicate
    $AllGhostDevices = @($GhostDevices) + @($HiddenNet) |
        Sort-Object InstanceId -Unique

    $TotalDevices = $AllGhostDevices.Count

    if ($TotalDevices -eq 0) {
        Write-Host "[INFO] No VMware ghost devices found. System is clean." -ForegroundColor Green
        "[INFO] No ghost devices found" | Out-File $LogFile -Append
    } else {
        Write-Host "[FOUND] $TotalDevices VMware ghost device(s) to remove" -ForegroundColor Yellow
        Write-Host ""
        "[FOUND] $TotalDevices ghost devices" | Out-File $LogFile -Append

        foreach ($device in $AllGhostDevices) {
            $deviceName = $device.FriendlyName
            $deviceStatus = $device.Status
            $deviceClass = $device.Class

            Write-Host "[PROCESSING] $deviceName" -ForegroundColor Cyan
            Write-Host "    Status: $deviceStatus, Class: $deviceClass"
            "    Device: $deviceName ($deviceClass, $deviceStatus)" | Out-File $LogFile -Append

            try {
                $removed = $false

                # Method 1: Try PowerShell cmdlet (Windows 10 2004+/Server 2022)
                if (Get-Command Remove-PnpDevice -ErrorAction SilentlyContinue) {
                    $device | Remove-PnpDevice -Confirm:$false -ErrorAction Stop
                    Write-Host "[SUCCESS] Removed via Remove-PnpDevice: $deviceName" -ForegroundColor Green
                    "[SUCCESS] Removed via cmdlet: $deviceName" | Out-File $LogFile -Append
                    $RemovedDevices++
                    $removed = $true
                }
                # Method 2: Try pnputil.exe (Windows 10 2004+/Server 2025+)
                elseif (Test-Path "$env:SystemRoot\System32\pnputil.exe") {
                    $instanceId = $device.InstanceId
                    Write-Host "[INFO] Attempting removal via pnputil.exe..." -ForegroundColor Cyan

                    # Run pnputil /remove-device with instance ID
                    $pnpResult = & pnputil.exe /remove-device "$instanceId" 2>&1

                    # Check if removal succeeded (pnputil returns success message)
                    if ($LASTEXITCODE -eq 0 -or $pnpResult -match "success|removed") {
                        Write-Host "[SUCCESS] Removed via pnputil: $deviceName" -ForegroundColor Green
                        "[SUCCESS] Removed via pnputil: $deviceName" | Out-File $LogFile -Append
                        $RemovedDevices++
                        $removed = $true
                    } else {
                        Write-Host "[WARNING] pnputil failed: $deviceName" -ForegroundColor Yellow
                        Write-Host "    Output: $pnpResult" -ForegroundColor Gray
                        "[WARNING] pnputil failed: $deviceName - $pnpResult" | Out-File $LogFile -Append
                    }
                }

                # Method 3: No removal method available (Server 2016/2019, Win10 < 2004)
                if (-not $removed) {
                    Write-Host "[INFO] $deviceName (Status: $deviceStatus)" -ForegroundColor Yellow
                    Write-Host "    Automatic removal not supported on this Windows version" -ForegroundColor Yellow
                    Write-Host "    This ghost device is harmless - it's disconnected and won't interfere" -ForegroundColor Gray
                    "[INFO] $deviceName - Listed but not removed (no removal method available)" | Out-File $LogFile -Append
                    $FailedDevices++
                }
            } catch {
                Write-Host "[FAILED] Could not remove: $deviceName" -ForegroundColor Red
                Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
                "[FAILED] $deviceName - $($_.Exception.Message)" | Out-File $LogFile -Append
                $FailedDevices++
            }
            Write-Host ""
        }
    }

} catch {
    Write-Host "[ERROR] Failed to enumerate devices: $($_.Exception.Message)" -ForegroundColor Red
    "[ERROR] Enumeration failed: $($_.Exception.Message)" | Out-File $LogFile -Append
}

# Summary
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  Ghost Device Removal Complete" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor White
Write-Host "  Total ghost devices found:  $TotalDevices" -ForegroundColor White
Write-Host "  Successfully removed:       $RemovedDevices" -ForegroundColor Green
Write-Host "  Failed to remove:           $FailedDevices" -ForegroundColor $(if ($FailedDevices -gt 0) { "Red" } else { "White" })
Write-Host ""
Write-Host "Log file: $LogFile" -ForegroundColor White
Write-Host ""

"[SUMMARY] Total: $TotalDevices, Removed: $RemovedDevices, Failed: $FailedDevices" | Out-File $LogFile -Append
"[END] Ghost device removal - $(Get-Date)" | Out-File $LogFile -Append

# Note about network adapter implications
if ($RemovedDevices -gt 0) {
    Write-Host "NOTE: If network adapters were removed, static IP configurations" -ForegroundColor Yellow
    Write-Host "      or persistent routes may need to be reconfigured." -ForegroundColor Yellow
    Write-Host ""
}

# Windows version note
if ($FailedDevices -gt 0 -and $RemovedDevices -eq 0) {
    Write-Host "INFO: Ghost device removal requires Windows 10 2004+ or Server 2022+" -ForegroundColor Cyan
    Write-Host "      This Windows version lacks both Remove-PnpDevice cmdlet and pnputil support." -ForegroundColor Cyan
    Write-Host "      Ghost devices are harmless and can be safely ignored." -ForegroundColor Cyan
    Write-Host "      They are disconnected and won't cause network or hardware issues." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "      Optional: Manually remove via Device Manager:" -ForegroundColor Gray
    Write-Host "        1. Run: devmgmt.msc" -ForegroundColor Gray
    Write-Host "        2. View > Show hidden devices" -ForegroundColor Gray
    Write-Host "        3. Right-click disconnected VMware devices > Uninstall" -ForegroundColor Gray
    Write-Host ""
} elseif ($RemovedDevices -gt 0) {
    Write-Host "SUCCESS: Automatic ghost device removal completed." -ForegroundColor Green
    Write-Host "         Removal method: " -NoNewline -ForegroundColor Cyan
    if (Get-Command Remove-PnpDevice -ErrorAction SilentlyContinue) {
        Write-Host "Remove-PnpDevice PowerShell cmdlet" -ForegroundColor Green
    } else {
        Write-Host "pnputil.exe command-line tool" -ForegroundColor Green
    }
    Write-Host ""
}
