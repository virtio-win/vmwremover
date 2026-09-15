<#
.SYNOPSIS
    Remove the VMware vSockets Winsock2 catalog entries across ALL
    ControlSets (raw-registry scrub).

.DESCRIPTION
    Optional PowerShell augmentation for the VMware leftover cleanup.
    The batch baseline (reg\remove_vmware_winsock.bat) deregisters the
    VMware vSockets provider from the LIVE catalog via netsh, but that
    only touches the current control set. Windows stores the Winsock2
    catalog under each control set:

        HKLM\SYSTEM\<ControlSetNNN>\Services\WinSock2\Parameters\
            Protocol_Catalog9\Catalog_Entries\*
            NameSpace_Catalog5\Catalog_Entries\*

    Each entry stores a binary PackedCatalogItem blob that embeds the
    provider GUID. Matching a GUID inside a REG_BINARY value is not
    practical in batch, so it is done here: we search the blob for the
    16-byte (mixed-endian) form of the VMware vSockets provider GUID
    and delete matching entries in every control set.

    Best-effort: never throws to the caller. Exit 3010 if anything was
    deleted (reboot recommended); 0 otherwise.

    NOTE: this edits raw catalog entries but does NOT renumber the
    remaining ones. Pair it with a "netsh winsock reset" (done by the
    batch baseline) so the catalog is reindexed on the live system.
#>

$ErrorActionPreference = 'Continue'
$deleted = 0

# VMware vSockets provider GUID, as the mixed-endian byte sequence used
# in the packed catalog blob (Data1/2/3 little-endian, Data4 big-endian -
# exactly what [Guid]::ToByteArray() produces).
$vsockGuid  = [Guid]'570ADC4B-67B2-42CE-92B2-ACD33D88D842'
$guidBytes  = $vsockGuid.ToByteArray()

function Test-BytesContain {
    param([byte[]]$Haystack, [byte[]]$Needle)
    if ($null -eq $Haystack -or $Haystack.Length -lt $Needle.Length) { return $false }
    $last = $Haystack.Length - $Needle.Length
    for ($i = 0; $i -le $last; $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) { $match = $false; break }
        }
        if ($match) { return $true }
    }
    return $false
}

Write-Output "=== Remove VMware Winsock catalog entries (all ControlSets) ==="

$controlSets = Get-ChildItem -Path 'HKLM:\SYSTEM' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^ControlSet\d{3}$' }

$catalogs = @('Protocol_Catalog9', 'NameSpace_Catalog5')

foreach ($cs in $controlSets) {
    foreach ($cat in $catalogs) {
        $entriesPath = "HKLM:\SYSTEM\$($cs.PSChildName)\Services\WinSock2\Parameters\$cat\Catalog_Entries"
        if (-not (Test-Path $entriesPath)) { continue }

        Get-ChildItem -Path $entriesPath -ErrorAction SilentlyContinue | ForEach-Object {
            $entryKey = $_
            $props = Get-ItemProperty -Path $entryKey.PSPath -ErrorAction SilentlyContinue
            $isVMware = $false

            # PackedCatalogItem holds the provider path + GUID blob
            if ($props -and $props.PackedCatalogItem -is [byte[]]) {
                if (Test-BytesContain -Haystack $props.PackedCatalogItem -Needle $guidBytes) {
                    $isVMware = $true
                }
            }
            # Some namespace entries expose the GUID as a string value
            if (-not $isVMware) {
                foreach ($v in $props.PSObject.Properties) {
                    if ($v.Value -is [string] -and $v.Value -match '570ADC4B-67B2-42CE-92B2-ACD33D88D842') {
                        $isVMware = $true; break
                    }
                }
            }

            if ($isVMware) {
                try {
                    Remove-Item -Path $entryKey.PSPath -Recurse -Force -ErrorAction Stop
                    Write-Output "[SUCCESS] Deleted $($entryKey.PSChildName) in $cat ($($cs.PSChildName))"
                    $deleted++
                } catch {
                    Write-Output "[WARNING] Failed to delete $($entryKey.Name): $($_.Exception.Message)"
                }
            }
        }
    }
}

Write-Output "=== Winsock catalog cleanup finished. Entries deleted: $deleted ==="

if ($deleted -gt 0) { exit 3010 }
exit 0
