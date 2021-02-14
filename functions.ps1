function Test-IsElevated() {
    if (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
        Write-Error "Run this as admin ;)"
        Exit 1
    }
}

# source: https://stackoverflow.com/questions/8333455/how-to-loop-in-powershell-until-successful
function Invoke-CommandWithRetries {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory = $True)]
        [string]$Command,
        [Array]$Arguments,
        [int]$RetrySleepSeconds = 10,
        [int]$MaxAttempts = 10,
        [bool]$ShowCommandOutput = $true
    )

    Process {
        $attempt = 0            
        Write-Verbose "Executing command ($MaxAttempts attempts): $Command $Arguments"
        while ($true) {   
            
            & $Command $Arguments 2>&1 | 
            Tee-Object -Variable output | 
            Where-Object { $ShowCommandOutput -eq $true } | 
            Write-Host

            $stderr = $output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
            if ( ($LASTEXITCODE -eq 0) ) {
                Write-Verbose "Command executed successfully"
                return
            }

            Write-Verbose "Command failed with exit code ($LASTEXITCODE) and stderr: $stderr"
            if ($attempt -eq $MaxAttempts) {
                throw "All retry attempts exhausted"
            }

            $attempt++;
            Write-Verbose "Retrying in $RetrySleepSeconds seconds... [#$attempt/$MaxAttempts] "
            Start-Sleep -s $RetrySleepSeconds
        }
    }
}

function Wait-For-Node-Ready {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory = $true)]
        [string]$Node,
        [int]$RetrySleepSeconds = 15,
        [int]$MaxAttempts = 10
    )
 
    Write-Host "Waiting for $Node to be ready"
    Invoke-CommandWithRetries `
        -Command "multipass.exe" `
        -Arguments @("exec", "$Node", "--", "exit" ) `
        -RetrySleepSeconds $RetrySleepSeconds `
        -MaxAttempts $MaxAttempts `
        -ShowCommandOutput $false
}

function Wait-For-CloudInit-Completion {
    [CmdletBinding()]
    param( 
        [Parameter(Mandatory = $true)]
        [string]$Node,
        [int]$RetrySleepSeconds = 15,
        [int]$MaxAttempts = 10
    )

    $attempt = 0
    Write-Host "Waiting for Cloud-init completion"
    while ($true) {   
        # <https://stackoverflow.com/questions/33019093/how-do-detect-that-cloud-init-completed-initialization>
        Write-Verbose "Checking /run/cloud-init/result.json"

        multipass.exe exec $Node -- test -f /run/cloud-init/result.json
        if ($LASTEXITCODE -eq 0) {
            Write-Verbose "Result file found: /run/cloud-init/result.json"
            $result_raw = multipass.exe exec $Node -- cat /run/cloud-init/result.json
            Write-Verbose "Cloud-init result:`r`n$result_raw"
            $json = $result_raw | ConvertFrom-Json

            # TODO: This branching is all guess-work
            if ($json.v1) {
                if ($json.v1.errors.length -eq 0) {
                    Write-Host "Cloud-init completed"
                    return
                }
                else {
                    throw "Cloud-init errors detected"
                }
            }
        }
        else {
            Write-Verbose "Result file doesn't yet exist: /run/cloud-init/result.json"
        }
        
        Write-Verbose "Cloud-init not completed"
        if ($attempt -eq $MaxAttempts) {
            $ex = new-object System.Management.Automation.CmdletInvocationException "All retry attempts exhausted"
            throw $ex
        }

        $attempt++;
        Write-Verbose "Retrying test execution [#$attempt/$MaxAttempts] in $RetrySleepSeconds seconds..."
        Start-Sleep -s $RetrySleepSeconds
    }
}

function Invoke-ProvisionHook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Node,

        [Parameter(Mandatory = $true)]
        [object]$HooksSpec,

        [Parameter(Mandatory = $true)]
        [string]$HookName,

        [Parameter(Mandatory = $false)]
        [switch]$Throw = $false
    )

    $HookPath = $HooksSpec[$HookName]
    if ($HookPath) {
        Write-Host "Running hook: $HookPath"
        multipass.exe exec $Node -- sudo bash -c "test -f $HookPath && chmod +x $HookPath && $HookPath 2>&1 | tee $HookName.log"
        if ($Throw -and -not $?) {
            throw "There was a problem running hook $HookName, which resolved to path: $HookPath. Please review necessary logs and any output that immediately preceding this message."
        }

        return $?
    }
    else {
        Write-Verbose "No hook defined for $HookName"
        return $true
    }
}
