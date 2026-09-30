# Read-only probe allowlist

The collectors may invoke only commands that query local state. They must never
request elevation or perform package, service, network-test, mount, power, or
configuration operations.

## POSIX collector

Allowed command families:

- shell built-ins: `command`, `printf`, `read`, `test`/`[`;
- text processing: `awk`, `grep`, `iconv` (optional UTF-8 validation), `sed`,
  `tr`;
- identity and kernel: `date`, `getconf`, `hostname`, `id`, `uname`;
- filesystem and network queries: local-only `df`, `ifconfig`, `ip`, `route`;
- macOS queries: `diskutil list`, `pmset -g`, `scutil --dns`,
  `sw_vers`, `sysctl -n`, and narrowly scoped `diskutil`/`system_profiler`
  queries in `--full`.

The machine-enforced command inventory is
`schema/posix-command-allowlist.txt`. CI lexes shell command positions,
rejects dynamic command dispatch and output redirection outside `/dev/null`,
and requires every allowlist entry to be exercised by the audit.

Direct reads are limited to ordinary operating-system metadata under `/etc`,
`/proc`, `/sys`, and device-tree paths. Block devices are never opened.

## Windows collector

Allowed APIs and cmdlets:

- .NET environment and Windows identity APIs;
- `Get-CimInstance` for operating system, computer system, BIOS, processor,
  battery, logical disk, physical disk, and network configuration classes;
- `Get-Command`, `Get-NetAdapter`, `Get-NetIPAddress`, `Get-NetRoute`, and
  `Get-DnsClientServerAddress`.

The source-policy test rejects known elevation, package-manager, active-network,
mount, service-control, shutdown, registry-write, and configuration commands.
Physical-disk enumeration is restricted to explicit `--full` mode.
PowerShell's parser is also used to enumerate every command invocation; only
the cmdlets above and collector-local functions are accepted. Dynamic command
dispatch and networking or mutating .NET API families are rejected.
