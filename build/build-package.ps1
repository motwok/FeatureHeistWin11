# Builds the release assets into -Out:
#   FeatureHeist-<Version>-scripts.zip  src\scripts, README, LICENSE, NOTICE
#   FeatureHeist-<Version>.msi          everything needed to install, once src\installer\FeatureHeist.wxs exists
# tools\ (migration script) is repo-only and goes into neither asset.
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$Out = 'dist'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid version: $Version" }
if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
New-Item -ItemType Directory -Force $Out | Out-Null
$scripts = Join-Path $root 'src\scripts'

$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$stage = Join-Path $tmp "featureheist-$Version"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item $scripts (Join-Path $stage 'scripts') -Recurse
Copy-Item README.md, LICENSE, NOTICE $stage
$zip = Join-Path $Out "FeatureHeist-$Version-scripts.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item $stage -Recurse -Force

# smoke test: every script, nothing from tools\, no Microsoft binary
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $zip))
try {
    $names = $z.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }
    foreach ($s in Get-ChildItem $scripts -Recurse -File) {
        $rel = 'scripts/' + ($s.FullName.Substring($scripts.Length + 1) -replace '\\', '/')
        if ($names -notcontains $rel) { throw "missing in archive: $rel" }
    }
    $repoOnly = Get-ChildItem tools -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object Name
    $leak = $names | Where-Object { $repoOnly -contains (Split-Path $_ -Leaf) }
    if ($leak) { throw "repo-only file in archive: $($leak -join ', ')" }
    $bad = $names | Where-Object { $_ -match '\.(sys|cat|mum|cab|wim|esd|iso|dll|exe)$' }
    if ($bad) { throw "binary in archive: $($bad -join ', ')" }
} finally { $z.Dispose() }
"built $zip"

# --- MSI: one build per culture; non-base cultures become embedded language transforms
$wxs = 'src\installer\FeatureHeist.wxs'
if (-not (Test-Path $wxs)) { 'no MSI source, MSI skipped'; return }
$wixVersion = '7.0.1'
$ext = 'WixToolset.Util.wixext', 'WixToolset.UI.wixext'
# native tools write progress to stderr; with 'Stop' Windows PowerShell treats that as an error
function Invoke-Exe([string]$exe, [string[]]$a) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $exe @a 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $eap }
    if ($LASTEXITCODE -ne 0) { throw "$exe $($a -join ' ') failed: exit $LASTEXITCODE" }
}
if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    Invoke-Exe dotnet @('tool', 'install', '--global', 'wix', '--version', $wixVersion)
    $env:PATH += ";$env:USERPROFILE\.dotnet\tools"
}
foreach ($e in $ext) { Invoke-Exe wix @('extension', 'add', '-acceptEula', 'wix7', '-g', "$e/$wixVersion") }

# late-bound Windows Installer COM; PSObject wrappers must not reach InvokeMember (DISP_E_TYPEMISMATCH)
function Invoke-Com($o, [string]$m, [string]$kind, [object[]]$a = @()) {
    $a = @($a | ForEach-Object { if ($_ -is [psobject]) { $_.PSObject.BaseObject } else { $_ } })
    [System.__ComObject].InvokeMember($m, $kind, $null, $o, $a)
}
# database handles must be closed before the MSI can be reopened for writing
function Close-Com { foreach ($o in $args) { if ($o) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($o) } }; [gc]::Collect(); [gc]::WaitForPendingFinalizers() }

$cultures = @(Get-ChildItem src\installer -Filter *.wxl | ForEach-Object BaseName | Sort-Object { $_ -ne 'en-US' })
$work = Join-Path $tmp "featureheist-msi-$Version"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force $work | Out-Null
$lcid = @{}
# one product code for all cultures; a language transform must not change it
$productCode = [guid]::NewGuid().ToString('B').ToUpper()
# WixUI has no own strings for these; its dialogs fall back to the parent language
$uiFallback = @{ 'en-GB' = 'en-US'; 'es-MX' = 'es-ES'; 'fr-CA' = 'fr-FR'; 'sr-Latn-RS' = 'sr-Latn-CS' }
foreach ($c in $cultures) {
    $o = Join-Path $work "$c.msi"
    $a = @('build', '-acceptEula', 'wix7', $wxs, '-arch', 'x64', '-culture', $c, '-loc', "src\installer\$c.wxl",
        '-d', "Version=$Version", '-d', "ProductCode=$productCode", '-d', "Scripts=$scripts", '-o', $o)
    if ($uiFallback[$c]) { $a += '-culture', $uiFallback[$c] }
    foreach ($e in $ext) { $a += '-ext', $e }
    Invoke-Exe wix $a
    $lcid[$c] = ([xml](Get-Content "src\installer\$c.wxl" -Raw)).WixLocalization.String | Where-Object Id -eq 'Lcid' | ForEach-Object Value
}
$msi = Join-Path $Out "FeatureHeist-$Version.msi"
Copy-Item (Join-Path $work "$($cultures[0]).msi") $msi

$wi = New-Object -ComObject WindowsInstaller.Installer
foreach ($c in $cultures | Select-Object -Skip 1) {
    $mst = Join-Path $work "$c.mst"
    $base = Invoke-Com $wi OpenDatabase InvokeMethod @($msi, 0)
    $loc = Invoke-Com $wi OpenDatabase InvokeMethod @((Join-Path $work "$c.msi"), 0)
    [void](Invoke-Com $loc GenerateTransform InvokeMethod @($base, $mst))
    [void](Invoke-Com $loc CreateTransformSummaryInfo InvokeMethod @($base, $mst, 0, 0))
    Close-Com $base $loc
    $db = Invoke-Com $wi OpenDatabase InvokeMethod @($msi, 1)
    $view = Invoke-Com $db OpenView InvokeMethod @('INSERT INTO `_Storages` (`Name`, `Data`) VALUES (?, ?)')
    $rec = Invoke-Com $wi CreateRecord InvokeMethod @(2)
    Invoke-Com $rec StringData SetProperty @(1, $lcid[$c]) | Out-Null
    Invoke-Com $rec SetStream InvokeMethod @(2, $mst) | Out-Null
    Invoke-Com $view Execute InvokeMethod @($rec) | Out-Null
    Invoke-Com $view Close InvokeMethod | Out-Null
    Invoke-Com $db Commit InvokeMethod | Out-Null
    Close-Com $rec $view $db
}
# Template: platform;languages - Windows Installer applies the transform of the user's language
$db = Invoke-Com $wi OpenDatabase InvokeMethod @($msi, 1)
$si = Invoke-Com $db SummaryInformation GetProperty @(1)
Invoke-Com $si Property SetProperty @(7, "x64;$(($cultures | ForEach-Object { $lcid[$_] }) -join ',')") | Out-Null
Invoke-Com $si Persist InvokeMethod | Out-Null
Invoke-Com $db Commit InvokeMethod | Out-Null
Close-Com $si $db $wi
Remove-Item $work -Recurse -Force
"built $msi ($($cultures -join ', '))"
