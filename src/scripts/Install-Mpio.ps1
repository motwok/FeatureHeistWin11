#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs MPIO + MSDSM from the extracted servicing package and enables feature MultipathIo.
.PARAMETER PayloadPath
    Payload root. Default: registry, else <scripts>\payload.
.PARAMETER SourcePath
    Server media; extracts first if no payload for this build exists.
.PARAMETER Index
    Image index for the extraction.
.PARAMETER ClaimBusType
    MSDSM automatic claim: iSCSI, SAS.
.PARAMETER RestoreSessions
    Reconnect the iSCSI sessions saved by Watch-All after the reboot.
.PARAMETER NoReboot
    Exit 3010 instead of rebooting.
.NOTES
    Exit codes: 0, 3010 (reboot required), 1.
#>
[CmdletBinding()]
param(
    [string]$PayloadPath,
    [string]$SourcePath,
    [int]$Index,
    [ValidateSet('iSCSI', 'SAS')][string[]]$ClaimBusType = @(),
    [switch]$RestoreSessions,
    [switch]$NoReboot
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1')
Assert-FhAdmin
$Task = 'FeatureHeist-MsdsmFix'

try {
    Write-FhLog '--- Install-Mpio'
    $payload = Resolve-FhPayload 'mpio' $PayloadPath $SourcePath $Index 'Extract-Mpio.ps1'
    Install-FhCbsPackage $payload | Out-Null
    Write-FhLog 'dism /enable-feature MultipathIo'
    Invoke-FhDism @('/enable-feature', '/featurename:MultipathIo') | Out-Null
    if ((Get-WindowsOptionalFeature -Online -FeatureName MultipathIo).State -notin 'Enabled', 'EnablePending') { throw 'Feature MultipathIo not enabled.' }

    foreach ($b in $ClaimBusType) {
        try { Import-Module MPIO -ErrorAction Stop; Enable-MSDSMAutomaticClaim -BusType $b -ErrorAction Stop | Out-Null; Write-FhLog "MSDSM claim: $b" }
        catch { Write-FhLog "WARNING: MSDSM claim $b failed, repeat after reboot: $($_.Exception.Message)" }
    }

    # MSDSM fails to start on the first boot after installation (code 37); restart the device once.
    $fix = Join-Path (Get-FhDataDir) 'MsdsmFix.ps1'
    @"
Start-Sleep 20
foreach (`$d in Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { `$_.HardwareID -contains 'ROOT\MSDSM' }) {
    `$c = (Get-PnpDeviceProperty -InstanceId `$d.InstanceId -KeyName DEVPKEY_Device_ProblemCode).Data
    if (`$c -ne 0) { & pnputil.exe /restart-device `$d.InstanceId | Out-Null }
    else { Unregister-ScheduledTask -TaskName '$Task' -Confirm:`$false -ErrorAction SilentlyContinue }
}
"@ | Set-Content $fix -Encoding ASCII
    Register-ScheduledTask -TaskName $Task -Force `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$fix`"") `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest) | Out-Null

    $m = Get-Content (Join-Path $payload 'manifest.json') -Raw | ConvertFrom-Json
    Set-FhState 'mpio' ([ordered]@{ Source = $m.Source; Installed = (Get-Date).ToString('s'); Claim = $ClaimBusType })
    Register-FhWatch
    # sessions only once MSDSM is active, i.e. after the reboot (Watch-All)
    if ($RestoreSessions) { New-Item -ItemType File -Force (Join-Path (Get-FhBackupDir) 'iscsi.pending') | Out-Null }
    Write-FhLog 'MPIO installed.'
    exit (Complete-FhRun $true -NoReboot:$NoReboot)
} catch {
    Write-FhLog "ERROR: $($_.Exception.Message)"
    exit 1
}
