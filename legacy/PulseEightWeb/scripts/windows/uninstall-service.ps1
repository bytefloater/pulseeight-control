<#
.SYNOPSIS
  Stops and removes the Windows service installed by install-service.ps1.
  Run from an elevated (Administrator) PowerShell prompt.

.EXAMPLE
  .\uninstall-service.ps1

.EXAMPLE
  .\uninstall-service.ps1 -RemoveFirewallRule
#>

param(
    [string]$ServiceName = "PulseEightControl",
    [string]$NssmPath = "nssm",
    [switch]$RemoveFirewallRule
)

$ErrorActionPreference = "Stop"

& $NssmPath stop $ServiceName
& $NssmPath remove $ServiceName confirm

Write-Host "Service '$ServiceName' removed."

if ($RemoveFirewallRule) {
    if (Get-NetFirewallRule -DisplayName $ServiceName -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName $ServiceName
        Write-Host "Firewall rule '$ServiceName' removed."
    } else {
        Write-Host "No firewall rule named '$ServiceName' found; nothing to remove."
    }
}
