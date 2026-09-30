#!/bin/sh

# Execute safe native checks and assert their output contract. Warnings are a
# valid health result; syntax-only success is not sufficient for this smoke.

set -u

fail()
{
    printf 'health-check smoke failed: %s\n' "$1" >&2
    exit 1
}

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) ||
    fail 'cannot resolve repository root'
output_path=$(mktemp "${TMPDIR:-/tmp}/health-check-smoke.XXXXXX") ||
    fail 'cannot create temporary output'
trap 'rm -f "$output_path"' EXIT HUP INT TERM

sh "$repository_root/health-check.sh" --plain --disk --processes >"$output_path"
health_status=$?
[ "$health_status" -le 1 ] || fail "health command returned $health_status"

[ "$(wc -l <"$output_path" | tr -d ' ')" -eq 2 ] ||
    fail 'expected exactly two selected result lines'
awk -F '\t' '
    NF != 3 { exit 1 }
    $1 == "disk" { disk++ }
    $1 == "processes" { processes++ }
    $2 !~ /^(pass|warn|unsupported)$/ { exit 1 }
    END { exit !(disk == 1 && processes == 1) }
' "$output_path" || fail 'native output does not match the result contract'

cat "$output_path"
printf '%s\n' 'Native health-check output smoke passed.'
