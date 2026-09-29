#!/bin/sh

set -u

fail()
{
    printf 'POSIX collector test failed: %s\n' "$1" >&2
    exit 1
}

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) ||
    fail 'cannot resolve repository root'
fixture_root=$repository_root/tests/fixtures/linux-basic
test_shell=${TEST_SHELL:-sh}
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/swiss-test.XXXXXX") ||
    fail 'cannot create temporary test directory'
trap 'rm -rf "$test_directory"' EXIT HUP INT TERM

run_collector()
{
    case "$test_shell" in
        sh) sh "$repository_root/swiss.sh" "$@" ;;
        dash) dash "$repository_root/swiss.sh" "$@" ;;
        busybox-ash) busybox ash "$repository_root/swiss.sh" "$@" ;;
        bash-posix) bash --posix "$repository_root/swiss.sh" "$@" ;;
        *) fail "unsupported TEST_SHELL: $test_shell" ;;
    esac
}

command -v jq >/dev/null 2>&1 || fail 'jq is required for development tests'

run_collector --version | grep -q '^linux-swiss-army-knife 0\.1\.0$' ||
    fail '--version output is incorrect'
run_collector --help | grep -q '^Usage: swiss\.sh' ||
    fail '--help output is incorrect'

if run_collector --not-an-option >"$test_directory/invalid.out" 2>"$test_directory/invalid.err"; then
    fail 'unknown option succeeded'
else
    invalid_status=$?
fi
[ "$invalid_status" -eq 2 ] || fail 'unknown option did not return exit status 2'

SWISS_FIXTURE_ROOT=$fixture_root run_collector --json >"$test_directory/report.json" ||
    fail 'fixture JSON collection failed'
jq -e '.schema_version == "1" and .collector.platform == "linux"' \
    "$test_directory/report.json" >/dev/null || fail 'top-level JSON metadata is invalid'
jq -e '(.facts | length) == 42 and (.facts | map(.key) | unique | length) == 42' \
    "$test_directory/report.json" >/dev/null || fail 'fact keys are missing or duplicated'
jq -e 'all(.facts[]; (.status | IN("ok", "unknown", "unsupported", "missing", "denied", "error")))' \
    "$test_directory/report.json" >/dev/null || fail 'invalid fact status'
jq -e 'all(.facts[]; (.confidence | IN("exact", "derived", "heuristic")))' \
    "$test_directory/report.json" >/dev/null || fail 'invalid confidence'

jq -r '.facts[].key' "$test_directory/report.json" >"$test_directory/actual-fields.txt"
cmp "$repository_root/schema/fields-v1.txt" "$test_directory/actual-fields.txt" >/dev/null ||
    fail 'fact order differs from schema/fields-v1.txt'

fact_value()
{
    jq -r --arg key "$1" '.facts[] | select(.key == $key) | .value' \
        "$test_directory/report.json"
}

[ "$(fact_value system.os.version)" = 42.1 ] || fail 'fixture OS version was not parsed'
expected_product='Fixture Linux "quoted" \ path snowman-☃'
[ "$(fact_value system.os.product)" = "$expected_product" ] ||
    fail 'quoted, backslash, or non-ASCII OS product was not preserved'
[ "$(fact_value hardware.cpu.model)" = 'Fixture Processor 9000' ] ||
    fail 'fixture CPU model was not parsed'
[ "$(fact_value hardware.cpu.logical_count)" = 2 ] ||
    fail 'fixture CPU count leaked from the live host'
[ "$(fact_value hardware.memory.total_bytes)" = 1073741824 ] ||
    fail 'fixture memory was not converted to bytes'
[ "$(fact_value hardware.battery.charge_percent)" = 73 ] ||
    fail 'fixture battery capacity was not parsed'
[ "$(fact_value network.default_route.gateway)" = 192.0.2.1 ] ||
    fail 'fixture route gateway was not decoded'
[ "$(fact_value network.dns.resolvers)" = '192.0.2.53,2001:db8::53' ] ||
    fail 'fixture DNS resolvers were not parsed'
fact_value hardware.storage | grep -q 'model=Fixture%3BDisk%7CModel%3D100%25' ||
    fail 'inventory delimiters were not percent-escaped'

SWISS_FIXTURE_ROOT=$fixture_root run_collector --plain >"$test_directory/plain.txt" ||
    fail 'plain collection failed'
[ "$(wc -l < "$test_directory/plain.txt" | tr -d ' ')" -eq 42 ] ||
    fail 'plain output does not contain one line per fact'
awk -F '\t' 'NF != 4 { exit 1 }' "$test_directory/plain.txt" ||
    fail 'plain output is not four-column tab-separated data'
jq -r '.facts[] | [.key,.status,.confidence,.value] | join("\t")' \
    "$test_directory/report.json" >"$test_directory/expected-plain.txt"
cmp "$test_directory/expected-plain.txt" "$test_directory/plain.txt" >/dev/null ||
    fail 'plain output differs from JSON fact semantics'

SWISS_FIXTURE_ROOT=$fixture_root run_collector --plain --debug >"$test_directory/debug.txt" ||
    fail 'debug collection failed'
awk -F '\t' 'NF != 5 { exit 1 }' "$test_directory/debug.txt" ||
    fail 'debug output does not include a source column'
cut -f1-4 "$test_directory/debug.txt" >"$test_directory/debug-core.txt"
cmp "$test_directory/expected-plain.txt" "$test_directory/debug-core.txt" >/dev/null ||
    fail 'debug output differs from JSON fact semantics'

SWISS_FIXTURE_ROOT=$fixture_root run_collector --json --full >"$test_directory/full.json" ||
    fail 'full fixture collection failed'
jq -e '.collector.mode == "full"' "$test_directory/full.json" >/dev/null ||
    fail '--full mode was not recorded'

for adapter in macos bsd unknown; do
    SWISS_FIXTURE_ROOT=$fixture_root SWISS_TEST_PLATFORM=$adapter \
        run_collector --json >"$test_directory/$adapter.json" ||
        fail "$adapter adapter fixture collection failed"
    jq -r '.facts[].key' "$test_directory/$adapter.json" >"$test_directory/$adapter-fields.txt"
    cmp "$repository_root/schema/fields-v1.txt" "$test_directory/$adapter-fields.txt" >/dev/null ||
        fail "$adapter adapter field order differs from the canonical manifest"
done
jq -e '
    (.facts[] | select(.key == "system.os.family") |
        .value == "macos" and .status == "ok") and
    (.facts[] | select(.key == "hardware.manufacturer") |
        .value == "Apple Inc." and .status == "ok") and
    (.facts[] | select(.key == "hardware.firmware.vendor") |
        .value == "Apple" and .status == "ok")
' "$test_directory/macos.json" >/dev/null ||
    fail 'macOS adapter fixture semantics are incorrect'

ipv6_fixture=$test_directory/linux-ipv6
cp -R "$fixture_root" "$ipv6_fixture"
printf '%s\n' 'Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT' \
    >"$ipv6_fixture/proc/net/route"
printf '%s\n' \
    '00000000000000000000000000000000 00 00000000000000000000000000000000 00 00000000000000000000000000000000 ffffffff 00000001 00000000 00200200 lo' \
    '00000000000000000000000000000000 00 00000000000000000000000000000000 00 20010db8000000000000000000000001 00000064 00000000 00000000 00000003 eth0' \
    >"$ipv6_fixture/proc/net/ipv6_route"
SWISS_FIXTURE_ROOT=$ipv6_fixture run_collector --json >"$test_directory/ipv6.json" ||
    fail 'IPv6-only route fixture collection failed'
ipv6_exists=$(jq -r '.facts[] | select(.key == "network.default_route.exists") | .value' \
    "$test_directory/ipv6.json")
ipv6_interface=$(jq -r '.facts[] | select(.key == "network.default_route.interface") | .value' \
    "$test_directory/ipv6.json")
ipv6_gateway=$(jq -r '.facts[] | select(.key == "network.default_route.gateway") | .value' \
    "$test_directory/ipv6.json")
if [ "$ipv6_exists" != true ] || [ "$ipv6_interface" != eth0 ] ||
    [ "$ipv6_gateway" != '2001:0db8:0000:0000:0000:0000:0000:0001' ]; then
    fail "IPv6 route mismatch: exists=$ipv6_exists interface=$ipv6_interface gateway=$ipv6_gateway"
fi

if command -v busybox >/dev/null 2>&1; then
    busybox_fixture=$test_directory/linux-busybox-df
    busybox_bin=$test_directory/busybox-bin
    cp -R "$fixture_root" "$busybox_fixture"
    rm -f "$busybox_fixture/fixtures/filesystems.txt"
    printf '%s\n' \
        '/dev/root / ext4 rw,relatime 0 0' \
        'server:/share /remote nfs rw,relatime 0 0' \
        'rclone remote: /cloud fuse.rclone rw,relatime 0 0' \
        >"$busybox_fixture/proc/mounts"
    mkdir -p "$busybox_bin"
    busybox --install -s "$busybox_bin"
    PATH=$busybox_bin SWISS_FIXTURE_ROOT=$busybox_fixture \
        SWISS_TEST_ALLOW_COMMAND=df "$busybox_bin/sh" "$repository_root/swiss.sh" --json \
        >"$test_directory/busybox-df.json" ||
        fail 'BusyBox-only filesystem fallback collection failed'
    jq -e '
        .facts[] | select(.key == "hardware.filesystems") |
        .status == "ok" and
        .source == "df -Pk for local /proc/mounts entries" and
        (.value | contains("/|total=")) and
        (.value | contains("/remote") | not) and
        (.value | contains("/cloud") | not)
    ' "$test_directory/busybox-df.json" >/dev/null ||
        fail 'BusyBox fallback did not restrict df to allowlisted local filesystems'
fi

if run_collector --plain --json >"$test_directory/conflict.out" 2>"$test_directory/conflict.err"; then
    fail 'mutually exclusive output options succeeded'
else
    conflict_status=$?
fi
[ "$conflict_status" -eq 2 ] || fail 'output-option conflict did not return exit status 2'

printf 'POSIX collector tests passed under %s.\n' "$test_shell"
