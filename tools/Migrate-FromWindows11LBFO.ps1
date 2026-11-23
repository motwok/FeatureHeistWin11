#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Replaces an LBFO installation made by github.com/hifihedgehog/Windows11LBFO with Feature Heist.
.DESCRIPTION
    1. Requires a Feature Heist LBFO payload for this build (or -SourcePath to extract it first).
    2. Saves the NIC teams (members, mode, algorithm, VLANs, static IPv4, DNS).
    3. Removes teams, ms_lbfo, the service, the registry entries and files written by Windows11LBFO,
       and the certificates it imported from the catalogs into TrustedPublisher and, if not
       self-signed, into Root (self-signed roots are part of Windows and stay).
    4. Registers a one-shot startup task: after the reboot it runs Install-Lbfo.ps1 -RestoreTeams
       (and Install-LbfoAdmin.ps1 with -AdminTool), then deletes itself.
    The network is down from step 3 until the teams are restored. Run it at the console.
.PARAMETER ScriptsPath
    Folder of the Feature Heist scripts. Default: ..\src\scripts, else C:\Program Files\FeatureHeist\scripts.
.PARAMETER SourcePath
    Server media; extracts the LBFO payload first if missing.
.PARAMETER AdminTool
    Also install LbfoAdmin after the reboot.
.PARAMETER Force
    Run although the session is remote.
.PARAMETER NoReboot
    Do not reboot (the startup task runs at the next boot).
#>
[CmdletBinding()]
param([string]$ScriptsPath, [string]$SourcePath, [switch]$AdminTool, [switch]$Force, [switch]$NoReboot)
$ErrorActionPreference = 'Stop'

if (-not $ScriptsPath) {
    $ScriptsPath = @((Join-Path (Split-Path $PSScriptRoot -Parent) 'src\scripts'), (Join-Path $env:ProgramFiles 'FeatureHeist\scripts')) |
        Where-Object { Test-Path (Join-Path $_ 'FeatureHeist.psm1') } | Select-Object -First 1
}
if (-not $ScriptsPath) { throw 'Feature Heist scripts not found; pass -ScriptsPath.' }
Import-Module (Join-Path $ScriptsPath 'FeatureHeist.psm1') -Force
Assert-FhAdmin

$Service = 'MsLbfoProvider'
$NetService = '{4D36E974-E325-11CE-BFC1-08002BE10318}'
$Task = 'FeatureHeist-Migrate'

try {
    Write-FhLog '--- Migrate-FromWindows11LBFO'
    if (Get-FhState 'lbfo') { throw 'LBFO is already installed by Feature Heist.' }
    $sys = Join-Path $env:SystemRoot 'System32\drivers\MsLbfoProvider.sys'
    if (-not (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Service") -and -not (Test-Path $sys)) { throw 'No Windows11LBFO installation found.' }
    if (-not $Force -and ($env:SESSIONNAME -like 'RDP-*' -or (Get-Process -Id $PID).SessionId -ne (Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId)) {
        throw 'Remote or non-console session: the network goes down during the migration. Run at the console or use -Force.'
    }
    if (-not (Find-FhPayload 'lbfo')) {
        if (-not $SourcePath) { throw "No LBFO payload for build $(Get-FhBaseBuild). Pass -SourcePath." }
        & (Join-Path $ScriptsPath 'Extract-Lbfo.ps1') -SourcePath $SourcePath
        if (-not (Find-FhPayload 'lbfo')) { throw 'Extraction failed.' }
    }
    if ($AdminTool -and -not (Find-FhPayload 'lbfoadmin')) {
        if (-not $SourcePath) { throw "No LbfoAdmin payload for build $(Get-FhBaseBuild). Pass -SourcePath." }
        & (Join-Path $ScriptsPath 'Extract-LbfoAdmin.ps1') -SourcePath $SourcePath
    }
    # Windows11LBFO wrote Control\Network keys only SYSTEM may delete: continue as SYSTEM
    if (-not (Test-FhSystem)) {
        $log = Join-Path $env:ProgramData 'FeatureHeist\FeatureHeist.log'
        $n = @(Get-Content $log).Count
        $c = "& $(ConvertTo-FhArg $PSCommandPath) -ScriptsPath $(ConvertTo-FhArg $ScriptsPath) -Force -NoReboot"
        if ($AdminTool) { $c += ' -AdminTool' }
        $rc = Invoke-FhAsSystem $c 'FeatureHeist-Migrate-Run'
        Get-Content $log | Select-Object -Skip $n | ForEach-Object { Write-Host $_ }
        if ($rc -notin 0, 3010) { exit 1 }
        exit (Complete-FhRun $true -NoReboot:$NoReboot)
    }
    if (Test-Path $sys) { Write-FhLog "Old driver: $((Get-Item $sys).VersionInfo.FileVersion)" }

    Save-FhTeams
    foreach ($t in @(Get-NetLbfoTeam -ErrorAction SilentlyContinue)) { Remove-NetLbfoTeam -Name $t.Name -Confirm:$false; Write-FhLog "Team removed: $($t.Name)" }

    & netcfg.exe -u ms_lbfo 2>&1 | Out-Null
    & sc.exe stop $Service 2>&1 | Out-Null
    & sc.exe delete $Service 2>&1 | Out-Null

    # catalogs: certificates imported with certutil -addstore, then the catalog itself
    $catRoot = Join-Path $env:SystemRoot 'System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
    $cats = @(Get-ChildItem $catRoot -Filter '*.cat' | Where-Object { $_.Name -match '^Microsoft-Windows-(Server-Features-Package016|ServerCore-Drivers-merged-Package)~31bf3856ad364e35~amd64~~10\.0\.20348\.' })
    foreach ($c in $cats) {
        $col = New-Object Security.Cryptography.X509Certificates.X509Certificate2Collection
        $col.Import($c.FullName)
        foreach ($cert in $col) {
            foreach ($store in 'TrustedPublisher', 'Root') {
                if ($store -eq 'Root' -and $cert.Subject -eq $cert.Issuer) { continue }
                $p = "Cert:\LocalMachine\$store\$($cert.Thumbprint)"
                if (Test-Path $p) { Remove-Item $p -Force; Write-FhLog "Certificate removed from ${store}: $($cert.Subject)" }
            }
        }
        Remove-FhCatalog $c.Name
        Remove-FhFile $c.FullName
    }

    # registry written by Windows11LBFO
    foreach ($k in "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\System\$Service", "HKLM:\SYSTEM\CurrentControlSet\Services\$Service") {
        if (Test-Path $k) { Remove-Item $k -Recurse -Force -ErrorAction SilentlyContinue; Write-FhLog "Removed: $k" }
    }
    foreach ($base in "HKLM:\SYSTEM\CurrentControlSet\Control\Network\$NetService", "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$NetService") {
        foreach ($k in Get-ChildItem $base -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.PSObject.Properties['ComponentId'] -and $p.ComponentId -eq 'ms_lbfo') { Remove-Item $k.PSPath -Recurse -Force; Write-FhLog "Removed: $($k.Name)" }
        }
    }
    $loaded = Test-Path HKLM:\DRIVERS
    if (-not $loaded) { & reg.exe load HKLM\DRIVERS (Join-Path $env:SystemRoot 'System32\config\DRIVERS') 2>&1 | Out-Null }
    try {
        $dd = 'HKLM:\DRIVERS\DriverDatabase'
        foreach ($k in @("$dd\DriverInfFiles\mslbfoprovider.inf", "$dd\DeviceIds\ms_lbfo") + @(Get-ChildItem "$dd\DriverPackages" -ErrorAction SilentlyContinue | Where-Object PSChildName -like 'mslbfoprovider.inf_amd64_*' | ForEach-Object PSPath)) {
            if (Test-Path $k) { Remove-Item $k -Recurse -Force; Write-FhLog "Removed: $k" }
        }
    } finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        if (-not $loaded) { & reg.exe unload HKLM\DRIVERS 2>&1 | Out-Null }
    }

    $w = $env:SystemRoot
    $files = @("$w\System32\drivers\MsLbfoProvider.sys", "$w\System32\drivers\en-US\MsLbfoProvider.sys.mui",
        "$w\System32\DriverStore\en-US\MsLbfoProvider.inf_loc", "$w\INF\MsLbfoProvider.inf", "$w\INF\MsLbfoProvider.pnf")
    $repo = @(Get-ChildItem "$w\System32\DriverStore\FileRepository" -Directory -Filter 'mslbfoprovider.inf_amd64_*' -ErrorAction SilentlyContinue)
    $files += @($repo | ForEach-Object { Get-ChildItem $_.FullName -Recurse -File | ForEach-Object FullName })
    foreach ($f in $files) { Remove-FhFile $f }
    foreach ($d in $repo) { if (-not (Get-ChildItem $d.FullName -Recurse -File)) { Remove-Item $d.FullName -Recurse -Force } }

    # after the reboot: install Feature Heist LBFO and restore the teams
    $c = "& '$(Join-Path $ScriptsPath 'Install-Lbfo.ps1')' -RestoreTeams -NoReboot"
    if ($AdminTool) { $c += "; & '$(Join-Path $ScriptsPath 'Install-LbfoAdmin.ps1')' -NoReboot" }
    $c += "; Unregister-ScheduledTask -TaskName '$Task' -Confirm:`$false"
    Register-ScheduledTask -TaskName $Task -Force `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$c`"") `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest) | Out-Null
    Write-FhLog 'Windows11LBFO removed; Feature Heist LBFO installs after the reboot.'
    exit (Complete-FhRun $true -NoReboot:$NoReboot)
} catch {
    Write-FhLog "ERROR: $($_.Exception.Message)"
    exit 1
}
