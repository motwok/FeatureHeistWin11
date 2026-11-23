#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the selected packages (MPIO, LBFO, LbfoAdmin) and reboots once.
.PARAMETER Packages
    Mpio, Lbfo, LbfoAdmin. Default: all. LbfoAdmin requires Lbfo.
.PARAMETER PayloadPath
    Payload root. Default: registry, else <scripts>\payload.
.PARAMETER SourcePath
    Server media; extracts first if no payload for this build exists.
.PARAMETER Index
    Image index for the extraction.
.PARAMETER ClaimBusType
    MSDSM automatic claim: iSCSI, SAS.
.PARAMETER RestoreTeams
    Recreate saved NIC teams after installing LBFO.
.PARAMETER RestoreSessions
    Reconnect saved iSCSI sessions after the reboot.
.PARAMETER NoReboot
    Exit 3010 instead of rebooting.
.NOTES
    Exit codes: 0, 3010 (reboot required), 1. Stops at the first failing package.
#>
[CmdletBinding()]
param(
    [ValidateSet('Mpio', 'Lbfo', 'LbfoAdmin')][string[]]$Packages = @('Mpio', 'Lbfo', 'LbfoAdmin'),
    [string]$PayloadPath, [string]$SourcePath, [int]$Index,
    [ValidateSet('iSCSI', 'SAS')][string[]]$ClaimBusType = @(),
    [switch]$RestoreTeams, [switch]$RestoreSessions,
    [switch]$NoReboot
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1') -Force
Assert-FhAdmin

$sel = @('Mpio', 'Lbfo', 'LbfoAdmin' | Where-Object { $Packages -contains $_ })
Write-FhLog "--- Install-All $($sel -join ', ')"
if ($SourcePath) {
    $missing = @($sel | Where-Object { -not (Find-FhPayload $_.ToLower() $PayloadPath) })
    if ($missing) {
        $a = @{ Packages = $missing; SourcePath = $SourcePath }
        if ($PayloadPath) { $a.PayloadPath = $PayloadPath }
        if ($Index) { $a.Index = $Index }
        & (Join-Path $PSScriptRoot 'Extract-All.ps1') @a
        if ($LASTEXITCODE -ne 0) { exit 1 }
    }
}
$reboot = $false
foreach ($p in $sel) {
    $a = @{ NoReboot = $true }
    if ($PayloadPath) { $a.PayloadPath = $PayloadPath }
    if ($p -eq 'Mpio' -and $ClaimBusType) { $a.ClaimBusType = $ClaimBusType }
    if ($p -eq 'Mpio' -and $RestoreSessions) { $a.RestoreSessions = $true }
    if ($p -eq 'Lbfo' -and $RestoreTeams) { $a.RestoreTeams = $true }
    & (Join-Path $PSScriptRoot "Install-$p.ps1") @a
    if ($LASTEXITCODE -eq 3010) { $reboot = $true }
    elseif ($LASTEXITCODE -ne 0) { Write-FhLog "ERROR: Install-$p failed."; exit 1 }
}
exit (Complete-FhRun $reboot -NoReboot:$NoReboot)
