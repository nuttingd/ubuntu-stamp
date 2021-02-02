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
    $Yes = ((Read-Host "Are you sure you want to teardown $Node? Be sure checkpoints are merged, etc. 'yes' to continue.") -eq "yes"),

    [Parameter(Mandatory = $false)]
    [switch]
    $Purge
)

# Source functions
$rootDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
. ${rootDir}\functions.ps1

# Must be admin for Hyper-V commands
Test-IsElevated


$verboseArg = @()
if ($Verbose) {
  $verboseArg = @("-vv")
}

if ($Yes) {
    # TODO: add a pre-teardown hook for things like backups

    # stopping before deleting helps avoid some buggy lock-ups w/ multipass
    multipass.exe stop $Node $verboseArg
    multipass.exe delete $Node $verboseArg
    if ($Purge) {
        Write-Host "Running `"multipass purge`""
        multipass purge $verboseArg
    }
    else {
        Write-Host "Done! (run multipass purge to clean up old vm)"
    }
}
else {
    Write-Host "Abort! Abort!"
}
