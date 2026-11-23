#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Extracts the selected packages with a single image mount.
.PARAMETER Packages
    Mpio, Lbfo, LbfoAdmin. Default: all.
.PARAMETER SourcePath
    Server ISO, install.wim/esd or drive root. Default: first drive with a Server install.wim/esd.
.PARAMETER Index
    Image index. Default: smallest image.
.PARAMETER PayloadPath
    Payload root. Default: registry, else <scripts>\payload.
#>
[CmdletBinding()]
param(
    [ValidateSet('Mpio', 'Lbfo', 'LbfoAdmin')][string[]]$Packages = @('Mpio', 'Lbfo', 'LbfoAdmin'),
    [string]$SourcePath, [int]$Index, [string]$PayloadPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1')
Assert-FhAdmin

$src = $null; $img = $null; $rc = 0
try {
    Write-FhLog "--- Extract-All $($Packages -join ', ')"
    $src = Open-FhSource $SourcePath $Index
    $img = if ($Packages -contains 'Mpio') { Mount-FhImage $src -EnableFeature MultiPathIO } else { Mount-FhImage $src }
    foreach ($p in 'Mpio', 'Lbfo', 'LbfoAdmin' | Where-Object { $Packages -contains $_ }) {
        $a = @{ MountPath = $img.Path; Source = $src }
        if ($PayloadPath) { $a.PayloadPath = $PayloadPath }
        & (Join-Path $PSScriptRoot "Extract-$p.ps1") @a
        if ($LASTEXITCODE -ne 0) { $rc = 1 }
    }
} catch {
    Write-FhLog "ERROR: $($_.Exception.Message)"
    $rc = 1
} finally {
    Dismount-FhImage $img; Close-FhSource $src
}
exit $rc
