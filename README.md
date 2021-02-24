# ubuntu stamp

Provision Ubuntu VMs in Hyper-V from templates.

A thin wrapper for Multipass using Powershell, held together by duct-tape, baling-wire and spit.

---

## Pre-requisites
- Install Multipass 1.6+
  - `1.6` is the first version to support the `--network` option, which allowed me to delete hundreds of lines of fragile code
- Set `MULTIPASS_STORAGE` to define a custom storage drive:
  - <https://github.com/canonical/multipass/pull/1789#issuecomment-705403501>
    ```ps1
    # In Administrator's PowerShell
    PS> Stop-Service Multipass
    PS> Set-ItemProperty -Path "HKLM:System\CurrentControlSet\Control\Session Manager\Environment" -Name MULTIPASS_STORAGE -Value "<path>"
    PS> Start-Service Multipass
    ```
- (Optional) Create an External Switch in Hyper-V
  - I used to script this. The code was fragile and ridiculous to maintain when I would run it only once. 

## spec.yaml
TODO

## Hooks
TODO
