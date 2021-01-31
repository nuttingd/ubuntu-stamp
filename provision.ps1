# provision.ps1
# -------------
# This script provisions the VM using multipass, powershell, and ssh
# When multipass improves the ability to customize VM networking, etc, a lot of
# this may be eliminated.

[CmdletBinding()]
param (
  [Parameter(Mandatory = $true)]
  [string]
  $Node,

  [Parameter(Mandatory = $true)]
  [ValidateScript( {
      if (-Not ($_ | Test-Path) ) {
        throw "File or folder does not exist" 
      }
      if (-Not ($_ | Test-Path -PathType Leaf) ) {
        throw "The Path argument must be a file. Folder paths are not allowed."
      }
      return $true
    })]
  [System.IO.FileInfo]
  $VMSpecFile,
    
  [Parameter(Mandatory = $false)] # required for now, but I would like it to be optional. Need to figure out how to conditionally include the --cloud-init arg to multipass
  [ValidateScript( {
      if (-Not ($_ | Test-Path) ) {
        throw "File or folder does not exist" 
      }
      if (-Not ($_ | Test-Path -PathType Leaf) ) {
        throw "The Path argument must be a file. Folder paths are not allowed."
      }
      return $true
    })]
  [System.IO.FileInfo]
  $CloudInitFile = $null,

  [Parameter(Mandatory = $false)]
  [bool]
  $PhaseVMCreate = $true,

  [Parameter(Mandatory = $false)]
  [bool]
  $PhaseVMConfig = $true
)


# Source functions
$rootDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
. ${rootDir}\functions.ps1

# Must be admin for Hyper-V commands
Test-IsElevated

# Parse VM configuration parameters from JSON
$vmSpec = (Get-Content $VMSpecFile | ConvertFrom-Json)

$dynamicArgs = @()
if ($CloudInitFile) {
  $dynamicArgs = $dynamicArgs + "--cloud-init", $CloudInitFile 
}

# add a `--network id=ABC...` option for each item in the networks array
if ($vmSpec.networks) {
  $networkArgs = ($vmSpec.networks |
    ForEach-Object { ($_.PSObject.Properties |
    ForEach-Object { $_.Name, $_.Value -join "=" } ) -join "," }) |
    ForEach-Object { "--network", $_ }
  $dynamicArgs = $dynamicArgs + $networkArgs
}

# ---------- Phase VMCreate: Launching new node ----------
if ($PhaseVMCreate) {
  Write-Host "Creating node: $Node"
  multipass.exe launch `
    --name $Node `
    --disk $vmSpec.disk `
    --mem $vmSpec.mem `
    --cpus $vmSpec.cpus `
    $dynamicArgs

  Wait-For-Node-Ready -Node $Node -RetrySleepSeconds 30
  Wait-For-CloudInit-Completion -Node $Node
}
# ---------- Phase VMConfig: Configuring VM ----------
if ($PhaseVMConfig) {
  Invoke-ProvisionHook -Node $Node -HookPath "/root/hooks/before-vm-config.sh"

  Write-Host "Configuring VM"
  Write-Host "Stopping $Node"
  Stop-VM -Name $Node -Force
  
  Write-Host "Turning off automatic checkpoints"
  Set-VM -VMName $Node -AutomaticCheckpointsEnabled $false

  Write-Host "Starting $Node"
  Start-VM -Name $Node
  Wait-For-Node-Ready -Node $Node
} # /if($phaseVMConfig)

Invoke-ProvisionHook -Node $Node -HookPath "/root/hooks/bootstrap.sh"

Write-Host "Done!"
