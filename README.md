# Linux Swiss Army Knife

[![Validate GitHub-hosted runners](https://github.com/zieglerziga/linux-swiss-army-knife/actions/workflows/validate-runners.yml/badge.svg)](https://github.com/zieglerziga/linux-swiss-army-knife/actions/workflows/validate-runners.yml)

A dependency-free, read-only system inspector for Linux, minimal BusyBox
systems, macOS, and Windows. It reports operating-system, hardware, filesystem,
local-network, identity, and privilege facts without installing anything,
requesting elevation, changing configuration, or contacting the internet.

## Run it

Linux, BusyBox, and macOS use the POSIX shell entry point:

```sh
sh swiss.sh
sh swiss.sh --json
sh swiss.sh --plain --debug
sh swiss.sh --full
```

Windows uses Windows PowerShell 5.1 or modern PowerShell:

```powershell
.\swiss.ps1
.\swiss.ps1 --json
.\swiss.ps1 --plain --debug
.\swiss.ps1 --full
```

No installation or administrator/root access is required. Copy the appropriate
single script to the target computer and run it as the current user.

## Output

The default output is a compact human report. `--plain` produces stable
tab-separated facts, `--json` emits schema version 1, and `--debug` adds each
probe's source. Both platform entry points emit the same 42 fields and the same
statuses. See [the schema guide](docs/report-schema-v1.md) and the machine-
readable [JSON Schema](schema/swiss-report-v1.schema.json).

Unavailable information is represented honestly as `unknown`, `unsupported`,
`missing`, `denied`, or `error`; one failed probe does not abort the report.

## Read-only and privacy contract

The collectors do not invoke elevation tools, package managers, active network
tests, Wi-Fi scans, mounts, service controls, or configuration commands. Local
filesystem capacity collection excludes network filesystems. Potentially
slower macOS firmware/storage and Windows physical-disk enumeration is
available only with `--full`.

Reports intentionally contain potentially identifying local information:
hostname, username, hardware model, storage model, interface names, MAC
addresses, assigned local IP addresses, gateways, and configured DNS servers.
Review a report before sharing it. Wi-Fi credentials, Wi-Fi SSIDs, public IP
addresses, storage serial numbers, and external-connectivity tests are never
collected.

## Platform behavior

- Linux prefers `/proc`, `/sys`, `/etc`, and device-tree data, with safe command
  fallbacks. The baseline remains useful without `ip`, `ifconfig`, `lscpu`,
  `free`, `lsblk`, systemd, or a package manager.
- BusyBox `ash`, Dash, and Bash POSIX mode run the same `swiss.sh` file.
- macOS uses built-in `sw_vers`, `sysctl`, `ifconfig`, `route`, `scutil`, and
  `pmset` queries.
- Windows uses built-in .NET, CIM, and networking cmdlets and remains compatible
  with Windows PowerShell 5.1.
- BSD-like systems receive a best-effort portable baseline. GRUB and rescue
  media are explicitly outside the current running-OS collector.

## Development verification

Run the sanitized fixture suite locally with:

```sh
sh scripts/verify.sh
```

The suite performs POSIX parsing, ShellCheck when available, source-policy
checks, Dash/BusyBox/Bash behavior tests, JSON Schema validation, and PowerShell
tests when `pwsh` is installed. CI adds narrow live smokes on every supported
GitHub-hosted Linux, macOS, and Windows runner without executing the repository's
older interactive `docker_manager.sh`.
