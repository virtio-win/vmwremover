# vmwremover

Scripts to remove leftover VMware Tools drivers, services, devices,
registry entries, and (optionally) binaries from a Windows guest after a
vSphere -> KubeVirt/CNV (V2V) migration.

## Design: batch baseline + best-effort PowerShell

The tooling is a **hybrid**, but overwhelmingly pure batch. Every phase
that *can* be done in `.bat` is - so guests where PowerShell is locked
down are still cleaned up. PowerShell is used only where batch genuinely
cannot do the job: **Authenticode signature verification** and
**matching a GUID inside a binary registry value**. Those `.ps1` steps
are best-effort - a failure (or an absent PowerShell) is logged and
never aborts the run.

`cleanup_vmware_leftovers.bat` detects PowerShell once (resolving
`powershell.exe` on `PATH` with a fixed `System32` fallback, plus a probe
that it can actually execute) and orchestrates all phases, honouring exit
code `3010` from any phase to mean "reboot required".

### Phases (run by `cleanup_vmware_leftovers.bat`)

| Phase | Script | Type |
|-------|--------|------|
| Disable PnP devices | `drivers\disable_vmware_drivers.bat` | batch -> PS |
| Disable services | `services\disable_vmware_services.bat` | batch |
| Remove PnP device instances (incl. ghosts) | `drivers\remove_vmware_drivers.bat` | batch -> PS |
| Remove driver packages | `drivers\remove_vmware_driver_packages.bat` | batch |
| Clean legacy DRVSTORE folders | `drivers\clean_legacy_drvstore.bat` | batch |
| Remove registry entries | `reg\remove_vmware_registry.bat` | batch |
| Remove Winsock provider (live catalog) | `reg\remove_vmware_winsock.bat` | batch |
| Remove service keys across all ControlSets | `reg\delete_services_all_controlsets.bat` | batch |
| Remove Winsock catalog across all ControlSets | `reg\delete_winsock_registry.ps1` | PS (binary GUID match) |
| Remove services | `services\remove_vmware_services.bat` | batch |

The device phases are batch wrappers that call
`drivers\manage_vmware_pnp_devices.ps1` (no `devcon.exe` binary is shipped).
It enumerates present **and** non-present (ghost) nodes via `Get-PnpDevice`,
matching the VMware PCI vendor ID (`VEN_15AD`) and device-name tokens while
excluding virtio (`VEN_1AF4`) and Hyper-V (`VMBUS`/`vmic`). Removal uses the
best facility the OS provides - the `Remove-PnpDevice` cmdlet where present,
else `pnputil /remove-device` (build 19041+ / Server 2022+), else a SetupAPI
`DiUninstallDevice` P/Invoke that works on every supported build including
Server 2016/2019. Ghosts are covered by the same pass, so no separate
ghost-removal step is needed. If PowerShell is unavailable the device phases
skip cleanly and the remaining phases still run.

The Winsock catalog phase, `reg\delete_winsock_registry.ps1`, scrubs the
Winsock2 catalog across every ControlSet by matching the provider GUID
inside the binary `PackedCatalogItem` value - impractical in batch. When
PowerShell is unavailable it is skipped; the batch `netsh` Winsock phase
still handles the live catalog.

### Advanced / opt-in: binary file deletion

`files\remove_vmware_binaries.bat` deletes VMware install directories and
orphaned driver files (Broadcom KB 315629). It is **unsupported**, has no
undo, and is **not** run by the orchestrator - take a snapshot first and
run it deliberately. It is itself hybrid: it schedules locked driver
files for deletion on reboot via `PendingFileRenameOperations`, and when
PowerShell is available it
augments with `discover_vmware_binaries.ps1` (Authenticode-gated
discovery -> manifest), which the batch script then deletes from. Driver
packages are removed via `pnputil /delete-driver`; the DriverStore
FileRepository is never deleted directly, to avoid corrupting the driver
database.
