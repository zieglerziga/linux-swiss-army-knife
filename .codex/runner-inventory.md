# Free GitHub-hosted runner inventory

Verified on 2026-09-29 against GitHub's standard hosted-runner documentation
and the `actions/runner-images` inventory.

This repository is public. GitHub documents standard hosted runners as free and
unlimited for public repositories. Larger macOS runner labels are intentionally
excluded because they are not the standard free tier. Moving aliases such as
`ubuntu-latest`, `macos-latest`, and `windows-latest` are also excluded because
they do not add a distinct operating-system version.

Each row received a dedicated Luna subagent review before the validation matrix
was implemented.

| Workflow label | Operating system | Architecture | CI policy |
| --- | --- | --- | --- |
| `ubuntu-slim` | Minimal Ubuntu container | x64 | Required; lightweight parse-only checks |
| `ubuntu-22.04` | Ubuntu 22.04 | x64 | Required while GitHub supports the label |
| `ubuntu-22.04-arm` | Ubuntu 22.04 | arm64 | Required while GitHub supports the label |
| `ubuntu-24.04` | Ubuntu 24.04 | x64 | Required |
| `ubuntu-24.04-arm` | Ubuntu 24.04 | arm64 | Required |
| `ubuntu-26.04` | Ubuntu 26.04 | x64 | Required |
| `ubuntu-26.04-arm` | Ubuntu 26.04 | arm64 | Required |
| `macos-14` | macOS 14 | arm64 | Required until its announced retirement |
| `macos-15` | macOS 15 | arm64 | Required |
| `macos-15-intel` | macOS 15 | x64 | Required |
| `macos-26` | macOS 26 | arm64 | Required |
| `macos-26-intel` | macOS 26 | x64 | Required |
| `xcode-27` | macOS 27 with Xcode 27 | arm64 | Required; public preview has no SLA |
| `windows-2022` | Windows Server 2022 | x64 | Required |
| `windows-2025` | Windows Server 2025 | x64 | Required |
| `windows-2025-vs2026` | Windows Server 2025 with Visual Studio 2026 | x64 | Required |
| `windows-11-arm` | Windows 11 | arm64 | Required; canonical label is transitioning to the VS2026 image |
| `windows-11-vs2026-arm` | Windows 11 with Visual Studio 2026 | arm64 | Required |

Primary sources:

- [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [`actions/runner-images` available images](https://github.com/actions/runner-images#available-images)

The inventory is time-sensitive. When GitHub adds or retires a standard image,
update this document and the workflow matrix together, and repeat the dedicated
runner review for the changed labels.
