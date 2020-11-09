function Require-Elevated() {
    if (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
        Write-Error "Run this as admin ;)"
        Exit 1
    }
}

# source: https://stackoverflow.com/questions/8333455/how-to-loop-in-powershell-until-successful
function Call-CommandWithRetries {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory = $True)]
        [string]$Command,
        [Array]$Arguments,
        [int]$RetrySleepSeconds = 10,
        [int]$MaxAttempts = 10,
        [bool]$PrintCommand = $True
    )

    Process {
        $attempt = 0
        while ($true) {   
            Write-Host $(if ($PrintCommand) { "Executing: $Command $Arguments" } else { "Executing command..." }) 
            & $Command $Arguments 2>&1 | Tee-Object -Variable output | Write-Host

            $stderr = $output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
            if ( ($LASTEXITCODE -eq 0) ) {
                Write-Host "Command executed successfully"
                return $output
            }

            Write-Host "Command failed with exit code ($LASTEXITCODE) and stderr: $stderr" -ForegroundColor Yellow
            if ($attempt -eq $MaxAttempts) {
                $ex = new-object System.Management.Automation.CmdletInvocationException "All retry attempts exhausted"
                $category = [System.Management.Automation.ErrorCategory]::LimitsExceeded
                $errRecord = new-object System.Management.Automation.ErrorRecord $ex, "CommandFailed", $category, $Command
                $psCmdlet.WriteError($errRecord)
                return $output
            }

            $attempt++;
            Write-Host "Retrying test execution [#$attempt/$MaxAttempts] in $RetrySleepSeconds seconds..."
            Start-Sleep -s $RetrySleepSeconds
        }
    }
}


# source: https://stackoverflow.com/questions/8333455/how-to-loop-in-powershell-until-successful
function Wait-For-Node-Ready {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory = $true)]
        [string]$NodeId,
        [int]$RetrySleepSeconds = 15,
        [int]$MaxAttempts = 10
    )
 
    Write-Host "Waiting for $NodeId to be ready"
    Call-CommandWithRetries `
        -Command "multipass.exe" `
        -Arguments @("exec", "$NodeId", "--", "exit" ) `
        -RetrySleepSeconds $RetrySleepSeconds `
        -MaxAttempts $MaxAttempts `
        -PrintCommand $false
}

function Wait-For-CloudInit-Completion {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory = $true)]
        [string]$NodeId,
        [int]$RetrySleepSeconds = 15,
        [int]$MaxAttempts = 10
    )

    $attempt = 0
    Write-Host "Waiting for Cloud-init completion"
    while ($true) {   
        # <https://stackoverflow.com/questions/33019093/how-do-detect-that-cloud-init-completed-initialization>
        Write-Host "Checking /run/cloud-init/result.json"

        multipass.exe exec $NodeId -- test -f /run/cloud-init/result.json
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Result file found: /run/cloud-init/result.json"
            $result_raw = multipass.exe exec $NodeId -- cat /run/cloud-init/result.json
            #DEBUG: $result_raw = '{  "v1": {   "datasource": "DataSourceNoCloud [seed=/dev/sr0][dsmode=net]",   "errors": [1, 2, 3]  } }'
            Write-Host "Cloud-init result:`r`n$result_raw"
            $json = $result_raw | ConvertFrom-Json

            # TODO: This branching is all guess-work
            if ($json.v1) {
                if ($json.v1.errors.length -eq 0) {
                    Write-Host "Cloud-init completed"
                    return
                }
                else {
                    $ex = new-object System.Management.Automation.CmdletInvocationException "Cloud-init errors detected"
                    # $category = [System.Management.Automation.ErrorCategory]::LimitsExceeded
                    # $errRecord = new-object System.Management.Automation.ErrorRecord $ex, "CommandFailed", $category, $Command
                    # $psCmdlet.WriteError($errRecord)
                    throw $ex
                }
            }
        }
        else {
            Write-Host "Result file doesn't yet exist: /run/cloud-init/result.json"
        }
        
        Write-Host "Cloud-init not completed"
        if ($attempt -eq $MaxAttempts) {
            $ex = new-object System.Management.Automation.CmdletInvocationException "All retry attempts exhausted"
            # $category = [System.Management.Automation.ErrorCategory]::LimitsExceeded
            # $errRecord = new-object System.Management.Automation.ErrorRecord $ex, "CommandFailed", $category, $Command
            # $psCmdlet.WriteError($errRecord)
            throw $ex
        }

        $attempt++;
        Write-Host "Retrying test execution [#$attempt/$MaxAttempts] in $RetrySleepSeconds seconds..."
        Start-Sleep -s $RetrySleepSeconds
    }
}


function Run-Hook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$NodeId,

        [Parameter(Mandatory = $true)]
        [string]$HookPath
    )
    
    Write-Host "Running hook: $HookPath"
    multipass.exe exec $NodeId -- sudo bash -c "(test -f $HookPath && bash $HookPath) || ls -la $HookPath"
}
