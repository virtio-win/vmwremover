<#
.SYNOPSIS
    Force-delete ACL-protected VMware service keys across all ControlSets.

.DESCRIPTION
    Best-effort PowerShell mop-up for delete_services_all_controlsets.bat. A few
    VMware driver service keys (seen with vm3dmp_loader) carry a DACL/owner that
    denies delete even to Administrators, so reg.exe / Remove-Item return
    "Access is denied". Adjusting registry ownership is the one thing batch
    cannot do, so this helper enables SeTakeOwnershipPrivilege / SeRestorePrivilege,
    seizes ownership, grants Administrators FullControl, then removes the key
    (recursing into protected subkeys the same way).

    Targets: with a file argument, one full key path per line (passed by the
    batch for exactly the keys its reg delete could not remove). With no argument,
    it self-discovers using the SAME exact VMware service-name allowlist swept
    across every ControlSetNNN. Names are matched EXACTLY - it never touches
    netkvm / NETKVMP (virtio-net), vmbus / VMBusHID / vmgid / vmic* (Hyper-V
    Integration Services), or stornvme (Microsoft NVMe).

    Exit code: 3010 if at least one key was removed (reboot recommended), else 0.
#>
param([string]$TargetFile)

$ErrorActionPreference = 'Continue'

# --- Enable the privileges needed to seize ownership from TrustedInstaller/SYSTEM ---
$sig = @'
using System;
using System.Runtime.InteropServices;
public static class TokenPriv {
  [DllImport("advapi32.dll", SetLastError=true)]
  static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true)]
  static extern bool LookupPrivilegeValue(string host, string name, out long luid);
  [DllImport("advapi32.dll", SetLastError=true)]
  static extern bool AdjustTokenPrivileges(IntPtr tok, bool disableAll, ref TP newState, int len, IntPtr prev, IntPtr relen);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [StructLayout(LayoutKind.Sequential, Pack=1)]
  struct TP { public int Count; public long Luid; public int Attr; }
  public static bool Enable(string name) {
    IntPtr tok;
    if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false; // ADJUST|QUERY
    TP tp; tp.Count = 1; tp.Attr = 0x2;                                      // SE_PRIVILEGE_ENABLED
    if (!LookupPrivilegeValue(null, name, out tp.Luid)) return false;
    return AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
  }
}
'@
try { Add-Type -TypeDefinition $sig -ErrorAction Stop } catch { }
try {
    [void][TokenPriv]::Enable('SeTakeOwnershipPrivilege')
    [void][TokenPriv]::Enable('SeRestorePrivilege')
} catch { }

$admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')

function Seize-Key {
    param([string]$SubPath)   # e.g. SYSTEM\ControlSet001\Services\vm3dmp_loader
    # 1) take ownership (write only the owner section, so we need no prior read rights)
    try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $SubPath,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($null -eq $k) { return }
        $own = New-Object System.Security.AccessControl.RegistrySecurity
        $own.SetOwner($admins)
        $k.SetAccessControl($own)
        $k.Close()
    } catch { Write-Output "  [WARN] take-owner $SubPath : $($_.Exception.Message)" }
    # 2) grant Administrators FullControl (owner may now read/write the DACL)
    try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $SubPath,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if ($k) {
            $acl  = $k.GetAccessControl()
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                $admins, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.ResetAccessRule($rule)
            $k.SetAccessControl($acl)
            $k.Close()
        }
    } catch { Write-Output "  [WARN] grant $SubPath : $($_.Exception.Message)" }
    # 3) recurse into children (a protected subkey needs the same treatment)
    try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubPath)
        if ($k) {
            $children = $k.GetSubKeyNames()
            $k.Close()
            foreach ($c in $children) { Seize-Key "$SubPath\$c" }
        }
    } catch { }
}

function Remove-ProtectedKey {
    param([string]$FullPath)  # HKLM\SYSTEM\... or HKEY_LOCAL_MACHINE\SYSTEM\...
    $sub = $FullPath -replace '^(HKEY_LOCAL_MACHINE|HKLM)\\', ''
    $ps  = "HKLM:\$sub"
    if (-not (Test-Path -LiteralPath $ps)) { return $false }
    Seize-Key $sub
    try {
        Remove-Item -LiteralPath $ps -Recurse -Force -ErrorAction Stop
        Write-Output "[SUCCESS] Removed $sub"
        return $true
    } catch {
        Write-Output "[FAIL] Still could not remove $sub : $($_.Exception.Message)"
        return $false
    }
}

# --- Build the target list ---
$targets = @()
if ($TargetFile -and (Test-Path -LiteralPath $TargetFile)) {
    $targets = Get-Content -LiteralPath $TargetFile | Where-Object { $_ -and $_.Trim() -ne '' }
} else {
    # Exact VMware service names only - mirrors delete_services_all_controlsets.bat.
    $names = @('vmci','vsock','vmhgfs','vmmouse','vmusbmouse','vmrawdsk','vmmemctl',
               'vmxnet3','vmxnet3ndis6','pvscsi','vm3dmp','vm3dmp-debug','vm3dmp-stats',
               'vm3dmp_loader','vmwefifw','vsepflt','vnetWFP','vmStatsProvider')
    Get-ChildItem 'HKLM:\SYSTEM' | Where-Object { $_.PSChildName -match '^ControlSet\d{3}$' } | ForEach-Object {
        $cs = $_.PSChildName
        foreach ($n in $names) {
            if (Test-Path -LiteralPath "HKLM:\SYSTEM\$cs\Services\$n") {
                $targets += "HKLM\SYSTEM\$cs\Services\$n"
            }
        }
    }
}

if (-not $targets -or $targets.Count -eq 0) {
    Write-Output "[INFO] No protected VMware service keys to remove."
    exit 0
}

$removed = 0
foreach ($t in $targets) {
    if (Remove-ProtectedKey $t) { $removed++ }
}
Write-Output "[INFO] Protected-key mop-up finished. Removed: $removed"
if ($removed -gt 0) { exit 3010 }
exit 0
