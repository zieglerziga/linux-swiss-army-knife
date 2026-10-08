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

## 2026-10-07: daily hosted-runner specification report

### Changed

- Added dependency-free, read-only collectors for POSIX and Windows hosted
  runners. They emit compact JSON containing public runner/image/system facts
  only; hostnames, network information, user names, and tracking IDs are not
  collected.
- Added a fixture-driven static report with summary cards, a label filter, and
  a responsive observed-values table. The deployable dataset is assembled only
  from the current workflow's collector artifacts.
- Added `publish-runner-specifications.yml`, which collects the same 18
  explicit labels as the validation inventory daily at 03:17 UTC, aggregates
  their records, and deploys the static artifact through GitHub Pages.
- Added fixture/build/JavaScript checks to the existing runner validation
  workflow and documented local testing plus the Pages setup prerequisite.

### Why

The validated runner matrix establishes that this project works on materially
different hosted images. A point-in-time visualization makes the actual image
and operating-system specifications visible without granting the collector
network, package-management, or mutating capabilities.

### Verification

- `sh scripts/test-runner-site.sh`: passed.
- `sh scripts/validate-posix.sh`: passed with `/bin/sh`, `dash`, and Bash POSIX
  mode for every tracked shell script.
- `node --check site/app.js`: passed.
- PowerShell AST parsing of `scripts/collect-runner-windows.ps1`: passed.
- Ruby YAML parsing for both workflows: passed.
- Workflow assertions for the daily schedule, exact 18-label inventory match,
  full-SHA action pins, and required Pages deployment linkage/permissions:
  passed.
- `git diff --check`: passed.

`actionlint` is not installed locally. No hosted run has occurred because the
requested changes have not been pushed.

### Independent reviews

- Junior readability/documentation review initially found inconsistent runner
  schema-version types, incomplete two-workflow inventory guidance, and a
  filter label narrower than its behavior. All three were fixed.
- Senior correctness/security review initially found UTF-16LE output from
  Windows PowerShell 5.1 redirection and an unguarded non-default-branch manual
  deployment path. Both blockers were fixed with explicit UTF-8-no-BOM output,
  live encoding checks, and a default-branch deploy condition.
- Senior follow-up found that only the Windows collector had live schema-type
  coverage. An Ubuntu 24.04 collector smoke test was added.
- Final junior and senior Luna reviews reported no findings.

### Branch and commits

- Branch: `codex/gh-runner-pages`
- `79a0c87 feat(runners): collect hosted runner specifications`
- `645e99a feat(runners): add static specification report`
- `fd1687f ci(runners): publish daily specification report`
- `e37bf49 docs(runners): record specification report rollout`
- `f2555d6 fix(runners): emit portable specification records`
- `71a4985 fix(pages): restrict deployment and clarify operations`
- `72c6760 test(runners): cover POSIX specification schema`

### Known limitations and safe next step

The first Pages deployment requires a repository administrator to select
**GitHub Actions** as the Pages source and restrict the `github-pages`
environment to the default branch. After an authorized push to `main` (or a
manual dispatch of `main`), confirm all 18 collection jobs, the build artifact,
and the deployment on that exact commit. The report is an observation of the
current images, not a forward compatibility guarantee.
