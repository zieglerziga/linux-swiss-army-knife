#!/bin/sh

set -u

fail()
{
    printf 'POSIX health-check test failed: %s\n' "$1" >&2
    exit 1
}

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) ||
    fail 'cannot resolve repository root'
collector=$repository_root/health-check.sh
fixture_root=$repository_root/tests/fixtures/health-basic
test_shell=${TEST_SHELL:-sh}
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/health-check-test.XXXXXX") ||
    fail 'cannot create temporary test directory'
trap 'rm -rf "$test_directory"' EXIT HUP INT TERM

run_health_check()
{
    case "$test_shell" in
        busybox-ash) busybox ash "$collector" "$@" ;;
        bash-posix) bash --posix "$collector" "$@" ;;
        *) "$test_shell" "$collector" "$@" ;;
    esac
}

version_output=$(run_health_check --version) || fail '--version failed'
[ "$version_output" = 'health-check.sh 0.1.0' ] || fail '--version output is incorrect'
run_health_check --help | grep -q '^Usage: health-check\.sh' || fail '--help output is incorrect'

sudo_output=$(HEALTH_FIXTURE_ROOT=$fixture_root run_health_check --plain --sudo) ||
    fail 'selected sudo fixture check failed'
expected_sudo=$(printf 'sudo\tpass\tnon-interactive sudo policy validation succeeded')
[ "$sudo_output" = "$expected_sudo" ] || fail 'sudo output is not exact'

disk_output=
if disk_output=$(HEALTH_FIXTURE_ROOT=$fixture_root run_health_check --plain --disk); then
    fail 'warning disk fixture unexpectedly returned success'
else
    disk_status=$?
fi
[ "$disk_status" -eq 1 ] || fail 'disk warning did not return exit status 1'
expected_disk=$(printf 'disk\twarn\t1 filesystem(s) at or above 85%%: /=90%%')
[ "$disk_output" = "$expected_disk" ] || fail 'disk warning output is not exact'

disk_pass=$(HEALTH_FIXTURE_ROOT=$fixture_root run_health_check \
    --plain --disk --disk-warning 95) || fail 'disk pass fixture failed'
expected_disk_pass=$(printf 'disk\tpass\thighest local filesystem use is 90%%; warning threshold is 95%%')
[ "$disk_pass" = "$expected_disk_pass" ] || fail 'disk pass output is not exact'

process_output=
if process_output=$(HEALTH_FIXTURE_ROOT=$fixture_root run_health_check --plain --processes); then
    fail 'suspicious process fixture unexpectedly returned success'
else
    process_status=$?
fi
[ "$process_status" -eq 1 ] || fail 'process warning did not return exit status 1'
expected_process=$(printf 'processes\twarn\t2 process(es) in D or Z state: 101:D:blocked-worker, 202:Z:zombie-child')
[ "$process_output" = "$expected_process" ] || fail 'process output is not exact'

all_output=
if all_output=$(HEALTH_FIXTURE_ROOT=$fixture_root run_health_check --plain --all); then
    fail 'warning fixture set unexpectedly returned success'
else
    all_status=$?
fi
[ "$all_status" -eq 1 ] || fail '--all did not return the worst warning status'
[ "$(printf '%s\n' "$all_output" | wc -l | tr -d ' ')" -eq 4 ] ||
    fail '--all did not emit exactly four results'
printf '%s\n' "$all_output" | sed -n '1p' | grep -q '^sudo[[:space:]]' ||
    fail '--all result order does not start with sudo'
printf '%s\n' "$all_output" | sed -n '4p' | grep -q '^updates[[:space:]]' ||
    fail '--all result order does not end with updates'

if run_health_check --plain >"$test_directory/no-check.out" 2>"$test_directory/no-check.err"; then
    fail 'empty check selection unexpectedly succeeded'
else
    no_check_status=$?
fi
[ "$no_check_status" -eq 2 ] || fail 'empty selection did not return exit status 2'
grep -q 'select at least one check' "$test_directory/no-check.err" ||
    fail 'empty selection error is not useful'

if run_health_check --disk --disk-warning 101 >"$test_directory/threshold.out" \
    2>"$test_directory/threshold.err"; then
    fail 'invalid disk threshold unexpectedly succeeded'
else
    threshold_status=$?
fi
[ "$threshold_status" -eq 2 ] || fail 'invalid threshold did not return exit status 2'

mkdir "$test_directory/df-bin"
cat >"$test_directory/df-bin/df" <<'MOCK_DF'
#!/bin/sh
cat <<'DF_OUTPUT'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/root 1000 900 100 90% /
DF_OUTPUT
exit 1
MOCK_DF
chmod +x "$test_directory/df-bin/df"
partial_df_output=$(PATH="$test_directory/df-bin:$PATH" run_health_check \
    --plain --disk --disk-warning 95) ||
    fail 'usable df output was discarded because df returned non-zero'
[ "$partial_df_output" = "$expected_disk_pass" ] ||
    fail 'partial-success df output was parsed incorrectly'

mkdir "$test_directory/bin"
cat >"$test_directory/bin/ssh" <<'MOCK_SSH'
#!/bin/sh
printf '%s\n' "$@" >"$HEALTH_SSH_CAPTURE"
grep -q '^Usage: health-check.sh' || exit 91
printf 'disk\tpass\tmock remote disk output\n'
MOCK_SSH
chmod +x "$test_directory/bin/ssh"
remote_output=$(PATH="$test_directory/bin:$PATH" \
    HEALTH_SSH_CAPTURE="$test_directory/ssh-arguments.txt" \
    run_health_check --plain --disk --remote user@example.test) ||
    fail 'mock SSH execution failed'
expected_remote=$(printf 'disk\tpass\tmock remote disk output')
[ "$remote_output" = "$expected_remote" ] || fail 'remote output was changed locally'
grep -qx 'BatchMode=yes' "$test_directory/ssh-arguments.txt" ||
    fail 'remote execution did not require batch mode'
grep -qx 'StrictHostKeyChecking=yes' "$test_directory/ssh-arguments.txt" ||
    fail 'remote execution did not require strict host-key checking'
grep -qx 'user@example.test' "$test_directory/ssh-arguments.txt" ||
    fail 'remote destination was not passed exactly'
grep -qx -- '--disk' "$test_directory/ssh-arguments.txt" ||
    fail 'selected remote check was not forwarded'
if grep -qi 'StrictHostKeyChecking=no' "$test_directory/ssh-arguments.txt"; then
    fail 'remote execution disabled strict host-key checking'
fi

compatibility_output=$(HEALTH_FIXTURE_ROOT=$fixture_root \
    sh "$repository_root/pc_healt_check.sh" --plain --sudo \
    2>"$test_directory/compatibility.err") || fail 'compatibility entry point failed'
[ "$compatibility_output" = "$expected_sudo" ] || fail 'compatibility output differs'
grep -q 'deprecated' "$test_directory/compatibility.err" ||
    fail 'compatibility entry point did not explain the rename'

printf 'POSIX health-check tests passed under %s.\n' "$test_shell"
