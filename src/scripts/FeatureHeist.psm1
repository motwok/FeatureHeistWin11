# Shared functions of the Feature Heist scripts. Windows PowerShell 5.1, no external modules.
Set-StrictMode -Version 2.0

$script:Product  = 'FeatureHeist'
$script:DataDir  = Join-Path $env:ProgramData $script:Product
$script:RegRoot  = "HKLM:\SOFTWARE\$script:Product"
$script:LogFile  = Join-Path $script:DataDir 'FeatureHeist.log'
$script:CatRoot  = Join-Path $env:SystemRoot 'System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
$script:RebootCode = 3010

if (-not ('FeatureHeist.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
namespace FeatureHeist {
public static class Native {
    [DllImport("wintrust.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CryptCATAdminAcquireContext2(out IntPtr h, ref Guid subsystem, string hashAlg, IntPtr policy, uint flags);
    [DllImport("wintrust.dll", SetLastError = true)]
    static extern bool CryptCATAdminReleaseContext(IntPtr h, uint flags);
    [DllImport("wintrust.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CryptCATAdminAddCatalog(IntPtr h, string file, string baseName, uint flags);
    [DllImport("wintrust.dll", SetLastError = true)]
    static extern bool CryptCATAdminReleaseCatalogContext(IntPtr h, IntPtr info, uint flags);
    [DllImport("wintrust.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CryptCATAdminRemoveCatalog(IntPtr h, string file, uint flags);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool MoveFileEx(string existing, string newName, int flags);
    // DRIVER_ACTION_VERIFY
    static Guid Subsystem = new Guid("F750E6C3-38EE-11D1-85E5-00C04FC295EE");

    static IntPtr Acquire() {
        IntPtr h; Guid g = Subsystem;
        if (!CryptCATAdminAcquireContext2(out h, ref g, "SHA256", IntPtr.Zero, 0))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return h;
    }
    public static void AddCatalog(string file, string baseName) {
        IntPtr h = Acquire();
        try {
            IntPtr info = CryptCATAdminAddCatalog(h, file, baseName, 0);
            if (info == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            CryptCATAdminReleaseCatalogContext(h, info, 0);
        } finally { CryptCATAdminReleaseContext(h, 0); }
    }
    public static int RemoveCatalog(string baseName) {
        IntPtr h = Acquire();
        try { return CryptCATAdminRemoveCatalog(h, baseName, 0) ? 0 : Marshal.GetLastWin32Error(); }
        finally { CryptCATAdminReleaseContext(h, 0); }
    }

    // Authenticode digest: excludes CheckSum, security directory entry and certificate table.
    static byte[] PeHash(byte[] f, HashAlgorithm h) {
        if (f.Length < 0x40 || f[0] != 'M' || f[1] != 'Z') return null;
        int pe = BitConverter.ToInt32(f, 0x3C);
        if (pe < 0 || pe + 0x18 >= f.Length || BitConverter.ToUInt32(f, pe) != 0x4550) return null;
        int opt = pe + 0x18;
        int chk = opt + 0x40;
        int sec = opt + (BitConverter.ToUInt16(f, opt) == 0x20B ? 0x70 : 0x60) + 4 * 8;
        int certOff = BitConverter.ToInt32(f, sec);
        int certLen = BitConverter.ToInt32(f, sec + 4);
        int end = (certOff > 0 && certLen > 0 && certOff <= f.Length) ? certOff : f.Length;
        h.TransformBlock(f, 0, chk, null, 0);
        h.TransformBlock(f, chk + 4, sec - (chk + 4), null, 0);
        h.TransformBlock(f, sec + 8, end - (sec + 8), null, 0);
        h.TransformFinalBlock(new byte[0], 0, 0);
        return h.Hash;
    }
    // Hashes a catalog may list for a file: Authenticode (PE) or flat, SHA256 and SHA1.
    public static byte[][] CatalogHashes(string path) {
        byte[] f = File.ReadAllBytes(path);
        byte[] a = PeHash(f, SHA256.Create()), b = PeHash(f, SHA1.Create());
        if (a == null) { a = SHA256.Create().ComputeHash(f); b = SHA1.Create().ComputeHash(f); }
        return new byte[][] { a, b };
    }
    public static bool Contains(byte[] hay, byte[][] needles) {
        foreach (byte[] n in needles) {
            for (int i = 0; i <= hay.Length - n.Length; i++) {
                if (hay[i] != n[0]) continue;
                int j = 1;
                while (j < n.Length && hay[i + j] == n[j]) j++;
                if (j == n.Length) return true;
            }
        }
        return false;
    }
}
}
'@
}

# ---------------------------------------------------------------- log, run

function Write-FhLog {
    param([Parameter(Mandatory)][string]$Message)
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Force $script:DataDir | Out-Null }
    $l = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Add-Content -Path $script:LogFile -Value $l -Encoding UTF8
    Write-Host $l
}

function Invoke-FhNative {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList, [int[]]$Success = @(0))
    # native stderr must not become a terminating error
    $ErrorActionPreference = 'Continue'
    $out = & $FilePath @ArgumentList 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Add-Content -Path $script:LogFile -Value "    $_" -Encoding UTF8 }
    if ($Success -notcontains $code) {
        throw "$FilePath $($ArgumentList -join ' ') failed: exit $code $(($out | Select-Object -Last 2) -join ' ')"
    }
    $code
}

function Invoke-FhDism {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $code = Invoke-FhNative dism.exe (@('/online') + $ArgumentList + @('/norestart', '/quiet')) @(0, 3010)
    $code -eq 3010
}

# Exit code for MSI/Intune: 0 or 3010. Reboots only when run by hand without -NoReboot.
function Complete-FhRun {
    param([bool]$RebootRequired, [switch]$NoReboot)
    if (-not $RebootRequired) { return 0 }
    if ($NoReboot) { Write-FhLog 'Reboot required.'; return $script:RebootCode }
    Write-FhLog 'Rebooting in 10 seconds.'
    & shutdown.exe /r /t 10 /c "$script:Product" | Out-Null
    $script:RebootCode
}

function Get-FhDataDir {
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Force $script:DataDir | Out-Null }
    $script:DataDir
}

function Get-FhWindowsDir { $env:SystemRoot }

function Test-FhSystem { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18' }

# Runs a PowerShell command line as a one-shot SYSTEM task and returns its exit code. Used where the
# caller's token is not enough: MSI custom actions (DISM mount, 1314), keys only SYSTEM may change.
function Invoke-FhAsSystem {
    param([Parameter(Mandatory)][string]$Command, [string]$Name = 'FeatureHeist-RunAsSystem')
    $c = "$Command; exit `$LASTEXITCODE"
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $Name -Force `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$($c.Replace('"', '\"'))`"") `
        -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest) `
        -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) | Out-Null
    try {
        Start-ScheduledTask -TaskName $Name
        Start-Sleep 2
        while ((Get-ScheduledTask -TaskName $Name).State -eq 'Running') { Start-Sleep 2 }
        [int](Get-ScheduledTaskInfo -TaskName $Name).LastTaskResult
    } finally {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function ConvertTo-FhArg { param([string]$s) "'" + $s.Replace("'", "''") + "'" }

function Assert-FhAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as administrator.' }
}

# Servicing base build; enablement releases (25H2, 26H2) report a higher CurrentBuildNumber.
function Get-FhBaseBuild {
    (Get-Item (Join-Path $env:SystemRoot 'System32\ntoskrnl.exe')).VersionInfo.FileBuildPart
}

function Get-FhUiLanguages {
    @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages' -ErrorAction SilentlyContinue | ForEach-Object PSChildName)
}

# ------------------------------------------------------------------ state

function Get-FhKey {
    param([string]$Sub)
    $k = if ($Sub) { "$script:RegRoot\$Sub" } else { $script:RegRoot }
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    $k
}

function Get-FhState {
    param([Parameter(Mandatory)][string]$Package)
    $k = "$script:RegRoot\Packages\$Package"
    if (-not (Test-Path $k)) { return $null }
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    if ($p -and ($p.PSObject.Properties.Name -contains 'State')) { $p.State | ConvertFrom-Json } else { $null }
}

function Set-FhState {
    param([Parameter(Mandatory)][string]$Package, [Parameter(Mandatory)]$State)
    Set-ItemProperty -Path (Get-FhKey "Packages\$Package") -Name State -Value ($State | ConvertTo-Json -Depth 5 -Compress)
}

function Remove-FhState {
    param([Parameter(Mandatory)][string]$Package)
    $k = "$script:RegRoot\Packages\$Package"
    if (Test-Path $k) { Remove-Item $k -Recurse -Force }
    if ((Test-Path "$script:RegRoot\Packages") -and -not (Get-ChildItem "$script:RegRoot\Packages")) { Remove-Item "$script:RegRoot\Packages" -Force }
}

# ---------------------------------------------------------------- payload

# Order: -PayloadPath, registry (written by Extract), <scripts>\payload.
function Get-FhPayloadRoot {
    param([string]$PayloadPath)
    if ($PayloadPath) { return $PayloadPath }
    $r = (Get-ItemProperty $script:RegRoot -ErrorAction SilentlyContinue)
    if ($r -and ($r.PSObject.Properties.Name -contains 'PayloadPath') -and $r.PayloadPath) { return $r.PayloadPath }
    Join-Path $PSScriptRoot 'payload'
}

function Set-FhPayloadRoot {
    param([Parameter(Mandatory)][string]$PayloadPath)
    $def = Join-Path $PSScriptRoot 'payload'
    $k = Get-FhKey
    if ((Resolve-Path $PayloadPath).Path.TrimEnd('\') -ieq $def.TrimEnd('\')) { Remove-ItemProperty $k -Name PayloadPath -ErrorAction SilentlyContinue }
    else { Set-ItemProperty $k -Name PayloadPath -Value (Resolve-Path $PayloadPath).Path }
}

function Write-FhManifest {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Source)
    $files = foreach ($f in Get-ChildItem $Path -Recurse -File | Where-Object Name -ne 'manifest.json') {
        [ordered]@{ Path = $f.FullName.Substring($Path.Length + 1); Sha256 = (Get-FileHash $f.FullName -Algorithm SHA256).Hash }
    }
    [ordered]@{ Source = $Source; Created = (Get-Date).ToString('s'); Files = @($files) } |
        ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Path 'manifest.json') -Encoding UTF8
}

function Test-FhManifest {
    param([Parameter(Mandatory)][string]$Path)
    $m = Join-Path $Path 'manifest.json'
    if (-not (Test-Path $m)) { throw "No manifest: $m" }
    $j = Get-Content $m -Raw | ConvertFrom-Json
    foreach ($f in $j.Files) {
        $p = Join-Path $Path $f.Path
        if (-not (Test-Path $p)) { throw "Payload file missing: $p" }
        if ((Get-FileHash $p -Algorithm SHA256).Hash -ne $f.Sha256) { throw "Payload file modified: $p" }
    }
    $j
}

# Payload dir of a package for this machine's base build; $null if absent.
function Find-FhPayload {
    param([Parameter(Mandatory)][string]$Package, [string]$PayloadPath)
    $d = Join-Path (Join-Path (Get-FhPayloadRoot $PayloadPath) (Get-FhBaseBuild)) $Package
    if (Test-Path (Join-Path $d 'manifest.json')) { $d } else { $null }
}

# Install scripts: payload dir, extracted first from -SourcePath if missing.
function Resolve-FhPayload {
    param([Parameter(Mandatory)][string]$Package, [string]$PayloadPath, [string]$SourcePath, [int]$Index, [Parameter(Mandatory)][string]$ExtractScript)
    $d = Find-FhPayload $Package $PayloadPath
    if (-not $d) {
        if (-not $SourcePath) { throw "No $Package payload for build $(Get-FhBaseBuild) in $(Get-FhPayloadRoot $PayloadPath). Run $ExtractScript or pass -SourcePath." }
        $a = @{ SourcePath = $SourcePath }
        if ($PayloadPath) { $a.PayloadPath = $PayloadPath }
        if ($Index) { $a.Index = $Index }
        & (Join-Path $PSScriptRoot $ExtractScript) @a | Out-Null
        $d = Find-FhPayload $Package $PayloadPath
        if (-not $d) { throw "Extraction did not produce a $Package payload for build $(Get-FhBaseBuild); the Server media build must match." }
    }
    Write-FhLog "Payload: $d"
    $null = Test-FhManifest $d
    $d
}

# ------------------------------------------------------------ source image

# ISO, install.wim/esd or drive root -> @{ Wim; Index; Build; Name; Version; Iso }.
function Open-FhSource {
    param([string]$SourcePath, [int]$Index)
    $iso = $null
    if ($SourcePath -match '\.iso$') {
        $iso = Mount-DiskImage -ImagePath (Resolve-Path $SourcePath).Path -PassThru
        $SourcePath = '{0}:\' -f ($iso | Get-Volume).DriveLetter
        Write-FhLog "ISO mounted as $SourcePath"
    }
    $cand = if ($SourcePath -match '\.(wim|esd)$') { @($SourcePath) }
            elseif ($SourcePath) { 'install.wim', 'install.esd' | ForEach-Object { [IO.Path]::Combine($SourcePath, "sources\$_") } }
            else { foreach ($d in Get-PSDrive -PSProvider FileSystem) { 'install.wim', 'install.esd' | ForEach-Object { Join-Path $d.Root "sources\$_" } } }
    $wim = $cand | Where-Object { (Test-Path $_ -ErrorAction SilentlyContinue) -and (Get-WindowsImage -ImagePath $_ | Where-Object ImageName -like '*Server*') } | Select-Object -First 1
    if (-not $wim) {
        if ($iso) { Dismount-DiskImage -ImagePath $iso.ImagePath | Out-Null }
        throw 'No Windows Server install.wim/esd found; pass -SourcePath.'
    }
    $imgs = foreach ($i in Get-WindowsImage -ImagePath $wim) { Get-WindowsImage -ImagePath $wim -Index $i.ImageIndex }
    $img = if ($Index) { $imgs | Where-Object ImageIndex -eq $Index } else { $imgs | Sort-Object ImageSize | Select-Object -First 1 }
    if (-not $img) { throw "Index $Index not found in $wim" }
    Write-FhLog ('Source: {0} index {1}: {2} {3}' -f $wim, $img.ImageIndex, $img.ImageName, $img.Version)
    [pscustomobject]@{ Wim = $wim; Index = $img.ImageIndex; Build = [int]($img.Version -split '\.')[2]; Name = $img.ImageName; Version = $img.Version; Iso = $iso }
}

function Close-FhSource {
    param($Source)
    if ($Source -and $Source.Iso) { Dismount-DiskImage -ImagePath $Source.Iso.ImagePath | Out-Null }
}

# Read-only mount of the source, or (-Writable) a mount of an exported copy; the source is never changed.
function Mount-FhImage {
    param([Parameter(Mandatory)]$Source, [switch]$Writable, [string[]]$EnableFeature)
    $dir = Join-Path $script:DataDir 'mount'
    if (Get-WindowsImage -Mounted | Where-Object Path -eq $dir) { Dismount-WindowsImage -Path $dir -Discard | Out-Null }
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $copy = $null
    if ($Writable -or $EnableFeature) {
        $copy = Join-Path $script:DataDir 'source.wim'
        if (Test-Path $copy) { Remove-Item $copy -Force }
        Write-FhLog 'Exporting image to a working copy.'
        Export-WindowsImage -SourceImagePath $Source.Wim -SourceIndex $Source.Index -DestinationImagePath $copy -CompressionType fast | Out-Null
        Mount-WindowsImage -ImagePath $copy -Index 1 -Path $dir | Out-Null
        # disabled features keep their payload compressed (DCS); enabling expands it
        foreach ($f in $EnableFeature) {
            Write-FhLog "Enabling $f in the working copy."
            Enable-WindowsOptionalFeature -Path $dir -FeatureName $f -All | Out-Null
        }
    } else {
        Mount-WindowsImage -ImagePath $Source.Wim -Index $Source.Index -Path $dir -ReadOnly | Out-Null
    }
    [pscustomobject]@{ Path = $dir; Copy = $copy }
}

function Dismount-FhImage {
    param($Image)
    if (-not $Image) { return }
    if (Get-WindowsImage -Mounted | Where-Object Path -eq $Image.Path) { Dismount-WindowsImage -Path $Image.Path -Discard | Out-Null }
    if (Test-Path $Image.Path) { Remove-Item $Image.Path -Recurse -Force -ErrorAction SilentlyContinue }
    if ($Image.Copy -and (Test-Path $Image.Copy)) { Remove-Item $Image.Copy -Force -ErrorAction SilentlyContinue }
}

function New-FhPayloadDir {
    param([Parameter(Mandatory)][string]$Package, [Parameter(Mandatory)]$Source, [string]$PayloadPath)
    $root = Get-FhPayloadRoot $PayloadPath
    $d = Join-Path (Join-Path $root $Source.Build) $Package
    if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    New-Item -ItemType Directory -Force $d | Out-Null
    Set-FhPayloadRoot $root
    $d
}

function Get-FhSourceInfo {
    param([Parameter(Mandatory)]$Source)
    [ordered]@{ Image = $Source.Name; Version = $Source.Version; Index = $Source.Index; File = Split-Path $Source.Wim -Leaf }
}

# ------------------------------------------------------------ CBS packages

# Newest neutral .mum and newest language pack .mum per language of a package.
function Get-FhPackageMums {
    param([Parameter(Mandatory)][string]$Mount, [Parameter(Mandatory)][string]$Name)
    $pk = Join-Path $Mount 'Windows\servicing\Packages'
    $all = @(Get-ChildItem $pk -Filter "$Name~*~amd64~*.mum")
    $byLang = $all | Group-Object { ($_.BaseName -split '~')[3] }
    foreach ($g in $byLang) {
        $m = $g.Group | Sort-Object { [version](($_.BaseName -split '~')[-1]) } | Select-Object -Last 1
        [pscustomobject]@{ Language = $(if ($g.Name) { $g.Name } else { 'neutral' }); Mum = $m }
    }
}

# Expanded-CAB package folder (update.mum/.cat, manifests, payload) from a mounted image.
# Components are resolved through a copy of the image's COMPONENTS hive.
function Export-FhCbsPackage {
    param([Parameter(Mandatory)][string]$Mount, [Parameter(Mandatory)][IO.FileInfo[]]$Mum, [Parameter(Mandatory)][string]$Destination)
    $hive = Join-Path (Get-FhDataDir) 'COMPONENTS.copy'
    $key = 'FH_SRC_COMPONENTS'
    Copy-Item (Join-Path $Mount 'Windows\System32\config\COMPONENTS') $hive -Force
    Invoke-FhNative reg.exe @('load', "HKLM\$key", $hive) | Out-Null
    $hk = $null
    try {
        $hk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("$key\DerivedData\Components")
        $all = $hk.GetSubKeyNames()
        $sxs = Join-Path $Mount 'Windows\WinSxS'
        foreach ($m in $Mum) {
            $lang = ($m.BaseName -split '~')[3]
            $dest = Join-Path $Destination $(if ($lang) { $lang } else { 'neutral' })
            New-Item -ItemType Directory -Force $dest | Out-Null
            Copy-Item $m.FullName (Join-Path $dest 'update.mum')
            Copy-Item ([IO.Path]::ChangeExtension($m.FullName, '.cat')) (Join-Path $dest 'update.cat')
            [xml]$x = Get-Content $m.FullName -Raw
            $keys = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($u in $x.assembly.package.update) {
                foreach ($ai in @($u.SelectNodes('*[local-name()="component" or local-name()="driver"]/*[local-name()="assemblyIdentity"]'))) {
                    $culture = if ($ai.language -and $ai.language -ne 'neutral') { $ai.language.ToLower() } else { 'none' }
                    $k = $null
                    foreach ($c in $all -like "$($ai.processorArchitecture)_*_$($ai.version)_$($culture)_*") {
                        $s = $hk.OpenSubKey($c)
                        try { $id = $s.GetValue('identity'); if ($id -is [byte[]]) { $id = [Text.Encoding]::ASCII.GetString($id) } } finally { $s.Close() }
                        if ("$id" -like "$($ai.name),*") { $k = $c; break }
                    }
                    if (-not $k) { throw "Component not found: $($ai.name) $($ai.version) $($ai.language)" }
                    [void]$keys.Add($k)
                    # owned components carry a c!<name>_<hash> value with the deployment's hash
                    $hash = ($k -split '_')[-1]
                    foreach ($n in $all) {
                        $s = $hk.OpenSubKey($n)
                        try { if ($s.GetValueNames() | Where-Object { $_ -like 'c!*' -and ($_ -split '_')[-1] -eq $hash }) { [void]$keys.Add($n) } } finally { $s.Close() }
                    }
                }
            }
            foreach ($k in $keys) {
                $man = Join-Path $sxs "Manifests\$k.manifest"
                if (-not (Test-Path $man)) { throw "Manifest missing in image: $k" }
                Copy-Item $man (Join-Path $dest "$k.manifest")
                $src = Join-Path $sxs $k
                $files = if (Test-Path $src) { @(Get-ChildItem $src -File) } else { @() }
                if ($files) {
                    New-Item -ItemType Directory -Force (Join-Path $dest $k) | Out-Null
                    foreach ($f in $files) {
                        $fs = [IO.File]::OpenRead($f.FullName)
                        try { $b = New-Object byte[] 4; [void]$fs.Read($b, 0, 4) } finally { $fs.Close() }
                        if ($b[0] -eq 0x44 -and $b[1] -eq 0x43 -and $b[2] -eq 0x53 -and $b[3] -eq 1) { throw "Payload still compressed (DCS): $($f.FullName)" }
                        Copy-Item $f.FullName (Join-Path $dest "$k\$($f.Name)")
                    }
                }
            }
            Write-FhLog "Exported $($m.BaseName) ($($keys.Count) components)"
        }
    } finally {
        if ($hk) { $hk.Close() }
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        Invoke-FhNative reg.exe @('unload', "HKLM\$key") @(0, 1) | Out-Null
        Remove-Item "$hive*" -Force -ErrorAction SilentlyContinue
    }
}

# Installs neutral package, then the language packs of installed UI languages; returns reboot flag.
function Install-FhCbsPackage {
    param([Parameter(Mandatory)][string]$Path)
    $reboot = $false
    $dirs = @(Join-Path $Path 'neutral') + @(Get-FhUiLanguages | ForEach-Object { Join-Path $Path $_ } | Where-Object { Test-Path (Join-Path $_ 'update.mum') })
    foreach ($d in $dirs) {
        Write-FhLog "dism /add-package $(Split-Path $d -Leaf)"
        if (Invoke-FhDism @('/add-package', "/packagepath:$d")) { $reboot = $true }
    }
    $reboot
}

# Removes all packages of that name, language packs first; returns reboot flag.
function Uninstall-FhCbsPackage {
    param([Parameter(Mandatory)][string]$Name)
    $reboot = $false
    $pk = @(Get-WindowsPackage -Online | Where-Object { $_.PackageName -like "$Name~*" -and $_.PackageState -ne 'Absent' } |
        Sort-Object { if ($_.PackageName -like '*~amd64~~*') { 1 } else { 0 } })
    foreach ($p in $pk) {
        Write-FhLog "dism /remove-package $($p.PackageName)"
        if (Invoke-FhDism @('/remove-package', "/packagename:$($p.PackageName)")) { $reboot = $true }
    }
    $reboot
}

# ---------------------------------------------------------------- catalogs

# Smallest catalog of the image that lists the file's hash.
function Find-FhCatalog {
    param([Parameter(Mandatory)][string]$Mount, [Parameter(Mandatory)][string]$File)
    $h = [FeatureHeist.Native]::CatalogHashes($File)
    $dir = Join-Path $Mount 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
    foreach ($c in Get-ChildItem $dir -Filter *.cat | Sort-Object Length) {
        if ([FeatureHeist.Native]::Contains([IO.File]::ReadAllBytes($c.FullName), $h)) { return $c }
    }
    throw "No catalog in the image lists $File"
}

function Assert-FhMicrosoftSignature {
    param([Parameter(Mandatory)][string]$Path)
    $s = Get-AuthenticodeSignature -FilePath $Path
    if ($s.Status -ne 'Valid' -or -not $s.SignerCertificate -or $s.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "Not validly signed by Microsoft: $Path ($($s.Status))"
    }
}

function Add-FhCatalog {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$BaseName)
    Assert-FhMicrosoftSignature $Path
    [FeatureHeist.Native]::AddCatalog($Path, $BaseName)
    Write-FhLog "Catalog registered: $BaseName"
}

function Remove-FhCatalog {
    param([Parameter(Mandatory)][string]$BaseName)
    $e = [FeatureHeist.Native]::RemoveCatalog($BaseName)
    if ($e -eq 0) { Write-FhLog "Catalog removed: $BaseName" } else { Write-FhLog "WARNING: removing catalog $BaseName failed: $e" }
}

# Deletes now, or at next boot if locked.
function Remove-FhFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return }
    try { Remove-Item $Path -Force -ErrorAction Stop; Write-FhLog "Deleted: $Path" }
    catch {
        # MOVEFILE_DELAY_UNTIL_REBOOT
        if ([FeatureHeist.Native]::MoveFileEx($Path, [NullString]::Value, 4)) { Write-FhLog "Deleted at next boot: $Path" }
        else { Write-FhLog "WARNING: cannot delete $Path" }
    }
}

# ------------------------------------------------------------ teams, iSCSI

function Get-FhBackupDir {
    $d = Join-Path $script:DataDir 'backup'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
    $d
}

# Teams with members, team NICs (VLAN) and the IPv4 configuration of each team NIC.
function Save-FhTeams {
    param([string]$Path = (Join-Path (Get-FhBackupDir) 'teams.json'))
    $teams = foreach ($t in @(Get-NetLbfoTeam -ErrorAction SilentlyContinue)) {
        $nics = foreach ($n in @(Get-NetLbfoTeamNic -Team $t.Name)) {
            $if = Get-NetIPInterface -InterfaceAlias $n.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue
            [ordered]@{
                Name = $n.Name; VlanID = $n.VlanID; Primary = $n.Primary
                Dhcp = $(if ($if) { "$($if.Dhcp)" } else { 'Enabled' })
                Addresses = @(Get-NetIPAddress -InterfaceAlias $n.Name -AddressFamily IPv4 -PrefixOrigin Manual -ErrorAction SilentlyContinue | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
                Gateway = @(Get-NetRoute -InterfaceAlias $n.Name -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object NextHop)
                Dns = @((Get-DnsClientServerAddress -InterfaceAlias $n.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
            }
        }
        [ordered]@{
            Name = $t.Name; Members = @(Get-NetLbfoTeamMember -Team $t.Name | ForEach-Object Name)
            Mode = "$($t.TeamingMode)"; Algorithm = "$($t.LoadBalancingAlgorithm)"; Nics = @($nics)
        }
    }
    if (-not $teams) { return }
    @($teams) | ConvertTo-Json -Depth 6 | Set-Content $Path -Encoding UTF8
    Write-FhLog "Teams saved: $Path"
}

function Restore-FhTeams {
    param([string]$Path = (Join-Path (Get-FhBackupDir) 'teams.json'))
    if (-not (Test-Path $Path)) { Write-FhLog "No team backup: $Path"; return }
    foreach ($t in (Get-Content $Path -Raw | ConvertFrom-Json)) {
        if (Get-NetLbfoTeam -Name $t.Name -ErrorAction SilentlyContinue) { continue }
        $members = @($t.Members | Where-Object { Get-NetAdapter -Name $_ -ErrorAction SilentlyContinue })
        if (-not $members) { Write-FhLog "WARNING: no member of team $($t.Name) present"; continue }
        New-NetLbfoTeam -Name $t.Name -TeamMembers $members -TeamingMode $t.Mode -LoadBalancingAlgorithm $t.Algorithm -Confirm:$false | Out-Null
        foreach ($n in @($t.Nics)) {
            if (-not $n.Primary) { Add-NetLbfoTeamNic -Team $t.Name -Name $n.Name -VlanID $n.VlanID -Confirm:$false | Out-Null }
            elseif ($n.VlanID) { Set-NetLbfoTeamNic -Team $t.Name -Name $n.Name -VlanID $n.VlanID | Out-Null }
        }
        Start-Sleep 5
        foreach ($n in @($t.Nics)) {
            if ($n.Dhcp -ne 'Disabled' -or -not $n.Addresses) { continue }
            foreach ($a in @($n.Addresses)) {
                $ip, $len = $a -split '/'
                $p = @{ InterfaceAlias = $n.Name; IPAddress = $ip; PrefixLength = [int]$len }
                if ($n.Gateway -and $a -eq @($n.Addresses)[0]) { $p.DefaultGateway = @($n.Gateway)[0] }
                New-NetIPAddress @p -ErrorAction SilentlyContinue | Out-Null
            }
            if ($n.Dns) { Set-DnsClientServerAddress -InterfaceAlias $n.Name -ServerAddresses $n.Dns }
        }
        Write-FhLog "Team restored: $($t.Name)"
    }
}

function Save-FhIscsiSessions {
    param([string]$Path = (Join-Path (Get-FhBackupDir) 'iscsi.json'))
    $s = @(Get-IscsiSession -ErrorAction SilentlyContinue | ForEach-Object {
        $c = Get-IscsiConnection -IscsiSession $_ -ErrorAction SilentlyContinue | Select-Object -First 1
        [ordered]@{ Target = $_.TargetNodeAddress; Portal = $(if ($c) { $c.TargetAddress } else { $null }); Port = $(if ($c) { $c.TargetPortNumber } else { 3260 }); Persistent = $_.IsPersistent }
    })
    if (-not $s) { return }
    $s | ConvertTo-Json -Depth 4 | Set-Content $Path -Encoding UTF8
}

# Without MPIO each extra session shows the LUN once more; keep one session per target.
function Limit-FhIscsiSessions {
    foreach ($g in @(Get-IscsiSession -ErrorAction SilentlyContinue | Group-Object TargetNodeAddress | Where-Object Count -gt 1)) {
        foreach ($s in $g.Group | Select-Object -Skip 1) { Disconnect-IscsiTarget -SessionIdentifier $s.SessionIdentifier -Confirm:$false -ErrorAction SilentlyContinue }
        Write-FhLog "WARNING: MPIO missing, $($g.Count - 1) extra session(s) to $($g.Name) disconnected"
    }
}

function Restore-FhIscsiSessions {
    param([string]$Path = (Join-Path (Get-FhBackupDir) 'iscsi.json'))
    if (-not (Test-Path $Path)) { return }
    foreach ($g in (Get-Content $Path -Raw | ConvertFrom-Json) | Group-Object Target) {
        $have = @(Get-IscsiSession -ErrorAction SilentlyContinue | Where-Object TargetNodeAddress -eq $g.Name).Count
        foreach ($s in $g.Group | Select-Object -Skip $have) {
            if (-not $s.Portal) { continue }
            Connect-IscsiTarget -NodeAddress $s.Target -TargetPortalAddress $s.Portal -TargetPortalPortNumber $s.Port -IsMultipathEnabled $true -IsPersistent ([bool]$s.Persistent) -ErrorAction SilentlyContinue | Out-Null
        }
        Write-FhLog "iSCSI sessions restored: $($g.Name)"
    }
}

# ------------------------------------------------------------------ watch

function Register-FhWatch {
    $s = Join-Path $PSScriptRoot 'Watch-All.ps1'
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$s`""
    $boot = New-ScheduledTaskTrigger -AtStartup; $boot.Delay = 'PT2M'
    $daily = New-ScheduledTaskTrigger -Daily -At 12:00
    # Windows Update: installation successful (event 19)
    $cls = Get-CimClass -Namespace ROOT\Microsoft\Windows\TaskScheduler -ClassName MSFT_TaskEventTrigger
    $wu = New-CimInstance -CimClass $cls -ClientOnly
    $wu.Enabled = $true
    $wu.Subscription = '<QueryList><Query Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-WindowsUpdateClient''] and EventID=19]]</Select></Query></QueryList>'
    Register-ScheduledTask -TaskName 'FeatureHeist-Watch' -Force -Action $a -Trigger @($boot, $daily, $wu) `
        -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest) `
        -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)) | Out-Null
    if (-not [Diagnostics.EventLog]::SourceExists($script:Product)) { New-EventLog -LogName Application -Source $script:Product }
}

function Unregister-FhWatch {
    if (Get-ChildItem "$script:RegRoot\Packages" -ErrorAction SilentlyContinue) { return }
    Unregister-ScheduledTask -TaskName 'FeatureHeist-Watch' -Confirm:$false -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function *-Fh*
