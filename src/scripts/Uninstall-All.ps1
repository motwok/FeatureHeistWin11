#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the selected packages (LbfoAdmin, LBFO, MPIO) and reboots once.
.PARAMETER Packages
    Mpio, Lbfo, LbfoAdmin. Default: all. Removing Lbfo also removes LbfoAdmin.
.PARAMETER Force
    Remove NIC teams; continue although MPIO claims disks.
.PARAMETER NoReboot
    Exit 3010 instead of rebooting.
.NOTES
    Exit codes: 0, 3010 (reboot required), 1.
#>
[CmdletBinding()]
param(
    [string[]]$Packages,
    [switch]$Force, [switch]$NoReboot
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1')
$Packages = @(Split-FhList $Packages 'Mpio', 'Lbfo', 'LbfoAdmin' Packages)
if (-not $Packages) { $Packages = 'Mpio', 'Lbfo', 'LbfoAdmin' }
Assert-FhAdmin

$sel = @('LbfoAdmin', 'Lbfo', 'Mpio' | Where-Object { $Packages -contains $_ })
Write-FhLog "--- Uninstall-All $($sel -join ', ')"
# check blockers first, so that nothing is removed when one package would refuse
if (-not $Force) {
    $why = @()
    if ($sel -contains 'Lbfo' -and @(Get-NetLbfoTeam -ErrorAction SilentlyContinue).Count) { $why += 'NIC teams exist' }
    if ($sel -contains 'Mpio') {
        try { if (@(Get-CimInstance -Namespace root\wmi -ClassName MPIO_DISK_INFO -ErrorAction Stop | ForEach-Object DriveInfo | Where-Object { $_ }).Count) { $why += 'MPIO claims disks' } } catch {}
    }
    if ($why) { Write-FhLog "ERROR: $($why -join ', '). Nothing removed; use -Force."; exit 1 }
}
$reboot = $false
foreach ($p in $sel) {
    $a = @{ NoReboot = $true }
    if ($Force -and $p -ne 'LbfoAdmin') { $a.Force = $true }
    & (Join-Path $PSScriptRoot "Uninstall-$p.ps1") @a
    if ($LASTEXITCODE -eq 3010) { $reboot = $true }
    elseif ($LASTEXITCODE -ne 0) { Write-FhLog "ERROR: Uninstall-$p failed."; exit 1 }
}
exit (Complete-FhRun $reboot -NoReboot:$NoReboot)
