#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Disables MultipathIo and removes the MPIO servicing packages.
.PARAMETER Force
    Continue although MPIO claims disks. Leave only one path per LUN connected, or the LUN
    appears once per path after the reboot.
.PARAMETER NoReboot
    Exit 3010 instead of rebooting.
.NOTES
    Exit codes: 0, 3010 (reboot required), 1.
#>
[CmdletBinding()]
param([switch]$Force, [switch]$NoReboot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1') -Force
Assert-FhAdmin
$Package = 'Microsoft-Windows-MultipathIo-Package'
$Task = 'FeatureHeist-MsdsmFix'

try {
    Write-FhLog '--- Uninstall-Mpio'
    if (-not (Get-WindowsPackage -Online | Where-Object { $_.PackageName -like "$Package~*" -and $_.PackageState -ne 'Absent' })) {
        Write-FhLog 'MPIO not installed.'
        Remove-FhState 'mpio'
        exit 0
    }
    $disks = @()
    try { $disks = @(Get-CimInstance -Namespace root\wmi -ClassName MPIO_DISK_INFO -ErrorAction Stop | ForEach-Object DriveInfo | Where-Object { $_ }) } catch {}
    if ($disks.Count) {
        if (-not $Force) { throw "MPIO claims $($disks.Count) disk(s). Disconnect the paths or use -Force." }
        Write-FhLog "WARNING: -Force with $($disks.Count) MPIO disk(s)."
    }
    if (Get-Command Disable-MSDSMAutomaticClaim -ErrorAction SilentlyContinue) {
        foreach ($b in 'iSCSI', 'SAS') { try { Disable-MSDSMAutomaticClaim -BusType $b -ErrorAction Stop | Out-Null } catch {} }
    }
    $f = Get-WindowsOptionalFeature -Online -FeatureName MultipathIo -ErrorAction SilentlyContinue
    if ($f -and $f.State -ne 'Disabled') {
        Write-FhLog 'dism /disable-feature MultipathIo'
        Invoke-FhDism @('/disable-feature', '/featurename:MultipathIo') | Out-Null
    }
    Uninstall-FhCbsPackage $Package | Out-Null
    Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
    Remove-FhFile (Join-Path $env:ProgramData 'FeatureHeist\MsdsmFix.ps1')
    Remove-FhState 'mpio'
    Unregister-FhWatch
    Write-FhLog 'MPIO removed.'
    exit (Complete-FhRun $true -NoReboot:$NoReboot)
} catch {
    Write-FhLog "ERROR: $($_.Exception.Message)"
    exit 1
}
