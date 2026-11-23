#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the LBFO driver (NIC teaming): catalogs, driver, service, NetCfg component ms_lbfo.
.PARAMETER PayloadPath
    Payload root. Default: registry, else <scripts>\payload.
.PARAMETER SourcePath
    Server media; extracts first if no payload for this build exists.
.PARAMETER Index
    Image index for the extraction.
.PARAMETER RestoreTeams
    Recreate the NIC teams saved by Watch-All or Migrate-FromWindows11LBFO.
.PARAMETER NoReboot
    Exit 3010 instead of rebooting.
.NOTES
    Exit codes: 0, 3010 (reboot required), 1.
    The INF has no CatalogFile line, so the driver store rejects it (0xE000022F). In %windir%\INF
    it is verified against the registered catalogs like an inbox INF.
    Start type is automatic: unlike on Server nothing else loads the driver at boot.
#>
[CmdletBinding()]
param([string]$PayloadPath, [string]$SourcePath, [int]$Index, [switch]$RestoreTeams, [switch]$NoReboot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1')
Assert-FhAdmin
$Service = 'MsLbfoProvider'
$CatPrefix = 'FeatureHeist-'

$st = $null
try {
    Write-FhLog '--- Install-Lbfo'
    $owner = Get-FhLbfoOwner
    if ($owner -eq 'FeatureHeist') { Write-FhLog 'LBFO already installed.'; exit 0 }
    if ($owner) { throw (Get-FhForeignLbfoHint) }
    $payload = Resolve-FhPayload 'lbfo' $PayloadPath $SourcePath $Index 'Extract-Lbfo.ps1'
    $m = Get-Content (Join-Path $payload 'manifest.json') -Raw | ConvertFrom-Json
    $st = [ordered]@{ Source = $m.Source; Installed = (Get-Date).ToString('s'); Catalogs = @(); Files = @(); Inf = $null }

    foreach ($c in Get-ChildItem (Join-Path $payload 'catalogs') -Filter *.cat) {
        Add-FhCatalog $c.FullName "$CatPrefix$($c.Name)"
        $st.Catalogs += "$CatPrefix$($c.Name)"; Set-FhState 'lbfo' $st
    }
    $drv = Join-Path (Get-FhWindowsDir) 'System32\drivers'
    $targets = [ordered]@{ 'MsLbfoProvider.sys' = Join-Path $drv 'MsLbfoProvider.sys'; 'MsLbfoProvider.sys.mui' = Join-Path $drv 'en-US\MsLbfoProvider.sys.mui' }
    foreach ($n in $targets.Keys) {
        $f = Join-Path $payload "driver\$n"
        if (-not (Test-Path $f)) { continue }
        if (Test-Path $targets[$n]) { throw "Already exists: $($targets[$n])" }
        New-Item -ItemType Directory -Force (Split-Path $targets[$n]) | Out-Null
        Copy-Item $f $targets[$n]
        $st.Files += $targets[$n]; Set-FhState 'lbfo' $st
    }
    Assert-FhMicrosoftSignature $targets['MsLbfoProvider.sys']

    $svc = Get-Content (Join-Path $payload 'service.json') -Raw | ConvertFrom-Json
    if ([int]$svc.Type -ne 1) { throw "Unexpected service type $($svc.Type)" }
    $err = @{ 0 = 'ignore'; 1 = 'normal'; 2 = 'severe'; 3 = 'critical' }[[int]$svc.ErrorControl]
    Invoke-FhNative sc.exe @('create', $Service, 'type=', 'kernel', 'start=', 'auto', 'error=', $err, 'group=', $svc.Group, 'binPath=', $svc.ImagePath, 'DisplayName=', $svc.DisplayName) | Out-Null
    Invoke-FhNative sc.exe @('description', $Service, $svc.Description) | Out-Null
    $st.Service = $Service; Set-FhState 'lbfo' $st

    $inf = Join-Path (Get-FhWindowsDir) 'INF\mslbfoprovider.inf'
    if (Test-Path $inf) { throw "Already exists: $inf" }
    Copy-Item (Join-Path $payload 'driver\mslbfoprovider.inf') $inf
    $st.Inf = $inf; Set-FhState 'lbfo' $st
    Assert-FhMicrosoftSignature $inf

    Write-FhLog 'netcfg -c s -i ms_lbfo'
    # 0x0004A020 NETCFG_S_REBOOT
    $code = Invoke-FhNative netcfg.exe @('-c', 's', '-i', 'ms_lbfo') @(0, 0x0004A020)
    $reboot = $code -ne 0
    if (-not $reboot -and (Get-CimInstance Win32_SystemDriver -Filter "Name='$Service'").State -ne 'Running') { throw "$Service not running." }
    Register-FhWatch
    Write-FhLog 'LBFO installed.'
    if ($RestoreTeams -and -not $reboot) { Restore-FhTeams }
    exit (Complete-FhRun $reboot -NoReboot:$NoReboot)
} catch {
    Write-FhLog "ERROR: $($_.Exception.Message)"
    if ($st) { Write-FhLog 'Partial installation; run Uninstall-Lbfo.ps1.' }
    exit 1
}
