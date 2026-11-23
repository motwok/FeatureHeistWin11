# Contributing to Feature Heist

Thanks for your interest in Feature Heist!

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md); please be respectful.

> **Security issue?** Do **not** open a public issue; report it privately, see [SECURITY.md](SECURITY.md).

## Ways to contribute

- **Bug reports**: [open an issue](https://github.com/motwok/FeatureHeistWin11/issues)
- **Feature requests**: [open an issue](https://github.com/motwok/FeatureHeistWin11/issues)
- **Translations** of the MSI and script texts are welcome as pull requests.
- **Pull requests** are welcome, see below.

Ideas, reproductions and well-described problems are genuinely valuable too.

## Repository layout

| Path | Content |
|---|---|
| `src/scripts/` | extract, install and uninstall scripts and their shared module; shipped in the ZIP and the MSI |
| `src/installer/` | WiX source of the MSI, one `.wxl` file per language |
| `tools/` | repo-only scripts (migration from other LBFO installations); never shipped |
| `tests/` | Pester tests |
| `build/` | packaging script used by the Build workflow |
| `docs/` | user documentation |
| `.github/` | workflows, issue and PR templates, release notes configuration |

## Pull requests

Feature Heist runs as administrator and changes the storage stack (MPIO) and the network stack (LBFO)
of Windows. A mistake can leave a machine unbootable or offline, so every change is reviewed carefully
before it is merged. To make that easy:

- For anything larger than a small fix, open an issue first so the approach can be agreed on.
- Keep a pull request focused on one change. Work on a branch of your fork and target `master`.
- Use a Conventional Commit style title, for example `feat: ...`, `fix: ...`, `docs: ...`.
- Write code, comments and documentation in English.
- Scripts must run on Windows PowerShell 5.1 with what ships with Windows. No external modules or
  tools; anything else needs to be agreed in an issue first.
- Never include Microsoft files (drivers, catalogs, packages, images) in a pull request.
- Never import certificates into trust stores, enable test signing or weaken Secure Boot, HVCI or code
  integrity.
- Do not put raw non-ASCII characters into source code; write them as escape sequences.
- Diagrams in Markdown are Mermaid, not ASCII art.
- Test your change in a virtual machine with a checkpoint, never first on a machine you need. Describe
  in the pull request what you tested (Windows build, Server media version, packages).

By submitting a pull request you agree that your contribution is licensed under the
**GNU AGPL v3** (see [LICENSE](LICENSE)).

## Writing a good bug report

Please include:

- **What happened** and **what you expected**.
- The **Feature Heist version** and the **package** concerned (MPIO, LBFO, LbfoAdmin).
- The **Windows version and build** of the client (`winver`, or
  `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'`) and the edition.
- The **Windows Server media** used: version and build of the image (`Get-WindowsImage`).
- The relevant part of the **log** (`%ProgramData%\FeatureHeist\*.log`).
- **Steps to reproduce**, if you can; even rough ones help.

Remove host names, IP addresses or other details you do not want to make public before posting.

## Feature requests

Describe the problem you're trying to solve, not just a proposed solution; it helps find the best fit.
Note that not every request will be implemented; Feature Heist intentionally stays small and focused.

## Forking

Feature Heist is licensed under the **GNU AGPL v3** (see [LICENSE](LICENSE)). You are of course free to
fork and modify it under those terms.

## Support Me

If Feature Heist helps you, you can support it: [Buy Me a Coffee](https://ko-fi.com/motwok)
