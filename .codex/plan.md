# Linux Swiss Army Knife: read-only information collection plan

## First goal

Build a dependency-free, read-only system inspector that produces a useful and
honest report on ordinary Linux distributions, minimal BusyBox systems, macOS,
and Windows.

The first goal is information collection only. The tool must not install
packages, change configuration, elevate privileges, start or stop services, or
repair anything.

Success means one familiar command and one consistent report model across
platforms. It does not require one byte-identical executable on every operating
system.

## Initial platform strategy

- `swiss.sh`: POSIX `sh` entry point for Linux, BusyBox/embedded Linux, macOS,
  and BSD-like systems.
- `swiss.ps1`: PowerShell entry point for Windows.
- Both entry points emit the same logical fields and use the same status names.
- The POSIX implementation is the first implementation milestone because it
  covers the widest range of Unix-like hosts, including the Zyxel NAS326.
- No helper is required for the baseline report. Optional helpers may be added
  later for facts that native interfaces cannot expose.
- GRUB is outside the running-OS inspector. Pre-boot support should eventually
  be delivered as a small Linux rescue image that launches `swiss.sh`.

## Read-only contract

Default collection must:

- run as the current user and never invoke `sudo`, `doas`, `su`, or an elevation
  prompt;
- avoid package managers and dependency installation;
- avoid writing persistent files, caches, configuration, registry values, or
  logs owned by this tool;
- avoid changing network, power, device, mount, firewall, or service state;
- avoid active Wi-Fi scans;
- avoid external network traffic such as `ping`, DNS tests, HTTP requests, and
  public-IP discovery;
- avoid loading kernel modules, mounting filesystems, and opening raw devices;
- print unavailable or permission-denied facts instead of trying to gain more
  access;
- make the exact commands used by every probe auditable in the source.

Reading local kernel and operating-system interfaces is allowed, including
`/proc`, `/sys`, `/etc`, sysctl values, CIM/WMI, and command output that only
queries current state.

Some nominally read-only commands may be expensive or wake sleeping hardware.
Those probes belong behind an explicit `--full` option and must still honor all
rules above.

## Design principles

1. **Capability detection over assumptions.** Check commands, readable files,
   and supported flags before using them. Do not infer capabilities solely from
   a distribution or BusyBox version.
2. **Graceful degradation.** A missing command or inaccessible file loses only
   the associated facts, not the whole report.
3. **Native sources first.** Prefer interfaces already supplied by the host.
   The collector must remain useful with no internet connection or package
   manager.
4. **Fast by default.** The normal report should complete quickly and avoid
   broad or slow hardware enumeration.
5. **No hidden interpretation.** Where possible, record the source of a value
   and distinguish detected facts from heuristics.
6. **Stable schema.** Human-readable output may improve over time, but
   machine-readable field names and statuses must be versioned.
7. **Treat host data as untrusted.** Do not use `eval`, execute parsed values, or
   source system metadata files such as `/etc/os-release`.

## Report model

Every fact has:

- `key`: stable dotted name, for example `system.kernel.release`;
- `value`: detected value, possibly empty when unavailable;
- `status`: result of collection;
- `source`: file, command, or method used;
- `confidence`: `exact`, `derived`, or `heuristic` where interpretation is
  involved.

Initial statuses:

- `ok`: value was collected successfully;
- `unknown`: the probe ran but could not determine a value;
- `unsupported`: no meaningful probe exists for this platform;
- `missing`: an optional file or command is absent;
- `denied`: the current user lacks access;
- `error`: an unexpected probe failure occurred.

The first output modes should be:

- default terminal report for humans;
- `--plain` for stable, uncolored text;
- `--json` for automation;
- `--debug` to include probe sources and non-sensitive failure details.

Color must be disabled when output is not a terminal or when `NO_COLOR` is set.

## Version-one facts

### Collector metadata

- collector name and version;
- schema version;
- collection timestamp;
- selected mode (`normal` or `full`);
- detected platform adapter;
- warnings and probe errors.

### Identity and privilege

- hostname;
- current username;
- numeric user and primary group IDs where meaningful;
- whether the current process is root/administrator;
- names of detected elevation tools, without testing or invoking them.

Do not claim that a user can elevate merely because `sudo`, `doas`, or another
tool exists.

### Operating system

- OS family;
- distribution/product name;
- OS version and build;
- kernel name and release;
- machine architecture;
- userspace bitness where it can be determined reliably;
- physical host, virtual machine, container, WSL, or unknown environment;
- uptime where available.

### Hardware

- manufacturer and model;
- firmware/BIOS information where readable;
- CPU model;
- logical processor count;
- total memory;
- battery presence and basic state where available;
- filesystem capacity and usage;
- basic block-storage inventory only when it can be queried safely without raw
  device access.

### Local network state

- hostname;
- interface names;
- interface state;
- loopback, wired, Wi-Fi, tunnel, bridge, virtual, or unknown classification;
- local MAC address where exposed;
- assigned IPv4 and IPv6 addresses;
- default route and local gateway;
- configured local DNS resolvers;
- whether a default route exists.

Do not infer internet connectivity from the presence of a route. Do not contact
an external server in the default collector. Wi-Fi SSID should be opt-in because
it can be privacy-sensitive and may trigger platform permission behavior.

## Probe hierarchy

Each fact should try the least platform-specific reliable source first and then
fall back without failing the report.

### Portable POSIX baseline

Use conservative invocations of:

- `uname` for kernel, architecture, and hostname;
- `id` for user and group identity;
- `getconf` for supported system limits;
- `df -P` for portable filesystem usage;
- `date` for the report timestamp;
- `command -v` for capability discovery.

### Linux and BusyBox

Prefer readable kernel/system files, then optional commands:

- OS: `/etc/os-release`, known release files, then `uname`;
- CPU: `/proc/cpuinfo`, `getconf`, then `lscpu` when available;
- memory: `/proc/meminfo`, then `free` when available;
- model/firmware: `/sys/class/dmi/id`, device-tree files, then optional tools;
- uptime: `/proc/uptime`;
- filesystems: `df -P`, `/proc/mounts`;
- interfaces: `/sys/class/net`, then progressively richer `ip` or `ifconfig`
  output;
- routes: `/proc/net/route`, IPv6 route data where practical, then `ip route`
  or `route`;
- DNS: parse resolver configuration without performing a lookup;
- containers/VMs: cgroup and DMI hints, reported as derived or heuristic.

BusyBox compatibility is a design constraint, not a special afterthought. A
baseline report must work with `/bin/sh` plus commonly built BusyBox applets and
must continue with reduced detail when applets are absent.

### macOS

Use built-in commands with narrow queries:

- `sw_vers` for product information;
- `uname` and `sysctl` for kernel and hardware facts;
- `ifconfig`, `route`, `networksetup`, and `scutil` for local network state;
- `pmset` and I/O Registry queries for power information;
- narrowly selected `system_profiler` data only in `--full` mode.

### BSD-like systems

Begin with the POSIX baseline, then use capability-tested `sysctl`, `ifconfig`,
`netstat`, and native release files. BSD support may initially be best-effort,
but it must fail by field rather than by report.

### Windows

Use PowerShell and built-in APIs:

- CIM for operating system, hardware, firmware, CPU, memory, and storage facts;
- .NET identity APIs for the current user and administrator token;
- `Get-NetAdapter`, `Get-NetIPConfiguration`, and related cmdlets when present;
- CIM fallbacks for older Windows PowerShell environments;
- registry reads only when the value has no safer built-in source.

The Windows collector must not require PowerShell 7; Windows PowerShell 5.1 is
the compatibility baseline unless testing shows a necessary exception.

## POSIX implementation rules

The Unix collector must run under `/bin/sh` and avoid Bash-only behavior:

- no arrays, `[[ ... ]]`, `(( ... ))`, process substitution, or brace
  expansion;
- no `source`, `function` keyword, `$RANDOM`, or `${value//from/to}`;
- no dependence on `local`, `pipefail`, `readlink -f`, `sed -i`, `grep -P`, or
  GNU-only flags;
- use `printf` instead of `echo`;
- use `command -v` instead of `which`;
- quote expansions and avoid `eval`;
- do not use `set -e` as a substitute for explicit probe error handling;
- force a predictable locale only where parsing command output requires it;
- stream facts where possible so the default run needs no temporary files.

## Internal architecture

Keep the first Unix release distributable as one script, but divide it into
clear internal modules:

1. argument parsing and safety mode;
2. output and escaping functions;
3. fact/status storage or streaming protocol;
4. capability detection;
5. common POSIX probes;
6. platform detection;
7. Linux/BusyBox probes;
8. macOS probes;
9. BSD probes;
10. renderer and summary;
11. main entry point.

Probe functions should collect facts rather than format decorative output.
This keeps terminal, plain-text, and JSON renderers consistent.

## Development and review workflow

Use the staged workflow adapted from the `silabs-codex-experiment`
development playbook. Every meaningful stage must be implemented, verified,
reviewed, corrected, and recorded before the next stage is treated as complete.

### Two independent read-only reviews

After each meaningful implementation stage, request two independent reviews.
Reviewers inspect the patch and test evidence without editing files:

1. **Software and portability review**
   - readability and discoverability;
   - strict POSIX-shell compatibility and PowerShell clarity;
   - graceful behavior when commands or files are absent;
   - documentation and user-facing output;
   - maintainability of the probe and renderer boundaries.
2. **Senior systems and security review**
   - correctness of Linux, BusyBox, macOS, BSD, and Windows semantics;
   - the read-only, no-elevation, and no-network-traffic guarantees;
   - parsing of untrusted host data and shell-injection risks;
   - privacy exposure in reports;
   - CI, workflow, fixture, and fallback correctness.

For schema work, JSON escaping, hostile fixtures, or other test-heavy stages,
add a third test-architect review when it would materially improve confidence.
That reviewer challenges coverage, test oracles, boundaries, and tests that can
pass without proving the intended behavior.

Each review cycle must:

- record findings with severity and exact file/line references;
- keep reviewers read-only and leave fixes to the implementation stage;
- resolve or explicitly defer each finding with a reason;
- rerun the relevant local verification after fixes;
- send the corrected patch through follow-up review when findings were
  substantive;
- record remaining risks in `.codex/status.md`.

No stage is called reviewed merely because tests passed, and no stage is called
verified merely because reviewers found no issue.

### Status log

Keep `.codex/status.md` as the chronological source of truth. Before a handoff
or stopping point, append a short entry containing:

- what changed and why;
- review findings and their resolutions;
- commands run and their results;
- relevant CI run URLs or IDs;
- current branch and exact commit, or `uncommitted`;
- known limitations and a safe next step.

Do not place secrets, tokens, private addresses, hostnames, MAC addresses, or
other collected machine-specific values in the status log or test fixtures.

### Commit discipline

- Develop on a scoped feature branch from `main` and merge through a pull
  request unless the repository owner chooses another integration model.
- Keep each meaningful, verified stage in its own Conventional Commit.
- Separate implementation, review-fix, CI, and documentation changes when they
  represent independently understandable stages.
- Add a commit body when motivation, safety constraints, or verification are
  not obvious from the diff.
- Do not mix generated fixture updates with unrelated implementation changes.
- Push feature commits to the configured remote for backup when remote writes
  are authorized.
- Do not claim CI passed until the checks for that exact commit have completed
  successfully. A later status-only commit is a new head and must also finish
  its checks.

Example commit sequence:

```text
docs(plan): define read-only collection contract
ci(verify): add portable collector quality gates
feat(posix): add baseline identity and kernel probes
test(posix): cover missing and hostile host metadata
fix(review): harden fact parsing and fallback behavior
docs(status): record milestone verification evidence
```

## Continuous integration plan

Establish pull-request automation before opening a large implementation pull
request. If the base branch has no workflow yet, land a small bootstrap workflow
first so GitHub has registered the automation. The bootstrap confirms that CI
is active; it is not a replacement for the full quality gates.

The full workflow should run for:

- pull requests targeting `main`;
- pushes to `main`;
- manual dispatch.

Proposed jobs:

| Check | What it verifies |
| --- | --- |
| Source policy | Expected files, licenses, no generated host reports, and no forbidden persistent or machine-specific data |
| POSIX lint | ShellCheck in `sh` mode, formatting, and rejection of known Bashisms and non-portable command assumptions |
| Linux shell matrix | Tests under `dash`, BusyBox `ash`, and Bash in POSIX mode, including reduced-`PATH` fixtures |
| Read-only policy | No elevation, package-manager, active network, Wi-Fi scan, mount, service-control, or configuration commands enter the default probe path |
| Output/schema | Plain output snapshots, valid JSON, stable field names, escaping, and unavailable/error status behavior |
| macOS smoke | Built-in `/bin/sh` execution plus macOS-specific fixture and safe live-probe tests |
| Windows smoke | Windows PowerShell 5.1 and modern PowerShell tests, PSScriptAnalyzer, and matching-schema checks once `swiss.ps1` exists |
| Workflow security | `actionlint` and `zizmor` checks for GitHub Actions configuration |
| Secret scan | Pull-request base-to-head scan so only the proposed commit range is evaluated |

The initial CI can add jobs incrementally as their platform collectors appear,
but a missing job must be documented rather than represented as coverage.

### CI security requirements

- Use read-only workflow permissions by default and grant narrower additional
  permissions only to a job that proves it needs them.
- Pin third-party actions to immutable commit SHAs and document the associated
  stable release tag.
- Use ordinary `pull_request` events; do not use `pull_request_target` for code
  execution from proposed changes.
- Do not use repository secrets or a personal access token for normal collector
  verification.
- Reject mutable Docker action tags.
- Keep secret scanning limited to the exact pull-request base-to-head range.
- Add a manual action-version audit that compares pinned commits with current
  stable releases without silently updating them.
- Treat CI configuration as executable code and include it in both review
  passes.

### Local-to-CI parity

Expose the same verification through a single local entry point, initially
`scripts/verify.sh` and optionally a root `Makefile` wrapper. CI should call
that entry point instead of duplicating validation logic in workflow YAML.
Platform-only jobs may add their native checks around the shared verifier.

The verifier itself must not collect or publish real machine-identifying facts.
Tests should use sanitized fixtures, with only narrow smoke checks against the
ephemeral CI runner.

## Implementation milestones

### Milestone 0: contract and fixtures

- Finalize the version-one field list and JSON shape.
- Define status and confidence semantics with examples.
- Create sanitized fixtures for `/proc`, `/sys`, release files, routes, and
  representative command output.
- Define the read-only command allowlist for each platform.
- Add `.codex/status.md` and begin recording exact verification evidence.
- Add the local verification entry point and CI bootstrap.
- Land the full initial quality workflow on the base branch before a large
  collector implementation pull request.

### Milestone 1: POSIX skeleton

- Add `swiss.sh` with strict POSIX syntax.
- Implement argument parsing and human/plain renderers.
- Implement fact emission, error isolation, and debug sources.
- Add platform and capability detection.
- Add the portable identity, kernel, hostname, architecture, and filesystem
  probes.

### Milestone 2: Linux and BusyBox baseline

- Implement `/proc`, `/sys`, `/etc`, and device-tree fallbacks.
- Implement network interface, address, route, and DNS discovery without active
  traffic.
- Test with BusyBox `ash` and reduced command sets.
- Validate behavior against the constraints expected on the Zyxel NAS326.

### Milestone 3: macOS adapter

- Implement narrow native probes.
- Confirm compatibility with the system `/bin/sh`.
- Separate fast default probes from slower `--full` enumeration.

### Milestone 4: JSON and schema validation

- Implement correct JSON escaping without requiring Python, Perl, or `jq`.
- Validate output against the versioned schema.
- Ensure errors and unavailable fields never corrupt the document.

### Milestone 5: Windows collector

- Add `swiss.ps1` with the matching schema.
- Support Windows PowerShell 5.1 and modern PowerShell.
- Add Windows-specific fixtures and tests.

### Milestone 6: packaging and documentation

- Document copying and running a single platform entry point.
- Document exactly what is collected and the privacy implications.
- Add examples for ordinary Linux, BusyBox NAS, macOS, and Windows.
- Document limitations for GRUB and the future rescue-image approach.

### Milestone completion gate

For every milestone:

1. run the relevant local verification;
2. complete both independent read-only reviews;
3. resolve findings and rerun verification;
4. create scoped Conventional Commits;
5. push only when authorized and wait for CI on the exact head;
6. record review, local verification, commit, and CI evidence in
   `.codex/status.md`.

## Testing strategy

### Static checks

- Run ShellCheck in POSIX mode during development.
- Reject known Bashisms and GNU-only assumptions.
- Treat development tools as test dependencies, never runtime dependencies.

### Unix shell matrix

Run the same tests with, where available:

- Debian/Ubuntu `dash`;
- BusyBox `ash`;
- Bash invoked as `sh`;
- macOS `/bin/sh`;
- at least one BSD `/bin/sh` as the project matures.

### Capability-reduction tests

- remove optional commands from `PATH`;
- make representative files absent or unreadable in fixtures;
- supply malformed and hostile metadata values;
- test systems without `/proc` or `/sys`;
- test read-only filesystems;
- test non-root users;
- test machines with no default route or no non-loopback interface.

### Output tests

- verify stable field names;
- validate JSON and escaping of quotes, backslashes, control characters, and
  non-ASCII text;
- ensure normal missing data produces statuses, not stack traces or partial
  documents;
- ensure human output remains readable at narrow terminal widths;
- ensure secrets such as Wi-Fi credentials are never collected.

### Read-only audit

Before each release:

- review every external command invocation;
- confirm no probe requests elevation or prompts for credentials;
- confirm no default probe emits network traffic;
- trace a representative run where practical to identify unexpected writes;
- document any query that may be slow, wake hardware, or be logged by the OS.

## Acceptance criteria for the first usable release

- `swiss.sh` runs successfully under POSIX `sh`, `dash`, and BusyBox `ash`.
- It needs no installation and does not require root.
- It produces a useful report when `ip`, `ifconfig`, `lscpu`, `free`, `lsblk`,
  systemd, and a package manager are all absent.
- A missing or denied source affects only its own facts.
- The default run does not mutate host state, request elevation, scan Wi-Fi, or
  send network traffic.
- Human-readable and valid JSON reports describe the same facts.
- Linux reports include identity, OS/kernel, basic CPU and memory, filesystems,
  interfaces, local addresses when obtainable, route state, and configured DNS.
- macOS reports the corresponding facts using only built-in tools.
- Each nontrivial value can identify its source in debug output.
- The documented BusyBox/NAS limitations match observed behavior on at least one
  constrained test environment, with the Zyxel NAS326 as a target device.
- Every completed milestone has two independent review records and documented
  finding resolutions.
- The release commit has passed every required CI job for that exact head.
- The commit history is divided into meaningful, verified Conventional Commits.

## Explicitly deferred work

- installing diagnostic tools;
- repairs, tuning, cleanup, and configuration changes;
- interactive troubleshooting workflows;
- remote execution or fleet management;
- active internet, DNS, latency, or bandwidth tests;
- SMART self-tests and destructive storage tests;
- firmware updates;
- a GRUB-native implementation;
- rescue image and bootable USB packaging;
- compiled native helpers.

These can become later goals without weakening the read-only guarantees of the
first collector.
