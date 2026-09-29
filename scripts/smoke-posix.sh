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

command -v python3 >/dev/null 2>&1 || fail 'python3 is required by the CI smoke'
python3 "$repository_root/scripts/validate-report.py" \
    "$repository_root/schema/swiss-report-v1.schema.json" "$report_path" ||
    fail 'schema validation failed'

python3 - "$report_path" "$expected_platform" <<'PY' ||
import json
import sys

with open(sys.argv[1], encoding="utf-8") as report_file:
    report = json.load(report_file)

facts = {fact["key"]: fact for fact in report["facts"]}
platform = sys.argv[2]

def require_ok(key):
    fact = facts[key]
    if fact["status"] != "ok" or not fact["value"].strip():
        raise SystemExit(f"{platform} live probe is not usable: {key}={fact}")
    return fact["value"]

for required_key in (
    "system.os.product",
    "system.os.version",
    "hardware.cpu.logical_count",
    "hardware.memory.total_bytes",
    "network.hostname",
    "network.interfaces",
):
    require_ok(required_key)

if int(facts["hardware.cpu.logical_count"]["value"]) <= 0:
    raise SystemExit("logical CPU count is not positive")
if int(facts["hardware.memory.total_bytes"]["value"]) <= 0:
    raise SystemExit("memory size is not positive")

if platform == "macos":
    uptime = int(require_ok("system.uptime_seconds"))
    if uptime < 0 or uptime > 10 * 365 * 24 * 60 * 60:
        raise SystemExit(f"macOS uptime is implausible: {uptime}")
PY
    fail 'native fact assertions failed'

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
