# Dot-sourced in BeforeAll: loads the module once, redirects its data folder and registry key.
$Scripts = (Resolve-Path (Join-Path $PSScriptRoot '..\src\scripts')).Path
Import-Module (Join-Path $Scripts 'FeatureHeist.psm1') -Force
$TestReg = 'HKCU:\Software\FeatureHeist.Tests'

# Fresh data folder and registry key; returns the data folder.
function Reset-FhTest {
    if (Test-Path $TestReg) { Remove-Item $TestReg -Recurse -Force }
    $d = Join-Path $TestDrive ([guid]::NewGuid())
    InModuleScope FeatureHeist -Parameters @{ d = $d; r = $TestReg } {
        param($d, $r)
        $script:DataDir = $d
        $script:LogFile = Join-Path $d 'FeatureHeist.log'
        $script:RegRoot = $r
    }
    $d
}

function Get-FhTestLog { Get-Content (Join-Path (Get-FhDataDir) 'FeatureHeist.log') -Raw }

function Invoke-FhScript {
    param([Parameter(Mandatory)][string]$Name, [hashtable]$Arguments = @{})
    $global:LASTEXITCODE = 0
    & (Join-Path $Scripts $Name) @Arguments | Out-Null
    $global:LASTEXITCODE
}

# Payload as written by Extract-*.ps1, for build 26100.
function New-FhTestPayload {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Package, [int]$ServiceType = 1)
    $d = Join-Path $Root "26100\$Package"
    New-Item -ItemType Directory -Force $d | Out-Null
    if ($Package -eq 'lbfo') {
        New-Item -ItemType Directory -Force (Join-Path $d 'driver'), (Join-Path $d 'catalogs') | Out-Null
        foreach ($n in 'MsLbfoProvider.sys', 'MsLbfoProvider.sys.mui', 'mslbfoprovider.inf') { Set-Content (Join-Path $d "driver\$n") $n }
        Set-Content (Join-Path $d 'catalogs\a.cat') 'cat'
        [ordered]@{ Type = $ServiceType; Start = 3; ErrorControl = 1; Group = 'NDIS'; ImagePath = '\SystemRoot\System32\drivers\MsLbfoProvider.sys'; DisplayName = 'LBFO'; Description = 'LBFO' } |
            ConvertTo-Json | Set-Content (Join-Path $d 'service.json')
    } else {
        New-Item -ItemType Directory -Force (Join-Path $d 'neutral') | Out-Null
        Set-Content (Join-Path $d 'neutral\update.mum') 'mum'
    }
    Write-FhManifest $d ([ordered]@{ Image = 'Windows Server 2025 Standard'; Version = '10.0.26100.1742' })
    $d
}

# Registry hive file built from a scratch key under HKCU (reg save needs administrator rights).
function New-FhTestHive {
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][scriptblock]$Fill)
    $k = 'HKCU:\Software\FeatureHeist.Hive'
    if (Test-Path $k) { Remove-Item $k -Recurse -Force }
    New-Item $k -Force | Out-Null
    try {
        & $Fill $k
        & reg.exe save 'HKCU\Software\FeatureHeist.Hive' $File /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'reg save failed' }
    } finally { Remove-Item $k -Recurse -Force }
}
