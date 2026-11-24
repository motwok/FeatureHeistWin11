#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Builds a copy of a Windows 11 ISO that installs Feature Heist at the end of Windows Setup.
.DESCRIPTION
    Extracts the packages from the Server media and adds them with the MSI to a new ISO. Setup runs
    the MSI from SetupComplete.cmd, or at the first logon when it skips SetupComplete.cmd (OEM
    product key). The client ISO stays unchanged. Uses IMAPI2 from Windows, no ADK needed.
.PARAMETER ClientIso
    Windows 11 ISO.
.PARAMETER SourcePath
    Server ISO, install.wim/esd or drive root. Its build must match the client.
.PARAMETER MsiPath
    FeatureHeist-<Version>.msi.
.PARAMETER OutputIso
    New ISO; must not exist.
.PARAMETER Packages
    Mpio, Lbfo, LbfoAdmin. Default: all.
.PARAMETER Index
    Server image index. Default: smallest image.
.PARAMETER ClaimBusType
    MSDSM automatic claim: iSCSI, SAS or None. Default: iSCSI (as in the MSI).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ClientIso,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$MsiPath,
    [Parameter(Mandatory)][string]$OutputIso,
    [string[]]$Packages, [int]$Index,
    [string[]]$ClaimBusType = 'iSCSI'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1')
$Packages = @(Split-FhList $Packages 'Mpio', 'Lbfo', 'LbfoAdmin' Packages)
if (-not $Packages) { $Packages = 'Mpio', 'Lbfo', 'LbfoAdmin' }
$ClaimBusType = @(Split-FhList $ClaimBusType 'iSCSI', 'SAS', 'None' ClaimBusType | Where-Object { $_ -ne 'None' })
Assert-FhAdmin

$stage = Join-Path (Get-FhDataDir) 'media'
$client = $null; $srv = $null; $iso = $null; $writing = $false
try {
    Write-FhLog "--- New-InstallMedia $($Packages -join ', ')"
    if ($Packages -contains 'LbfoAdmin' -and $Packages -notcontains 'Lbfo') { throw 'LbfoAdmin needs Lbfo.' }
    foreach ($f in $ClientIso, $MsiPath) { if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "File not found: $f" } }
    if (Test-Path -LiteralPath $OutputIso) { throw "Output exists: $OutputIso" }

    $client = Mount-FhIso $ClientIso
    $root = $client.Root
    foreach ($f in 'autounattend.xml', 'sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd') {
        if (Test-Path -LiteralPath (Join-Path $root $f)) { throw "The client media already contains $f." }
    }
    $img = Open-FhClientImage $root
    $srv = Open-FhSource $SourcePath $Index
    $build = $img.Build
    if ($build -ne $srv.Build) { $build = Get-FhImageBaseBuild $img }
    if ($build -ne $srv.Build) { throw "Build mismatch: client $build, Server $($srv.Build)." }
    Close-FhSource $srv
    $srv = $null

    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    $payload = New-FhMediaFiles $stage $MsiPath $Packages $ClaimBusType
    $saved = Get-FhPayloadSetting
    $a = @{ Packages = $Packages; SourcePath = $SourcePath; PayloadPath = $payload }
    if ($Index) { $a.Index = $Index }
    & (Join-Path $PSScriptRoot 'Extract-All.ps1') @a
    $rc = $LASTEXITCODE
    Restore-FhPayloadSetting $saved
    if ($rc -ne 0) { throw 'Extraction failed.' }

    Write-FhLog "Building $OutputIso"
    $iso = New-FhIsoImage $root $client.Label
    Add-FhIsoTree $iso $stage
    $writing = $true
    Save-FhIso $iso $OutputIso
    $writing = $false
    exit 0
} catch {
    Write-FhLog "ERROR: $($_.Exception.Message)"
    exit 1
} finally {
    # IMAPI2 keeps the added files open until the image object is released
    $iso = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Close-FhSource $srv
    if ($client) { Dismount-DiskImage -ImagePath $client.ImagePath | Out-Null }
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    if ($writing -and (Test-Path -LiteralPath $OutputIso)) { Remove-Item -LiteralPath $OutputIso -Force }
}
