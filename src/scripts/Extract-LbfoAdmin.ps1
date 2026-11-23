#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Extracts the LbfoAdmin servicing package (NDIS-LBFO-Admin-RSAT-Group, neutral + language packs).
.PARAMETER SourcePath
    Server ISO, install.wim/esd or drive root. Default: first drive with a Server install.wim/esd.
.PARAMETER Index
    Image index. Default: smallest image.
.PARAMETER PayloadPath
    Payload root. Default: registry, else <scripts>\payload.
.PARAMETER MountPath
    Already mounted image, with -Source (used by Extract-All).
#>
[CmdletBinding()]
param([string]$SourcePath, [int]$Index, [string]$PayloadPath, [string]$MountPath, [object]$Source)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1')
Assert-FhAdmin
$Package = 'Microsoft-Windows-NDIS-LBFO-Admin-RSAT-Group-Package'

$src = $null; $img = $null
try {
    Write-FhLog '--- Extract-LbfoAdmin'
    if ($MountPath) { $src = $Source; $mount = $MountPath }
    else { $src = Open-FhSource $SourcePath $Index; $img = Mount-FhImage $src; $mount = $img.Path }
    $mums = @(Get-FhPackageMums $mount $Package)
    if (-not ($mums | Where-Object Language -eq 'neutral')) { throw "$Package not found in the image." }
    $dest = New-FhPayloadDir 'lbfoadmin' $src $PayloadPath
    Export-FhCbsPackage $mount ($mums | ForEach-Object Mum) $dest
    Write-FhManifest $dest (Get-FhSourceInfo $src)
    Write-FhLog "LbfoAdmin payload: $dest ($(($mums | ForEach-Object Language) -join ', '))"
    exit 0
} catch {
    Write-FhLog "ERROR: $($_.Exception.Message)"
    exit 1
} finally {
    if (-not $MountPath) { Dismount-FhImage $img; Close-FhSource $src }
}
