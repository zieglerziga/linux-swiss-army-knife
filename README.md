# Linux Swiss Army Knife

[![Validate GitHub-hosted runners](https://github.com/zieglerziga/linux-swiss-army-knife/actions/workflows/validate-runners.yml/badge.svg)](https://github.com/zieglerziga/linux-swiss-army-knife/actions/workflows/validate-runners.yml)

A dependency-free system inspector and opt-in health checker for Linux, minimal
BusyBox systems, macOS, and Windows. The inventory command reports operating-
system, hardware, filesystem, local-network, identity, and privilege facts
without installing anything, requesting elevation, changing configuration, or
contacting the internet.

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

## Selectable health checks

Health checks are separate from the stable inventory report. Select one or more
checks explicitly, or use `--all`:

```sh
sh health-check.sh --sudo --disk
sh health-check.sh --processes --updates --plain
sh health-check.sh --all --disk-warning 90
```

Windows exposes the same selection and output contract:

```powershell
.\health-check.ps1 --sudo --disk
.\health-check.ps1 --processes --updates --plain
.\health-check.ps1 --all --disk-warning 90
```

The checks report elevation state, flag local filesystem mount paths over the
configured used-space threshold, identify Linux `D`/`Z` process
states or non-responsive Windows GUI processes, and query available updates.
On POSIX systems the sudo check validates `sudo -n`; on Windows it reports
whether the process is already elevated and detects `sudo` without invoking an
elevation prompt. POSIX package managers use cached metadata without refreshing
it. Windows uses the read-only Windows Update search API only when `--updates`
is selected. The Linux disk scan ignores read-only mounts such as package
images, where a reported 100% capacity is expected. The portable `df` fallback
also excludes known pseudo-filesystem sources such as macOS `devfs`.

Run the POSIX command on a Linux or BusyBox host without installing it:

```sh
sh health-check.sh --remote user@example.test --disk --processes
sh health-check.sh --remote user@example.test --identity ~/.ssh/example --all
```

PowerShell can drive the same POSIX remote mode by streaming the sibling shell
script to a Linux, macOS, or BusyBox target:

```powershell
.\health-check.ps1 --remote user@example.test --identity $HOME\.ssh\example --disk
```

Remote mode streams the script over batch-mode SSH and requires the target's
verified host key to already be present in local `known_hosts`; unknown keys are
rejected without prompting. Verify the fingerprint out of band before adding a
new host key. Password login and SSH forwarding are disabled for the check.
Default output uses `[PASS]`, `[WARN]`, `[FAIL]`, `[UNSUPPORTED]`, or `[ERROR]`.
`--plain` emits stable `check<TAB>status<TAB>detail` rows. Exit status is `0` for
all-pass, `1` for warnings or unsupported checks, and `2` for errors or invalid
usage.

## Output

The default output is a compact human report. `--plain` produces stable
tab-separated facts, `--json` emits schema version 1, and `--debug` adds each
probe's source. Both platform entry points emit the same 42 fields and the same
statuses. See [the schema guide](docs/report-schema-v1.md) and the machine-
readable [JSON Schema](schema/swiss-report-v1.schema.json).

Unavailable information is represented honestly as `unknown`, `unsupported`,
`missing`, `denied`, or `error`; one failed probe does not abort the report.

## Read-only and privacy contract

The `swiss.sh` and `swiss.ps1` inventory collectors do not invoke elevation
tools, package managers, active network tests, Wi-Fi scans, mounts, service
controls, or configuration commands. Local filesystem capacity collection
excludes network filesystems. Potentially slower macOS firmware/storage and
Windows physical-disk enumeration is available only with `--full`.

`health-check.*` has a narrower opt-in contract: `--sudo`, `--updates`, and
`--remote` may create normal authentication, package-query, or SSH audit events,
but do not install updates, elevate a command, or change remote configuration.

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
checks, Dash/BusyBox/Bash behavior tests, exact health-check output assertions,
JSON Schema validation, and PowerShell tests when `pwsh` is installed. CI runs
the health commands—not only linters—on the supported GitHub-hosted Linux,
macOS, and Windows runners without executing the repository's older interactive
`docker_manager.sh`.
