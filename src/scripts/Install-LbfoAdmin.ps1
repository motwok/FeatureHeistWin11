#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs LbfoAdmin (NIC teaming GUI) from the extracted servicing package. Requires LBFO.
.PARAMETER PayloadPath
    Payload root. Default: registry, else <scripts>\payload.
.PARAMETER SourcePath
    Server media; extracts first if no payload for this build exists.
.PARAMETER Index
    Image index for the extraction.
.PARAMETER NoReboot
    Exit 3010 instead of rebooting.
.NOTES
    Exit codes: 0, 3010 (reboot required), 1.
#>
[CmdletBinding()]
param([string]$PayloadPath, [string]$SourcePath, [int]$Index, [switch]$NoReboot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1')
Assert-FhAdmin

try {
    Write-FhLog '--- Install-LbfoAdmin'
    if (-not (Get-FhState 'lbfo')) { throw 'LBFO is not installed; run Install-Lbfo.ps1 first.' }
    $payload = Resolve-FhPayload 'lbfoadmin' $PayloadPath $SourcePath $Index 'Extract-LbfoAdmin.ps1'
    $reboot = Install-FhCbsPackage $payload
    $m = Get-Content (Join-Path $payload 'manifest.json') -Raw | ConvertFrom-Json
    Set-FhState 'lbfoadmin' ([ordered]@{ Source = $m.Source; Installed = (Get-Date).ToString('s') })
    Register-FhWatch
    Write-FhLog 'LbfoAdmin installed.'
    exit (Complete-FhRun $reboot -NoReboot:$NoReboot)
} catch {
    Write-FhLog "ERROR: $($_.Exception.Message)"
    exit 1
}
