<#
.SYNOPSIS
    Disable or remove all VMware-related PnP devices - present or non-present
    (ghost) - using only built-in Windows facilities, with no external binary.

.DESCRIPTION
    Replaces the devcon.exe-based manage_vmware_pnp_devices.bat. Enumeration
    uses Get-PnpDevice, which returns both present and non-present device
    nodes, so ghost phantoms left after a V2V/CNV migration are covered by the
    same pass (devcon findall did the same).

    -Mode disable : Disable-PnpDevice on each PRESENT match. A non-present node
                    cannot be disabled and is skipped.
    -Mode remove  : uninstall each match. The removal path is chosen by what
                    the OS actually provides:
                      1. Remove-PnpDevice cmdlet, where present;
                      2. else "pnputil /remove-device" (build 19041+ /
                         Server 2022+);
                      3. else a SetupAPI call (DiUninstallDevice via P/Invoke),
                         which works on every supported build including Server
                         2016/2019 - this is the uninstall devcon did
                         internally, so removal has full parity without devcon.

    Matching is strict: a device qualifies only if its FriendlyName carries a
    VMware token (VMware / vsock / vmci / vmxnet / pvscsi) OR its InstanceId
    carries the VMware PCI vendor id VEN_15AD. Devices whose InstanceId is
    virtio (VEN_1AF4) or Microsoft Hyper-V (VMBUS / vmic) are excluded, so the
    replacement virtio NIC/disk and the Hyper-V Integration devices are never
    touched.

    Exit code: 3010 if at least one device was removed (reboot recommended),
    else 0. Never throws - a failure on one device is logged and skipped.
#>
param(
    [ValidateSet('disable', 'remove')]
    [string]$Mode = 'remove'
)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $scriptDir 'manage_vmware_pnp_devices.log'
"=== VMware PnP device $Mode - $(Get-Date) ===" | Out-File -FilePath $log -Encoding UTF8

function Write-Log { param([string]$m) Write-Host $m; $m | Out-File -FilePath $log -Append -Encoding UTF8 }

# VMware-positive tokens in the friendly name, and the VMware PCI vendor id.
$vmwareName = 'VMware|vsock|vmci|vmxnet|pvscsi'
# Never touch the replacements: virtio (VEN_1AF4) or Hyper-V (VMBUS/vmic).
$excludeId  = 'VEN_1AF4|VMBUS|\\vmic'

if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) {
    Write-Log "[SKIP] Get-PnpDevice not available on this OS - cannot manage PnP devices."
    exit 0
}

# --- OS removal-capability probe (mirrors remove_ghost_devices.ps1) ---
# Remove-PnpDevice is absent on several Server images, and "pnputil
# /remove-device" needs build 19041+ (Server 2022+). The SetupAPI fallback
# below covers everything else (Server 2016/2019), so removal never depends on
# any one of them being present.
$canCmdlet = [bool](Get-Command Remove-PnpDevice -ErrorAction SilentlyContinue)
$build = 0
try { $build = [int](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).BuildNumber }
catch {
    try { $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop).CurrentBuildNumber } catch { }
}
$canPnputil = $build -ge 19041

# --- SetupAPI fallback: the all-versions removal path (compiled on demand) ---
# SetupDiOpenDeviceInfo + DiUninstallDevice is exactly the uninstall devcon
# performed, so it removes present and ghost nodes on builds that have neither
# Remove-PnpDevice nor "pnputil /remove-device". Add-Type ships as text in this
# .ps1 - there is no binary to distribute.
$script:setupApiReady = $false
$script:needReboot = $false
function Initialize-SetupApi {
    if ($script:setupApiReady) { return $true }
    try {
        Add-Type -Namespace Vmw -Name Dev -ErrorAction Stop -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct SP_DEVINFO_DATA { public uint cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved; }
[DllImport("setupapi.dll", SetLastError=true)]
public static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr ClassGuid, IntPtr hwndParent);
[DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool SetupDiOpenDeviceInfo(IntPtr DeviceInfoSet, string DeviceInstanceId, IntPtr hwndParent, uint Flags, ref SP_DEVINFO_DATA DeviceInfoData);
[DllImport("setupapi.dll", SetLastError=true)]
public static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);
[DllImport("newdev.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool DiUninstallDevice(IntPtr hwndParent, IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, uint Flags, ref bool NeedReboot);
'@
        $script:setupApiReady = $true
    } catch {
        Write-Log "  [WARN] SetupAPI unavailable (Add-Type failed): $($_.Exception.Message)"
        $script:setupApiReady = $false
    }
    return $script:setupApiReady
}

function Remove-DeviceViaSetupApi {
    param([string]$InstanceId)
    if (-not (Initialize-SetupApi)) { return $false }
    $invalid = [System.IntPtr](-1)
    $set = [Vmw.Dev]::SetupDiCreateDeviceInfoList([System.IntPtr]::Zero, [System.IntPtr]::Zero)
    if ($set -eq [System.IntPtr]::Zero -or $set -eq $invalid) { return $false }
    try {
        $data = New-Object 'Vmw.Dev+SP_DEVINFO_DATA'
        $data.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($data)
        if (-not [Vmw.Dev]::SetupDiOpenDeviceInfo($set, $InstanceId, [System.IntPtr]::Zero, 0, [ref]$data)) { return $false }
        $reboot = $false
        $ok = [Vmw.Dev]::DiUninstallDevice([System.IntPtr]::Zero, $set, [ref]$data, 0, [ref]$reboot)
        if ($ok -and $reboot) { $script:needReboot = $true }
        return $ok
    } finally {
        [void][Vmw.Dev]::SetupDiDestroyDeviceInfoList($set)
    }
}

# --- Enumerate matching devices (present + non-present). ---
$devices = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
    (
        ($_.FriendlyName -and $_.FriendlyName -match $vmwareName) -or
        ($_.InstanceId   -and $_.InstanceId   -match 'VEN_15AD')
    ) -and
    -not ($_.InstanceId -and $_.InstanceId -match $excludeId)
}

# A non-present device cannot be disabled - only remove touches ghosts. Filter
# on Status rather than the .Present property, which is not exposed by
# Get-PnpDevice on older builds (e.g. Server 2016) and would silently drop
# every device there. Non-present nodes report Status 'Unknown'; present ones
# report OK/Error/Degraded/etc.
if ($Mode -eq 'disable') {
    $devices = $devices | Where-Object { $_.Status -ne 'Unknown' }
}

if (-not $devices) {
    Write-Log "[INFO] No VMware PnP devices to $Mode."
    exit 0
}

$done = 0
foreach ($d in $devices) {
    $name = if ($d.FriendlyName) { $d.FriendlyName } else { $d.InstanceId }

    if ($Mode -eq 'disable') {
        Write-Log "[DISABLE] $name  [$($d.Status)]  $($d.InstanceId)"
        try {
            $d | Disable-PnpDevice -Confirm:$false -ErrorAction Stop
            Write-Log "  [SUCCESS] Disabled $name"
            $done++
        } catch {
            Write-Log "  [WARN] Could not disable $name : $($_.Exception.Message)"
        }
        continue
    }

    # remove: try the cheapest available path first, fall through to SetupAPI.
    Write-Log "[REMOVE] $name  [$($d.Status)]  $($d.InstanceId)"
    $ok = $false
    if ($canCmdlet) {
        try {
            $d | Remove-PnpDevice -Confirm:$false -ErrorAction Stop
            $ok = $true
            Write-Log "  [SUCCESS] Removed $name (cmdlet)"
        } catch {
            Write-Log "  [INFO] Remove-PnpDevice failed, trying next path: $($_.Exception.Message)"
        }
    }
    if (-not $ok -and $canPnputil) {
        & pnputil.exe /remove-device "$($d.InstanceId)" > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            $ok = $true
            Write-Log "  [SUCCESS] Removed $name (pnputil)"
        }
    }
    if (-not $ok) {
        if (Remove-DeviceViaSetupApi -InstanceId $d.InstanceId) {
            $ok = $true
            Write-Log "  [SUCCESS] Removed $name (SetupAPI)"
        }
    }
    if ($ok) { $done++ } else { Write-Log "  [WARN] Could not remove $name" }
}

Write-Log "[INFO] VMware PnP device $Mode finished. Affected: $done"
if ($Mode -eq 'remove' -and $done -gt 0) { exit 3010 }
exit 0
