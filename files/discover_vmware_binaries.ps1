<#
.SYNOPSIS
    Discover VMware binaries and write a removal manifest.

.DESCRIPTION
    Optional PowerShell augmentation for the VMware leftover binaries
    cleanup. Discovery only - this script deletes nothing. It finds
    candidate files under the known VMware locations, confirms each is
    really VMware's via an Authenticode-signature check (Test-VMwareFile),
    and writes the confirmed paths to a manifest (vmware_binaries.txt)
    that remove_vmware_binaries.bat then deletes from.

    The signature gate is why this is worth doing in PowerShell: batch
    cannot verify Authenticode, so it can only match on path/name. Here
    we avoid deleting a same-named non-VMware file.

    DriverStore\FileRepository is intentionally NOT searched - driver
    packages must be removed with "pnputil /delete-driver" (handled by
    drivers\remove_vmware_driver_packages.bat), never by deleting the
    FileRepository directly, which risks driver-database corruption.
#>

$ErrorActionPreference = 'Continue'
$manifest = Join-Path $PSScriptRoot 'vmware_binaries.txt'

function Test-VMwareFile {
    <#
        Returns $true if the file is confirmed to be VMware's. Three tiers,
        ORed together (a file need satisfy only ONE tier); each tier ANDs
        its own conditions. Unsigned files are never accepted.
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $sig) { return $false }

    $company = ''
    try { $company = (Get-Item -LiteralPath $Path).VersionInfo.CompanyName } catch { }

    # Tier 1: valid signature AND signer org is VMware
    if ($sig.Status -eq 'Valid' -and
        $sig.SignerCertificate -and
        $sig.SignerCertificate.Subject -match 'O="?VMware') {
        return $true
    }

    # Tier 2: valid signature (e.g. WHQL/Microsoft) AND VMware version metadata
    if ($sig.Status -eq 'Valid' -and
        $sig.SignerCertificate -and
        $company -match 'VMware') {
        return $true
    }

    # Tier 3: signature not Valid but present (e.g. expired VMware cert),
    #         signer org is VMware AND VMware version metadata
    if ($sig.Status -ne 'Valid' -and
        $sig.Status -ne 'NotSigned' -and
        $sig.SignerCertificate -and
        $sig.SignerCertificate.Subject -match 'O="?VMware' -and
        $company -match 'VMware') {
        return $true
    }

    return $false
}

$found = New-Object System.Collections.Generic.List[string]

function Add-Candidate {
    param([string]$Path, [string]$Method)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $full = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path
    if (-not $full) { $full = $Path }
    if ($found -contains $full) { return }
    if (Test-VMwareFile $full) {
        $found.Add($full)
        Write-Output "[FOUND:$Method] $full"
    } else {
        Write-Output "[SKIP:not-vmware] $full"
    }
}

Write-Output "=== Discover VMware binaries ==="

# ---- Method 1: known VMware directories ----
$dirs = @(
    "$env:ProgramFiles\VMware",
    "${env:ProgramFiles(x86)}\VMware",
    "$env:ProgramFiles\Common Files\VMware",
    "${env:ProgramFiles(x86)}\Common Files\VMware",
    "$env:ProgramData\VMware"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

foreach ($d in $dirs) {
    Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { Add-Candidate -Path $_.FullName -Method 'Dir' }
}

# ---- Method 2: vm* / vsock* files under system directories ----
$globs = @(
    "$env:SystemRoot\System32\vm*.*",
    "$env:SystemRoot\System32\vsock*.*",
    "$env:SystemRoot\System32\drivers\vm*.*",
    "$env:SystemRoot\System32\drivers\vsock*.*",
    "$env:SystemRoot\SysWOW64\vm*.*",
    "$env:SystemRoot\SysWOW64\vsock*.*"
)
foreach ($g in $globs) {
    Get-ChildItem -Path $g -File -ErrorAction SilentlyContinue |
        ForEach-Object { Add-Candidate -Path $_.FullName -Method 'Glob' }
}

# ---- Method 3: service ImagePath discovery (signature-gated) ----
# Some VMware service binaries live outside the paths above. Read each
# service's ImagePath, normalise it to a real filesystem path, and only
# accept it if Test-VMwareFile confirms it, so a non-VMware binary that
# merely matches the name pattern is never flagged for deletion.
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue |
    ForEach-Object {
        $ip = (Get-ItemProperty -Path $_.PSPath -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
        if (-not $ip) { return }
        if ($ip -notmatch 'vmware|vm3d|vm\d') { return }

        $clean = $ip.Trim('"')
        $clean = $clean -replace '^\\SystemRoot\\', "$env:SystemRoot\"
        $clean = $clean -replace '^\\\?\?\\', ''
        $clean = $clean -replace '(?i)\\systemroot\\', "$env:SystemRoot\"
        if ($clean -match '(?i)([A-Za-z]:\\.*?\.(exe|sys|dll))') {
            $clean = $Matches[1]
        }
        Add-Candidate -Path $clean -Method 'Service'
    }

# ---- Write the manifest ----
$header = @(
    '# VMware binaries manifest - generated by discover_vmware_binaries.ps1',
    '# Consumed by remove_vmware_binaries.bat. One path per line.',
    '# Lines beginning with # and blank lines are ignored.'
)
$header + $found | Set-Content -LiteralPath $manifest -Encoding ASCII

Write-Output "=== Discovery finished. Confirmed VMware files: $($found.Count) ==="
Write-Output "Manifest: $manifest"
exit 0
