#requires -Version 3.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Uninstall VMware products via Windows Installer (proper uninstall).

.DESCRIPTION
    Uses the Windows Installer COM API to find and uninstall VMware products
    (VMware Tools, etc.) via their Product GUIDs. This is the PROPER way to
    remove VMware software - it triggers the official uninstaller which removes
    files, services, drivers, and registry entries cleanly.

    This script should run FIRST in the cleanup workflow, before any manual
    file/service/driver removal. The other cleanup scripts handle remnants that
    survive the official uninstall.

.NOTES
    Must be run as Administrator
    Should be run FIRST in the VMware cleanup workflow
#>

$ErrorActionPreference = "Continue"

# ===============================================================
# Configuration
# ===============================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $ScriptDir "msi_uninstall.log"

# ===============================================================
# Helper Functions
# ===============================================================

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $Message -ErrorAction SilentlyContinue
}

# ===============================================================
# Initialize
# ===============================================================

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  VMware MSI Uninstaller" -ForegroundColor Cyan
Write-Host "  Proper Windows Installer-based removal" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

# Initialize log file
"===============================================================" | Out-File $LogFile
"  VMware MSI Uninstall Log - $(Get-Date)" | Out-File $LogFile -Append
"===============================================================" | Out-File $LogFile -Append

# Initialize counters
$ProductsFound = 0
$ProductsUninstalled = 0
$ProductsSkipped = 0
$ProductsFailed = 0

# ===============================================================
# Find VMware Products via Windows Installer
# ===============================================================

Write-Host "==========================================" -ForegroundColor Yellow
Write-Host " Scanning for VMware products" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "[INFO] Querying Windows Installer database..." -ForegroundColor White
Write-Log "[INFO] Querying Windows Installer for VMware products"

$vmwareProducts = @()

try {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $products = $installer.Products

    foreach ($productCode in $products) {
        try {
            $productName = $installer.ProductInfo($productCode, "InstalledProductName")

            if ($productName -match "VMware") {
                $version = $installer.ProductInfo($productCode, "VersionString")
                $publisher = $installer.ProductInfo($productCode, "Publisher")

                $vmwareProducts += [PSCustomObject]@{
                    Name = $productName
                    ProductCode = $productCode
                    Version = $version
                    Publisher = $publisher
                }

                Write-Host "[FOUND] $productName" -ForegroundColor Green
                Write-Host "        Version: $version" -ForegroundColor Gray
                Write-Host "        GUID: $productCode" -ForegroundColor Gray
                Write-Log "[FOUND] $productName (Version: $version, GUID: $productCode)"

                $ProductsFound++
            }
        } catch {
            # Skip products we can't query
            continue
        }
    }
} catch {
    Write-Log "[ERROR] Windows Installer COM query failed: $($_.Exception.Message)"
    Write-Host "[ERROR] Failed to query Windows Installer: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Exiting - cannot proceed without installer access" -ForegroundColor Red
    exit 1
}

Write-Host ""

if ($ProductsFound -eq 0) {
    Write-Host "[OK] No VMware products found in Windows Installer" -ForegroundColor Green
    Write-Log "[OK] No VMware products found - nothing to uninstall"
    Write-Host ""
    Write-Host "No VMware products installed via MSI. Cleanup scripts can proceed." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

Write-Host "[INFO] Found $ProductsFound VMware product(s) to uninstall" -ForegroundColor Cyan
Write-Host ""

# ===============================================================
# Uninstall VMware Products
# ===============================================================

Write-Host "==========================================" -ForegroundColor Yellow
Write-Host " Uninstalling VMware products" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""

foreach ($product in $vmwareProducts) {
    Write-Host "[PROCESSING] $($product.Name)" -ForegroundColor Cyan
    Write-Log "[UNINSTALL] Attempting to uninstall: $($product.Name)"

    try {
        # Use msiexec for silent uninstall
        # /x = uninstall
        # /qn = quiet, no UI
        # /norestart = don't restart automatically
        $arguments = "/x `"$($product.ProductCode)`" /qn /norestart"

        Write-Host "        Executing: msiexec.exe $arguments" -ForegroundColor Gray
        Write-Log "[EXEC] msiexec.exe $arguments"

        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow

        if ($process.ExitCode -eq 0) {
            Write-Host "[SUCCESS] Uninstalled: $($product.Name)" -ForegroundColor Green
            Write-Log "[SUCCESS] Uninstalled: $($product.Name) (Exit code: 0)"
            $ProductsUninstalled++
        } elseif ($process.ExitCode -eq 1605) {
            # 1605 = ERROR_UNKNOWN_PRODUCT (already uninstalled or product not found)
            Write-Host "[SKIPPED] Product already uninstalled: $($product.Name)" -ForegroundColor Gray
            Write-Log "[SKIPPED] Product not found (Exit code: 1605) - likely already uninstalled"
            $ProductsSkipped++
        } elseif ($process.ExitCode -eq 3010) {
            # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED
            Write-Host "[SUCCESS] Uninstalled: $($product.Name) (reboot required)" -ForegroundColor Yellow
            Write-Log "[SUCCESS] Uninstalled: $($product.Name) (Exit code: 3010 - reboot required)"
            $ProductsUninstalled++
        } else {
            Write-Host "[FAILED] Uninstall failed with exit code: $($process.ExitCode)" -ForegroundColor Red
            Write-Log "[FAILED] Uninstall failed: $($product.Name) (Exit code: $($process.ExitCode))"
            $ProductsFailed++
        }
    } catch {
        Write-Host "[ERROR] Exception during uninstall: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "[ERROR] Exception: $($_.Exception.Message)"
        $ProductsFailed++
    }

    Write-Host ""
}

# ===============================================================
# Summary
# ===============================================================

Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host " Uninstall Complete" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor White
Write-Host "  Products found:        $ProductsFound" -ForegroundColor White
Write-Host "  Successfully uninstalled: $ProductsUninstalled" -ForegroundColor Green
Write-Host "  Already uninstalled:   $ProductsSkipped" -ForegroundColor Gray
Write-Host "  Failed:                $ProductsFailed" -ForegroundColor Red
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "[SUMMARY] Found: $ProductsFound, Uninstalled: $ProductsUninstalled, Skipped: $ProductsSkipped, Failed: $ProductsFailed"

if ($ProductsUninstalled -gt 0) {
    Write-Host "VMware products have been uninstalled via Windows Installer." -ForegroundColor Green
    Write-Host "The cleanup scripts will now remove any remaining files/services/drivers." -ForegroundColor Cyan
} elseif ($ProductsSkipped -gt 0) {
    Write-Host "VMware products were already uninstalled." -ForegroundColor Cyan
    Write-Host "The cleanup scripts will remove leftover remnants." -ForegroundColor Cyan
}

if ($ProductsFailed -gt 0) {
    Write-Host ""
    Write-Host "WARNING: $ProductsFailed product(s) failed to uninstall" -ForegroundColor Yellow
    Write-Host "The cleanup scripts will still attempt to remove remnants." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Log file: $LogFile" -ForegroundColor Cyan
Write-Host ""

exit 0
