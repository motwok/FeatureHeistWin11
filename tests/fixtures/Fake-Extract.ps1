# Stand-in for Extract-*.ps1 in Resolve-FhPayload tests: 'ok' writes an empty 'fake' payload.
param([string]$SourcePath, [string]$PayloadPath, [int]$Index)
if ($SourcePath -ne 'ok') { exit 1 }
$d = Join-Path $PayloadPath "$(Get-FhBaseBuild)\fake"
New-Item -ItemType Directory -Force $d | Out-Null
'{"Source":{"Index":' + $Index + '},"Files":[]}' | Set-Content (Join-Path $d 'manifest.json')
exit 0
