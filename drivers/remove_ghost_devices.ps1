<#
.SYNOPSIS
    Remove non-present (ghost) VMware PnP devices left after a V2V/CNV migration.

.DESCRIPTION
    Ghost devices are simply non-present PnP nodes, which the consolidated
    device manager already enumerates and removes in one pass alongside present
    devices. To avoid a second, weaker copy of that logic drifting out of sync,
    this script delegates to manage_vmware_pnp_devices.ps1 -Mode remove, which:
      - matches strictly on VMware name tokens or PCI VEN_15AD (excluding
        virtio VEN_1AF4 and Hyper-V VMBUS/vmic),
      - removes via Remove-PnpDevice, "pnputil /remove-device" (build 19041+),
        or a SetupAPI DiUninstallDevice call that works on every supported
        build, and
      - returns 3010 if anything was removed (reboot recommended), else 0.

    Kept as a named entry point because the verifier suggests running it
    directly as the ghost-removal remediation step.
#>

$manager = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'manage_vmware_pnp_devices.ps1'
if (-not (Test-Path -LiteralPath $manager)) {
    Write-Host "[ERROR] manage_vmware_pnp_devices.ps1 not found next to this script."
    exit 1
}
& $manager -Mode remove
exit $LASTEXITCODE
