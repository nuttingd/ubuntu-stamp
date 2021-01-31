# teardown.ps1
# ------------
# This will destroy the VM.

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]
    $Node,

    [Parameter(Mandatory = $false)]
    [switch]
    $Yes = ((Read-Host "Are you sure you want to teardown $Node? Be sure checkpoints are merged, etc. 'yes' to continue.") -eq "yes")
)

# Source functions
$rootDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
. ${rootDir}\functions.ps1

# Must be admin for Hyper-V commands
Test-IsElevated

if ($Yes) {
    # stopping before deleting helps avoid some buggy lock-ups w/ multipass
    multipass.exe stop $Node
    multipass.exe delete $Node
    Write-Host "Done! (run multipass purge to clean up old vm)"    
}
else {
    Write-Host "Abort! Abort!"
}
