#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Extracts the MPIO servicing package (neutral + language packs) from Windows Server media.
.PARAMETER SourcePath
    Server ISO, install.wim/esd or drive root. Default: first drive with a Server install.wim/esd.
.PARAMETER Index
    Image index. Default: smallest image.
.PARAMETER PayloadPath
    Payload root. Default: registry, else <scripts>\payload.
.PARAMETER MountPath
    Already mounted writable image with MultiPathIO enabled, with -Source (used by Extract-All).
#>
[CmdletBinding()]
param([string]$SourcePath, [int]$Index, [string]$PayloadPath, [string]$MountPath, [object]$Source)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1') -Force
Assert-FhAdmin
$Package = 'Microsoft-Windows-MultipathIo-Package'

$src = $null; $img = $null
try {
    Write-FhLog '--- Extract-Mpio'
    if ($MountPath) {
        $src = $Source
        $mount = $MountPath
    } else {
        $src = Open-FhSource $SourcePath $Index
        $img = Mount-FhImage $src -EnableFeature MultiPathIO
        $mount = $img.Path
    }
    $mums = @(Get-FhPackageMums $mount $Package)
    if (-not ($mums | Where-Object Language -eq 'neutral')) { throw "$Package not found in the image." }
    $dest = New-FhPayloadDir 'mpio' $src $PayloadPath
    Export-FhCbsPackage $mount ($mums | ForEach-Object Mum) $dest
    Write-FhManifest $dest (Get-FhSourceInfo $src)
    Write-FhLog "MPIO payload: $dest ($(($mums | ForEach-Object Language) -join ', '))"
    exit 0
} catch {
    Write-FhLog "ERROR: $($_.Exception.Message)"
    exit 1
} finally {
    if (-not $MountPath) { Dismount-FhImage $img; Close-FhSource $src }
}
