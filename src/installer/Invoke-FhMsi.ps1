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
# full uninstall: the payload below the program folder goes, an external payload stays. The product key
# goes unless packages installed by the scripts (not selected in the MSI) remain.
if ($PurgeDefaultPayload -and $rc -in 0, 3010) {
    $p = Join-Path $PSScriptRoot 'payload'
    if (Test-Path $p) { Remove-Item $p -Recurse -Force }
    $k = 'HKLM:\SOFTWARE\FeatureHeist'
    $left = @(Get-ChildItem "$k\Packages" -ErrorAction SilentlyContinue | ForEach-Object PSChildName)
    if (-not $left) {
        if (Test-Path $k) { Remove-Item $k -Recurse -Force }
    } else {
        $r = Get-ItemProperty $k -Name PayloadPath -ErrorAction SilentlyContinue
        if ($r -and $r.PayloadPath -like "$p*") { Remove-ItemProperty $k -Name PayloadPath }
        $w = Get-ScheduledTask FeatureHeist-Watch -ErrorAction SilentlyContinue
        if ($w -and "$($w.Actions.Arguments)" -like "*$PSScriptRoot*") {
            Unregister-ScheduledTask -TaskName FeatureHeist-Watch -Confirm:$false
            Write-FhLog "WARNING: FeatureHeist-Watch removed with the MSI; $($left -join ', ') remain. To monitor them again: Import-Module <scripts>\FeatureHeist.psm1; Register-FhWatch"
        }
    }
}
if ($rc -in 0, 3010) { exit 0 }
exit $rc
