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
expected_disk=$(printf 'disk\twarn\t1 local filesystem path(s) at or above 85%%: /=90%%')
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
printf '%s\n' "$*" >>"$HEALTH_DF_CAPTURE"
case " $* " in
    *' -Pkl '*)
        if [ "${HEALTH_DF_GLOBAL_PARTIAL:-0}" -eq 1 ]; then
            cat <<'DF_OUTPUT'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/root 1000 900 100 90% /
DF_OUTPUT
        fi
        exit 1
        ;;
    *' / '*)
        cat <<'DF_OUTPUT'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/root 1000 900 100 90% /
DF_OUTPUT
        ;;
    *' /media/ntfs '*)
        cat <<'DF_OUTPUT'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/ntfs 1000 960 40 96% /media/ntfs
DF_OUTPUT
        ;;
    *' /unreadable '*) exit 9 ;;
    *' /partial '*)
        cat <<'DF_OUTPUT'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/partial 1000 100 900 10% /partial
DF_OUTPUT
        exit 9
        ;;
    *' /bind '*)
        cat <<'DF_OUTPUT'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/root 1000 900 100 90% /bind
DF_OUTPUT
        ;;
    *)
        printf '%s\n' 'mock df received an unexpected mount' >&2
        exit 9
        ;;
esac
MOCK_DF
chmod +x "$test_directory/df-bin/df"
cat >"$test_directory/mounts" <<'MOUNTS'
/dev/root / ext4 rw 0 0
server:/share /remote nfs rw 0 0
MOUNTS
partial_df_output=$(PATH="$test_directory/df-bin:$PATH" \
    HEALTH_DF_CAPTURE="$test_directory/df-arguments.txt" \
    HEALTH_TEST_MOUNTS_PATH="$test_directory/mounts" run_health_check \
    --plain --disk --disk-warning 95) ||
    fail 'procfs fallback did not recover from unsupported df -l syntax'
[ "$partial_df_output" = "$expected_disk_pass" ] ||
    fail 'partial-success df output was parsed incorrectly'
if grep -q '/remote' "$test_directory/df-arguments.txt"; then
    fail 'BusyBox df fallback queried a network mount'
fi

global_partial_output=
if global_partial_output=$(PATH="$test_directory/df-bin:$PATH" \
    HEALTH_DF_CAPTURE="$test_directory/df-arguments.txt" \
    HEALTH_DF_GLOBAL_PARTIAL=1 run_health_check \
    --plain --disk --disk-warning 95); then
    fail 'partial nonzero local-only df output unexpectedly passed'
else
    global_partial_status=$?
fi
[ "$global_partial_status" -eq 1 ] ||
    fail 'partial local-only df output did not return unsupported status'
expected_global_partial=$(printf 'disk\tunsupported\tknown local filesystems are below 95%%, but scan is incomplete: query failure(s): df -Pkl returned nonzero')
[ "$global_partial_output" = "$expected_global_partial" ] ||
    fail 'partial local-only df output was treated as complete'

cat >"$test_directory/mounts" <<'MOUNTS'
/dev/root / ext4 rw 0 0
/dev/root /bind ext4 rw,bind 0 0
MOUNTS
bind_output=
if bind_output=$(PATH="$test_directory/df-bin:$PATH" \
    HEALTH_DF_CAPTURE="$test_directory/df-arguments.txt" \
    HEALTH_TEST_MOUNTS_PATH="$test_directory/mounts" run_health_check \
    --plain --disk --disk-warning 85); then
    fail 'full bind-mount fixture unexpectedly returned success'
else
    bind_status=$?
fi
[ "$bind_status" -eq 1 ] || fail 'bind-mount warnings did not return status 1'
expected_bind=$(printf 'disk\twarn\t2 local filesystem path(s) at or above 85%%: /=90%%, /bind=90%%')
[ "$bind_output" = "$expected_bind" ] ||
    fail 'distinct bind mount paths were not reported consistently'

cat >"$test_directory/mounts" <<'MOUNTS'
/dev/root / ext4 rw 0 0
/dev/ntfs /media/ntfs fuseblk rw 0 0
server:/share /remote nfs rw 0 0
MOUNTS
fuse_disk_output=
if fuse_disk_output=$(PATH="$test_directory/df-bin:$PATH" \
    HEALTH_DF_CAPTURE="$test_directory/df-arguments.txt" \
    HEALTH_TEST_MOUNTS_PATH="$test_directory/mounts" run_health_check \
    --plain --disk --disk-warning 95); then
    fail 'nearly full fuseblk fixture unexpectedly returned success'
else
    fuse_disk_status=$?
fi
[ "$fuse_disk_status" -eq 1 ] || fail 'fuseblk warning did not return status 1'
expected_fuse_disk=$(printf 'disk\twarn\t1 local filesystem path(s) at or above 95%%: /media/ntfs=96%%')
[ "$fuse_disk_output" = "$expected_fuse_disk" ] ||
    fail 'fuseblk filesystem was not included in disk results'
if grep -q '/remote' "$test_directory/df-arguments.txt"; then
    fail 'network mount was queried alongside fuseblk'
fi

cat >"$test_directory/mounts" <<'MOUNTS'
/dev/root / ext4 rw 0 0
/dev/mystery /mystery mysteryfs rw 0 0
MOUNTS
unknown_disk_output=
if unknown_disk_output=$(PATH="$test_directory/df-bin:$PATH" \
    HEALTH_DF_CAPTURE="$test_directory/df-arguments.txt" \
    HEALTH_TEST_MOUNTS_PATH="$test_directory/mounts" run_health_check \
    --plain --disk --disk-warning 95); then
    fail 'unclassified filesystem fixture unexpectedly passed'
else
    unknown_disk_status=$?
fi
[ "$unknown_disk_status" -eq 1 ] ||
    fail 'unclassified filesystem did not return unsupported status'
expected_unknown_disk=$(printf 'disk\tunsupported\tknown local filesystems are below 95%%, but scan is incomplete: unclassified type(s): mysteryfs')
[ "$unknown_disk_output" = "$expected_unknown_disk" ] ||
    fail 'unclassified filesystem was silently omitted'

cat >"$test_directory/mounts" <<'MOUNTS'
/dev/mystery /mystery mysteryfs rw 0 0
MOUNTS
all_unknown_output=
if all_unknown_output=$(PATH="$test_directory/df-bin:$PATH" \
    HEALTH_DF_CAPTURE="$test_directory/df-arguments.txt" \
    HEALTH_TEST_MOUNTS_PATH="$test_directory/mounts" run_health_check \
    --plain --disk --disk-warning 95); then
    fail 'all-unknown filesystem fixture unexpectedly passed'
else
    all_unknown_status=$?
fi
[ "$all_unknown_status" -eq 1 ] ||
    fail 'all-unknown filesystem fixture did not return unsupported status'
expected_all_unknown=$(printf 'disk\tunsupported\tfilesystem scan incomplete: unclassified type(s): mysteryfs')
[ "$all_unknown_output" = "$expected_all_unknown" ] ||
    fail 'all-unknown filesystem result is not exact'

cat >"$test_directory/mounts" <<'MOUNTS'
/dev/root / ext4 rw 0 0
/dev/data /unreadable xfs rw 0 0
MOUNTS
unreadable_disk_output=
if unreadable_disk_output=$(PATH="$test_directory/df-bin:$PATH" \
    HEALTH_DF_CAPTURE="$test_directory/df-arguments.txt" \
    HEALTH_TEST_MOUNTS_PATH="$test_directory/mounts" run_health_check \
    --plain --disk --disk-warning 95); then
    fail 'partially unreadable local filesystem fixture unexpectedly passed'
else
    unreadable_disk_status=$?
fi
[ "$unreadable_disk_status" -eq 1 ] ||
    fail 'unreadable local filesystem did not return unsupported status'
expected_unreadable_disk=$(printf 'disk\tunsupported\tknown local filesystems are below 95%%, but scan is incomplete: unreadable local path(s): /unreadable')
[ "$unreadable_disk_output" = "$expected_unreadable_disk" ] ||
    fail 'failed local df query was silently omitted'

cat >"$test_directory/mounts" <<'MOUNTS'
/dev/root / ext4 rw 0 0
/dev/partial /partial xfs rw 0 0
MOUNTS
partial_mount_output=
if partial_mount_output=$(PATH="$test_directory/df-bin:$PATH" \
    HEALTH_DF_CAPTURE="$test_directory/df-arguments.txt" \
    HEALTH_TEST_MOUNTS_PATH="$test_directory/mounts" run_health_check \
    --plain --disk --disk-warning 95); then
    fail 'partial nonzero per-mount df output unexpectedly passed'
else
    partial_mount_status=$?
fi
[ "$partial_mount_status" -eq 1 ] ||
    fail 'partial per-mount df output did not return unsupported status'
expected_partial_mount=$(printf 'disk\tunsupported\tknown local filesystems are below 95%%, but scan is incomplete: unreadable local path(s): /partial')
[ "$partial_mount_output" = "$expected_partial_mount" ] ||
    fail 'partial per-mount df output was treated as complete'

mkdir "$test_directory/package-bin"
cat >"$test_directory/package-bin/package-mock" <<'PACKAGE_MOCK'
#!/bin/sh
manager=${0##*/}
printf '%s\t%s\t%s\n' "$manager" "${HOMEBREW_NO_AUTO_UPDATE:-}" "$*" \
    >>"$HEALTH_PACKAGE_CAPTURE"
if [ "${HEALTH_PACKAGE_FAILURE:-0}" -eq 1 ]; then
    exit 7
fi
if [ "${HEALTH_PACKAGE_EMPTY:-0}" -eq 1 ]; then
    exit 0
fi
case "$manager" in
    apt-get) printf '%s\n' 'Inst sample [1] (2 repository)' ;;
    dnf|yum) printf '%s\n' 'sample.x86_64 2 repository'; exit 100 ;;
    zypper) printf '%s\n' 'v | repository | sample | 1 | 2 | x86_64' ;;
    apk) printf '%s\n' 'sample-1 < 2' ;;
    pacman) printf '%s\n' 'sample 1 -> 2' ;;
    brew) printf '%s\n' 'sample' ;;
esac
PACKAGE_MOCK
chmod +x "$test_directory/package-bin/package-mock"
for package_manager in apt-get dnf yum zypper apk pacman brew; do
    ln -s package-mock "$test_directory/package-bin/$package_manager"
    package_output=
    if package_output=$(PATH="$test_directory/package-bin:$PATH" \
        HEALTH_TEST_PACKAGE_MANAGER="$package_manager" \
        HEALTH_PACKAGE_CAPTURE="$test_directory/package-arguments.txt" \
        run_health_check --plain --updates); then
        fail "$package_manager update fixture unexpectedly returned success"
    else
        package_status=$?
    fi
    [ "$package_status" -eq 1 ] ||
        fail "$package_manager update fixture did not return warning status"
    expected_package=$(printf 'updates\twarn\t1 cached package update(s) are available via %s' \
        "$package_manager")
    [ "$package_output" = "$expected_package" ] ||
        fail "$package_manager update output is not exact"
done
grep -q '^apt-get.*-s.*Debug::NoLocking=1.*upgrade' \
    "$test_directory/package-arguments.txt" || fail 'apt-get was not simulation-only'
grep -q '^dnf.*--cacheonly' "$test_directory/package-arguments.txt" ||
    fail 'dnf was not cache-only'
grep -q '^yum.*-C' "$test_directory/package-arguments.txt" ||
    fail 'yum was not cache-only'
grep -q '^zypper.*--no-refresh' "$test_directory/package-arguments.txt" ||
    fail 'zypper was allowed to refresh metadata'
grep -q '^brew[[:space:]]*1[[:space:]]' "$test_directory/package-arguments.txt" ||
    fail 'Homebrew auto-update was not disabled'

package_failure_output=
if package_failure_output=$(PATH="$test_directory/package-bin:$PATH" \
    HEALTH_TEST_PACKAGE_MANAGER=pacman HEALTH_PACKAGE_FAILURE=1 \
    HEALTH_PACKAGE_CAPTURE="$test_directory/package-arguments.txt" \
    run_health_check --plain --updates); then
    fail 'failed pacman query unexpectedly succeeded'
else
    package_failure_status=$?
fi
[ "$package_failure_status" -eq 2 ] ||
    fail 'failed pacman query did not return error status'
expected_package_failure=$(printf 'updates\terror\tpacman could not query cached update metadata')
[ "$package_failure_output" = "$expected_package_failure" ] ||
    fail 'failed pacman query was not reported as an error'

package_empty_output=$(PATH="$test_directory/package-bin:$PATH" \
    HEALTH_TEST_PACKAGE_MANAGER=pacman HEALTH_PACKAGE_EMPTY=1 \
    HEALTH_PACKAGE_CAPTURE="$test_directory/package-arguments.txt" \
    run_health_check --plain --updates) ||
    fail 'empty successful pacman query did not pass'
expected_package_empty=$(printf 'updates\tpass\tno cached package updates are available via pacman')
[ "$package_empty_output" = "$expected_package_empty" ] ||
    fail 'zero-update pacman output is not exact'

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
