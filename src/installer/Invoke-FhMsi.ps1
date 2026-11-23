# MSI custom action: runs Install-All / Uninstall-All for the packages whose feature state changes,
# as a SYSTEM task (custom actions lack privileges DISM needs to mount images, error 1314).
# 3010 is mapped to 0; the MSI schedules the reboot itself.
param(
    [Parameter(Mandatory)][ValidateSet('Install', 'Uninstall')][string]$Action,
    [string]$Packages,
    [string]$SourcePath,
    [string]$PayloadPath,
    [string]$Claim,
    [switch]$ForeignLbfo,
    [switch]$PurgeDefaultPayload
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FeatureHeist.psm1')

$sel = @($Packages -split '[,; ]' | Where-Object { $_ })
$rc = 0
if ($ForeignLbfo) { Write-FhLog "WARNING: LBFO skipped. $(Get-FhForeignLbfoHint)" }
if ($sel) {
    if ($Action -eq 'Install') {
        $c = "& $(ConvertTo-FhArg (Join-Path $PSScriptRoot 'Install-All.ps1')) -NoReboot -Packages $($sel -join ',')"
        if ($SourcePath.Trim()) { $c += " -SourcePath $(ConvertTo-FhArg $SourcePath.Trim())" }
        if ($PayloadPath.Trim()) { $c += " -PayloadPath $(ConvertTo-FhArg $PayloadPath.Trim().TrimEnd('\'))" }
        $cl = @($Claim -split '[,; ]' | Where-Object { $_ -in 'iSCSI', 'SAS' })
        if ($cl) { $c += " -ClaimBusType $($cl -join ',')" }
    } else {
        $c = "& $(ConvertTo-FhArg (Join-Path $PSScriptRoot 'Uninstall-All.ps1')) -NoReboot -Force -Packages $($sel -join ',')"
    }
    $rc = Invoke-FhAsSystem $c 'FeatureHeist-Msi'
    "$Action $($sel -join ',') -> $rc"
}
# full uninstall: payload below the program folder and the product key go; an external payload stays.
# Packages installed by the scripts and not selected in the MSI keep their state and payload.
if ($PurgeDefaultPayload -and $rc -in 0, 3010 -and -not (Get-ChildItem HKLM:\SOFTWARE\FeatureHeist\Packages -ErrorAction SilentlyContinue)) {
    $p = Join-Path $PSScriptRoot 'payload'
    if (Test-Path $p) { Remove-Item $p -Recurse -Force }
    if (Test-Path HKLM:\SOFTWARE\FeatureHeist) { Remove-Item HKLM:\SOFTWARE\FeatureHeist -Recurse -Force }
}
if ($rc -in 0, 3010) { exit 0 }
exit $rc
