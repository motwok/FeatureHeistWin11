# Security Policy

Feature Heist runs as administrator, installs drivers and servicing packages and registers catalogs in
the system catalog database. That makes it security-sensitive by nature, and reports are taken
seriously.

## Reporting a vulnerability

**Please report vulnerabilities privately; do not open a public issue, pull request, or discussion for a
security problem.**

Use **GitHub's private vulnerability reporting**:

1. Go to the repository's **Security** tab ->
   **[Report a vulnerability](https://github.com/motwok/FeatureHeistWin11/security/advisories/new)**.
2. Describe the issue with enough detail to reproduce and assess it.

This keeps the report private between you and the maintainer and integrates with GitHub Security
Advisories for a coordinated fix and disclosure.

### What to include

- A clear description of the vulnerability and its **impact**.
- **Steps to reproduce** (or a proof of concept).
- Affected **version** of Feature Heist, the **Windows build** and the **Server media** used.
- Any suggested mitigation, if you have one.

## What to expect

This is a single-maintainer project, so responses are best-effort rather than bound to a fixed SLA. You
can expect an acknowledgement of your report, an assessment, and, for confirmed issues, a coordinated fix
and disclosure. Credit is given to reporters who want it.

Please give a reasonable amount of time for a fix before any public disclosure.

## Supported versions

Only the **latest release** receives security fixes. Older releases are not patched; please update to
the newest one.

| Version | Supported |
|---|---|
| Latest release | yes |
| Older releases | no |

## Scope

Feature Heist deliberately does things that can look alarming but are by design:

- it runs **as administrator** (the MSI as LocalSystem) and mounts the Windows Server ISO you select,
- it installs **original Microsoft servicing packages** (`.mum`/`.cat`) from that media with DISM,
- for LBFO it registers **unchanged Microsoft catalogs** from that media in the system catalog database
  (`CryptCATAdminAddCatalog`), so that Windows accepts the unchanged Microsoft driver files as signed;
  every catalog is checked for a valid Microsoft Windows signature first,
- it creates the driver service of LBFO, places its INF in `%windir%\INF` and installs the network
  component with `netcfg`,
- after installing MPIO it runs a scheduled task as SYSTEM once at startup, which restarts the MSDSM
  device if it failed to start and then deletes itself.

These documented behaviors are **not** vulnerabilities on their own. Genuine security issues include, for
example: importing certificates into any trust store; installing or registering a file or catalog that
is not an unchanged, validly signed Microsoft file from the selected media; enabling test signing or
weakening Secure Boot, HVCI or code integrity; writing outside the documented locations; or a way for a
non-administrator to make Feature Heist install or run something.
