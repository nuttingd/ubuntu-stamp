# teardown.ps1
# ------------
# This will destroy the VM.

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]
    $node
)

# Source functions
$rootDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
. ${rootDir}\functions.ps1

# Must be admin for Hyper-V commands
Test-IsElevated

$continue = Read-Host "Are you sure you want to teardown ${node}? Be sure checkpoints are merged, etc. 'yes' to continue."
if ($continue -eq "yes") {
    # stopping before deleting helps avoid some buggy lock-ups w/ multipass
    multipass.exe stop ${node}
    multipass.exe delete ${node}
    Write-Host "Done! (run multipass purge to clean up old vm)"    
}
else {
    Write-Host "Abort! Abort!"
}
