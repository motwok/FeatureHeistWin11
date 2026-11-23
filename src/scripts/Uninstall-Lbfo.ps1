#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the LBFO driver installed by Install-Lbfo.ps1.
.PARAMETER Force
    Remove existing NIC teams first (network interruption).
.PARAMETER NoReboot
    Exit 3010 instead of rebooting.
.NOTES
    Exit codes: 0, 3010 (reboot required), 1. LbfoAdmin is removed first if installed.
#>
[CmdletBinding()]
param([switch]$Force, [switch]$NoReboot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1') -Force
Assert-FhAdmin
$NetService = 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\{4D36E974-E325-11CE-BFC1-08002BE10318}'

try {
    Write-FhLog '--- Uninstall-Lbfo'
    $st = Get-FhState 'lbfo'
    if (-not $st) { Write-FhLog 'LBFO not installed by Feature Heist.'; exit 0 }
    $teams = @(Get-NetLbfoTeam -ErrorAction SilentlyContinue)
    if ($teams.Count) {
        if (-not $Force) { throw "NIC teams exist ($($teams.Name -join ', ')). Remove them or use -Force." }
        foreach ($t in $teams) { Remove-NetLbfoTeam -Name $t.Name -Confirm:$false; Write-FhLog "Team removed: $($t.Name)" }
    }
    if (Get-FhState 'lbfoadmin') {
        & (Join-Path $PSScriptRoot 'Uninstall-LbfoAdmin.ps1') -NoReboot
        if ($LASTEXITCODE -notin 0, 3010) { throw 'Uninstall-LbfoAdmin failed.' }
    }
    if (Get-ChildItem $NetService -ErrorAction SilentlyContinue | Where-Object { (Get-ItemProperty $_.PSPath).PSObject.Properties['ComponentId'] -and (Get-ItemProperty $_.PSPath).ComponentId -eq 'ms_lbfo' }) {
        Write-FhLog 'netcfg -u ms_lbfo'
        Invoke-FhNative netcfg.exe @('-u', 'ms_lbfo') @(0, 0x0004A020) | Out-Null
    }
    if ($st.Inf) { Remove-FhFile $st.Inf; Remove-FhFile ([IO.Path]::ChangeExtension($st.Inf, '.pnf')) }
    if ($st.PSObject.Properties['Service'] -and $st.Service -and (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($st.Service)")) {
        Invoke-FhNative sc.exe @('stop', $st.Service) @(0, 1052, 1062) | Out-Null
        Invoke-FhNative sc.exe @('delete', $st.Service) @(0, 1072) | Out-Null
        Write-FhLog "Service deleted: $($st.Service)"
    }
    foreach ($f in @($st.Files)) { Remove-FhFile $f }
    foreach ($c in @($st.Catalogs)) { Remove-FhCatalog $c }
    Remove-FhState 'lbfo'
    Unregister-FhWatch
    Write-FhLog 'LBFO removed.'
    exit (Complete-FhRun $true -NoReboot:$NoReboot)
} catch {
    Write-FhLog "ERROR: $($_.Exception.Message)"
    exit 1
}
