#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Extracts the LBFO driver (MsLbfoProvider) with the smallest Microsoft catalogs listing its files.
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
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1') -Force
Assert-FhAdmin
$Service = 'MsLbfoProvider'
$Files = [ordered]@{
    'MsLbfoProvider.sys'     = 'Windows\System32\drivers\MsLbfoProvider.sys'
    'MsLbfoProvider.sys.mui' = 'Windows\System32\drivers\en-US\MsLbfoProvider.sys.mui'
    'mslbfoprovider.inf'     = 'Windows\INF\mslbfoprovider.inf'
}

$src = $null; $img = $null; $hive = $null
try {
    Write-FhLog '--- Extract-Lbfo'
    if ($MountPath) { $src = $Source; $mount = $MountPath }
    else { $src = Open-FhSource $SourcePath $Index; $img = Mount-FhImage $src; $mount = $img.Path }
    $dest = New-FhPayloadDir 'lbfo' $src $PayloadPath
    foreach ($d in 'driver', 'catalogs') { New-Item -ItemType Directory -Force (Join-Path $dest $d) | Out-Null }

    foreach ($n in $Files.Keys) {
        $f = Join-Path $mount $Files[$n]
        if (-not (Test-Path $f)) {
            if ($n -like '*.mui') { Write-FhLog "Not in image, skipped: $($Files[$n])"; continue }
            throw "Not in image: $($Files[$n])"
        }
        Copy-Item $f (Join-Path $dest "driver\$n")
        $cat = Find-FhCatalog $mount $f
        Copy-Item $cat.FullName (Join-Path $dest "catalogs\$($cat.Name)") -Force
        Write-FhLog "$n -> $($cat.Name) ($($cat.Length) bytes)"
    }

    # the INF has no service section; the service comes from the component manifest
    $hive = Join-Path $env:ProgramData 'FeatureHeist\SYSTEM.copy'
    Copy-Item (Join-Path $mount 'Windows\System32\config\SYSTEM') $hive -Force
    & reg.exe load HKLM\FH_SRC_SYSTEM $hive 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot load SYSTEM hive of the image.' }
    try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("FH_SRC_SYSTEM\ControlSet001\Services\$Service")
        if (-not $k) { throw "Service $Service not in image." }
        $svc = [ordered]@{}
        try { foreach ($v in 'Type', 'Start', 'ErrorControl', 'Group', 'ImagePath', 'DisplayName', 'Description') { $svc[$v] = $k.GetValue($v, $null, 'DoNotExpandEnvironmentNames') } }
        finally { $k.Close() }
    } finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload HKLM\FH_SRC_SYSTEM 2>&1 | Out-Null
    }
    $svc | ConvertTo-Json | Set-Content (Join-Path $dest 'service.json') -Encoding UTF8
    Write-FhManifest $dest (Get-FhSourceInfo $src)
    Write-FhLog "LBFO payload: $dest"
    exit 0
} catch {
    Write-FhLog "ERROR: $($_.Exception.Message)"
    exit 1
} finally {
    if ($hive) { Remove-Item "$hive*" -Force -ErrorAction SilentlyContinue }
    if (-not $MountPath) { Dismount-FhImage $img; Close-FhSource $src }
}
