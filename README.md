# Feature Heist for Windows 11

<img src="src/installer/art/logo.svg" alt="Feature Heist logo" width="128">

[![Build](https://github.com/motwok/FeatureHeistWin11/actions/workflows/build.yml/badge.svg?branch=master)](https://github.com/motwok/FeatureHeistWin11/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/motwok/FeatureHeistWin11)](https://github.com/motwok/FeatureHeistWin11/releases/latest)
![Coverage](https://img.shields.io/badge/coverage-100%25-brightgreen)
![Platform](https://img.shields.io/badge/platform-Windows%2011%20x64%20(26100)-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-blue)
![MSI languages](https://img.shields.io/badge/MSI-38%20languages-blue)
![Audience](https://img.shields.io/badge/audience-Windows%20admins%20%7C%20homelab-blueviolet)
![Use](https://img.shields.io/badge/use-lab%20%26%20test%20only-orange)
[![License](https://img.shields.io/github/license/motwok/FeatureHeistWin11)](LICENSE)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20Me-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/motwok)

Installs Windows Server features on Windows 11 that Microsoft does not ship for the client:

| Package | What |
|---|---|
| MPIO | Multipath I/O + MSDSM (original servicing package from the Server image) |
| LBFO | NIC teaming driver (MsLbfoProvider) |
| LbfoAdmin | NIC teaming GUI (`LbfoAdmin.exe`) |

Tested on Windows 11 24H2 (build 26100) with Windows Server 2025 media, including a cumulative
update, path failover (MPIO, iSCSI) and member failover (LBFO).

## Requirements

- Windows 11 based on build 26100 (24H2/25H2/26H2) and Windows Server 2025 media (ISO) of the
  same build. **No Microsoft files are included in this repository or the release**; they are
  extracted from your own Server media on the target machine.
- Administrator rights.

## MSI

Download `FeatureHeist-X.Y.Z.msi` from the [releases](https://github.com/motwok/FeatureHeistWin11/releases).
All packages are selected by default; enter the path of the Server ISO (or of a folder with files
extracted before). The setup UI comes in the 38 Windows display languages. English and German are
written by hand, all other languages are machine-translated: native speakers who want to check or
improve a translation are very welcome (`src/installer/<culture>.wxl`, see [CONTRIBUTING.md](CONTRIBUTING.md)).

```
msiexec /i FeatureHeist-X.Y.Z.msi /qn ISO="D:\Server2025.iso"
msiexec /i FeatureHeist-X.Y.Z.msi /qn ADDLOCAL=Core,MPIO ISO="D:\Server2025.iso" CLAIMISCSI=iSCSI CLAIMSAS=SAS
msiexec /i FeatureHeist-X.Y.Z.msi /qn PAYLOADDIR="\\server\share\payload"
msiexec /x FeatureHeist-X.Y.Z.msi /qn
```

| Property | Default | Meaning |
|---|---|---|
| `ISO` | | Server ISO, `install.wim` or drive; only needed if no extracted files exist |
| `PAYLOADDIR` | `<install dir>\scripts\payload` | extracted files (target of the extraction, or source) |
| `CLAIMISCSI` | `iSCSI` | MSDSM claims iSCSI disks; empty to disable |
| `CLAIMSAS` | | `SAS`: MSDSM also claims SAS disks, including local ones |

Removing MPIO or LBFO needs a reboot; uninstalling removes existing NIC teams. Packages installed
with the scripts before are kept; a full uninstall leaves those not selected in the MSI in place.

LBFO installed by another tool (Windows11LBFO) is left alone: the MSI skips LBFO (with LBFO as the
only selection it stops) and LbfoAdmin works with it. To replace it, see
[Migration from Windows11LBFO](#migration-from-windows11lbfo).

## Scripts

`FeatureHeist-X.Y.Z-scripts.zip`, run as administrator (`powershell -ExecutionPolicy Bypass -File ...`):

| Script | |
|---|---|
| `Extract-All.ps1 -SourcePath D:\Server2025.iso` | extract all packages with one image mount |
| `Install-All.ps1 [-Packages Mpio,Lbfo,LbfoAdmin] [-ClaimBusType iSCSI]` | install, one reboot |
| `Uninstall-All.ps1 [-Force]` | remove; `-Force` removes NIC teams and ignores MPIO disks |
| `Extract-/Install-/Uninstall-Mpio.ps1`, `-Lbfo.ps1`, `-LbfoAdmin.ps1` | single package |
| `Extract-Languages.ps1 -SourcePath D:\Languages.iso [-Language de-DE,fr-FR]` | add MPIO/LbfoAdmin languages from the Server "Languages and Optional Features" ISO (after `Extract-All`) |

Extracted files go to `scripts\payload\<build>\<package>` or `-PayloadPath`, which is remembered.
`Install-*.ps1 -SourcePath ...` extracts first if nothing for this build is there. Uninstalling needs
no extracted files. `-NoReboot` returns exit code 3010 instead of rebooting. With LBFO installed by
another tool, `Install-All.ps1` asks whether to skip LBFO (unattended it skips it), `Install-Lbfo.ps1`
stops. Log:
`%ProgramData%\FeatureHeist\FeatureHeist.log`.

## After Windows updates

Task `FeatureHeist-Watch` (SYSTEM; at startup, daily, after each installed update) checks that the
installed packages are still active. While they are, it saves the NIC teams and iSCSI sessions. If one
is missing, it writes a warning to the Application log (source `FeatureHeist`), notifies signed-in
users, and without MPIO keeps only one iSCSI session per target. It does not reinstall by itself:
run `Install-All.ps1 -RestoreTeams -RestoreSessions` or repair the MSI.

## Migration from Windows11LBFO

`tools\Migrate-FromWindows11LBFO.ps1` (repository only, not in the release assets) replaces an
installation made by the Windows11LBFO scripts (hifihedgehog/Windows11LBFO): it saves the
teams, removes the old driver, its registry entries, files and catalogs, and installs the Feature Heist
driver after the reboot, with the teams (VLANs, static IPv4) restored. The network is down meanwhile;
run it at the console.

```
powershell -ExecutionPolicy Bypass -File tools\Migrate-FromWindows11LBFO.ps1 -SourcePath D:\Server2025.iso -AdminTool
```

## Limits

- Windows Update does not service the LBFO driver; it stays at the version of the Server media.
- After a feature update to a new base build, Server media of that build is needed.
- In a VM, LBFO supports only the TransportPorts, IPAddresses and MacAddresses algorithms, and the
  virtual NICs need MAC address spoofing or `AllowTeaming` (Hyper-V).

## Disclaimer

For lab and test use only. Using Windows Server components on a Windows client is not covered
by the Windows client license. Not affiliated with or endorsed by Microsoft. Use at your own
risk: MPIO is part of the storage stack, LBFO of the network stack. Try it in a virtual machine
with a checkpoint first.

## Credits

Feature Heist was inspired by **Windows11LBFO** by hifihedgehog ([hifihedgehog/Windows11LBFO](https://github.com/hifihedgehog/Windows11LBFO)),
which first brought the Server NIC teaming driver to Windows 11. Many thanks for that groundwork.

## Help and contributing

- Questions and problems: [SUPPORT.md](SUPPORT.md)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md), [Code of Conduct](CODE_OF_CONDUCT.md)
- Security issues: [SECURITY.md](SECURITY.md) (private reporting)

## License

Copyright (c) Emmo Emminghaus. Licensed under the [GNU AGPL v3](LICENSE); see also [NOTICE](NOTICE).

## Support Me

Feature Heist is free and open source. If it saves you some trouble, you can support it:
[Buy Me a Coffee](https://ko-fi.com/motwok)
