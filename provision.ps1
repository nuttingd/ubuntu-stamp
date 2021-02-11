# provision.ps1
# -------------
# This script provisions the VM using multipass, powershell, and ssh
# When multipass improves the ability to customize VM networking, etc, a lot of
# this may be eliminated.

[CmdletBinding()]
param (
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
  $SpecFile,

  [Parameter(Mandatory=$true)]
  [string]
  $Instance,

  [Parameter(Mandatory = $false)]
  [bool]
  $PhaseVMCreate = $true,

  [Parameter(Mandatory = $false)]
  [bool]
  $PhaseVMConfig = $true,

  [Parameter(Mandatory = $false)]
  [bool]
  $PhaseCopyUserdata = $true,
  
  [Parameter(Mandatory = $false)]
  [bool]
  $PhaseBootstrap = $true,

  [Parameter(Mandatory = $false)]
  [bool]
  $Cleanup = $true
)

$Verbose = $PSBoundParameters['Verbose']

# Source functions
$rootDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
. ${rootDir}\functions.ps1

# Must be admin for Hyper-V commands
Test-IsElevated

# ---------- Reading and decomposing spec YAML ----------
if ($null -eq (Get-Module powershell-yaml)) {
  Write-Host "Installing powershell-yaml"
  Install-Module powershell-yaml
}

$specItem = Get-Item $SpecFile
$specRaw = $specItem | Get-Content
$spec = $specRaw | ConvertFrom-Yaml -Ordered
$meta = $spec.meta
$node = "$($meta.namespace)-$($meta.name)-$Instance"
$vars = $spec.vars

# TODO, parameterize vars: vslues file? STAMP_ env vars? CLI args?
# TODO: yeah yeah, not sanitizing inputs, etc. Be careful
if ($vars) {
  Write-Verbose "Substituting variables"
  foreach ($var in $vars.GetEnumerator()) {
    $search = "{{ vars.$($var.Key) }}"
    Write-Verbose "search: $search -> $($var.Value)"
    $specRaw = $specRaw.Replace($search, $var.Value)
  }
  $spec = $specRaw | ConvertFrom-Yaml -Ordered
}

Write-Host "Provisioning $Node using $SpecFile"
Write-Verbose "vm spec:`n---`n$($spec.vm | ConvertTo-Yaml)"

# cloud-init
New-Item .\.tmp -ItemType Directory -ea 0
$timestamp = "$([Math]::Round((Get-Date).ToFileTime()/10000))"
$cloudInitFile = ".\.tmp\$timestamp-ci.yaml"
Write-Verbose "Writing temporary cloud-init file: $cloudInitFile"
"#cloud-config" | Out-File $cloudInitFile
$spec["cloud-init"] | ConvertTo-Yaml | Out-File $cloudInitFile -Append

# ---------- Build multipass arguments list ----------
$multipassArgs = @("--name", $Node)
if ($cloudInitFile) {
  $multipassArgs = $multipassArgs + @("--cloud-init", $cloudInitFile)
}

# add a `--network id=ABC...` option for each item in the networks array
if ($spec.vm.networks) {
  $networkArgs = ($spec.vm.networks |
    ForEach-Object { 
      ($_.GetEnumerator() | 
        ForEach-Object { $_.Key, $_.Value -join "=" }
      ) -join "," 
    }
  ) | ForEach-Object { "--network", $_ }

  $multipassArgs = $multipassArgs + $networkArgs
}

if ($spec.vm.disk) { $multipassArgs = $multipassArgs + @("--disk", $spec.vm.disk) }
if ($spec.vm.mem) { $multipassArgs = $multipassArgs + @("--mem", $spec.vm.mem) }
if ($spec.vm.cpus) { $multipassArgs = $multipassArgs + @("--cpus", $spec.vm.cpus) }

$verboseArg = @()
if ($Verbose) {
  $verboseArg = @("-vvv")
}
$multipassArgs = $multipassArgs + $verboseArg
Write-Verbose "Multipass arguments: $multipassArgs"

# ---------- Phase VMCreate: Launching new node ----------
if ($PhaseVMCreate) {
  Write-Host "Creating node: $Node"
  multipass.exe launch $multipassArgs
  Wait-For-Node-Ready -Node $Node -RetrySleepSeconds 30
  Wait-For-CloudInit-Completion -Node $Node
}

# ---------- Phase VMConfig: Configuring VM ----------
if ($PhaseVMConfig) {
  Invoke-ProvisionHook -Node $Node -HooksSpec $spec.hooks -HookName "before-vm-config" -Throw

  Write-Host "Configuring VM"
  Write-Host "Stopping $Node"
  Stop-VM -Name $Node -Force
  
  Write-Host "Turning off automatic checkpoints"
  Set-VM -VMName $Node -AutomaticCheckpointsEnabled $false

  # add a HDD for each item in the disks array
  if ($spec.vm.disks) {
    $spec.vm.disks | ForEach-Object { 
      Write-Host "Attaching hard disk $_ to $Node"
      Add-VMHardDiskDrive -VMName $Node -Path $_
    }
  }

  Write-Host "Starting $Node"
  Start-VM -Name $Node
  Wait-For-Node-Ready -Node $Node
}

# ---------- Phase CopyUserdata: Copying userdata ----------
if ($PhaseCopyUserdata) {
  Invoke-ProvisionHook -Node $Node -HooksSpec $spec.hooks -HookName "before-copy-userdata" -Throw

  Write-Host "Copying userdata"
  if ($spec.userdata) {
    $spec.userdata | ForEach-Object { 
      $local = Get-Item (Join-Path $specItem.Directory $_.local -Resolve)
      $target = $_.target 
      if ($local && $target) {
        $permissions = $_.permissions ?? "0770"
        $owner = $_.owner ?? "root"
        $isDirectory = $local.PSIsContainer

        # Creating temporary mount
        $mount_source = if ($isDirectory) { $local.Parent } else { $local.Directory }
        $tmp_mount_path = "/tmp/userdata-$("$(New-Guid)".Substring(0,8))"
        $mount_target = "${Node}:$tmp_mount_path"
        Write-Host "Creating a temporary mount: $mount_source to $mount_target"
        multipass.exe mount $mount_source $mount_target $verboseArg

        # Copying file(s)
        if ($isDirectory) {
          # using rsync to avoid the contextual gotchas of cp (for idempotency / deterministic behavior)
          $copy_directory_cmd = "rsync -rt $tmp_mount_path/$($local.Name)/ $target/"
          Write-Verbose "cmd: $copy_directory_cmd"
          multipass.exe exec $Node -- sudo bash -c $copy_directory_cmd
        }
        else {
          Write-Host "Copying $($local.Name) to ${Node}:$target"
          $copy_file_cmd = "mkdir -p ``dirname $target`` && cp $tmp_mount_path/$($local.Name) $target"
          Write-Verbose "cmd: $copy_file_cmd"
          multipass.exe exec $Node -- sudo bash -c $copy_file_cmd
        }

        # Unmount
        Write-Host "Unmounting temporary mount"
        multipass.exe unmount $mount_target $verboseArg

        # Set file permissions
        Write-Host "Setting file permissions"
        $recursive = if ($isDirectory) {"-R "} else {""}
        
        Write-Verbose "Changing owner to $owner"
        $change_owner_cmd = "chown $recursive $owner $target"
        Write-Verbose "cmd: $change_owner_cmd"
        multipass.exe exec $Node -- sudo bash -c $change_owner_cmd
        
        Write-Verbose "Changing permissions to $permissions"
        $change_permissions_cmd = "chmod $recursive $permissions $target"
        Write-Verbose "cmd: $change_permissions_cmd"
        multipass.exe exec $Node -- sudo bash -c $change_permissions_cmd
      }
      else {
        Write-Error "There was a problem copying user data.`n`tlocal: $($_.local)`n`ttarget: $($_.target)"
      }
    }
  }
}

# ---------- Phase Bootstrap: Running bootstrap script ----------
if ($PhaseBootstrap) {
  $hookResult = Invoke-ProvisionHook -Node $Node -HooksSpec $spec.hooks -HookName "bootstrap"
  if (!$hookResult) { Write-Error "There was a problem with the bootstrap script! Please review the output and take corrective action." }
}

Write-Host "Cleaning up"
Write-Verbose "Deleting temporary cloud-init file: $cloudInitFile"
Remove-Item -Path $cloudInitFile

Write-Host "Done!"
