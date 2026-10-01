#!/bin/sh

set -u

fail()
{
    printf 'verification failed: %s\n' "$1" >&2
    exit 1
}

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) ||
    fail 'cannot resolve repository root'
cd "$repository_root" || fail 'cannot enter repository root'

printf '%s\n' '== Parse checks =='
sh -n swiss.sh || fail 'sh rejected swiss.sh'
sh -n health-check.sh || fail 'sh rejected health-check.sh'
sh -n pc_healt_check.sh || fail 'sh rejected pc_healt_check.sh'
sh -n tests/test-posix.sh || fail 'sh rejected tests/test-posix.sh'
sh -n tests/test-health-posix.sh || fail 'sh rejected tests/test-health-posix.sh'
sh -n tests/test-source-policy.sh || fail 'sh rejected tests/test-source-policy.sh'
[ -f swiss.ps1 ] || fail 'swiss.ps1 is missing'
[ -f health-check.ps1 ] || fail 'health-check.ps1 is missing'
[ -f scripts/smoke-health-windows.ps1 ] || fail 'Windows health smoke is missing'

if command -v dash >/dev/null 2>&1; then
    dash -n swiss.sh || fail 'dash rejected swiss.sh'
fi
if command -v busybox >/dev/null 2>&1; then
    busybox ash -n swiss.sh || fail 'BusyBox ash rejected swiss.sh'
fi
if command -v bash >/dev/null 2>&1; then
    bash --posix -n swiss.sh || fail 'Bash POSIX mode rejected swiss.sh'
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --shell=sh swiss.sh scripts/*.sh tests/*.sh ||
        fail 'ShellCheck reported findings'
else
    printf '%s\n' 'NOTE: ShellCheck is unavailable; static lint was skipped.'
fi

printf '%s\n' '== Source policy =='
sh tests/test-source-policy.sh || fail 'source-policy checks failed'

printf '%s\n' '== POSIX behavior =='
env TEST_SHELL=sh sh tests/test-posix.sh || fail 'tests failed under /bin/sh'
env TEST_SHELL=sh sh tests/test-health-posix.sh ||
    fail 'health-check tests failed under /bin/sh'
if command -v dash >/dev/null 2>&1; then
    env TEST_SHELL=dash sh tests/test-posix.sh || fail 'tests failed under dash'
    env TEST_SHELL=dash sh tests/test-health-posix.sh ||
        fail 'health-check tests failed under dash'
fi
if command -v busybox >/dev/null 2>&1; then
    env TEST_SHELL=busybox-ash sh tests/test-posix.sh || fail 'tests failed under BusyBox ash'
    env TEST_SHELL=busybox-ash sh tests/test-health-posix.sh ||
        fail 'health-check tests failed under BusyBox ash'
fi
if command -v bash >/dev/null 2>&1; then
    env TEST_SHELL=bash-posix sh tests/test-posix.sh || fail 'tests failed under Bash POSIX mode'
    env TEST_SHELL=bash-posix sh tests/test-health-posix.sh ||
        fail 'health-check tests failed under Bash POSIX mode'
fi

printf '%s\n' '== Sanitized report smoke =='
live_report=$(mktemp "${TMPDIR:-/tmp}/swiss-fixture.XXXXXX") ||
    fail 'cannot create fixture-smoke output'
trap 'rm -f "$live_report"' EXIT HUP INT TERM
SWISS_FIXTURE_ROOT=$repository_root/tests/fixtures/linux-basic \
    sh swiss.sh --json >"$live_report" || fail 'fixture JSON collection failed'
if command -v jq >/dev/null 2>&1; then
    jq -e '.schema_version == "1" and (.facts | length == 42)' "$live_report" >/dev/null ||
        fail 'fixture JSON report is invalid'
elif command -v ruby >/dev/null 2>&1; then
    ruby -rjson -e 'report=JSON.parse(File.read(ARGV[0])); abort unless report["schema_version"] == "1" && report["facts"].length == 42' "$live_report" ||
        fail 'fixture JSON report is invalid'
else
    printf '%s\n' 'NOTE: jq and Ruby are unavailable; JSON parse smoke was skipped.'
fi
if command -v python3 >/dev/null 2>&1; then
    python3 scripts/validate-report.py schema/swiss-report-v1.schema.json "$live_report" ||
        fail 'fixture report failed JSON Schema validation'
    invalid_report=$(mktemp "${TMPDIR:-/tmp}/swiss-invalid.XXXXXX") ||
        fail 'cannot create negative-schema fixture'
    if command -v jq >/dev/null 2>&1; then
        jq '.facts[1].key = .facts[0].key' "$live_report" >"$invalid_report"
        if python3 scripts/validate-report.py schema/swiss-report-v1.schema.json \
            "$invalid_report" >/dev/null 2>&1; then
            rm -f "$invalid_report"
            fail 'schema accepted a duplicate/out-of-order canonical key'
        fi
    fi
    rm -f "$invalid_report"
else
    printf '%s\n' 'NOTE: Python 3 is unavailable; JSON Schema validation was skipped.'
fi

if command -v pwsh >/dev/null 2>&1; then
    SWISS_FIXTURE_MODE=1 pwsh -NoLogo -NoProfile -File tests/test-windows.ps1 ||
        fail 'PowerShell collector tests failed'
    pwsh -NoLogo -NoProfile -File tests/test-health-windows.ps1 ||
        fail 'PowerShell health-check tests failed'
else
    printf '%s\n' 'NOTE: PowerShell is unavailable; native tests are delegated to Windows CI.'
fi

git diff --check || fail 'git diff --check failed'
printf '%s\n' 'All local verification passed.'
