# Development status

This file is the chronological source of truth for implementation stages,
reviews, verification, commits, CI runs, known limitations, and safe next
steps. Do not record machine-identifying output, credentials, or secrets here.

## 2026-09-29: planning baseline

### Changed

- Defined the dependency-free, read-only collection goal in `.codex/plan.md`.
- Added the staged two-review workflow adapted from the
  `silabs-codex-experiment` development playbook.
- Added Conventional Commit discipline and exact-head CI evidence rules.
- Defined an initial CI job model for POSIX shells, BusyBox, macOS, Windows,
  schema validation, read-only policy enforcement, workflow security, and
  secret scanning.

### Why

The project needs verifiable safety and portability practices before system
inspection code is introduced. In particular, a read-only collector needs both
ordinary software review and systems/security review because passing tests
alone cannot prove that probes are portable or side-effect free.

### Reviews

- Not started. This entry records planning work, not a completed implementation
  milestone.

### Verification

- `git diff --check`: passed after the workflow import.

### Branch and commit

- Branch: `main`
- Commit: `uncommitted`

### Known limitations

- No collector, fixtures, verification script, or CI workflow exists yet.
- The exact version-one JSON schema is not finalized.
- Platform support described in the plan remains proposed, not tested.

### Safe next step

Finalize the version-one fact schema and status representation, then add the
local verification entry point and minimal CI bootstrap before implementing
host probes.

## 2026-09-29: free hosted-runner validation matrix

### Changed

- Added `.github/workflows/validate-runners.yml` with 18 dedicated matrix jobs
  covering every explicit standard GitHub-hosted runner image documented for
  public repositories on this date.
- Added Linux and macOS runner metadata validation plus parse-only POSIX shell
  checks.
- Added Windows Server/Windows 11 metadata validation, native architecture
  checks, PowerShell AST parsing, Git Bash parse-only checks, and Visual Studio
  2026 major-version validation on the explicit VS2026 images.
- Pinned `actions/checkout` v7.0.1 to commit
  `3d3c42e5aac5ba805825da76410c181273ba90b1` and disabled credential
  persistence.
- Added `.codex/runner-inventory.md` with the dated runner inventory and policy.
- Added a README badge and a concise explanation of the current read-only CI
  scope.

### Why

The collector is intended to work across materially different operating-system
and architecture environments. Exercising every free standard hosted image
detects shell, PowerShell, OS-version, and architecture assumptions before the
collector reaches users. Existing interactive management code is parsed but
never executed.

### Dedicated runner reviews

One Luna subagent independently reviewed each of the 18 runner labels before
implementation:

- Linux: `ubuntu-slim`, Ubuntu 22.04/24.04/26.04 on x64 and arm64;
- macOS: 14 arm64, 15 arm64/x64, 26 arm64/x64, and the Xcode 27 preview;
- Windows: Server 2022, Server 2025, Server 2025 with VS2026, Windows 11
  arm64, and Windows 11 arm64 with VS2026.

The reviews confirmed the official label/architecture mappings and consistently
required parse-only handling of `docker_manager.sh` because it contains
interactive and mutating operations.

### Independent staged reviews

- Software/portability review: no findings after follow-up.
- Senior systems/security review: initially found that Linux checked only
  `VERSION_ID` and did not prove Ubuntu identity. Fixed by requiring readable
  `/etc/os-release` and `ID=ubuntu`, including for `ubuntu-slim`.
- Test-architect review: initially found that the Xcode 27 preview row was
  non-blocking. Fixed by making all 18 rows blocking.
- Security hardening: all checkout steps now set
  `persist-credentials: false`.
- Follow-up reviews confirmed no remaining actionable or blocking findings.

Accepted limitations are filename enumeration by conventional `.sh`, `.ps1`,
`.psm1`, and `.psd1` extensions, and the fact that GitHub does not expose the
scheduled runner label as independent runtime metadata. The workflow validates
OS, architecture, product family, and version while `runs-on` selects the label.

### Verification

- `sh -n scripts/validate-posix.sh`: passed.
- `sh -n scripts/validate-runner-posix.sh`: passed.
- `sh scripts/validate-posix.sh`: passed for every current `.sh` file without
  executing project entry points.
- Ruby YAML syntax parsing of `.github/workflows/validate-runners.yml`: passed.
- Matrix inventory assertion: 18 rows.
- Checkout-hardening assertion: 3 checkout sites with credential persistence
  disabled.
- Blocking-policy assertion: no `continue-on-error` rows.
- Trailing-whitespace scan: passed.
- `git diff --check`: passed.

Native `actionlint`, Windows PowerShell 5.1, and PowerShell 7 were unavailable
on the local Linux host. Their first executable verification will be the hosted
workflow itself; PowerShell compatibility was inspected in both independent
review passes.

### CI runs

- None yet. The workflow has not been committed or pushed.

### Branch and commit

- Branch: `main`
- Commit: `uncommitted`

### Known lifecycle risks

- `xcode-27` is public preview and has no SLA, but remains blocking to ensure
  that all requested available images genuinely validate.
- `macos-14` is scheduled for retirement on 2026-11-02 and must be removed when
  GitHub removes the label.
- Ubuntu 22.04 images have entered deprecation and must remain only while their
  labels are available.
- `windows-11-arm` is transitioning to the VS2026 image through 2026-09-30;
  the explicit VS2026 label is tested separately.

### Safe next step

Create a scoped commit such as
`ci(validation): cover all hosted runner versions`, push it when authorized,
and wait for all 18 jobs on that exact commit before claiming CI success.

## 2026-09-29: cross-platform read-only collectors

### Changed

- Added `swiss.sh`, a single-file POSIX collector with Linux, BusyBox, macOS,
  BSD-baseline, human, plain, debug, full, and JSON paths.
- Added `swiss.ps1`, a matching 42-field Windows collector compatible with
  Windows PowerShell 5.1 syntax and modern PowerShell.
- Added the exact version-one field manifest and JSON Schema, sanitized Linux
  fixtures, a small standard-library schema validator, source-policy checks,
  and behavior tests for POSIX shells and PowerShell.
- Changed filesystem capacity collection to local filesystems only. macOS
  storage/firmware and Windows physical-disk enumeration require `--full`.
- Added platform CI smokes and collector tests to the existing 18-runner
  matrix, plus user documentation covering execution and report privacy.

### Why

The repository's first feature target is one familiar, dependency-free,
read-only report model across Linux/macOS and Windows. The implementation must
remain useful on this Omarchy Steam Deck and on reduced BusyBox systems while
degrading per fact when a command or local interface is unavailable.

### Reviews and resolutions

Two independent initial read-only reviews produced substantive findings:

- The systems/security review found that unrestricted `df -Pk` could contact
  mounted network filesystems, the source-policy check was bypassable, CI did
  not run behavior tests, fixtures leaked live host facts, IPv6/fallback route
  handling was incomplete, inventories lacked delimiter escaping, and the
  schema did not enforce canonical keys.
- The test-architect review additionally found non-canonical macOS/unknown
  field order, missing Windows enforcement, weak plain/debug parity checks,
  and missing hostile-value, `--full`, and cross-adapter coverage.

Resolved by using local-only filesystem enumeration, moving potentially
expensive storage queries behind `--full`, hermetically disabling command
probes in fixtures, adding IPv6 and failed-command fallbacks, percent-encoding
inventory delimiters, validating exactly 42 ordered keys, comparing all output
modes, requiring both entry points, and running shared/native tests in CI.

Follow-up review attempts and the dedicated portability reviewer could not
complete because the reviewer account reached its usage limit. Therefore this
entry records the initial review findings and verified fixes but does not claim
independent follow-up approval. The limitation is explicit rather than treating
the failed reviewer turns as successful reviews.

### Verification

- Installed Dash, BusyBox, ShellCheck, and PowerShell 7.6.6 through Omarchy's
  package workflow with GUI authentication; the account has full passworded
  sudo rights through `wheel`.
- `scripts/verify.sh`: passed under `/bin/sh`, Dash, BusyBox `ash`, Bash POSIX
  mode, ShellCheck, PowerShell 7.6.6, source-policy tests, schema validation,
  negative schema tests, and sanitized fixture tests.
- `SWISS_EXPECTED_PLATFORM=linux sh scripts/smoke-posix.sh`: passed on the
  Omarchy Steam Deck.
- A Bubblewrap smoke with a read-only root and detached network namespace
  produced valid 42-field Linux JSON.
- Ruby JSON/YAML parsing, the 18-row matrix assertion, PowerShell AST parsing,
  `git diff --check`, and immutable-checkout assertions passed locally.

No machine-identifying report values were added to the repository or this log.

### CI runs

- Bootstrap commit `3d2fa30530399024a914b3b313a421ffa4864fe4` ran as
  [GitHub Actions run 36631092215](https://github.com/zieglerziga/linux-swiss-army-knife/actions/runs/36631092215).
  Linux and macOS rows passed, but all Windows rows failed because Windows
  PowerShell returned multiple `bash.exe` applications and the validator
  coerced them into one invalid path. Commit `b4d056e` selects the first exact
  application. The feature-head CI run is pending.

### Branch and commits

- Branch: `codex/read-only-inspector-v1`
- `981055a` — `feat(inspector): add cross-platform read-only collectors`
- `86729ab` — `test(inspector): enforce schema and safety contract`
- `52c6e11` — `ci(validation): execute collector quality gates`
- `b4d056e` — `fix(ci): select one Git Bash executable`
- Documentation/status changes in this entry: `uncommitted`

### Known limitations

- Native macOS and Windows probe behavior awaits the feature branch's hosted
  CI run; local Windows-path tests used PowerShell 7 on Linux plus an emulated
  Windows control path.
- Independent follow-up review remains pending because reviewer usage was
  exhausted.
- BSD support is a best-effort portable baseline rather than release-grade
  platform coverage.

### Safe next step

Push the feature branch, open a pull request, wait for every job on the exact
head, fix any native-platform findings, and rerun the full matrix before merge.
