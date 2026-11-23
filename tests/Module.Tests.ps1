#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }
BeforeDiscovery {
    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
AfterAll {
    if (Test-Path $TestReg) { Remove-Item $TestReg -Recurse -Force }
}

Describe 'Log and run' {
    BeforeEach { $data = Reset-FhTest }

    It 'creates the data folder and logs' {
        Write-FhLog 'hello'
        Get-FhDataDir | Should -Be $data
        Get-FhTestLog | Should -Match 'hello'
    }
    It 'logs native output' {
        Get-FhDataDir | Out-Null
        Invoke-FhNative cmd.exe @('/c', 'echo', 'native-out') | Should -Be 0
        Get-FhTestLog | Should -Match 'native-out'
    }
    It 'throws on an unexpected exit code' {
        Get-FhDataDir | Out-Null
        { Invoke-FhNative cmd.exe @('/c', 'exit', '5') } | Should -Throw '*exit 5*'
        Invoke-FhNative cmd.exe @('/c', 'exit', '5') @(0, 5) | Should -Be 5
    }
    It 'reports a DISM reboot' {
        Mock -ModuleName FeatureHeist Invoke-FhNative { 3010 }
        Invoke-FhDism @('/x') | Should -BeTrue
    }
    It 'reports no DISM reboot' {
        Mock -ModuleName FeatureHeist Invoke-FhNative { 0 }
        Invoke-FhDism @('/x') | Should -BeFalse
    }
    It 'reboots when run without -NoReboot' {
        Mock -ModuleName FeatureHeist shutdown.exe { }
        Complete-FhRun $true | Should -Be 3010
        Should -Invoke -ModuleName FeatureHeist shutdown.exe -Times 1
    }
    It 'checks the account' {
        Test-FhSystem | Should -BeFalse
        Get-FhWindowsDir | Should -Be $env:SystemRoot
        if ($IsAdmin) { { Assert-FhAdmin } | Should -Not -Throw } else { { Assert-FhAdmin } | Should -Throw }
        @(Get-FhUiLanguages).Count | Should -BeGreaterThan 0
    }
    It 'runs a command as a SYSTEM task' {
        $global:FhPoll = 0
        Mock -ModuleName FeatureHeist Register-ScheduledTask { }
        Mock -ModuleName FeatureHeist Unregister-ScheduledTask { }
        Mock -ModuleName FeatureHeist Start-ScheduledTask { }
        Mock -ModuleName FeatureHeist Start-Sleep { }
        Mock -ModuleName FeatureHeist Get-ScheduledTask { $global:FhPoll++; [pscustomobject]@{ State = $(if ($global:FhPoll -lt 2) { 'Running' } else { 'Ready' }) } }
        Mock -ModuleName FeatureHeist Get-ScheduledTaskInfo { [pscustomobject]@{ LastTaskResult = 3010 } }
        Invoke-FhAsSystem 'Write-Output "a b"' 'FH-Test' | Should -Be 3010
        Should -Invoke -ModuleName FeatureHeist Register-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'FH-Test' }
        Should -Invoke -ModuleName FeatureHeist Unregister-ScheduledTask -Times 2
    }
}

Describe 'State' {
    BeforeEach { Reset-FhTest | Out-Null }

    It 'stores, reads and removes package state' {
        Get-FhState 'x' | Should -BeNullOrEmpty
        Set-FhState 'x' ([ordered]@{ A = 1 })
        Set-FhState 'y' @{ B = 2 }
        (Get-FhState 'x').A | Should -Be 1
        Remove-FhState 'x'
        Get-FhState 'x' | Should -BeNullOrEmpty
        Test-Path "$TestReg\Packages" | Should -BeTrue
        Remove-FhState 'y'
        Test-Path "$TestReg\Packages" | Should -BeFalse
    }
    It 'ignores a package key without state' {
        New-Item "$TestReg\Packages\z" -Force | Out-Null
        Get-FhState 'z' | Should -BeNullOrEmpty
    }
}

Describe 'Payload root' {
    BeforeEach { Reset-FhTest | Out-Null }

    It 'uses the remembered path, else the scripts folder' {
        Get-FhPayloadRoot | Should -Be (Join-Path $Scripts 'payload')
        $p = New-Item -ItemType Directory -Force (Join-Path $TestDrive 'remember')
        Set-FhPayloadRoot $p.FullName
        Get-FhPayloadRoot | Should -Be $p.FullName
    }
    It 'forgets the path when it is the default' {
        $def = Join-Path $Scripts 'payload'
        $made = -not (Test-Path $def)
        if ($made) { New-Item -ItemType Directory $def | Out-Null }
        try {
            Set-ItemProperty (Get-FhKey) PayloadPath 'X:\old'
            Set-FhPayloadRoot $def
            Get-FhPayloadRoot | Should -Be $def
        } finally { if ($made) { Remove-Item $def -Force } }
    }
    It 'requires a manifest' {
        { Test-FhManifest $TestDrive } | Should -Throw '*No manifest*'
    }
    It 'creates a clean payload folder and remembers its root' {
        $root = Join-Path $TestDrive 'np'
        $s = [pscustomobject]@{ Build = 26100; Name = 'S'; Version = 'v'; Index = 1; Wim = 'C:\x\install.wim' }
        $d = New-FhPayloadDir 'mpio' $s $root
        Set-Content (Join-Path $d 'old') ''
        $d = New-FhPayloadDir 'mpio' $s $root
        Get-ChildItem $d | Should -BeNullOrEmpty
        Get-FhPayloadRoot | Should -Be (Resolve-Path $root).Path
        (Get-FhSourceInfo $s).File | Should -Be 'install.wim'
    }
}

Describe 'Resolve payload' {
    BeforeEach {
        Reset-FhTest | Out-Null
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $fake = '..\..\tests\fixtures\Fake-Extract.ps1'
    }

    It 'returns an existing payload' {
        $d = New-FhTestPayload $root 'mpio'
        Mock -ModuleName FeatureHeist Get-FhBaseBuild { 26100 }
        Resolve-FhPayload 'mpio' $root -ExtractScript $fake | Should -Be $d
    }
    It 'needs -SourcePath without a payload' {
        { Resolve-FhPayload 'fake' $root -ExtractScript $fake } | Should -Throw '*pass -SourcePath*'
    }
    It 'extracts first' {
        $d = Resolve-FhPayload 'fake' $root 'ok' 3 $fake
        $d | Should -BeLike '*\fake'
        (Get-Content (Join-Path $d 'manifest.json') -Raw | ConvertFrom-Json).Source.Index | Should -Be 3
    }
    It 'fails when the extraction gives nothing' {
        { Resolve-FhPayload 'fake' $root 'bad' -ExtractScript $fake } | Should -Throw '*must match*'
    }
}

Describe 'Source image' {
    BeforeEach {
        Reset-FhTest | Out-Null
        $src = Join-Path $TestDrive 'media'
        New-Item -ItemType Directory -Force (Join-Path $src 'sources') | Out-Null
        Set-Content (Join-Path $src 'sources\install.wim') ''
        Mock -ModuleName FeatureHeist Get-WindowsImage -ParameterFilter { -not $Index } {
            [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows Server 2025 Standard' }
            [pscustomobject]@{ ImageIndex = 2; ImageName = 'Windows Server 2025 Datacenter' }
        }
        Mock -ModuleName FeatureHeist Get-WindowsImage -ParameterFilter { $Index } {
            [pscustomobject]@{ ImageIndex = [int]$Index; ImageName = "Server $Index"; ImageSize = 10 - $Index; Version = '10.0.26100.1742' }
        }
        Mock -ModuleName FeatureHeist Mount-DiskImage { [pscustomobject]@{ ImagePath = $ImagePath } }
        Mock -ModuleName FeatureHeist Dismount-DiskImage { }
        Mock -ModuleName FeatureHeist Get-Volume -RemoveParameterType DiskImage { [pscustomobject]@{ DriveLetter = 'Q' } }
    }

    It 'picks the smallest image of a media folder' {
        $s = Open-FhSource $src
        $s.Index | Should -Be 2
        $s.Build | Should -Be 26100
        Close-FhSource $s
        Should -Invoke -ModuleName FeatureHeist Dismount-DiskImage -Times 0
    }
    It 'takes a wim and an index' {
        (Open-FhSource (Join-Path $src 'sources\install.wim') 1).Index | Should -Be 1
        { Open-FhSource $src 5 } | Should -Throw '*Index 5*'
    }
    It 'searches all drives' {
        Mock -ModuleName FeatureHeist Get-PSDrive { [pscustomobject]@{ Root = "$src\" } }
        (Open-FhSource).Wim | Should -Be (Join-Path $src 'sources\install.wim')
    }
    It 'mounts an ISO and dismounts it when no Server image is on it' {
        $iso = Join-Path $TestDrive 'x.iso'
        Set-Content $iso ''
        { Open-FhSource $iso } | Should -Throw '*No Windows Server*'
        Should -Invoke -ModuleName FeatureHeist Dismount-DiskImage -Times 1
        Close-FhSource ([pscustomobject]@{ Iso = [pscustomobject]@{ ImagePath = $iso } })
        Should -Invoke -ModuleName FeatureHeist Dismount-DiskImage -Times 2
    }
}

Describe 'Image mount' {
    BeforeEach {
        $data = Reset-FhTest
        $global:FhMountDir = Join-Path $data 'mount'
        Mock -ModuleName FeatureHeist Get-WindowsImage { [pscustomobject]@{ Path = $global:FhMountDir } }
        Mock -ModuleName FeatureHeist Dismount-WindowsImage { }
        Mock -ModuleName FeatureHeist Mount-WindowsImage { }
        Mock -ModuleName FeatureHeist Export-WindowsImage { }
        Mock -ModuleName FeatureHeist Enable-WindowsOptionalFeature { }
        $s = [pscustomobject]@{ Wim = 'x.wim'; Index = 2 }
    }

    It 'mounts read-only and cleans up' {
        New-Item -ItemType Directory -Force (Join-Path $data 'mount') | Out-Null
        $i = Mount-FhImage $s
        $i.Copy | Should -BeNullOrEmpty
        Should -Invoke -ModuleName FeatureHeist Mount-WindowsImage -Times 1 -ParameterFilter { $ReadOnly }
        Dismount-FhImage $i
        Should -Invoke -ModuleName FeatureHeist Dismount-WindowsImage -Times 2
        Test-Path $i.Path | Should -BeFalse
    }
    It 'enables features in an exported copy' {
        New-Item -ItemType Directory -Force $data | Out-Null
        Set-Content (Join-Path $data 'source.wim') ''
        $i = Mount-FhImage $s -EnableFeature MultiPathIO
        $i.Copy | Should -Be (Join-Path $data 'source.wim')
        Should -Invoke -ModuleName FeatureHeist Enable-WindowsOptionalFeature -Times 1
        Set-Content $i.Copy ''
        Dismount-FhImage $i
        Test-Path $i.Copy | Should -BeFalse
        Dismount-FhImage $null
    }
}

Describe 'CBS packages' {
    BeforeEach { Reset-FhTest | Out-Null }

    It 'installs the neutral package and the installed languages' {
        Mock -ModuleName FeatureHeist Get-FhUiLanguages { 'de-DE', 'fr-FR' }
        Mock -ModuleName FeatureHeist Invoke-FhDism { $ArgumentList[1] -like '*de-DE' }
        $p = Join-Path $TestDrive 'cbs'
        New-Item -ItemType Directory -Force (Join-Path $p 'neutral'), (Join-Path $p 'de-DE') | Out-Null
        Set-Content (Join-Path $p 'de-DE\update.mum') ''
        Install-FhCbsPackage $p | Should -BeTrue
        Should -Invoke -ModuleName FeatureHeist Invoke-FhDism -Times 2
    }
    It 'removes language packs before the neutral package' {
        $global:FhOrder = @()
        Mock -ModuleName FeatureHeist Get-WindowsPackage {
            foreach ($n in 'P~31bf~amd64~~1', 'P~31bf~amd64~de-DE~1', 'Q~31bf~amd64~~1') { [pscustomobject]@{ PackageName = $n; PackageState = 'Installed' } }
            [pscustomobject]@{ PackageName = 'P~31bf~amd64~fr-FR~1'; PackageState = 'Absent' }
        }
        Mock -ModuleName FeatureHeist Invoke-FhDism { $global:FhOrder += $ArgumentList[1]; $true }
        Uninstall-FhCbsPackage 'P' | Should -BeTrue
        $global:FhOrder | Should -Be @('/packagename:P~31bf~amd64~de-DE~1', '/packagename:P~31bf~amd64~~1')
    }
}

Describe 'Package export' -Skip:(-not $IsAdmin) {
    BeforeEach {
        Reset-FhTest | Out-Null
        $m = Join-Path $TestDrive ([guid]::NewGuid())
        $pk = Join-Path $m 'Windows\servicing\Packages'
        $sxs = Join-Path $m 'Windows\WinSxS'
        New-Item -ItemType Directory -Force $pk, (Join-Path $sxs 'Manifests'), (Join-Path $m 'Windows\System32\config') | Out-Null
        $a = 'amd64_microsoft-windows-foo_31bf3856ad364e35_10.0.26100.1_none_aaa111'
        $b = 'amd64_microsoft-windows-foo.deployment_31bf3856ad364e35_10.0.26100.1_none_bbb222'
        $l = 'amd64_microsoft-windows-foo.resources_31bf3856ad364e35_10.0.26100.1_de-de_ccc333'
        $x = 'amd64_microsoft-windows-bar_31bf3856ad364e35_10.0.26100.1_none_ddd444'
        New-FhTestHive (Join-Path $m 'Windows\System32\config\COMPONENTS') {
            param($k)
            $c = "$k\DerivedData\Components"
            foreach ($n in $a, $b, $l, $x) { New-Item "$c\$n" -Force | Out-Null }
            New-ItemProperty "$c\$a" identity -PropertyType Binary -Value ([Text.Encoding]::ASCII.GetBytes('Microsoft-Windows-Foo, Culture=neutral')) | Out-Null
            New-ItemProperty "$c\$x" identity -Value 'Microsoft-Windows-Bar, Culture=neutral' | Out-Null
            New-ItemProperty "$c\$l" identity -Value 'Microsoft-Windows-Foo.Resources, Culture=de-DE' | Out-Null
            New-ItemProperty "$c\$b" 'c!microsoft-w..-foo_31bf3856ad364e35_10.0.26100.1_aaa111' -Value '' | Out-Null
        }
        function New-Mum([string]$File, [string]$Name, [string]$Lang) {
            Set-Content $File ('<?xml version="1.0"?><assembly xmlns="urn:schemas-microsoft-com:asm.v3"><package><update name="u"><component>' +
                "<assemblyIdentity name=`"$Name`" version=`"10.0.26100.1`" processorArchitecture=`"amd64`" language=`"$Lang`"/>" +
                '</component></update></package></assembly>')
            Set-Content ([IO.Path]::ChangeExtension($File, '.cat')) 'cat'
        }
        New-Mum (Join-Path $pk 'P~31bf3856ad364e35~amd64~~10.0.26100.1.mum') 'Microsoft-Windows-Foo' 'neutral'
        New-Mum (Join-Path $pk 'P~31bf3856ad364e35~amd64~de-DE~10.0.26100.1.mum') 'Microsoft-Windows-Foo.Resources' 'de-DE'
        foreach ($n in $a, $b, $l) { Set-Content (Join-Path $sxs "Manifests\$n.manifest") $n }
        New-Item -ItemType Directory (Join-Path $sxs $a) | Out-Null
        Set-Content (Join-Path $sxs "$a\foo.dll") 'MZfoo'
        $dest = Join-Path $TestDrive ([guid]::NewGuid())
    }

    It 'exports packages with owned components and payload' {
        Export-FhCbsPackage $m (Get-FhPackageMums $m 'P' | ForEach-Object Mum) $dest
        Test-Path (Join-Path $dest 'neutral\update.cat') | Should -BeTrue
        Test-Path (Join-Path $dest "neutral\$b.manifest") | Should -BeTrue
        Test-Path (Join-Path $dest "neutral\$a\foo.dll") | Should -BeTrue
        Test-Path (Join-Path $dest "neutral\$x.manifest") | Should -BeFalse
        Test-Path (Join-Path $dest "de-DE\$l.manifest") | Should -BeTrue
        Test-Path 'HKLM:\FH_SRC_COMPONENTS' | Should -BeFalse
    }
    It 'refuses compressed payload' {
        [IO.File]::WriteAllBytes((Join-Path $sxs "$a\foo.dll"), [byte[]](0x44, 0x43, 0x53, 1, 0))
        { Export-FhCbsPackage $m (Get-Item (Join-Path $pk 'P~31bf3856ad364e35~amd64~~10.0.26100.1.mum')) $dest } | Should -Throw '*compressed*'
    }
    It 'needs every manifest' {
        Remove-Item (Join-Path $sxs "Manifests\$b.manifest")
        { Export-FhCbsPackage $m (Get-Item (Join-Path $pk 'P~31bf3856ad364e35~amd64~~10.0.26100.1.mum')) $dest } | Should -Throw '*Manifest missing*'
    }
    It 'needs a readable COMPONENTS hive' {
        Set-Content (Join-Path $m 'Windows\System32\config\COMPONENTS') 'not a hive'
        { Export-FhCbsPackage $m (Get-Item (Join-Path $pk 'P~31bf3856ad364e35~amd64~~10.0.26100.1.mum')) $dest } | Should -Throw '*Cannot load COMPONENTS*'
    }
    It 'needs every component' {
        $f = Join-Path $pk 'N~31bf3856ad364e35~amd64~~10.0.26100.1.mum'
        New-Mum $f 'Microsoft-Windows-Nope' 'neutral'
        { Export-FhCbsPackage $m (Get-Item $f) $dest } | Should -Throw '*Component not found*'
    }
}

Describe 'Catalogs and files' {
    BeforeEach { Reset-FhTest | Out-Null }

    It 'finds the smallest catalog that lists a file' {
        $m = Join-Path $TestDrive 'cm'
        $cr = Join-Path $m 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
        New-Item -ItemType Directory -Force $cr | Out-Null
        $f = Join-Path $TestDrive 'f.inf'
        Set-Content $f 'payload'
        $h = [FeatureHeist.Native]::CatalogHashes($f)
        [IO.File]::WriteAllBytes((Join-Path $cr 'big.cat'), [byte[]]((@(0) * 100) + $h[0]))
        [IO.File]::WriteAllBytes((Join-Path $cr 'small.cat'), [byte[]]((@(1) * 10) + $h[1]))
        [IO.File]::WriteAllBytes((Join-Path $cr 'none.cat'), [byte[]](@(2) * 5))
        (Find-FhCatalog $m $f).Name | Should -Be 'small.cat'
        Remove-Item (Join-Path $cr 'small.cat'), (Join-Path $cr 'big.cat')
        { Find-FhCatalog $m $f } | Should -Throw '*No catalog*'
    }
    It 'accepts only Microsoft signatures' {
        { Assert-FhMicrosoftSignature (Join-Path $env:SystemRoot 'System32\notepad.exe') } | Should -Not -Throw
        $f = Join-Path $TestDrive 'u.ps1'
        Set-Content $f '1'
        { Assert-FhMicrosoftSignature $f } | Should -Throw '*Not validly signed*'
    }
    It 'registers and removes a catalog' -Skip:(-not $IsAdmin) {
        $cr = Join-Path $env:SystemRoot 'System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
        $c = Get-ChildItem $cr -Filter 'Microsoft-Windows-*.cat' | Sort-Object Length | Where-Object { (Get-AuthenticodeSignature $_.FullName).Status -eq 'Valid' } | Select-Object -First 1
        $copy = Join-Path $TestDrive 'test.cat'
        Copy-Item $c.FullName $copy
        Add-FhCatalog $copy 'FeatureHeist-PesterTest.cat'
        Test-Path (Join-Path $cr 'FeatureHeist-PesterTest.cat') | Should -BeTrue
        Remove-FhCatalog 'FeatureHeist-PesterTest.cat'
        Get-FhTestLog | Should -Match 'Catalog removed: FeatureHeist-PesterTest.cat'
    }
    It 'removes a catalog that is not registered' {
        Remove-FhCatalog 'FeatureHeist-PesterNone.cat'
        Get-FhTestLog | Should -Match 'FeatureHeist-PesterNone.cat'
    }
    It 'deletes files, locked ones at the next boot' {
        Remove-FhFile (Join-Path $TestDrive 'nothing')
        $f = Join-Path $TestDrive 'del.txt'
        Set-Content $f ''
        Remove-FhFile $f
        Test-Path $f | Should -BeFalse
        Set-Content $f ''
        $s = [IO.File]::Open($f, 'Open', 'Read', 'None')
        try { Remove-FhFile $f } finally { $s.Close() }
        Get-FhTestLog | Should -Match $(if ($IsAdmin) { 'Deleted at next boot' } else { 'cannot delete' })
        Remove-Item $f
    }
}

Describe 'Teams' {
    BeforeEach {
        $data = Reset-FhTest
        Mock -ModuleName FeatureHeist Get-NetLbfoTeam { [pscustomobject]@{ Name = 'T'; TeamingMode = 'Lacp'; LoadBalancingAlgorithm = 'Dynamic' } }
        Mock -ModuleName FeatureHeist Get-NetLbfoTeamNic {
            [pscustomobject]@{ Name = 'T'; VlanID = 5; Primary = $true }
            [pscustomobject]@{ Name = 'T - VLAN 10'; VlanID = 10; Primary = $false }
        }
        Mock -ModuleName FeatureHeist Get-NetLbfoTeamMember { [pscustomobject]@{ Name = 'E1' }; [pscustomobject]@{ Name = 'E2' } }
        Mock -ModuleName FeatureHeist Get-NetIPInterface { }
        Mock -ModuleName FeatureHeist Get-NetIPInterface -ParameterFilter { $InterfaceAlias -eq 'T - VLAN 10' } { [pscustomobject]@{ Dhcp = 'Disabled' } }
        Mock -ModuleName FeatureHeist Get-NetIPAddress { [pscustomobject]@{ IPAddress = '192.0.2.5'; PrefixLength = 24 }; [pscustomobject]@{ IPAddress = '198.51.100.5'; PrefixLength = 24 } }
        Mock -ModuleName FeatureHeist Get-NetRoute { [pscustomobject]@{ NextHop = '192.0.2.1' } }
        Mock -ModuleName FeatureHeist Get-DnsClientServerAddress { [pscustomobject]@{ ServerAddresses = @('192.0.2.2') } }
        Mock -ModuleName FeatureHeist Get-NetAdapter { [pscustomobject]@{ Name = 'x' } }
        Mock -ModuleName FeatureHeist New-NetLbfoTeam { }
        Mock -ModuleName FeatureHeist Add-NetLbfoTeamNic { }
        Mock -ModuleName FeatureHeist Set-NetLbfoTeamNic { }
        Mock -ModuleName FeatureHeist Start-Sleep { }
        Mock -ModuleName FeatureHeist New-NetIPAddress { }
        Mock -ModuleName FeatureHeist Set-DnsClientServerAddress { }
    }

    It 'saves and restores teams, VLANs and static addresses' {
        Save-FhTeams
        $j = Get-Content (Join-Path $data 'backup\teams.json') -Raw | ConvertFrom-Json
        @($j.Nics).Count | Should -Be 2
        Mock -ModuleName FeatureHeist Get-NetLbfoTeam { }
        Restore-FhTeams
        Should -Invoke -ModuleName FeatureHeist New-NetLbfoTeam -Times 1 -ParameterFilter { $Name -eq 'T' -and $TeamMembers.Count -eq 2 }
        Should -Invoke -ModuleName FeatureHeist Set-NetLbfoTeamNic -Times 1
        Should -Invoke -ModuleName FeatureHeist Add-NetLbfoTeamNic -Times 1 -ParameterFilter { $VlanID -eq 10 }
        Should -Invoke -ModuleName FeatureHeist New-NetIPAddress -Times 1 -ParameterFilter { $DefaultGateway -eq '192.0.2.1' }
        Should -Invoke -ModuleName FeatureHeist New-NetIPAddress -Times 2
        Should -Invoke -ModuleName FeatureHeist Set-DnsClientServerAddress -Times 1
    }
    It 'saves nothing without teams' {
        Mock -ModuleName FeatureHeist Get-NetLbfoTeam { }
        Save-FhTeams
        Test-Path (Join-Path $data 'backup\teams.json') | Should -BeFalse
        Restore-FhTeams
        Get-FhTestLog | Should -Match 'No team backup'
    }
    It 'skips existing teams and teams without members' {
        $p = Join-Path $TestDrive 't.json'
        '[{"Name":"T","Members":["E1"],"Mode":"Lacp","Algorithm":"Dynamic","Nics":[]},{"Name":"U","Members":["X"],"Mode":"Lacp","Algorithm":"Dynamic","Nics":[]}]' | Set-Content $p
        Mock -ModuleName FeatureHeist Get-NetLbfoTeam { }
        Mock -ModuleName FeatureHeist Get-NetLbfoTeam -ParameterFilter { $Name -eq 'T' } { [pscustomobject]@{ Name = 'T' } }
        Mock -ModuleName FeatureHeist Get-NetAdapter { }
        Restore-FhTeams $p
        Should -Invoke -ModuleName FeatureHeist New-NetLbfoTeam -Times 0
        Get-FhTestLog | Should -Match 'no member of team U'
    }
}

Describe 'iSCSI sessions' {
    BeforeEach {
        $data = Reset-FhTest
        Mock -ModuleName FeatureHeist Get-IscsiSession { foreach ($i in 1, 2) { [pscustomobject]@{ TargetNodeAddress = 'iqn.test'; SessionIdentifier = "s$i"; IsPersistent = $true } } }
        Mock -ModuleName FeatureHeist Get-IscsiConnection -RemoveParameterType IscsiSession { [pscustomobject]@{ TargetAddress = '192.0.2.10'; TargetPortNumber = 3260 } }
        Mock -ModuleName FeatureHeist Disconnect-IscsiTarget { }
        Mock -ModuleName FeatureHeist Connect-IscsiTarget { }
    }

    It 'saves, limits and restores sessions' {
        Save-FhIscsiSessions
        @((Get-Content (Join-Path $data 'backup\iscsi.json') -Raw | ConvertFrom-Json)).Count | Should -Be 2
        Limit-FhIscsiSessions
        Should -Invoke -ModuleName FeatureHeist Disconnect-IscsiTarget -Times 1
        Mock -ModuleName FeatureHeist Get-IscsiSession { [pscustomobject]@{ TargetNodeAddress = 'iqn.test' } }
        Restore-FhIscsiSessions
        Should -Invoke -ModuleName FeatureHeist Connect-IscsiTarget -Times 1
    }
    It 'skips sessions without a known portal' {
        Mock -ModuleName FeatureHeist Get-IscsiConnection -RemoveParameterType IscsiSession { }
        Save-FhIscsiSessions
        Mock -ModuleName FeatureHeist Get-IscsiSession { }
        Restore-FhIscsiSessions
        Should -Invoke -ModuleName FeatureHeist Connect-IscsiTarget -Times 0
    }
    It 'does nothing without sessions or backup' {
        Mock -ModuleName FeatureHeist Get-IscsiSession { }
        Save-FhIscsiSessions
        Test-Path (Join-Path $data 'backup\iscsi.json') | Should -BeFalse
        Restore-FhIscsiSessions
        Should -Invoke -ModuleName FeatureHeist Connect-IscsiTarget -Times 0
    }
}

Describe 'Watch task' {
    BeforeEach {
        Reset-FhTest | Out-Null
        Mock -ModuleName FeatureHeist Register-ScheduledTask { }
        Mock -ModuleName FeatureHeist Unregister-ScheduledTask { }
        Mock -ModuleName FeatureHeist New-EventLog { }
    }

    It 'registers the task with three triggers' -Skip:(-not $IsAdmin) {
        Register-FhWatch
        Should -Invoke -ModuleName FeatureHeist Register-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'FeatureHeist-Watch' -and @($Trigger).Count -eq 3 }
    }
    It 'removes the task only when no package is left' {
        Set-FhState 'mpio' @{ A = 1 }
        Unregister-FhWatch
        Should -Invoke -ModuleName FeatureHeist Unregister-ScheduledTask -Times 0
        Remove-FhState 'mpio'
        Unregister-FhWatch
        Should -Invoke -ModuleName FeatureHeist Unregister-ScheduledTask -Times 1
    }
}
