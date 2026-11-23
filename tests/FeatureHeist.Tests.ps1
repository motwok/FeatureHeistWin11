#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\scripts\FeatureHeist.psm1') -Force
}

Describe 'Manifest' {
    BeforeEach {
        $script:d = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force (Join-Path $d 'sub') | Out-Null
        Set-Content (Join-Path $d 'a.txt') 'a'
        Set-Content (Join-Path $d 'sub\b.txt') 'b'
        Write-FhManifest $d ([ordered]@{ Image = 'X'; Version = '10.0.26100.1' })
    }
    It 'lists every file with its hash' {
        $j = Get-Content (Join-Path $d 'manifest.json') -Raw | ConvertFrom-Json
        @($j.Files).Count | Should -Be 2
        ($j.Files | Where-Object Path -eq 'sub\b.txt').Sha256 | Should -Be (Get-FileHash (Join-Path $d 'sub\b.txt')).Hash
    }
    It 'accepts an unchanged payload' {
        (Test-FhManifest $d).Source.Image | Should -Be 'X'
    }
    It 'rejects a modified file' {
        Add-Content (Join-Path $d 'a.txt') 'x'
        { Test-FhManifest $d } | Should -Throw '*modified*'
    }
    It 'rejects a missing file' {
        Remove-Item (Join-Path $d 'sub\b.txt')
        { Test-FhManifest $d } | Should -Throw '*missing*'
    }
}

Describe 'Payload location' {
    It 'prefers an explicit path' {
        Get-FhPayloadRoot 'D:\p' | Should -Be 'D:\p'
    }
    It 'finds a payload only for this base build' {
        $root = Join-Path $TestDrive 'pl'
        $d = Join-Path $root "$(Get-FhBaseBuild)\lbfo"
        New-Item -ItemType Directory -Force $d | Out-Null
        Find-FhPayload 'lbfo' $root | Should -BeNullOrEmpty
        Write-FhManifest $d @{}
        Find-FhPayload 'lbfo' $root | Should -Be $d
        Find-FhPayload 'mpio' $root | Should -BeNullOrEmpty
    }
}

Describe 'Package selection' {
    It 'picks the newest neutral package and one per language' {
        $m = Join-Path $TestDrive 'img'
        $pk = Join-Path $m 'Windows\servicing\Packages'
        New-Item -ItemType Directory -Force $pk | Out-Null
        foreach ($n in 'P~31bf3856ad364e35~amd64~~10.0.26100.1591', 'P~31bf3856ad364e35~amd64~~10.0.26100.7462',
                       'P~31bf3856ad364e35~amd64~de-DE~10.0.26100.1', 'Q~31bf3856ad364e35~amd64~~10.0.26100.9999') {
            Set-Content (Join-Path $pk "$n.mum") ''
        }
        $r = @(Get-FhPackageMums $m 'P')
        $r.Count | Should -Be 2
        ($r | Where-Object Language -eq 'neutral').Mum.BaseName | Should -Be 'P~31bf3856ad364e35~amd64~~10.0.26100.7462'
        ($r | Where-Object Language -eq 'de-DE').Mum.BaseName | Should -Be 'P~31bf3856ad364e35~amd64~de-DE~10.0.26100.1'
    }
}

Describe 'Catalog hashes' {
    It 'hashes a non-PE file flat (SHA256, SHA1)' {
        $f = Join-Path $TestDrive 'x.inf'
        Set-Content $f '[Version]' -Encoding ASCII
        $h = [FeatureHeist.Native]::CatalogHashes($f)
        ([BitConverter]::ToString($h[0]) -replace '-') | Should -Be (Get-FileHash $f -Algorithm SHA256).Hash
        ([BitConverter]::ToString($h[1]) -replace '-') | Should -Be (Get-FileHash $f -Algorithm SHA1).Hash
    }
    It 'finds a hash inside a byte array' {
        $n = [byte[]](1, 2, 3)
        [FeatureHeist.Native]::Contains([byte[]](9, 1, 2, 3, 9), @(, $n)) | Should -BeTrue
        [FeatureHeist.Native]::Contains([byte[]](9, 1, 2, 9, 3), @(, $n)) | Should -BeFalse
    }
    It 'uses the Authenticode digest for a signed PE file' {
        $f = Join-Path $env:SystemRoot 'System32\notepad.exe'
        $h = [FeatureHeist.Native]::CatalogHashes($f)
        ([BitConverter]::ToString($h[0]) -replace '-') | Should -Not -Be (Get-FileHash $f -Algorithm SHA256).Hash
        $h[0].Length | Should -Be 32
    }
}

Describe 'Reboot handling' {
    It 'returns 0 without a pending reboot' { Complete-FhRun $false | Should -Be 0 }
    It 'returns 3010 with -NoReboot' { Complete-FhRun $true -NoReboot | Should -Be 3010 }
}
