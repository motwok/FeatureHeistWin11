#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the LbfoAdmin servicing packages.
.PARAMETER NoReboot
    Exit 3010 instead of rebooting.
.NOTES
    Exit codes: 0, 3010 (reboot required), 1.
#>
[CmdletBinding()]
param([switch]$NoReboot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1')
Assert-FhAdmin

try {
    Write-FhLog '--- Uninstall-LbfoAdmin'
    $reboot = Uninstall-FhCbsPackage 'Microsoft-Windows-NDIS-LBFO-Admin-RSAT-Group-Package'
    Remove-FhState 'lbfoadmin'
    Unregister-FhWatch
    Write-FhLog 'LbfoAdmin removed.'
    exit (Complete-FhRun $reboot -NoReboot:$NoReboot)
} catch {
    Write-FhLog "ERROR: $($_.Exception.Message)"
    exit 1
}
