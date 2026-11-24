#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }
# Runs the scripts with every system change mocked; Windows is redirected to a TestDrive folder.
BeforeDiscovery {
    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
    # stand-ins for cmdlets that a client or server may lack
    $global:FhStubs = @()
    foreach ($c in 'Enable-MSDSMAutomaticClaim', 'Disable-MSDSMAutomaticClaim') {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
            New-Item "function:global:$c" -Value { [CmdletBinding()] param($BusType) } | Out-Null
            $global:FhStubs += $c
        }
    }
    if (-not (Get-Command msg.exe -ErrorAction SilentlyContinue)) { New-Item 'function:global:msg.exe' -Value { } | Out-Null; $global:FhStubs += 'msg.exe' }
}
AfterAll {
    foreach ($c in $global:FhStubs) { Remove-Item "function:global:$c" -ErrorAction SilentlyContinue }
    if (Test-Path $TestReg) { Remove-Item $TestReg -Recurse -Force }
}

Describe 'Scripts' {
    BeforeEach {
        $data = Reset-FhTest
        $pl = Join-Path $TestDrive ([guid]::NewGuid())
        $win = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force (Join-Path $win 'INF'), (Join-Path $win 'System32\drivers') | Out-Null
        $mount = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force $mount | Out-Null
        $mum = Join-Path $mount 'p.mum'
        Set-Content $mum ''
        $global:Fh = @{ Win = $win; Mount = $mount; Mum = $mum; Svc = $false; Net = $false; Teams = @(); Disks = @(); Driver = 'Running'; Feature = 'Enabled'; Packages = @() }

        Mock Assert-FhAdmin { }
        Mock Get-FhBaseBuild { 26100 }
        Mock Get-FhWindowsDir { $global:Fh.Win }
        Mock Get-FhLbfoOwner { if ($global:Fh.Owner) { $global:Fh.Owner } elseif (Get-FhState 'lbfo') { 'FeatureHeist' } }
        Mock Test-FhInteractive { $false }
        Mock Read-Host { 's' }
        Mock -ModuleName FeatureHeist Get-FhBaseBuild { 26100 }
        Mock Invoke-FhNative { & (Get-Module FeatureHeist) { param($a) Invoke-FhNative @a } $PesterBoundParameters }
        Mock Invoke-FhNative -ParameterFilter { $FilePath -ne 'reg.exe' } { 0 }
        Mock Invoke-FhDism { $false }
        Mock Install-FhCbsPackage { $true }
        Mock Uninstall-FhCbsPackage { $true }
        Mock Add-FhCatalog { }
        Mock Remove-FhCatalog { }
        Mock Assert-FhMicrosoftSignature { }
        Mock Register-FhWatch { }
        Mock Unregister-FhWatch { }
        Mock Restore-FhTeams { }
        Mock Save-FhTeams { }
        Mock Save-FhIscsiSessions { }
        Mock Restore-FhIscsiSessions { }
        Mock Limit-FhIscsiSessions { }
        Mock Register-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
        Mock Enable-MSDSMAutomaticClaim { }
        Mock Disable-MSDSMAutomaticClaim { }
        # Pester 6: a filtered mock needs a default
        foreach ($c in 'Import-Module', 'Test-Path', 'Get-ChildItem', 'Get-ItemProperty') {
            Mock $c ([scriptblock]::Create("& (Get-Command $c -CommandType Cmdlet) @PesterBoundParameters"))
        }
        Mock Import-Module -ParameterFilter { $Name -eq 'MPIO' } { }
        Mock Write-EventLog { }
        Mock msg.exe { }
        Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = $global:Fh.Feature } }
        Mock Get-WindowsPackage { foreach ($n in $global:Fh.Packages) { [pscustomobject]@{ PackageName = $n; PackageState = 'Installed' } } }
        Mock Get-CimInstance { [pscustomobject]@{ State = $global:Fh.Driver } }
        Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'MPIO_DISK_INFO' } { foreach ($d in $global:Fh.Disks) { [pscustomobject]@{ DriveInfo = $d } } }
        Mock Get-NetLbfoTeam { foreach ($t in $global:Fh.Teams) { [pscustomobject]@{ Name = $t } } }
        Mock Remove-NetLbfoTeam { }
        Mock Test-Path -ParameterFilter { "$Path" -like 'HKLM:\SYSTEM\CurrentControlSet\Services\*' } { $global:Fh.Svc }
        Mock Get-ChildItem -ParameterFilter { "$Path" -like '*\Control\Network\*' } { if ($global:Fh.Net) { [pscustomobject]@{ PSPath = 'fh-net' } } }
        Mock Get-ItemProperty -ParameterFilter { "$Path" -eq 'fh-net' } { [pscustomobject]@{ ComponentId = 'ms_lbfo' } }
        Mock Open-FhSource { [pscustomobject]@{ Wim = 'install.wim'; Index = 1; Build = 26100; Name = 'Windows Server 2025 Standard'; Version = '10.0.26100.1742'; Iso = $null } }
        Mock Mount-FhImage { [pscustomobject]@{ Path = $global:Fh.Mount; Copy = $null } }
        Mock Dismount-FhImage { }
        Mock Close-FhSource { }
        Mock Get-FhPackageMums { [pscustomobject]@{ Language = 'neutral'; Mum = Get-Item $global:Fh.Mum } }
        Mock Export-FhCbsPackage { }
        Mock Find-FhCatalog { Get-Item $global:Fh.Mum }
    }

    Context 'Extract' {
        It 'extracts MPIO and LbfoAdmin from a mounted image' {
            foreach ($s in 'Extract-Mpio.ps1', 'Extract-LbfoAdmin.ps1') {
                Invoke-FhScript $s @{ MountPath = $mount; Source = (Open-FhSource); PayloadPath = $pl } | Should -Be 0
            }
            Test-Path (Join-Path $pl '26100\mpio\manifest.json') | Should -BeTrue
            Test-Path (Join-Path $pl '26100\lbfoadmin\manifest.json') | Should -BeTrue
            Should -Invoke Mount-FhImage -Times 0
        }
        It 'mounts the source itself' {
            foreach ($s in 'Extract-Mpio.ps1', 'Extract-LbfoAdmin.ps1') { Invoke-FhScript $s @{ SourcePath = 'x.iso'; PayloadPath = $pl } | Should -Be 0 }
            Should -Invoke Dismount-FhImage -Times 2
        }
        It 'fails when the package is not in the image' {
            Mock Get-FhPackageMums { }
            foreach ($s in 'Extract-Mpio.ps1', 'Extract-LbfoAdmin.ps1') { Invoke-FhScript $s @{ SourcePath = 'x.iso'; PayloadPath = $pl } | Should -Be 1 }
        }
        It 'fails without the LBFO driver in the image' {
            Invoke-FhScript 'Extract-Lbfo.ps1' @{ SourcePath = 'x.iso'; PayloadPath = $pl } | Should -Be 1
            Should -Invoke Dismount-FhImage -Times 1
        }
        It 'extracts LBFO with service settings from the image' -Skip:(-not $IsAdmin) {
            foreach ($f in 'Windows\System32\drivers\MsLbfoProvider.sys', 'Windows\INF\mslbfoprovider.inf') {
                New-Item -ItemType Directory -Force (Split-Path (Join-Path $mount $f)) | Out-Null
                Set-Content (Join-Path $mount $f) $f
            }
            New-Item -ItemType Directory -Force (Join-Path $mount 'Windows\System32\config') | Out-Null
            New-FhTestHive (Join-Path $mount 'Windows\System32\config\SYSTEM') {
                param($k)
                $s = New-Item "$k\ControlSet001\Services\MsLbfoProvider" -Force
                New-ItemProperty $s.PSPath Type -PropertyType DWord -Value 1 | Out-Null
                New-ItemProperty $s.PSPath ImagePath -PropertyType ExpandString -Value '\SystemRoot\System32\drivers\MsLbfoProvider.sys' | Out-Null
            }
            Invoke-FhScript 'Extract-Lbfo.ps1' @{ MountPath = $mount; Source = (Open-FhSource); PayloadPath = $pl } | Should -Be 0
            $j = Get-Content (Join-Path $pl '26100\lbfo\service.json') -Raw | ConvertFrom-Json
            $j.Type | Should -Be 1
            $j.ImagePath | Should -Be '\SystemRoot\System32\drivers\MsLbfoProvider.sys'
            Get-FhTestLog | Should -Match 'skipped'
        }
        It 'fails when the SYSTEM hive cannot be loaded' {
            foreach ($f in 'Windows\System32\drivers\MsLbfoProvider.sys', 'Windows\INF\mslbfoprovider.inf', 'Windows\System32\config\SYSTEM') {
                New-Item -ItemType Directory -Force (Split-Path (Join-Path $mount $f)) | Out-Null
                Set-Content (Join-Path $mount $f) $f
            }
            Invoke-FhScript 'Extract-Lbfo.ps1' @{ MountPath = $mount; Source = (Open-FhSource); PayloadPath = $pl } | Should -Be 1
            Get-FhTestLog | Should -Match 'reg.exe load .* failed'
        }
        It 'fails when the image has no LBFO service' -Skip:(-not $IsAdmin) {
            foreach ($f in 'Windows\System32\drivers\MsLbfoProvider.sys', 'Windows\INF\mslbfoprovider.inf') {
                New-Item -ItemType Directory -Force (Split-Path (Join-Path $mount $f)) | Out-Null
                Set-Content (Join-Path $mount $f) $f
            }
            New-Item -ItemType Directory -Force (Join-Path $mount 'Windows\System32\config') | Out-Null
            New-FhTestHive (Join-Path $mount 'Windows\System32\config\SYSTEM') { param($k) New-Item "$k\ControlSet001\Services" -Force | Out-Null }
            Invoke-FhScript 'Extract-Lbfo.ps1' @{ MountPath = $mount; Source = (Open-FhSource); PayloadPath = $pl } | Should -Be 1
            Get-FhTestLog | Should -Match 'not in image'
        }
        It 'extracts several packages with one mount' {
            Invoke-FhScript 'Extract-All.ps1' @{ Packages = 'Mpio, lbfoadmin'; SourcePath = 'x.iso'; PayloadPath = $pl } | Should -Be 0
            Should -Invoke Mount-FhImage -Times 1 -ParameterFilter { $EnableFeature -contains 'MultiPathIO' }
            Invoke-FhScript 'Extract-All.ps1' @{ Packages = 'Lbfo'; SourcePath = 'x.iso' } | Should -Be 1
            Should -Invoke Mount-FhImage -Times 1 -ParameterFilter { -not $EnableFeature }
        }
        It 'reports a source error' {
            Mock Open-FhSource { throw 'no media' }
            Invoke-FhScript 'Extract-All.ps1' | Should -Be 1
        }
    }

    Context 'Install media' {
        BeforeEach {
            $global:Fh.Media = Join-Path $TestDrive ([guid]::NewGuid())
            New-Item -ItemType Directory -Force (Join-Path $Fh.Media 'sources') | Out-Null
            $ci = Join-Path $TestDrive 'client.iso'
            Set-Content $ci 'iso'
            $msi = Join-Path $TestDrive 'fh.msi'
            Set-Content $msi 'msi'
            $out = Join-Path $TestDrive "$([guid]::NewGuid()).iso"
            Mock Mount-FhIso { [pscustomobject]@{ Root = $global:Fh.Media + '\'; Label = 'CCCOMA'; ImagePath = 'client.iso' } }
            Mock Dismount-DiskImage { }
            Mock Open-FhClientImage { [pscustomobject]@{ Wim = 'install.wim'; Index = 1; Build = 26100 } }
            Mock Get-FhImageBaseBuild { 26100 }
            Mock New-FhIsoImage { 'img' }
            Mock Add-FhIsoTree { }
            Mock Save-FhIso { Set-Content $Path 'iso' }
            $arg = @{ ClientIso = $ci; SourcePath = 'server.iso'; MsiPath = $msi; OutputIso = $out; Packages = 'Mpio'; Index = 2 }
        }
        It 'builds the ISO with MSI and payload' {
            Mock Add-FhIsoTree { $global:Fh.Staged = @(Get-ChildItem $Source -Recurse -File | ForEach-Object { $_.FullName.Substring($Source.Length + 1) }) }
            New-Item -ItemType Directory -Force (Join-Path (Get-FhDataDir) 'media\left-over') | Out-Null
            Invoke-FhScript 'New-InstallMedia.ps1' $arg | Should -Be 0
            Test-Path $out | Should -BeTrue
            $Fh.Staged | Should -Contain 'autounattend.xml'
            $Fh.Staged | Should -Contain 'sources\$OEM$\$1\ProgramData\FeatureHeist\Media\FeatureHeist.msi'
            $Fh.Staged | Should -Contain 'sources\$OEM$\$1\ProgramData\FeatureHeist\Media\payload\26100\mpio\manifest.json'
            Should -Invoke New-FhIsoImage -Times 1 -ParameterFilter { $Label -eq 'CCCOMA' }
            Should -Invoke Get-FhImageBaseBuild -Times 0
            Should -Invoke Dismount-DiskImage -Times 1
            Test-Path (Join-Path (Get-FhDataDir) 'media') | Should -BeFalse
            (Get-FhPayloadSetting).Value | Should -BeNullOrEmpty
        }
        It 'checks the kernel build when the image versions differ' {
            Mock Open-FhClientImage { [pscustomobject]@{ Wim = 'install.wim'; Index = 1; Build = 26200 } }
            Invoke-FhScript 'New-InstallMedia.ps1' $arg | Should -Be 0
            Should -Invoke Get-FhImageBaseBuild -Times 1
            Mock Get-FhImageBaseBuild { 22621 }
            $arg.OutputIso = Join-Path $TestDrive 'b.iso'
            Invoke-FhScript 'New-InstallMedia.ps1' $arg | Should -Be 1
            Get-FhTestLog | Should -Match 'Build mismatch: client 22621'
            Test-Path $arg.OutputIso | Should -BeFalse
        }
        It 'stops on invalid input' {
            $arg.Packages = 'LbfoAdmin'
            Invoke-FhScript 'New-InstallMedia.ps1' $arg | Should -Be 1
            Get-FhTestLog | Should -Match 'LbfoAdmin needs Lbfo'
            $arg.Packages = 'Mpio'
            $arg.MsiPath = Join-Path $TestDrive 'none.msi'
            Invoke-FhScript 'New-InstallMedia.ps1' $arg | Should -Be 1
            Get-FhTestLog | Should -Match 'File not found'
            $arg.MsiPath = $msi
            Set-Content $out 'old'
            Invoke-FhScript 'New-InstallMedia.ps1' $arg | Should -Be 1
            Get-FhTestLog | Should -Match 'Output exists'
            Get-Content $out | Should -Be 'old'
            Should -Invoke Mount-FhIso -Times 0
        }
        It 'refuses media with an answer file' {
            Set-Content (Join-Path $Fh.Media 'autounattend.xml') 'x'
            $arg.Remove('Packages')
            Invoke-FhScript 'New-InstallMedia.ps1' $arg | Should -Be 1
            Get-FhTestLog | Should -Match 'already contains autounattend.xml'
            Should -Invoke Dismount-DiskImage -Times 1
        }
        It 'fails when the extraction fails and keeps the payload setting' {
            Set-ItemProperty (Get-FhKey) -Name PayloadPath -Value 'C:\old'
            $arg.Packages = 'Lbfo'
            $arg.ClaimBusType = 'None'
            Invoke-FhScript 'New-InstallMedia.ps1' $arg | Should -Be 1
            Get-FhTestLog | Should -Match 'Extraction failed'
            (Get-FhPayloadSetting).Value | Should -Be 'C:\old'
            Should -Invoke New-FhIsoImage -Times 0
        }
        It 'removes a partly written ISO' {
            Mock Save-FhIso { Set-Content $Path 'part'; throw 'disk full' }
            Invoke-FhScript 'New-InstallMedia.ps1' $arg | Should -Be 1
            Test-Path $out | Should -BeFalse
        }
    }

    Context 'Extract languages' {
        BeforeEach {
            Mock Open-FhLanguageSource { [pscustomobject]@{ Cabs = @(Get-Item $global:Fh.Mum); Iso = $null } }
            Mock Expand-FhCab {
                New-Item -ItemType Directory -Force $Destination | Out-Null
                foreach ($n in 'MultipathIo', 'NDIS-LBFO-Admin-RSAT-Group') { Set-Content (Join-Path $Destination "Microsoft-Windows-$n-Package~31bf3856ad364e35~amd64~de-DE~10.0.26100.1.mum") '' }
            }
            Mock Export-FhLanguagePackage {
                New-Item -ItemType Directory -Force (Join-Path $Destination 'de-DE') | Out-Null
                Set-Content (Join-Path $Destination 'de-DE\update.mum') 'de'
                'de-DE'
            }
        }
        It 'adds language packs to extracted payloads only' {
            $d = New-FhTestPayload $pl 'mpio'
            Invoke-FhScript 'Extract-Languages.ps1' @{ SourcePath = 'l.iso'; PayloadPath = $pl } | Should -Be 0
            (Test-FhManifest $d).Files.Path | Should -Contain 'de-DE\update.mum'
            (Get-Content (Join-Path $d 'manifest.json') -Raw | ConvertFrom-Json).Source.Version | Should -Be '10.0.26100.1742'
            Get-FhTestLog | Should -Match 'No lbfoadmin payload for build 26100'
            Test-Path (Join-Path $data 'langpack') | Should -BeFalse
        }
        It 'fails without an extracted payload' {
            Invoke-FhScript 'Extract-Languages.ps1' @{ SourcePath = 'l.iso'; PayloadPath = $pl } | Should -Be 1
            Get-FhTestLog | Should -Match 'No language pack added'
        }
        It 'skips a language pack without our packages' {
            New-FhTestPayload $pl 'mpio' | Out-Null
            Mock Expand-FhCab { New-Item -ItemType Directory -Force $Destination | Out-Null }
            Invoke-FhScript 'Extract-Languages.ps1' @{ SourcePath = 'l.iso'; PayloadPath = $pl } | Should -Be 1
        }
    }

    Context 'Install' {
        It 'installs MPIO with claims and pending session restore' {
            New-FhTestPayload $pl 'mpio' | Out-Null
            Invoke-FhScript 'Install-Mpio.ps1' @{ PayloadPath = $pl; ClaimBusType = 'iSCSI', 'SAS'; RestoreSessions = $true; NoReboot = $true } | Should -Be 3010
            (Get-FhState 'mpio').Claim | Should -Be @('iSCSI', 'SAS')
            Test-Path (Join-Path $data 'backup\iscsi.pending') | Should -BeTrue
            Test-Path (Join-Path $data 'MsdsmFix.ps1') | Should -BeTrue
            Should -Invoke Enable-MSDSMAutomaticClaim -Times 2
        }
        It 'keeps going when a claim fails' {
            New-FhTestPayload $pl 'mpio' | Out-Null
            Mock Enable-MSDSMAutomaticClaim { throw 'not yet' }
            Invoke-FhScript 'Install-Mpio.ps1' @{ PayloadPath = $pl; ClaimBusType = 'iSCSI'; NoReboot = $true } | Should -Be 3010
            Get-FhTestLog | Should -Match 'MSDSM claim iSCSI failed'
        }
        It 'fails when the feature is not enabled' {
            New-FhTestPayload $pl 'mpio' | Out-Null
            $global:Fh.Feature = 'Disabled'
            Invoke-FhScript 'Install-Mpio.ps1' @{ PayloadPath = $pl; NoReboot = $true } | Should -Be 1
        }
        It 'fails without payload' {
            Invoke-FhScript 'Install-Mpio.ps1' @{ PayloadPath = $pl; NoReboot = $true } | Should -Be 1
        }
        It 'installs LBFO and restores teams' {
            New-FhTestPayload $pl 'lbfo' | Out-Null
            Invoke-FhScript 'Install-Lbfo.ps1' @{ PayloadPath = $pl; RestoreTeams = $true; NoReboot = $true } | Should -Be 0
            $st = Get-FhState 'lbfo'
            $st.Catalogs | Should -Be 'FeatureHeist-a.cat'
            $st.Files.Count | Should -Be 2
            Test-Path (Join-Path $win 'INF\mslbfoprovider.inf') | Should -BeTrue
            Should -Invoke Restore-FhTeams -Times 1
            Should -Invoke Invoke-FhNative -Times 1 -ParameterFilter { $FilePath -eq 'netcfg.exe' }
        }
        It 'returns 3010 when NetCfg needs a reboot' {
            $d = New-FhTestPayload $pl 'lbfo'
            Remove-Item (Join-Path $d 'driver\MsLbfoProvider.sys.mui')
            Write-FhManifest $d @{}
            Mock Invoke-FhNative -ParameterFilter { $FilePath -eq 'netcfg.exe' } { 0x0004A020 }
            Invoke-FhScript 'Install-Lbfo.ps1' @{ PayloadPath = $pl; RestoreTeams = $true; NoReboot = $true } | Should -Be 3010
            Should -Invoke Restore-FhTeams -Times 0
        }
        It 'detects its own and foreign installations' {
            Set-FhState 'lbfo' @{ A = 1 }
            Invoke-FhScript 'Install-Lbfo.ps1' @{ PayloadPath = $pl } | Should -Be 0
            Remove-FhState 'lbfo'
            $global:Fh.Owner = 'Foreign'
            Invoke-FhScript 'Install-Lbfo.ps1' @{ PayloadPath = $pl } | Should -Be 1
            Get-FhTestLog | Should -Match 'Migrate-FromWindows11LBFO'
        }
        It 'installs LbfoAdmin on a foreign LBFO' {
            New-FhTestPayload $pl 'lbfoadmin' | Out-Null
            $global:Fh.Owner = 'Foreign'
            Invoke-FhScript 'Install-LbfoAdmin.ps1' @{ PayloadPath = $pl; NoReboot = $true } | Should -Be 3010
        }
        It 'refuses LBFO alone over a foreign LBFO' {
            $global:Fh.Owner = 'Foreign'
            Invoke-FhScript 'Install-All.ps1' @{ Packages = 'Lbfo'; PayloadPath = $pl; NoReboot = $true } | Should -Be 1
            Get-FhTestLog | Should -Match 'ERROR: LBFO is installed by another tool'
        }
        It 'skips a foreign LBFO when unattended' {
            foreach ($p in 'mpio', 'lbfoadmin') { New-FhTestPayload $pl $p | Out-Null }
            $global:Fh.Owner = 'Foreign'
            Invoke-FhScript 'Install-All.ps1' @{ PayloadPath = $pl; NoReboot = $true } | Should -Be 3010
            Get-FhTestLog | Should -Match 'WARNING: LBFO skipped'
            Get-FhState 'lbfo' | Should -BeNullOrEmpty
            Get-FhState 'lbfoadmin' | Should -Not -BeNullOrEmpty
            Should -Invoke Read-Host -Times 0
        }
        It 'asks whether to skip a foreign LBFO' {
            New-FhTestPayload $pl 'mpio' | Out-Null
            $global:Fh.Owner = 'Foreign'
            Mock Test-FhInteractive { $true }
            Mock Read-Host { 'a' }
            Invoke-FhScript 'Install-All.ps1' @{ Packages = 'Mpio', 'Lbfo'; PayloadPath = $pl; NoReboot = $true } | Should -Be 1
            Get-FhState 'mpio' | Should -BeNullOrEmpty
            Mock Read-Host { 's' }
            Invoke-FhScript 'Install-All.ps1' @{ Packages = 'Mpio', 'Lbfo'; PayloadPath = $pl; NoReboot = $true } | Should -Be 3010
            Get-FhState 'mpio' | Should -Not -BeNullOrEmpty
        }
        It 'reports a partial installation' {
            New-FhTestPayload $pl 'lbfo' | Out-Null
            $global:Fh.Driver = 'Stopped'
            Invoke-FhScript 'Install-Lbfo.ps1' @{ PayloadPath = $pl; NoReboot = $true } | Should -Be 1
            Get-FhTestLog | Should -Match 'Partial installation'
        }
        It 'does not overwrite existing files' {
            New-FhTestPayload $pl 'lbfo' | Out-Null
            Set-Content (Join-Path $win 'System32\drivers\MsLbfoProvider.sys') ''
            Invoke-FhScript 'Install-Lbfo.ps1' @{ PayloadPath = $pl; NoReboot = $true } | Should -Be 1
            Remove-Item (Join-Path $win 'System32\drivers\MsLbfoProvider.sys')
            Remove-FhState 'lbfo'
            Set-Content (Join-Path $win 'INF\mslbfoprovider.inf') ''
            Invoke-FhScript 'Install-Lbfo.ps1' @{ PayloadPath = $pl; NoReboot = $true } | Should -Be 1
            Get-FhTestLog | Should -Match 'Already exists: .*mslbfoprovider.inf'
        }
        It 'rejects an unexpected service type' {
            New-FhTestPayload $pl 'lbfo' -ServiceType 2 | Out-Null
            Invoke-FhScript 'Install-Lbfo.ps1' @{ PayloadPath = $pl; NoReboot = $true } | Should -Be 1
            Get-FhTestLog | Should -Match 'Unexpected service type'
        }
        It 'installs LbfoAdmin only after LBFO' {
            New-FhTestPayload $pl 'lbfoadmin' | Out-Null
            Invoke-FhScript 'Install-LbfoAdmin.ps1' @{ PayloadPath = $pl; NoReboot = $true } | Should -Be 1
            Set-FhState 'lbfo' @{ A = 1 }
            Invoke-FhScript 'Install-LbfoAdmin.ps1' @{ PayloadPath = $pl; NoReboot = $true } | Should -Be 3010
            Get-FhState 'lbfoadmin' | Should -Not -BeNullOrEmpty
        }
        It 'installs all packages with one reboot' {
            foreach ($p in 'mpio', 'lbfo', 'lbfoadmin') { New-FhTestPayload $pl $p | Out-Null }
            Invoke-FhScript 'Install-All.ps1' @{ PayloadPath = $pl; SourcePath = 'x.iso'; ClaimBusType = 'iSCSI'; RestoreTeams = $true; RestoreSessions = $true; NoReboot = $true } | Should -Be 3010
            foreach ($p in 'mpio', 'lbfo', 'lbfoadmin') { Get-FhState $p | Should -Not -BeNullOrEmpty }
            Should -Invoke Open-FhSource -Times 0
            Should -Invoke Restore-FhTeams -Times 1
        }
        It 'extracts missing packages first' {
            Invoke-FhScript 'Install-All.ps1' @{ Packages = 'Mpio'; PayloadPath = $pl; SourcePath = 'x.iso'; Index = 2; NoReboot = $true } | Should -Be 3010
            Should -Invoke Open-FhSource -Times 1 -ParameterFilter { $Index -eq 2 }
        }
        It 'stops when the extraction fails' {
            Mock Open-FhSource { throw 'no media' }
            Invoke-FhScript 'Install-All.ps1' @{ Packages = 'Mpio'; SourcePath = 'x.iso'; NoReboot = $true } | Should -Be 1
        }
        It 'stops at the first failed package' {
            Invoke-FhScript 'Install-All.ps1' @{ Packages = 'Lbfo', 'LbfoAdmin'; PayloadPath = $pl; NoReboot = $true } | Should -Be 1
            Get-FhTestLog | Should -Match 'Install-Lbfo failed'
            Get-FhTestLog | Should -Not -Match 'Install-LbfoAdmin'
        }
        It 'needs no reboot when nothing asks for one' {
            New-FhTestPayload $pl 'lbfoadmin' | Out-Null
            Set-FhState 'lbfo' @{ A = 1 }
            Mock Install-FhCbsPackage { $false }
            Invoke-FhScript 'Install-All.ps1' @{ Packages = 'LbfoAdmin'; PayloadPath = $pl } | Should -Be 0
        }
    }

    Context 'Uninstall' {
        It 'removes LbfoAdmin' {
            Set-FhState 'lbfoadmin' @{ A = 1 }
            Invoke-FhScript 'Uninstall-LbfoAdmin.ps1' @{ NoReboot = $true } | Should -Be 3010
            Get-FhState 'lbfoadmin' | Should -BeNullOrEmpty
            Mock Uninstall-FhCbsPackage { throw 'dism' }
            Invoke-FhScript 'Uninstall-LbfoAdmin.ps1' @{ NoReboot = $true } | Should -Be 1
        }
        It 'leaves LBFO alone that it did not install' {
            Invoke-FhScript 'Uninstall-Lbfo.ps1' | Should -Be 0
            Get-FhTestLog | Should -Match 'not installed by Feature Heist'
        }
        It 'keeps LBFO while teams exist' {
            Set-FhState 'lbfo' @{ A = 1 }
            $global:Fh.Teams = @('T')
            Invoke-FhScript 'Uninstall-Lbfo.ps1' @{ NoReboot = $true } | Should -Be 1
            Get-FhState 'lbfo' | Should -Not -BeNullOrEmpty
        }
        It 'removes LBFO with -Force' {
            $sys = Join-Path $win 'System32\drivers\MsLbfoProvider.sys'
            $inf = Join-Path $win 'INF\mslbfoprovider.inf'
            Set-Content $sys ''
            Set-Content $inf ''
            Set-FhState 'lbfo' ([ordered]@{ Catalogs = @('FeatureHeist-a.cat'); Files = @($sys); Inf = $inf; Service = 'MsLbfoProvider' })
            Set-FhState 'lbfoadmin' @{ A = 1 }
            $global:Fh.Teams = @('T')
            $global:Fh.Net = $true
            $global:Fh.Svc = $true
            Invoke-FhScript 'Uninstall-Lbfo.ps1' @{ Force = $true; NoReboot = $true } | Should -Be 3010
            Should -Invoke Remove-NetLbfoTeam -Times 1
            Should -Invoke Invoke-FhNative -Times 1 -ParameterFilter { $FilePath -eq 'netcfg.exe' }
            Should -Invoke Invoke-FhNative -Times 2 -ParameterFilter { $FilePath -eq 'sc.exe' }
            Should -Invoke Remove-FhCatalog -Times 1
            Test-Path $sys | Should -BeFalse
            Test-Path $inf | Should -BeFalse
            Get-FhState 'lbfo' | Should -BeNullOrEmpty
            Get-FhState 'lbfoadmin' | Should -BeNullOrEmpty
        }
        It 'stops when LbfoAdmin cannot be removed' {
            Set-FhState 'lbfo' @{ A = 1 }
            Set-FhState 'lbfoadmin' @{ A = 1 }
            Mock Uninstall-FhCbsPackage { throw 'dism' }
            Invoke-FhScript 'Uninstall-Lbfo.ps1' @{ NoReboot = $true } | Should -Be 1
            Get-FhState 'lbfo' | Should -Not -BeNullOrEmpty
        }
        It 'finds no MPIO to remove' {
            Set-FhState 'mpio' @{ A = 1 }
            Invoke-FhScript 'Uninstall-Mpio.ps1' | Should -Be 0
            Get-FhState 'mpio' | Should -BeNullOrEmpty
        }
        It 'keeps MPIO while it claims disks' {
            $global:Fh.Packages = @('Microsoft-Windows-MultipathIo-Package~31bf3856ad364e35~amd64~~10.0.26100.1')
            $global:Fh.Disks = @('d1')
            Invoke-FhScript 'Uninstall-Mpio.ps1' @{ NoReboot = $true } | Should -Be 1
        }
        It 'removes MPIO with -Force' {
            $global:Fh.Packages = @('Microsoft-Windows-MultipathIo-Package~31bf3856ad364e35~amd64~~10.0.26100.1')
            $global:Fh.Disks = @('d1')
            Set-Content (Join-Path (Get-FhDataDir) 'MsdsmFix.ps1') ''
            Mock Disable-MSDSMAutomaticClaim { throw 'not claimed' }
            Invoke-FhScript 'Uninstall-Mpio.ps1' @{ Force = $true; NoReboot = $true } | Should -Be 3010
            Should -Invoke Invoke-FhDism -Times 1
            Test-Path (Join-Path $data 'MsdsmFix.ps1') | Should -BeFalse
        }
        It 'removes MPIO when the WMI class is missing' {
            $global:Fh.Packages = @('Microsoft-Windows-MultipathIo-Package~31bf3856ad364e35~amd64~~10.0.26100.1')
            $global:Fh.Feature = 'Disabled'
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'MPIO_DISK_INFO' } { throw 'invalid class' }
            Invoke-FhScript 'Uninstall-Mpio.ps1' @{ NoReboot = $true } | Should -Be 3010
            Should -Invoke Invoke-FhDism -Times 0
            Mock Uninstall-FhCbsPackage { throw 'dism' }
            Invoke-FhScript 'Uninstall-Mpio.ps1' @{ NoReboot = $true } | Should -Be 1
        }
        It 'removes nothing when one package would refuse' {
            Set-FhState 'lbfo' @{ A = 1 }
            $global:Fh.Teams = @('T')
            $global:Fh.Disks = @('d1')
            Invoke-FhScript 'Uninstall-All.ps1' @{ NoReboot = $true } | Should -Be 1
            Get-FhTestLog | Should -Match 'NIC teams exist, MPIO claims disks'
            Get-FhState 'lbfo' | Should -Not -BeNullOrEmpty
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'MPIO_DISK_INFO' } { throw 'invalid class' }
            Invoke-FhScript 'Uninstall-All.ps1' @{ Packages = 'Mpio'; NoReboot = $true } | Should -Be 0
        }
        It 'removes all packages with -Force' {
            Set-FhState 'lbfo' ([ordered]@{ Catalogs = @(); Files = @(); Inf = $null })
            Set-FhState 'lbfoadmin' @{ A = 1 }
            $global:Fh.Packages = @('Microsoft-Windows-MultipathIo-Package~31bf3856ad364e35~amd64~~10.0.26100.1')
            $global:Fh.Teams = @('T')
            Invoke-FhScript 'Uninstall-All.ps1' @{ Force = $true; NoReboot = $true } | Should -Be 3010
            foreach ($p in 'mpio', 'lbfo', 'lbfoadmin') { Get-FhState $p | Should -BeNullOrEmpty }
        }
        It 'stops at the first failed package' {
            Set-FhState 'lbfoadmin' @{ A = 1 }
            Mock Uninstall-FhCbsPackage { throw 'dism' }
            Invoke-FhScript 'Uninstall-All.ps1' @{ NoReboot = $true } | Should -Be 1
            Get-FhTestLog | Should -Match 'Uninstall-LbfoAdmin failed'
        }
    }

    Context 'Watch' {
        It 'saves teams and sessions while all packages are active' {
            foreach ($p in 'mpio', 'lbfo', 'lbfoadmin') { Set-FhState $p @{ A = 1 } }
            $global:Fh.Packages = @('Microsoft-Windows-NDIS-LBFO-Admin-RSAT-Group-Package~31bf3856ad364e35~amd64~~10.0.26100.1')
            New-Item -ItemType File -Force (Join-Path $data 'backup\iscsi.pending') | Out-Null
            Invoke-FhScript 'Watch-All.ps1' | Should -Be 0
            Should -Invoke Restore-FhIscsiSessions -Times 1
            Should -Invoke Save-FhTeams -Times 1
            Should -Invoke Save-FhIscsiSessions -Times 1
            Test-Path (Join-Path $data 'backup\iscsi.pending') | Should -BeFalse
        }
        It 'warns when packages are gone' {
            foreach ($p in 'mpio', 'lbfo', 'lbfoadmin') { Set-FhState $p @{ A = 1 } }
            foreach ($p in 'mpio', 'lbfo', 'lbfoadmin') { New-FhTestPayload $pl $p | Out-Null }
            Set-FhPayloadRoot $pl
            $global:Fh.Feature = 'Disabled'
            $global:Fh.Driver = 'Stopped'
            Invoke-FhScript 'Watch-All.ps1' | Should -Be 0
            Should -Invoke Limit-FhIscsiSessions -Times 1
            Should -Invoke Write-EventLog -Times 1
            Should -Invoke msg.exe -Times 1
            Get-FhTestLog | Should -Match 'mpio, lbfo, lbfoadmin no longer active.*Reinstall'
        }
        It 'asks for Server media when no payload fits' {
            Set-FhState 'lbfo' @{ A = 1 }
            Set-FhPayloadRoot (New-Item -ItemType Directory -Force $pl).FullName
            $global:Fh.Driver = 'Stopped'
            Invoke-FhScript 'Watch-All.ps1' | Should -Be 0
            Should -Invoke Limit-FhIscsiSessions -Times 0
            Get-FhTestLog | Should -Match 'Server media of this build'
        }
        It 'reports errors' {
            Mock Get-FhState { throw 'registry' }
            Invoke-FhScript 'Watch-All.ps1' | Should -Be 1
        }
    }
}
