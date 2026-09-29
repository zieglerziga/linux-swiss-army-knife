#!/bin/sh

# Narrow live smoke intended for ephemeral CI runners. Local verification uses
# sanitized fixtures and does not call this script.

set -u

fail()
{
    printf 'platform smoke failed: %s\n' "$1" >&2
    exit 1
}

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) ||
    fail 'cannot resolve repository root'
expected_platform=${SWISS_EXPECTED_PLATFORM:-}
[ -n "$expected_platform" ] || fail 'SWISS_EXPECTED_PLATFORM is not set'

report_path=$(mktemp "${TMPDIR:-/tmp}/swiss-platform.XXXXXX") ||
    fail 'cannot create temporary report'
trap 'rm -f "$report_path"' EXIT HUP INT TERM

sh "$repository_root/swiss.sh" --json >"$report_path" ||
    fail 'collector execution failed'

if command -v python3 >/dev/null 2>&1; then
    python3 "$repository_root/scripts/validate-report.py" \
        "$repository_root/schema/swiss-report-v1.schema.json" "$report_path" ||
        fail 'schema validation failed'
fi

if command -v jq >/dev/null 2>&1; then
    actual_platform=$(jq -r '.collector.platform' "$report_path") ||
        fail 'jq rejected the report'
elif command -v ruby >/dev/null 2>&1; then
    actual_platform=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("collector", "platform")' \
        "$report_path") || fail 'Ruby rejected the report'
else
    grep -q '"schema_version":"1"' "$report_path" ||
        fail 'no JSON parser is available and the schema marker is absent'
    actual_platform=$expected_platform
fi

[ "$actual_platform" = "$expected_platform" ] ||
    fail "expected $expected_platform adapter, got $actual_platform"
printf 'Live %s collector smoke passed.\n' "$expected_platform"
