#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Adds MPIO and LbfoAdmin language packs from the Windows Server "Languages and Optional Features" media
    to the payloads extracted from a Server ISO (run Extract-All or Extract-Mpio/-LbfoAdmin first).
.PARAMETER SourcePath
    Languages and Optional Features ISO, its drive root or folder, or one Server language pack CAB.
.PARAMETER Language
    Language codes, e.g. de-DE, fr-FR. Default: all on the media.
.PARAMETER PayloadPath
    Payload root. Default: registry, else <scripts>\payload.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourcePath, [string[]]$Language, [string]$PayloadPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1')
Assert-FhAdmin
$Packages = [ordered]@{ mpio = 'Microsoft-Windows-MultipathIo-Package'; lbfoadmin = 'Microsoft-Windows-NDIS-LBFO-Admin-RSAT-Group-Package' }

$src = $null
$tmp = Join-Path (Get-FhDataDir) 'langpack'
try {
    Write-FhLog '--- Extract-Languages'
    $root = Get-FhPayloadRoot $PayloadPath
    $src = Open-FhLanguageSource $SourcePath $Language
    $done = [ordered]@{}
    foreach ($cab in $src.Cabs) {
        Write-FhLog "Expanding $($cab.Name)"
        Expand-FhCab $cab.FullName $tmp
        foreach ($p in $Packages.Keys) {
            $mum = Get-ChildItem $tmp -Filter "$($Packages[$p])~*.mum" | Select-Object -First 1
            if (-not $mum) { continue }
            $build = ([version](($mum.BaseName -split '~')[-1])).Build
            $dest = Join-Path (Join-Path $root $build) $p
            if (-not (Test-Path (Join-Path $dest 'manifest.json'))) { Write-FhLog "No $p payload for build $build; extract it from the Server ISO first."; continue }
            if (-not $done.Contains($dest)) { $null = Test-FhManifest $dest; $done[$dest] = New-Object System.Collections.ArrayList }
            [void]$done[$dest].Add((Export-FhLanguagePackage $tmp $Packages[$p] $dest))
        }
    }
    if (-not $done.Count) { throw 'No language pack added.' }
    foreach ($d in $done.Keys) {
        Write-FhManifest $d (Get-Content (Join-Path $d 'manifest.json') -Raw | ConvertFrom-Json).Source
        Write-FhLog "Language packs in ${d}: $($done[$d] -join ', ')"
    }
    exit 0
} catch {
    Write-FhLog "ERROR: $($_.Exception.Message)"
    exit 1
} finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Close-FhSource $src
}
