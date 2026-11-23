#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Checks after boot and Windows updates that the installed packages are still active.
.DESCRIPTION
    Run by task FeatureHeist-Watch. Active: saves NIC teams and iSCSI sessions. Missing: event log
    warning (source FeatureHeist), message to signed-in users, and without MPIO only one iSCSI
    session per target is kept. Reinstall with Install-All.ps1 (-RestoreTeams, -RestoreSessions).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1')

function Test-Active([string]$p) {
    switch ($p) {
        'mpio' { (Get-WindowsOptionalFeature -Online -FeatureName MultipathIo -ErrorAction SilentlyContinue).State -eq 'Enabled' -and (Get-CimInstance Win32_SystemDriver -Filter "Name='msdsm'") }
        'lbfo' { (Get-CimInstance Win32_SystemDriver -Filter "Name='MsLbfoProvider'").State -eq 'Running' }
        'lbfoadmin' { [bool](Get-WindowsPackage -Online | Where-Object { $_.PackageName -like 'Microsoft-Windows-NDIS-LBFO-Admin-RSAT-Group-Package~*~~*' -and $_.PackageState -eq 'Installed' }) }
    }
}

try {
    $missing = @()
    foreach ($p in 'mpio', 'lbfo', 'lbfoadmin') {
        if ((Get-FhState $p) -and -not (Test-Active $p)) { $missing += $p }
    }
    if (-not $missing) {
        $pending = Join-Path (Get-FhBackupDir) 'iscsi.pending'
        if ((Get-FhState 'mpio') -and (Test-Path $pending)) { Restore-FhIscsiSessions; Remove-Item $pending -Force }
        if (Get-FhState 'lbfo') { Save-FhTeams }
        if (Get-FhState 'mpio') { Save-FhIscsiSessions }
        exit 0
    }
    if ($missing -contains 'mpio') { Limit-FhIscsiSessions }
    $payload = @($missing | Where-Object { Find-FhPayload $_ })
    $how = if ($payload.Count -eq $missing.Count) { 'Reinstall: Install-All.ps1 -RestoreTeams -RestoreSessions, or MSI repair.' }
           else { "No extracted files for build $(Get-FhBaseBuild); Windows Server media of this build is needed." }
    $msg = "Feature Heist: $($missing -join ', ') no longer active (build $(Get-FhBaseBuild)). $how"
    Write-FhLog "WARNING: $msg"
    Write-EventLog -LogName Application -Source FeatureHeist -EventId 100 -EntryType Warning -Message $msg -ErrorAction SilentlyContinue
    & msg.exe * /TIME:0 $msg 2>$null
    exit 0
} catch {
    Write-FhLog "ERROR: Watch-All: $($_.Exception.Message)"
    exit 1
}
