#requires -Version 3.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Discover and catalog all VMware binary files on the system.

.DESCRIPTION
    Generates a comprehensive list of VMware binaries for removal using 4 methods:
    - Method 1: Scan Program Files directories
    - Method 2: Scan System32/drivers for vm* files (excluding Hyper-V)
    - Method 3: Extract from Registry ImagePath values
    - Method 4: Query Windows Installer cache

.NOTES
    Must be run as Administrator
    Converted from discover_vmware_binaries.bat for better performance and maintainability
#>

$ErrorActionPreference = "Continue"

# ===============================================================
# Configuration
# ===============================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutputFile = Join-Path $ScriptDir "vmware_binaries.txt"
$LogFile = Join-Path $ScriptDir "discovery.log"

# VMware vendor identification patterns (whitelist approach - much safer than exclusions)
$VMwareCompanyPatterns = @(
    'VMware',
    'VMware, Inc.'
)

# ===============================================================
# Helper Functions
# ===============================================================

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $Message -ErrorAction SilentlyContinue
}

function Test-VMwareFile {
    <#
    .SYNOPSIS
        Positively identifies a file as belonging to VMware using cryptographic verification.

    .DESCRIPTION
        Uses a three-tier verification approach for maximum safety:

        1. PRIMARY: Direct VMware Authenticode signature (best case)
           - File signed directly by VMware certificate authority
           - Example: vmGuestLib.dll

        2. MICROSOFT WHQL: Valid signature + VMware metadata (common for drivers)
           - File signed by Microsoft Hardware Compatibility Publisher
           - BUT has CompanyName="VMware, Inc." in VersionInfo
           - This is NORMAL - Microsoft requires WHQL certification for drivers
           - Example: vmci.sys, vmmouse.sys (signed by Microsoft but made by VMware)

        3. FALLBACK: Expired/untrusted VMware signature + metadata
           - Old VMware Tools with expired certificates
           - Still has VMware certificate subject + CompanyName

        This ensures we ONLY delete files we are absolutely certain belong to VMware,
        while handling both direct VMware signatures AND Microsoft WHQL signatures.

    .PARAMETER FilePath
        Full path to the file to check

    .RETURNS
        $true if file is verified as VMware, $false otherwise
    #>
    param([string]$FilePath)

    try {
        $fileName = Split-Path -Leaf $FilePath

        # PRIMARY METHOD: Authenticode signature verification (cryptographic proof)
        $signature = Get-AuthenticodeSignature -FilePath $FilePath -ErrorAction SilentlyContinue

        if ($signature) {
            # Path 1: Valid signature directly from VMware (best case)
            # Note: O= field may have quotes: O="VMware, Inc." or O=VMware
            if ($signature.Status -eq "Valid" -and
                $signature.SignerCertificate.Subject -match 'O="?VMware') {
                Write-Log "[VERIFIED-SIGNATURE] $fileName - Signed by: VMware"
                return $true
            }

            # Path 2: Valid signature from Microsoft WHQL or other authority
            # Many VMware drivers are WHQL-certified and signed by Microsoft Hardware Compatibility Publisher
            # Example: vmci.sys, vmmouse.sys have valid Microsoft signatures but VMware metadata
            if ($signature.Status -eq "Valid" -and $signature.SignerCertificate -ne $null) {
                $versionInfo = (Get-Item $FilePath -ErrorAction Stop).VersionInfo
                $companyName = $versionInfo.CompanyName

                if ($companyName -match "VMware") {
                    # Extract signer organization for logging
                    $signerOrg = "Unknown"
                    if ($signature.SignerCertificate.Subject -match 'O=([^,]+)') {
                        $signerOrg = $matches[1]
                    }
                    Write-Log "[VERIFIED-METADATA] $fileName - CompanyName: $companyName (WHQL/signed by $signerOrg)"
                    return $true
                }
            }

            # Path 3: Invalid/expired signature but has VMware in certificate
            # Old VMware Tools with expired certificates
            # Note: O= field may have quotes: O="VMware, Inc." or O=VMware
            if ($signature.Status -ne "Valid" -and
                $signature.Status -ne "NotSigned" -and
                $signature.SignerCertificate.Subject -match 'O="?VMware') {

                $versionInfo = (Get-Item $FilePath -ErrorAction Stop).VersionInfo
                $companyName = $versionInfo.CompanyName

                if ($companyName -match "VMware") {
                    Write-Log "[VERIFIED-METADATA] $fileName - CompanyName: $companyName (signature: $($signature.Status))"
                    return $true
                }
            }
        }

        # If no valid signature and not VMware-signed, skip it
        Write-Log "[SKIPPED] $fileName - No valid VMware signature or metadata"
        return $false
    }
    catch {
        # If we can't verify, err on the side of caution - don't delete
        Write-Log "[WARNING] Could not verify: $FilePath - $($_.Exception.Message)"
        return $false
    }

    return $false
}

function Add-BinaryToOutput {
    param([string]$Path, [string]$Comment = "", [string]$Method = "")

    if ($Comment) {
        Add-Content -Path $OutputFile -Value "`n# $Comment"
    }

    # Deduplication: check if path already discovered
    $normalizedPath = $Path.ToLowerInvariant()
    if ($script:DiscoveredPaths.ContainsKey($normalizedPath)) {
        Write-Log "[DUPLICATE] $Path - Already found by $($script:DiscoveredPaths[$normalizedPath])"
        return $false
    }

    Add-Content -Path $OutputFile -Value $Path
    $script:DiscoveredPaths[$normalizedPath] = $Method
    return $true
}

# ===============================================================
# Initialize
# ===============================================================

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  VMware Binary Discovery Tool" -ForegroundColor Cyan
Write-Host "  Run as Administrator" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[INFO] Output will be saved to: $OutputFile" -ForegroundColor White
Write-Host "[INFO] Log file: $LogFile" -ForegroundColor White
Write-Host ""

# Initialize log file
"===============================================================" | Out-File $LogFile
"  VMware Binary Discovery Log - $(Get-Date)" | Out-File $LogFile -Append
"===============================================================" | Out-File $LogFile -Append

# Initialize output file
@"
# VMware Binaries Discovered on $(Get-Date)
# This file contains full paths to VMware binary files
# ==============================================================

"@ | Out-File $OutputFile

$TotalCount = 0
$DiscoveredPaths = @{}  # Hash table for deduplication

# ===============================================================
# Method 1: Scan Program Files and ProgramData directories
# ===============================================================
# Note: ProgramData contains config files (.adm, .admx, .txt, .conf, .log)
#       that don't have Authenticode signatures, so we scan ALL files here.
# ===============================================================

Write-Host "==========================================" -ForegroundColor Yellow
Write-Host " Method 1: Scanning Program Files & ProgramData" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Log "[METHOD 1] Scanning Program Files and ProgramData directories"

$Method1Count = 0

$PathsToScan = @(
    "$env:ProgramFiles\VMware",
    "${env:ProgramFiles(x86)}\VMware",
    "$env:ProgramFiles\Common Files\VMware",
    "${env:ProgramFiles(x86)}\Common Files\VMware",
    "$env:ProgramData\VMware"
)

foreach ($path in $PathsToScan) {
    if (Test-Path $path) {
        Write-Host "[INFO] Found: $path" -ForegroundColor Green
        Write-Log "[FOUND] $path"

        Add-BinaryToOutput -Comment "From $path" -Method "Method1"

        # Get ALL files (not just .exe/.dll/.sys)
        # ProgramData contains config files that need to be removed too
        $files = Get-ChildItem -Path $path -Recurse -File -ErrorAction SilentlyContinue

        foreach ($file in $files) {
            if (Add-BinaryToOutput -Path $file.FullName -Method "Method1") {
                $Method1Count++
                $TotalCount++
            }
        }
    } else {
        Write-Host "[INFO] Not found: $path" -ForegroundColor Gray
        Write-Log "[NOT FOUND] $path"
    }
}

Write-Host "[INFO] Method 1 found $Method1Count files" -ForegroundColor Cyan
Write-Log "[METHOD 1] Found $Method1Count files"
Write-Host ""

# ===============================================================
# Method 2: Scan System32 for vm* files (Authenticode verification)
# ===============================================================
# Uses cryptographic signature verification to positively identify VMware files.
# Primary: Checks Authenticode digital signature (signed by VMware CA)
# Fallback: Checks CompanyName metadata (for expired certificates)
# ===============================================================

Write-Host "==========================================" -ForegroundColor Yellow
Write-Host " Method 2: Scanning System32 (Authenticode)" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Log "[METHOD 2] Scanning System32 for vm* files with signature verification"

$Method2Count = 0

# System32 - using WHITELIST approach (CompanyName verification)
Add-BinaryToOutput -Comment "From $env:SystemRoot\System32\vm* (verified VMware via metadata)" -Method "Method2"
$files = Get-ChildItem "$env:SystemRoot\System32\vm*.*" -File -ErrorAction SilentlyContinue
foreach ($file in $files) {
    if (Test-VMwareFile -FilePath $file.FullName) {
        if (Add-BinaryToOutput -Path $file.FullName -Method "Method2") {
            Write-Log "[VERIFIED] $($file.Name) - CompanyName: $($file.VersionInfo.CompanyName)"
            $Method2Count++
            $TotalCount++
        }
    }
}

# System32\drivers - using WHITELIST approach (CompanyName verification)
# Scan for both vm* and vsock* patterns (vsock.sys is VMware vSockets driver)
Add-BinaryToOutput -Comment "From $env:SystemRoot\System32\drivers\vm* (verified VMware via metadata)" -Method "Method2"
$files = Get-ChildItem "$env:SystemRoot\System32\drivers\vm*.*" -File -ErrorAction SilentlyContinue
foreach ($file in $files) {
    if (Test-VMwareFile -FilePath $file.FullName) {
        if (Add-BinaryToOutput -Path $file.FullName -Method "Method2") {
            Write-Log "[VERIFIED] $($file.Name) - CompanyName: $($file.VersionInfo.CompanyName)"
            $Method2Count++
            $TotalCount++
        }
    }
}

Add-BinaryToOutput -Comment "From $env:SystemRoot\System32\drivers\vsock* (VMware vSockets driver)" -Method "Method2"
$files = Get-ChildItem "$env:SystemRoot\System32\drivers\vsock*.*" -File -ErrorAction SilentlyContinue
foreach ($file in $files) {
    if (Test-VMwareFile -FilePath $file.FullName) {
        if (Add-BinaryToOutput -Path $file.FullName -Method "Method2") {
            Write-Log "[VERIFIED] $($file.Name) - CompanyName: $($file.VersionInfo.CompanyName)"
            $Method2Count++
            $TotalCount++
        }
    }
}

# Scan System32 for vsock* files (VMware vSockets DLLs - vsocklib.dll)
Add-BinaryToOutput -Comment "From $env:SystemRoot\System32\vsock* (VMware vSockets library)" -Method "Method2"
$files = Get-ChildItem "$env:SystemRoot\System32\vsock*.*" -File -ErrorAction SilentlyContinue
foreach ($file in $files) {
    if (Test-VMwareFile -FilePath $file.FullName) {
        if (Add-BinaryToOutput -Path $file.FullName -Method "Method2") {
            Write-Log "[VERIFIED] $($file.Name) - CompanyName: $($file.VersionInfo.CompanyName)"
            $Method2Count++
            $TotalCount++
        }
    }
}

# SysWOW64 (on 64-bit systems) - using WHITELIST approach
if (Test-Path "$env:SystemRoot\SysWOW64") {
    Add-BinaryToOutput -Comment "From $env:SystemRoot\SysWOW64\vm* (verified VMware via metadata)" -Method "Method2"
    $files = Get-ChildItem "$env:SystemRoot\SysWOW64\vm*.*" -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        if (Test-VMwareFile -FilePath $file.FullName) {
            if (Add-BinaryToOutput -Path $file.FullName -Method "Method2") {
                Write-Log "[VERIFIED] $($file.Name) - CompanyName: $($file.VersionInfo.CompanyName)"
                $Method2Count++
                $TotalCount++
            }
        }
    }

    # Scan SysWOW64 for vsock* files (VMware vSockets DLLs - 32-bit vsocklib.dll)
    Add-BinaryToOutput -Comment "From $env:SystemRoot\SysWOW64\vsock* (VMware vSockets library - 32-bit)" -Method "Method2"
    $files = Get-ChildItem "$env:SystemRoot\SysWOW64\vsock*.*" -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        if (Test-VMwareFile -FilePath $file.FullName) {
            if (Add-BinaryToOutput -Path $file.FullName -Method "Method2") {
                Write-Log "[VERIFIED] $($file.Name) - CompanyName: $($file.VersionInfo.CompanyName)"
                $Method2Count++
                $TotalCount++
            }
        }
    }
}

Write-Host "[INFO] Method 2 found $Method2Count files" -ForegroundColor Cyan
Write-Log "[METHOD 2] Found $Method2Count files"
Write-Host ""

# ===============================================================
# Method 3: Extract from Registry ImagePath values
# ===============================================================

Write-Host "==========================================" -ForegroundColor Yellow
Write-Host " Method 3: Extracting from Registry" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Log "[METHOD 3] Extracting ImagePath from registry"

$Method3Count = 0

Add-BinaryToOutput -Comment "From Registry ImagePath entries" -Method "Method3"

# Query all services for ImagePath containing VMware or vm*
try {
    $services = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services" -Recurse -ErrorAction SilentlyContinue |
        Get-ItemProperty -Name ImagePath -ErrorAction SilentlyContinue |
        Where-Object { $_.ImagePath -match 'vmware|vm3d|vm\d' }

    foreach ($service in $services) {
        $imagePath = $service.ImagePath

        # Strip quotes and expand environment variables
        $imagePath = $imagePath -replace '"', ''
        $imagePath = $imagePath -replace '\\SystemRoot\\', "$env:SystemRoot\"
        $imagePath = $imagePath -replace '\\\?\?\\', ''
        $imagePath = $imagePath -replace 'system32', 'System32'

        # Extract the executable path, ignoring any trailing arguments
        # Example: "C:\Program Files\VMware\VMware Tools\vmtoolsd.exe -n vmusr" -> "C:\...\vmtoolsd.exe"
        if ($imagePath -match '([A-Za-z]:\\.*?\.(?:exe|sys|dll))') {
            $cleanPath = $matches[1]

            # Only add if the file actually exists
            if (Test-Path $cleanPath) {
                if (Add-BinaryToOutput -Path $cleanPath -Method "Method3") {
                    Write-Log "[FOUND] $cleanPath"
                    $Method3Count++
                    $TotalCount++
                }
            }
        }
    }
} catch {
    Write-Log "[WARNING] Registry query error: $($_.Exception.Message)"
}

# NOTE: VMware Tools InstallPath scanning removed - Method 1 already scans
# C:\Program Files\VMware which covers the InstallPath location. Including
# it here was redundant and wasted CPU cycles despite deduplication logic.

Write-Host "[INFO] Method 3 found $Method3Count files" -ForegroundColor Cyan
Write-Log "[METHOD 3] Found $Method3Count files"
Write-Host ""

# ===============================================================
# Method 4: Check Windows Installer cache for VMware MSI
# ===============================================================

Write-Host "==========================================" -ForegroundColor Yellow
Write-Host " Method 4: Windows Installer Check" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Log "[METHOD 4] Checking for VMware products in Windows Installer"

$Method4Count = 0
$vmwareProductsInstalled = @()

try {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $products = $installer.Products

    foreach ($product in $products) {
        try {
            $productName = $installer.ProductInfo($product, "InstalledProductName")
            if ($productName -match "VMware") {
                $version = $installer.ProductInfo($product, "VersionString")
                $vmwareProductsInstalled += "$productName (Version: $version)"

                Write-Host "[WARNING] VMware product still installed: $productName" -ForegroundColor Yellow
                Write-Log "[WARNING] MSI product found: $productName (Version: $version, GUID: $product)"
                $Method4Count++
            }
        } catch {
            # Skip products we can't query
            continue
        }
    }
} catch {
    Write-Log "[WARNING] Windows Installer COM query failed: $($_.Exception.Message)"
}

if ($Method4Count -gt 0) {
    Write-Host ""
    Write-Host "[WARNING] Found $Method4Count VMware product(s) still registered in Windows Installer" -ForegroundColor Yellow
    Write-Host "[ACTION REQUIRED] Run uninstall_vmware_msi.ps1 FIRST to properly uninstall via Windows Installer" -ForegroundColor Cyan
    Write-Log "[WARNING] VMware products still installed - uninstall_vmware_msi.ps1 should be run first"
} else {
    Write-Host "[OK] No VMware products found in Windows Installer" -ForegroundColor Green
    Write-Log "[OK] No VMware MSI products registered"
}
Write-Host ""

# ===============================================================
# NOTE: DriverStore Cleanup
# ===============================================================
# DriverStore files are NOT scanned here because manually deleting them can
# corrupt the Windows Driver Store database. The proper removal method is:
#   1. Use pnputil /delete-driver oem*.inf /uninstall /force (already done)
#   2. If DriverStore directories persist, it means Windows is protecting them
#   3. Manual deletion risks driver database corruption in C:\Windows\INF
#
# If DriverStore directories remain after pnputil, they should be left alone
# or removed only by Windows Driver Store tools, never by file deletion.
# ===============================================================

# ===============================================================
# Summary
# ===============================================================

$summary = @"

# ==============================================================
# Discovery Summary
#   Method 1 (Program Files): $Method1Count files
#   Method 2 (System32): $Method2Count files
#   Method 3 (Registry): $Method3Count files
#   Method 4 (Installer Cache): $Method4Count packages
#   Total discovered: $TotalCount items
# ==============================================================
"@

Add-Content -Path $OutputFile -Value $summary

Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host " Discovery Complete" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor White
Write-Host "  Method 1 (Program Files):   $Method1Count files" -ForegroundColor White
Write-Host "  Method 2 (System32):        $Method2Count files" -ForegroundColor White
Write-Host "  Method 3 (Registry):        $Method3Count entries" -ForegroundColor White
Write-Host "  Method 4 (Installer Cache): $Method4Count packages" -ForegroundColor White
Write-Host "  -----------------------------------------" -ForegroundColor White
Write-Host "  Total discovered:           $TotalCount items" -ForegroundColor Green
Write-Host ""
Write-Host "Results saved to: $OutputFile" -ForegroundColor Cyan
Write-Host "Log file: $LogFile" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "[SUMMARY] Total discovered: $TotalCount items"
Write-Log "[SUMMARY] Method 1: $Method1Count, Method 2: $Method2Count, Method 3: $Method3Count, Method 4: $Method4Count"

exit 0
