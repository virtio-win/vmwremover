# vmwremover

VMware Tools removal scripts for Windows guests after v2v migration.

## Overview

This toolkit provides batch scripts to completely remove VMware Tools remnants from Windows VMs that have been migrated from VMware infrastructure to other hypervisors (e.g., via virt-v2v).

> **Important Note**: Cross-hypervisor migrations will never be perfectly clean. Some artifacts may persist despite thorough cleanup. For mission-critical production systems, consider a fresh OS installation on the target hypervisor rather than migration.

## Components

The toolkit is organized into four phases:

### 1. `/services/` - Service Management
- **`disable_vmware_services.bat`**: Stop and disable VMware services (non-destructive)
- **`remove_vmware_services.bat`**: Stop, disable, and permanently delete VMware services

### 2. `/drivers/` - Driver Management
- **`disable_vmware_drivers.bat`**: Disable VMware PnP devices using `devcon.exe`
- **`remove_vmware_drivers.bat`**: Remove VMware PnP devices using `devcon.exe`
- **`remove_vmware_driver_packages.bat`**: Remove VMware driver packages from the driver store using `pnputil.exe` (most aggressive)
- **`remove_ghost_devices.ps1`**: Remove hidden/disconnected VMware devices from Device Manager (post-cleanup)

### 3. `/binaries/` - Binary File Cleanup
- **`uninstall_vmware_msi.ps1`**: Proper MSI uninstall via Windows Installer (run FIRST)
- **`discover_vmware_binaries.ps1`**: Discover and catalog all VMware files including binaries (Program Files, System32) and config files (ProgramData) using cryptographic signature verification
- **`remove_vmware_binaries.ps1`**: Remove all discovered VMware files with automatic Winsock cleanup and locked file handling

### 4. `/reg/` - Registry Cleanup
- **`query_vmware_registry.bat`**: Query VMware registry entries (read-only diagnostic tool)
- **`remove_vmware_registry.bat`**: Delete VMware registry keys and values, including Winsock catalog cleanup
- **`delete_vsock_all_controlsets.ps1`**: Remove vsock service entries from all ControlSets (called by remove_vmware_registry.bat)
- **`delete_winsock_registry.ps1`**: Remove VMware vSockets from Winsock registry in all ControlSets (called by remove_vmware_registry.bat)
- **`cleanup_winsock_after_registry.ps1`**: Remove VMware vSockets from runtime Winsock catalog using netsh winsock reset (called by remove_vmware_registry.bat)

## Usage

### Recommended Execution Order

For complete VMware cleanup, run scripts in this sequence:

```cmd
1. binaries\uninstall_vmware_msi.ps1                    (proper MSI uninstall via Windows Installer)
2. services\remove_vmware_services.bat                  (stop and delete remaining services)
3. binaries\discover_vmware_binaries.ps1                (catalog all remaining files - binaries and config files)
4. drivers\remove_vmware_driver_packages.bat            (remove remaining driver store entries)
5. REBOOT #1                                             (unload drivers from kernel memory)
6. binaries\remove_vmware_binaries.ps1                  (delete all files with locked file handling)
7. reg\remove_vmware_registry.bat                       (registry + Winsock catalog cleanup)
8. REBOOT #2                                             (complete locked file deletion + finalize Winsock reset)
9. drivers\remove_ghost_devices.ps1                     (remove hidden devices - optional on older Windows)
```

**Important notes:**
- Run binary discovery **before** registry cleanup - registry entries contain paths to binaries
- **REBOOT #1** unloads kernel drivers so files can be deleted cleanly
- **REBOOT #2** completes locked file deletion and finalizes Winsock catalog reset for virtio-vsock

### Running Scripts

All scripts must be run as Administrator:

```cmd
# Right-click and select "Run as administrator"
# OR from elevated command prompt:
cd vmwremover\services
disable_vmware_services.bat
```

### Quick Start

For a complete cleanup on a v2v-migrated Windows VM:

```cmd
# 1. Proper MSI uninstall (via Windows Installer)
cd binaries
powershell -ExecutionPolicy Bypass -File .\uninstall_vmware_msi.ps1
# Uses official VMware uninstaller to cleanly remove products
# Removes files, services, drivers, and registry entries properly

# 2. Stop any remaining VMware services
cd ..\services
remove_vmware_services.bat

# 3. Discover remaining binaries (while registry intact)
cd ..\binaries
powershell -ExecutionPolicy Bypass -File .\discover_vmware_binaries.ps1

# 4. Remove remaining drivers
cd ..\drivers
remove_vmware_driver_packages.bat

# 5. REBOOT #1 to unload drivers before binary removal
shutdown /r /t 60 /c "VMware cleanup - unloading drivers"
# After reboot, continue with step 6

# 6. Remove remaining binaries (file deletion with locked file handling)
cd binaries
powershell -ExecutionPolicy Bypass -File .\remove_vmware_binaries.ps1
# Deletes all discovered files, schedules locked files for deletion on next boot

# 7. Clean registry and Winsock catalog
cd ..\reg
remove_vmware_registry.bat
# Automatically performs:
#   1. Delete Services\vsock from all ControlSets
#   2. Delete WinSock2 registry entries from all ControlSets
#   3. Run 'netsh winsock reset' to rebuild catalog from cleaned registry
#   4. Delete other VMware registry keys

# 8. REBOOT #2 to complete locked file deletion and finalize Winsock reset
shutdown /r /t 60 /c "VMware cleanup - completing file removal and Winsock reset"
# After reboot, continue with step 9

# 9. Remove ghost devices from Device Manager (optional)
cd ..\drivers
powershell -ExecutionPolicy Bypass -File .\remove_ghost_devices.ps1
# Note: On Windows Server 2019 and older, automatic removal is not supported
#       Ghost devices are harmless - manual removal via Device Manager is optional
```

## What Gets Removed

### Services
- All Windows services with "VMware" in their description
- Examples: VMware Tools Service, VMware Alias Manager, VMware CAF Management Agent

### Drivers
- VMware PnP devices (network, SCSI, mouse, video, etc.)
- Driver packages from Windows driver store
- Ghost/hidden devices from Device Manager
- Examples: vmci, vmxnet3, pvscsi, vmmouse, vsock

### Binaries
- VMware executables in `%ProgramFiles%\VMware\`
- VMware DLLs and drivers in `%SystemRoot%\System32\`
- Application data in `%ProgramData%\VMware\`
- Examples: vmtoolsd.exe, vmGuestLib.dll, vmci.sys, vmmouse.sys

### Registry
- VMware-related keys in `HKLM\SOFTWARE\VMware, Inc.\`
- Service entries in `HKLM\SYSTEM\CurrentControlSet\Services\`
- VMware driver metadata

## Logs

Each script generates logs in its own directory:
- `services\vmware_disable.log`
- `binaries\discovery.log` and `binaries\removal.log`
- `drivers\removal_log.txt` and `drivers\ghost_device_removal.log`
- `debug\verify_complete_removal.log`

## Requirements

- Windows 7 or later (tested on Windows Server 2016/2019/2022, Windows 10/11)
- Administrator privileges
- **PowerShell 4.0 or later** (Windows 8.1+, Server 2012 R2+)
  - For Windows 8/Server 2012, upgrade to [Windows Management Framework 5.1](https://www.microsoft.com/en-us/download/details.aspx?id=54616)
  - The `#requires -RunAsAdministrator` directive requires PowerShell 4.0+

## Locked Files & Reboot

Some VMware binaries may be locked by Windows. The binary removal script will:
1. Attempt immediate deletion
2. If locked, schedule deletion on next reboot
3. Prompt you to restart if any files require it

## Ghost Devices

After driver removal, hidden/disconnected VMware devices may persist in Device Manager. The `remove_ghost_devices.ps1` script removes these, preventing:
- Static IP configuration conflicts with old network adapters
- Persistent route table issues from disappeared interfaces
- Device Manager clutter from disconnected hardware

**Note**: Removing network ghost devices may require reconfiguring static IP addresses or persistent routes if they were bound to the old interface IDs.

## Critical: VMware vSockets Cleanup

VMware Tools installs a Winsock provider for AF_VSOCK (VMware vSockets) that **conflicts** with virtio-vsock after migration. The registry cleanup step addresses this critical issue:

**The Problem:**
- Both VMware vSockets and virtio-vsock use the same address family (AF_VSOCK = 40)
- Windows Winsock catalog can only have one provider per address family
- If VMware vSockets provider remains, virtio-vsock fails to register
- Simple `netsh winsock remove provider` command silently fails to remove it

**The Solution:**
1. Delete `Services\vsock` from **all** ControlSets (not just CurrentControlSet)
2. Delete VMware vSockets entries from WinSock2 registry in **all** ControlSets
3. Use `netsh winsock reset` to rebuild catalog from cleaned registry
4. Reboot to complete cleanup

The registry cleanup script (`reg\remove_vmware_registry.bat`) handles all of this automatically.

## Verification

After running all cleanup scripts, you can manually verify complete removal:

```cmd
# Check for remaining services
sc query | findstr /i vmware

# Check for remaining drivers
pnputil /enum-drivers | findstr /i vmware

# Check for remaining binaries
dir /s "%ProgramFiles%\VMware\"
dir /b %SystemRoot%\System32\vm*.*

# Check for remaining application data
dir /s "%ProgramData%\VMware\"

# Check for ghost devices
powershell "Get-PnpDevice -Status Unknown | Where-Object {$_.FriendlyName -like '*VMware*'}"

# Check registry
reg query "HKLM\SOFTWARE\VMware, Inc."
```

## Contributing

When adding new registry entries or binary paths, update:
- `reg\remove_vmware_registry.bat` for hardcoded registry cleanup
- `binaries\discover_vmware_binaries.bat` for additional discovery methods

## License

See [LICENSE](LICENSE) for details.
