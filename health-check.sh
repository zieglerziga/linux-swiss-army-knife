#!/bin/sh

# Selectable, read-only health checks for Linux, BusyBox, macOS, and other
# POSIX-like systems. Potentially observable operations (sudo policy checks,
# package-manager queries, and SSH) run only when explicitly selected.

set -u

PROGRAM_NAME=health-check.sh
PROGRAM_VERSION=0.1.0
CHECK_SUDO=0
CHECK_DISK=0
CHECK_PROCESSES=0
CHECK_UPDATES=0
OUTPUT_MODE=human
DISK_WARNING=85
REMOTE_HOST=
SSH_IDENTITY=
SSH_TIMEOUT=10
OVERALL_STATUS=0
SELECTED_CHECKS=0
HEALTH_FIXTURE_ROOT=${HEALTH_FIXTURE_ROOT:-}
HEALTH_TEST_MOUNTS_PATH=${HEALTH_TEST_MOUNTS_PATH:-}
HEALTH_TEST_PACKAGE_MANAGER=${HEALTH_TEST_PACKAGE_MANAGER:-}
HEALTH_TEST_PROC_ROOT=${HEALTH_TEST_PROC_ROOT:-}
HEALTH_TEST_PROC_MOUNTS_PATH=${HEALTH_TEST_PROC_MOUNTS_PATH:-}

usage()
{
    cat <<'EOF'
Usage: health-check.sh CHECK [CHECK ...] [OPTIONS]

Run explicitly selected system health checks.

Checks:
  --sudo              Detect root or non-interactive sudo access
  --disk              Report local filesystem paths over a usage threshold
  --processes         Detect processes in uninterruptible or zombie states
  --updates           Check cached package metadata for available updates
  --all               Run all four checks

Options:
  --plain             Stable tab-separated output: check, status, detail
  --disk-warning N    Warn when disk use is N percent or higher (default: 85)
  --remote HOST       Stream this script to a POSIX host over batch-mode SSH
  --identity PATH     SSH private key for --remote
  --connect-timeout N SSH connection timeout in seconds (default: 10)
  -h, --help          Show this help
  --version           Show the command version

Package metadata is never refreshed. Remote mode requires a verified host key
already present in local known_hosts; unknown keys and passwords are rejected.
EOF
}

fail_usage()
{
    printf '%s: %s\n' "$PROGRAM_NAME" "$1" >&2
    printf 'Try %s --help for usage.\n' "$PROGRAM_NAME" >&2
    exit 2
}

require_unsigned_integer()
{
    integer_name=$1
    integer_value=$2
    case "$integer_value" in
        ''|*[!0-9]*) fail_usage "$integer_name must be an unsigned integer" ;;
    esac
}

select_check()
{
    case "$1" in
        sudo) CHECK_SUDO=1 ;;
        disk) CHECK_DISK=1 ;;
        processes) CHECK_PROCESSES=1 ;;
        updates) CHECK_UPDATES=1 ;;
    esac
}

parse_arguments()
{
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --sudo)
                select_check sudo
                ;;
            --disk)
                select_check disk
                ;;
            --processes)
                select_check processes
                ;;
            --updates)
                select_check updates
                ;;
            --all)
                select_check sudo
                select_check disk
                select_check processes
                select_check updates
                ;;
            --plain)
                OUTPUT_MODE=plain
                ;;
            --disk-warning)
                shift
                [ "$#" -gt 0 ] || fail_usage '--disk-warning requires a value'
                DISK_WARNING=$1
                ;;
            --remote)
                shift
                [ "$#" -gt 0 ] || fail_usage '--remote requires a host'
                REMOTE_HOST=$1
                ;;
            --identity)
                shift
                [ "$#" -gt 0 ] || fail_usage '--identity requires a path'
                SSH_IDENTITY=$1
                ;;
            --connect-timeout)
                shift
                [ "$#" -gt 0 ] || fail_usage '--connect-timeout requires a value'
                SSH_TIMEOUT=$1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --version)
                printf '%s %s\n' "$PROGRAM_NAME" "$PROGRAM_VERSION"
                exit 0
                ;;
            --)
                shift
                [ "$#" -eq 0 ] || fail_usage "unexpected argument: $1"
                break
                ;;
            *)
                fail_usage "unknown option: $1"
                ;;
        esac
        shift
    done

    require_unsigned_integer '--disk-warning' "$DISK_WARNING"
    [ "$DISK_WARNING" -ge 1 ] && [ "$DISK_WARNING" -le 100 ] ||
        fail_usage '--disk-warning must be between 1 and 100'

    require_unsigned_integer '--connect-timeout' "$SSH_TIMEOUT"
    [ "$SSH_TIMEOUT" -ge 1 ] && [ "$SSH_TIMEOUT" -le 600 ] ||
        fail_usage '--connect-timeout must be between 1 and 600'

    SELECTED_CHECKS=$((CHECK_SUDO + CHECK_DISK + CHECK_PROCESSES + CHECK_UPDATES))
    [ "$SELECTED_CHECKS" -gt 0 ] || fail_usage 'select at least one check or --all'

    if [ -n "$SSH_IDENTITY" ] && [ -z "$REMOTE_HOST" ]; then
        fail_usage '--identity requires --remote'
    fi
}

status_label()
{
    case "$1" in
        pass) printf 'PASS' ;;
        warn) printf 'WARN' ;;
        fail) printf 'FAIL' ;;
        unsupported) printf 'UNSUPPORTED' ;;
        error|*) printf 'ERROR' ;;
    esac
}

emit_result()
{
    result_check=$1
    result_status=$2
    result_detail=$(printf '%s' "$3" | tr '\t\r\n' '   ')

    case "$result_status" in
        pass) ;;
        warn|unsupported)
            [ "$OVERALL_STATUS" -ge 1 ] || OVERALL_STATUS=1
            ;;
        fail|error)
            OVERALL_STATUS=2
            ;;
        *)
            invalid_status=$result_status
            result_status=error
            result_detail="invalid internal result status: $invalid_status"
            OVERALL_STATUS=2
            ;;
    esac

    if [ "$OUTPUT_MODE" = plain ]; then
        printf '%s\t%s\t%s\n' "$result_check" "$result_status" "$result_detail"
    else
        printf '[%s] %-10s %s\n' \
            "$(status_label "$result_status")" "$result_check" "$result_detail"
    fi
}

emit_fixture_result()
{
    fixture_check=$1
    fixture_path=$2
    if [ ! -r "$fixture_path" ]; then
        emit_result "$fixture_check" error "fixture is missing: $fixture_path"
        return
    fi

    fixture_line=$(sed -n '1p' "$fixture_path")
    fixture_status=$(printf '%s\n' "$fixture_line" | awk -F '\t' '{ print $1 }')
    fixture_detail=$(printf '%s\n' "$fixture_line" |
        awk '{ separator=index($0, "\t"); print substr($0, separator + 1) }')
    emit_result "$fixture_check" "$fixture_status" "$fixture_detail"
}

run_remote()
{
    case "$REMOTE_HOST" in
        ''|-*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._@-]*)
            fail_usage '--remote must be a DNS name, IPv4 address, or user@host'
            ;;
    esac
    command -v ssh >/dev/null 2>&1 || fail_usage 'ssh is required for --remote'
    [ -r "$0" ] || fail_usage 'cannot read this script for remote execution'
    if [ -n "$SSH_IDENTITY" ] && [ ! -r "$SSH_IDENTITY" ]; then
        fail_usage "SSH identity is not readable: $SSH_IDENTITY"
    fi

    set -- -T -o BatchMode=yes -o StrictHostKeyChecking=yes \
        -o ClearAllForwardings=yes \
        -o "ConnectTimeout=$SSH_TIMEOUT"
    if [ -n "$SSH_IDENTITY" ]; then
        set -- "$@" -o IdentitiesOnly=yes -i "$SSH_IDENTITY"
    fi
    set -- "$@" "$REMOTE_HOST" sh -s --
    [ "$CHECK_SUDO" -eq 0 ] || set -- "$@" --sudo
    [ "$CHECK_DISK" -eq 0 ] || set -- "$@" --disk
    [ "$CHECK_PROCESSES" -eq 0 ] || set -- "$@" --processes
    [ "$CHECK_UPDATES" -eq 0 ] || set -- "$@" --updates
    set -- "$@" --disk-warning "$DISK_WARNING"
    [ "$OUTPUT_MODE" = plain ] && set -- "$@" --plain

    ssh "$@" <"$0"
    remote_status=$?
    case "$remote_status" in
        0|1) return "$remote_status" ;;
        *) return 2 ;;
    esac
}

check_sudo()
{
    if [ -n "$HEALTH_FIXTURE_ROOT" ]; then
        emit_fixture_result sudo "$HEALTH_FIXTURE_ROOT/sudo-result.tsv"
        return
    fi

    if command -v id >/dev/null 2>&1 && [ "$(id -u 2>/dev/null)" = 0 ]; then
        emit_result sudo pass 'current process is already running as root'
    elif ! command -v sudo >/dev/null 2>&1; then
        emit_result sudo warn 'sudo is not installed and the current process is not root'
    elif sudo -n -v >/dev/null 2>&1; then
        emit_result sudo pass 'non-interactive sudo policy validation succeeded'
    else
        emit_result sudo warn 'sudo is installed but non-interactive elevation is unavailable'
    fi
}

find_mount_table()
{
    if [ -n "$HEALTH_TEST_MOUNTS_PATH" ]; then
        [ -r "$HEALTH_TEST_MOUNTS_PATH" ] || return 1
        printf '%s\n' "$HEALTH_TEST_MOUNTS_PATH"
    elif [ -r /proc/self/mounts ]; then
        printf '%s\n' /proc/self/mounts
    elif [ -r /proc/mounts ]; then
        printf '%s\n' /proc/mounts
    else
        return 1
    fi
}

classify_mounts()
{
    awk '
        BEGIN {
            local_types="rootfs ext2 ext3 ext4 xfs btrfs bcachefs f2fs"
            local_types=local_types " vfat exfat ntfs ntfs3 fuseblk zfs"
            local_types=local_types " tmpfs devtmpfs overlay squashfs erofs ramfs"
            local_types=local_types " ubifs jffs2 jfs nilfs2 reiserfs reiser4"

            remote_types="nfs nfs4 cifs smbfs smb3 9p afs ceph ceph-fuse"
            remote_types=remote_types " fuse.ceph glusterfs fuse.glusterfs lustre"
            remote_types=remote_types " sshfs fuse.sshfs davfs davfs2 gfs2 ocfs2"
            remote_types=remote_types " gpfs orangefs pvfs2"

            pseudo_types="proc sysfs cgroup cgroup2 devpts mqueue pstore"
            pseudo_types=pseudo_types " debugfs tracefs securityfs efivarfs"
            pseudo_types=pseudo_types " configfs fusectl fuse.portal"
            pseudo_types=pseudo_types " fuse.gvfsd-fuse autofs binfmt_misc"
            pseudo_types=pseudo_types " hugetlbfs rpc_pipefs nsfs bpf"
        }
        function list_contains(list, item) {
            return index(" " list " ", " " item " ") > 0
        }
        $4 !~ /(^|,)rw(,|$)/ { next }
        list_contains(local_types, $3) {
            print "local\t" $2
            next
        }
        !list_contains(remote_types, $3) &&
            !list_contains(pseudo_types, $3) && !seen_unknown[$3]++ {
            print "unknown\t" $3
        }
    ' "$1"
}

decode_mount_path()
{
    printf '%s' "$1" | sed 's/\\040/ /g; s/\\011/\	/g; s/\\134/\\/g'
}

read_mount_capacity()
{
    capacity_path=$1
    capacity_output=$(LC_ALL=C df -Pk "$capacity_path" 2>/dev/null)
    capacity_status=$?
    capacity_row_found=$(printf '%s\n' "$capacity_output" | awk '
        {
            value=$5
            sub(/%$/, "", value)
            if (value ~ /^[0-9]+$/) found=1
        }
        END { print found + 0 }
    ')

    [ -z "$capacity_output" ] || printf '%s\n' "$capacity_output"
    if [ "$capacity_status" -ne 0 ] || [ "$capacity_row_found" -ne 1 ]; then
        printf 'HEALTH_UNREADABLE_FILESYSTEM\t%s\n' "$capacity_path"
    fi
}

collect_mount_table_filesystems()
{
    # HEALTH_* rows explain why a scan is incomplete.
    mount_rows=$(classify_mounts "$1")
    if [ -z "$mount_rows" ]; then
        printf '%s\n' 'HEALTH_NO_WRITABLE_FILESYSTEMS'
        return
    fi

    printf '%s\n' "$mount_rows" |
        while IFS="$(printf '\t')" read -r mount_kind mount_value; do
            if [ "$mount_kind" = unknown ]; then
                printf 'HEALTH_UNKNOWN_FILESYSTEM\t%s\n' "$mount_value"
            else
                mount_path=$(decode_mount_path "$mount_value")
                read_mount_capacity "$mount_path"
            fi
        done
}

collect_global_filesystems()
{
    global_output=$(LC_ALL=C df -Pkl 2>/dev/null)
    global_status=$?
    [ -n "$global_output" ] || return 1

    printf '%s\n' "$global_output"
    if [ "$global_status" -ne 0 ]; then
        printf 'HEALTH_INCOMPLETE_FILESYSTEM_SCAN\t%s\n' \
            'df -Pkl returned nonzero'
    fi
}

collect_filesystem_rows()
{
    if [ -n "$HEALTH_FIXTURE_ROOT" ]; then
        fixture_df=$HEALTH_FIXTURE_ROOT/df.txt
        [ -r "$fixture_df" ] || return 1
        cat "$fixture_df"
        return
    fi

    command -v df >/dev/null 2>&1 || return 1
    if mount_table=$(find_mount_table); then
        # Reading the mount table keeps bind paths that GNU df normally hides.
        collect_mount_table_filesystems "$mount_table"
    else
        collect_global_filesystems
    fi
}

disk_capacity_rows()
{
    awk '
        function is_pseudo_source(source) {
            return source ~ /^(devfs|procfs|linprocfs|linsysfs|fdesc|fdescfs|map|-hosts)$/
        }
        $1 ~ /^HEALTH_/ { next }
        is_pseudo_source($1) { next }
        {
            capacity=$5
            sub(/%$/, "", capacity)
            if (capacity !~ /^[0-9]+$/) next

            mount_point=$6
            for (field=7; field<=NF; field++) {
                mount_point=mount_point " " $field
            }
            if (!seen_mount[mount_point]++) {
                print capacity + 0 "\t" mount_point
            }
        }
    '
}

collect_marker_details()
{
    marker_name=$1
    marker_separator=$2
    awk -v marker="$marker_name" -v separator="$marker_separator" '
        $1 == marker {
            detail=$2
            for (field=3; field<=NF; field++) {
                detail=detail " " $field
            }
            if (!seen[detail]++) {
                if (result != "") result=result separator
                result=result detail
            }
        }
        END { print result }
    '
}

count_nonempty_lines()
{
    awk 'NF { count++ } END { print count + 0 }'
}

check_disk()
{
    disk_output=$(collect_filesystem_rows) || {
        emit_result disk error 'local filesystem usage could not be read'
        return
    }
    if [ "$disk_output" = 'HEALTH_NO_WRITABLE_FILESYSTEMS' ]; then
        emit_result disk unsupported 'no writable local filesystem paths were found'
        return
    fi

    capacity_rows=$(printf '%s\n' "$disk_output" | disk_capacity_rows)
    disk_valid=$(printf '%s\n' "$capacity_rows" | count_nonempty_lines)
    disk_highest=$(printf '%s\n' "$capacity_rows" |
        awk '$1 > highest { highest=$1 } END { print highest + 0 }')
    disk_warning_count=$(printf '%s\n' "$capacity_rows" |
        awk -v threshold="$DISK_WARNING" \
            '$1 >= threshold { count++ } END { print count + 0 }')
    disk_items=$(printf '%s\n' "$capacity_rows" |
        awk -v threshold="$DISK_WARNING" '
            BEGIN { FS="\t" }
            $1 >= threshold {
                if (items != "") items=items ", "
                items=items $2 "=" $1 "%"
            }
            END { print items }
        ')
    disk_unknown_types=$(printf '%s\n' "$disk_output" |
        collect_marker_details HEALTH_UNKNOWN_FILESYSTEM ',')
    disk_unreadable_mounts=$(printf '%s\n' "$disk_output" |
        collect_marker_details HEALTH_UNREADABLE_FILESYSTEM ',')
    disk_query_failures=$(printf '%s\n' "$disk_output" |
        collect_marker_details HEALTH_INCOMPLETE_FILESYSTEM_SCAN ',')

    disk_incomplete=
    if [ -n "$disk_unknown_types" ]; then
        disk_incomplete="unclassified type(s): $disk_unknown_types"
    fi
    if [ -n "$disk_unreadable_mounts" ]; then
        [ -z "$disk_incomplete" ] || disk_incomplete="$disk_incomplete; "
        disk_incomplete="${disk_incomplete}unreadable local path(s): $disk_unreadable_mounts"
    fi
    if [ -n "$disk_query_failures" ]; then
        [ -z "$disk_incomplete" ] || disk_incomplete="$disk_incomplete; "
        disk_incomplete="${disk_incomplete}query failure(s): $disk_query_failures"
    fi

    if [ "$disk_valid" -eq 0 ] && [ -n "$disk_incomplete" ]; then
        emit_result disk unsupported "filesystem scan incomplete: $disk_incomplete"
    elif [ "$disk_valid" -eq 0 ]; then
        emit_result disk error 'filesystem output contained no usable capacity rows'
    elif [ "$disk_warning_count" -gt 0 ]; then
        disk_detail="$disk_warning_count local filesystem path(s) at or above "
        disk_detail="${disk_detail}$DISK_WARNING%: $disk_items"
        if [ -n "$disk_incomplete" ]; then
            disk_detail="$disk_detail; scan incomplete: $disk_incomplete"
        fi
        emit_result disk warn "$disk_detail"
    elif [ -n "$disk_incomplete" ]; then
        disk_detail="known local filesystems are below $DISK_WARNING%, "
        disk_detail="${disk_detail}but scan is incomplete: $disk_incomplete"
        emit_result disk unsupported "$disk_detail"
    else
        emit_result disk pass \
            "highest local filesystem use is $disk_highest%; warning threshold is $DISK_WARNING%"
    fi
}

procfs_hides_processes()
{
    awk '
        $2 == "/proc" && $3 == "proc" {
            option_count=split($4, options, ",")
            for (option_index=1; option_index<=option_count; option_index++) {
                if (options[option_index] ~ /^hidepid=/ &&
                    options[option_index] != "hidepid=0") {
                    hidden=1
                }
            }
        }
        END { exit hidden ? 0 : 1 }
    ' "$1"
}

read_procfs_processes()
{
    process_root=$1
    process_mounts_path=$HEALTH_TEST_PROC_MOUNTS_PATH
    if [ -z "$process_mounts_path" ] && [ "$process_root" = /proc ] &&
        [ -r /proc/mounts ]; then
        process_mounts_path=/proc/mounts
    fi
    if [ -n "$process_mounts_path" ] && [ -r "$process_mounts_path" ] &&
        procfs_hides_processes "$process_mounts_path"; then
        printf 'HEALTH_INCOMPLETE_PROCESS_SCAN\t%s\n' 'procfs uses hidepid'
    fi

    process_seen=0
    process_unreadable=0
    for process_directory in "$process_root"/[0-9]*; do
        [ -d "$process_directory" ] || continue
        process_stat=$process_directory/stat
        if [ ! -r "$process_stat" ]; then
            if [ -d "$process_directory" ]; then
                process_unreadable=$((process_unreadable + 1))
            fi
            continue
        fi

        process_line=$(sed -n '1p' "$process_stat" 2>/dev/null)
        process_status=$?
        if [ "$process_status" -ne 0 ] || [ -z "$process_line" ]; then
            [ -d "$process_directory" ] &&
                process_unreadable=$((process_unreadable + 1))
            continue
        fi

        process_id=${process_directory##*/}
        process_tail=${process_line##*) }
        process_state=${process_tail%% *}
        case "$process_state" in
            [ABCDEFGHIJKLMNOPQRSTUVWXYZ]) ;;
            *)
                process_unreadable=$((process_unreadable + 1))
                continue
                ;;
        esac

        process_name=
        if [ -r "$process_directory/comm" ]; then
            process_name=$(sed -n '1p' "$process_directory/comm" 2>/dev/null)
        fi
        printf '%s\t%s\t%s\n' "$process_id" "$process_state" "$process_name"
        process_seen=$((process_seen + 1))
    done

    if [ "$process_unreadable" -eq 1 ]; then
        printf 'HEALTH_INCOMPLETE_PROCESS_SCAN\t1 unreadable process entry\n'
    elif [ "$process_unreadable" -gt 1 ]; then
        printf 'HEALTH_INCOMPLETE_PROCESS_SCAN\t%d unreadable process entries\n' \
            "$process_unreadable"
    fi
    if [ "$process_seen" -eq 0 ]; then
        printf 'HEALTH_INCOMPLETE_PROCESS_SCAN\t%s\n' \
            'no readable process entries'
    fi
}

read_ps_processes()
{
    command -v ps >/dev/null 2>&1 || return 1

    process_output=$(ps -eo pid=,stat=,etime=,comm= 2>/dev/null)
    process_status=$?
    if [ "$process_status" -ne 0 ] || [ -z "$process_output" ]; then
        process_output=$(ps -axo pid=,stat=,etime=,comm= 2>/dev/null)
        process_status=$?
    fi
    if [ "$process_status" -ne 0 ] || [ -z "$process_output" ]; then
        process_output=$(ps -o pid= -o stat= -o etime= -o comm= 2>/dev/null)
        process_status=$?
        process_ps_incomplete=1
    else
        process_ps_incomplete=0
    fi
    [ "$process_status" -eq 0 ] && [ -n "$process_output" ] || return 1

    process_formatted=$(printf '%s\n' "$process_output" | awk '
        $1 ~ /^[0-9]+$/ && $2 ~ /^[[:alpha:]]/ {
            print $1 "\t" $2 "\t" $4
            found=1
        }
        END { if (!found) exit 1 }
    ') || return 1
    [ -n "$process_formatted" ] || return 1

    printf '%s\n' "$process_formatted"
    if [ "$process_ps_incomplete" -eq 1 ]; then
        printf 'HEALTH_INCOMPLETE_PROCESS_SCAN\t%s\n' \
            'ps could not request all processes'
    fi
}

collect_process_rows()
{
    if [ -n "$HEALTH_FIXTURE_ROOT" ]; then
        fixture_processes=$HEALTH_FIXTURE_ROOT/processes.tsv
        [ -r "$fixture_processes" ] || return 1
        cat "$fixture_processes"
        return
    fi

    process_root=$HEALTH_TEST_PROC_ROOT
    [ -n "$process_root" ] || process_root=/proc
    if [ -d "$process_root" ]; then
        read_procfs_processes "$process_root"
    else
        read_ps_processes
    fi
}

stuck_process_rows()
{
    awk '
        $1 == "HEALTH_INCOMPLETE_PROCESS_SCAN" { next }
        $2 ~ /^[DZ]/ {
            name=$3
            if (name == "") name="unknown"
            gsub(/[|\t\r\n]/, " ", name)
            print $1 "\t" $2 "\t" name
        }
    '
}

check_processes()
{
    processes_output=$(collect_process_rows) || {
        emit_result processes unsupported 'process states are unavailable on this platform'
        return
    }

    stuck_rows=$(printf '%s\n' "$processes_output" | stuck_process_rows)
    process_count=$(printf '%s\n' "$stuck_rows" | count_nonempty_lines)
    process_items=$(printf '%s\n' "$stuck_rows" |
        awk '
            BEGIN { FS="\t" }
            NR <= 10 {
                if (items != "") items=items ", "
                items=items $1 ":" $2 ":" $3
            }
            END { print items }
        ')
    process_incomplete=$(printf '%s\n' "$processes_output" |
        collect_marker_details HEALTH_INCOMPLETE_PROCESS_SCAN '; ')

    if [ "$process_count" -gt 0 ]; then
        process_suffix=
        [ "$process_count" -le 10 ] || process_suffix=' (first 10 shown)'
        process_detail="$process_count process(es) in D or Z state: $process_items$process_suffix"
        if [ -n "$process_incomplete" ]; then
            process_detail="$process_detail; scan incomplete: $process_incomplete"
        fi
        emit_result processes warn "$process_detail"
    elif [ -n "$process_incomplete" ]; then
        emit_result processes unsupported "process scan incomplete: $process_incomplete"
    else
        emit_result processes pass 'no processes are in uninterruptible or zombie states'
    fi
}

emit_update_count()
{
    update_manager=$1
    update_count=$2
    if [ "$update_count" -gt 0 ]; then
        emit_result updates warn \
            "$update_count cached package update(s) are available via $update_manager"
    else
        emit_result updates pass \
            "no cached package updates are available via $update_manager"
    fi
}

find_package_manager()
{
    for manager_candidate in apt-get dnf yum zypper apk pacman brew; do
        if command -v "$manager_candidate" >/dev/null 2>&1; then
            printf '%s\n' "$manager_candidate"
            return
        fi
    done
    return 1
}

check_apt_updates()
{
    update_output=$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null)
    update_status=$?
    if [ "$update_status" -ne 0 ]; then
        emit_result updates error 'apt-get could not query cached upgrade metadata'
        return
    fi
    update_count=$(printf '%s\n' "$update_output" |
        awk '/^Inst / { count++ } END { print count + 0 }')
    emit_update_count apt-get "$update_count"
}

check_dnf_updates()
{
    update_output=$(LC_ALL=C dnf -q --cacheonly check-update 2>/dev/null)
    update_status=$?
    if [ "$update_status" -ne 0 ] && [ "$update_status" -ne 100 ]; then
        emit_result updates error 'dnf could not query cached update metadata'
        return
    fi
    update_count=$(printf '%s\n' "$update_output" | awk '
        $1 ~ /^[[:alnum:]_.+-]+\.[[:alnum:]_]+$/ { count++ }
        END { print count + 0 }
    ')
    emit_update_count dnf "$update_count"
}

check_yum_updates()
{
    update_output=$(LC_ALL=C yum -q -C check-update 2>/dev/null)
    update_status=$?
    if [ "$update_status" -ne 0 ] && [ "$update_status" -ne 100 ]; then
        emit_result updates error 'yum could not query cached update metadata'
        return
    fi
    update_count=$(printf '%s\n' "$update_output" | awk '
        $1 ~ /^[[:alnum:]_.+-]+\.[[:alnum:]_]+$/ { count++ }
        END { print count + 0 }
    ')
    emit_update_count yum "$update_count"
}

check_zypper_updates()
{
    update_output=$(LC_ALL=C zypper --non-interactive --no-refresh list-updates 2>/dev/null) || {
        emit_result updates error 'zypper could not query cached update metadata'
        return
    }
    update_count=$(printf '%s\n' "$update_output" | awk -F '|' '
        $1 ~ /^[[:space:]]*v[[:space:]]*$/ { count++ }
        END { print count + 0 }
    ')
    emit_update_count zypper "$update_count"
}

check_apk_updates()
{
    update_output=$(LC_ALL=C apk version -l '<' 2>/dev/null) || {
        emit_result updates error 'apk could not query cached update metadata'
        return
    }
    update_count=$(printf '%s\n' "$update_output" | count_nonempty_lines)
    emit_update_count apk "$update_count"
}

check_pacman_updates()
{
    update_output=$(LC_ALL=C pacman -Qu 2>/dev/null)
    update_status=$?
    if [ "$update_status" -ne 0 ]; then
        emit_result updates error 'pacman could not query cached update metadata'
        return
    fi
    update_count=$(printf '%s\n' "$update_output" | count_nonempty_lines)
    emit_update_count pacman "$update_count"
}

check_brew_updates()
{
    update_output=$(HOMEBREW_NO_AUTO_UPDATE=1 LC_ALL=C brew outdated 2>/dev/null) || {
        emit_result updates error 'Homebrew could not query installed formula metadata'
        return
    }
    update_count=$(printf '%s\n' "$update_output" | count_nonempty_lines)
    emit_update_count brew "$update_count"
}

check_updates()
{
    if [ -n "$HEALTH_FIXTURE_ROOT" ]; then
        emit_fixture_result updates "$HEALTH_FIXTURE_ROOT/updates-result.tsv"
        return
    fi

    update_manager=$HEALTH_TEST_PACKAGE_MANAGER
    if [ -z "$update_manager" ]; then
        update_manager=$(find_package_manager) || update_manager=
    fi

    if [ -z "$update_manager" ]; then
        emit_result updates unsupported 'no supported package manager was found'
        return
    fi
    command -v "$update_manager" >/dev/null 2>&1 || {
        emit_result updates error "$update_manager is unavailable"
        return
    }

    case "$update_manager" in
        apt-get) check_apt_updates ;;
        dnf) check_dnf_updates ;;
        yum) check_yum_updates ;;
        zypper) check_zypper_updates ;;
        apk) check_apk_updates ;;
        pacman) check_pacman_updates ;;
        brew) check_brew_updates ;;
        *) emit_result updates error \
            "unsupported package-manager override: $update_manager" ;;
    esac
}

main()
{
    parse_arguments "$@"

    if [ -n "$REMOTE_HOST" ]; then
        run_remote
        exit $?
    fi

    if [ "$OUTPUT_MODE" = human ]; then
        printf 'Linux Swiss Army Knife health checks %s\n' "$PROGRAM_VERSION"
    fi

    [ "$CHECK_SUDO" -eq 0 ] || check_sudo
    [ "$CHECK_DISK" -eq 0 ] || check_disk
    [ "$CHECK_PROCESSES" -eq 0 ] || check_processes
    [ "$CHECK_UPDATES" -eq 0 ] || check_updates

    exit "$OVERALL_STATUS"
}

main "$@"
