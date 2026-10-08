# Linux Swiss Army Knife

[![Validate GitHub-hosted runners](https://github.com/zieglerziga/linux-swiss-army-knife/actions/workflows/validate-runners.yml/badge.svg)](https://github.com/zieglerziga/linux-swiss-army-knife/actions/workflows/validate-runners.yml)

A portable computer-information and maintenance toolkit. The first development
goal is dependency-free, read-only information collection across Linux,
BusyBox, macOS, and Windows.

The current validation workflow performs parse-only checks on every versioned
standard GitHub-hosted runner available to public repositories. Existing
interactive management scripts are never executed by CI.

## GitHub-hosted runner report

`publish-runner-specifications.yml` collects a fresh, read-only snapshot from
the same 18 explicit GitHub-hosted runner labels described in
`.codex/runner-inventory.md`. It runs every day at 03:17 UTC (deliberately not
at minute zero), on demand, and when the report implementation changes on
`main`.

The POSIX and Windows collectors use only local OS metadata and built-in
commands. They report the requested label, Actions OS/architecture context,
image OS/version, OS and kernel details, machine architecture, and the macOS
Xcode version when available. They intentionally do not collect hostnames,
network addresses, user names, or runner tracking identifiers.

Each collection job publishes one short-lived record. A separate build job
combines those records into a static, filterable report and deploys it through
the official GitHub Pages artifact workflow. Before the first deployment, a
repository administrator must select **GitHub Actions** as the Pages source in
the repository's Pages settings and restrict the `github-pages` environment to
the default branch. The workflow also prevents non-default-branch manual runs
from deploying.

GitHub may automatically disable scheduled workflows in a public repository
after 60 days without repository activity. If daily collection stops for that
reason, re-enable this workflow from the repository's Actions page.

To exercise the static report locally with non-identifying fixtures:

```sh
sh scripts/test-runner-site.sh
```

Observed image contents are a point-in-time report, not a compatibility
guarantee. The authoritative label lifecycle and validation policy remain in
`.codex/runner-inventory.md`.
