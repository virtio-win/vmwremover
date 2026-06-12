# Schedule a file for deletion on next reboot
# Uses direct registry write instead of MoveFileEx API
param(
    [Parameter(Mandatory=$true)]
    [string]$FilePath
)

try {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"

    # Get existing pending operations
    $existingValue = Get-ItemProperty -Path $regPath -Name PendingFileRenameOperations -ErrorAction SilentlyContinue |
                     Select-Object -ExpandProperty PendingFileRenameOperations

    # Format: \??\C:\path\to\file (followed by empty string for deletion)
    $fileEntry = "\??\$FilePath"

    if ($existingValue) {
        # Append to existing entries (cast to array to handle corrupted single-string values)
        $newValue = @($existingValue) + @($fileEntry, "")
    } else {
        # Create new entry
        $newValue = @($fileEntry, "")
    }

    # Write to registry
    Set-ItemProperty -Path $regPath -Name PendingFileRenameOperations -Value $newValue -Type MultiString

    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
