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

usage()
{
    cat <<'EOF'
Usage: health-check.sh CHECK [CHECK ...] [OPTIONS]

Run explicitly selected system health checks.

Checks:
  --sudo              Detect root or non-interactive sudo access
  --disk              Report local filesystems at or above a usage threshold
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

Package metadata is never refreshed. SSH uses the local strict host-key policy;
the command never disables host-key verification or prompts for a password.
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

    set -- -o BatchMode=yes -o StrictHostKeyChecking=yes \
        -o "ConnectTimeout=$SSH_TIMEOUT"
    if [ -n "$SSH_IDENTITY" ]; then
        set -- "$@" -i "$SSH_IDENTITY"
    fi
    set -- "$@" "$REMOTE_HOST" sh -s --
    [ "$CHECK_SUDO" -eq 0 ] || set -- "$@" --sudo
    [ "$CHECK_DISK" -eq 0 ] || set -- "$@" --disk
    [ "$CHECK_PROCESSES" -eq 0 ] || set -- "$@" --processes
    [ "$CHECK_UPDATES" -eq 0 ] || set -- "$@" --updates
    set -- "$@" --disk-warning "$DISK_WARNING"
    [ "$OUTPUT_MODE" = plain ] && set -- "$@" --plain

    ssh "$@" <"$0"
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

filesystem_output()
{
    if [ -n "$HEALTH_FIXTURE_ROOT" ]; then
        fixture_df=$HEALTH_FIXTURE_ROOT/df.txt
        [ -r "$fixture_df" ] || return 1
        cat "$fixture_df"
        return
    fi

    command -v df >/dev/null 2>&1 || return 1
    filesystem_data=$(LC_ALL=C df -Pkl 2>/dev/null)
    if [ -n "$filesystem_data" ]; then
        # Some df implementations return non-zero when one pseudo-filesystem is
        # unreadable even though they emitted usable rows for local disks.
        printf '%s\n' "$filesystem_data"
        return 0
    fi

    filesystem_data=$(LC_ALL=C df -Pk 2>/dev/null)
    [ -n "$filesystem_data" ] || return 1
    printf '%s\n' "$filesystem_data"
}

check_disk()
{
    disk_output=$(filesystem_output) || {
        emit_result disk error 'local filesystem usage could not be read'
        return
    }

    disk_summary=$(printf '%s\n' "$disk_output" | awk -v threshold="$DISK_WARNING" '
        function clean(value) {
            gsub(/[\t\r\n]/, " ", value)
            return value
        }
        {
            capacity=$5
            sub(/%$/, "", capacity)
            if (capacity !~ /^[0-9]+$/) next
            valid++
            if (capacity > highest) highest=capacity
            if (capacity >= threshold) {
                mount_point=$6
                for (field=7; field<=NF; field++) {
                    mount_point=mount_point " " $field
                }
                mount_point=clean(mount_point)
                if (items != "") items=items ", "
                items=items mount_point "=" capacity "%"
                warning++
            }
        }
        END { printf "%d|%d|%d|%s", valid, highest, warning, items }
    ')
    disk_valid=${disk_summary%%|*}
    disk_remaining=${disk_summary#*|}
    disk_highest=${disk_remaining%%|*}
    disk_remaining=${disk_remaining#*|}
    disk_warning_count=${disk_remaining%%|*}
    disk_items=${disk_remaining#*|}

    if [ "$disk_valid" -eq 0 ]; then
        emit_result disk error 'filesystem output contained no usable capacity rows'
    elif [ "$disk_warning_count" -gt 0 ]; then
        emit_result disk warn \
            "$disk_warning_count filesystem(s) at or above $DISK_WARNING%: $disk_items"
    else
        emit_result disk pass \
            "highest local filesystem use is $disk_highest%; warning threshold is $DISK_WARNING%"
    fi
}

process_rows()
{
    if [ -n "$HEALTH_FIXTURE_ROOT" ]; then
        fixture_processes=$HEALTH_FIXTURE_ROOT/processes.tsv
        [ -r "$fixture_processes" ] || return 1
        cat "$fixture_processes"
        return
    fi

    if [ -d /proc ]; then
        # Keep only the small PID/state/name projection instead of retaining
        # complete process metadata in memory on large hosts.
        for process_stat in /proc/[0-9]*/stat; do
            [ -r "$process_stat" ] || continue
            process_id=${process_stat%/stat}
            process_id=${process_id##*/}
            process_line=$(sed -n '1p' "$process_stat" 2>/dev/null) || continue
            process_tail=${process_line##*) }
            process_state=${process_tail%% *}
            process_name=
            if [ -r "/proc/$process_id/comm" ]; then
                process_name=$(sed -n '1p' "/proc/$process_id/comm" 2>/dev/null)
            fi
            printf '%s\t%s\t%s\n' "$process_id" "$process_state" "$process_name"
        done
        return
    fi

    command -v ps >/dev/null 2>&1 || return 1
    if ps -eo pid=,stat=,etime=,comm= >/dev/null 2>&1; then
        ps -eo pid=,stat=,etime=,comm= 2>/dev/null |
            awk '{ print $1 "\t" $2 "\t" $4 }'
    elif ps -axo pid=,stat=,etime=,comm= >/dev/null 2>&1; then
        ps -axo pid=,stat=,etime=,comm= 2>/dev/null |
            awk '{ print $1 "\t" $2 "\t" $4 }'
    elif ps -o pid= -o stat= -o etime= -o comm= >/dev/null 2>&1; then
        ps -o pid= -o stat= -o etime= -o comm= 2>/dev/null |
            awk '{ print $1 "\t" $2 "\t" $4 }'
    else
        return 1
    fi
}

check_processes()
{
    processes_output=$(process_rows) || {
        emit_result processes unsupported 'process states are unavailable on this platform'
        return
    }

    process_summary=$(printf '%s\n' "$processes_output" | awk '
        $2 ~ /^[DZ]/ {
            count++
            if (listed < 10) {
                if (items != "") items=items ", "
                name=$3
                if (name == "") name="unknown"
                items=items $1 ":" $2 ":" name
                listed++
            }
        }
        END { printf "%d|%s", count, items }
    ')
    process_count=${process_summary%%|*}
    process_items=${process_summary#*|}

    if [ "$process_count" -gt 0 ]; then
        process_suffix=
        [ "$process_count" -le 10 ] || process_suffix=' (first 10 shown)'
        emit_result processes warn \
            "$process_count process(es) in D or Z state: $process_items$process_suffix"
    else
        emit_result processes pass 'no processes are in uninterruptible or zombie states'
    fi
}

count_nonempty_lines()
{
    awk 'NF { count++ } END { print count + 0 }'
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

check_updates()
{
    if [ -n "$HEALTH_FIXTURE_ROOT" ]; then
        emit_fixture_result updates "$HEALTH_FIXTURE_ROOT/updates-result.tsv"
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        update_output=$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null)
        update_status=$?
        if [ "$update_status" -ne 0 ]; then
            emit_result updates error 'apt-get could not query cached upgrade metadata'
            return
        fi
        update_count=$(printf '%s\n' "$update_output" | awk '/^Inst / { count++ } END { print count + 0 }')
        emit_update_count apt-get "$update_count"
        return
    fi

    if command -v dnf >/dev/null 2>&1; then
        update_output=$(LC_ALL=C dnf -q --cacheonly check-update 2>/dev/null)
        update_status=$?
        if [ "$update_status" -ne 0 ] && [ "$update_status" -ne 100 ]; then
            emit_result updates error 'dnf could not query cached update metadata'
            return
        fi
        update_count=$(printf '%s\n' "$update_output" | awk '$1 ~ /^[[:alnum:]_.+-]+\.[[:alnum:]_]+$/ { count++ } END { print count + 0 }')
        emit_update_count dnf "$update_count"
        return
    fi

    if command -v yum >/dev/null 2>&1; then
        update_output=$(LC_ALL=C yum -q -C check-update 2>/dev/null)
        update_status=$?
        if [ "$update_status" -ne 0 ] && [ "$update_status" -ne 100 ]; then
            emit_result updates error 'yum could not query cached update metadata'
            return
        fi
        update_count=$(printf '%s\n' "$update_output" | awk '$1 ~ /^[[:alnum:]_.+-]+\.[[:alnum:]_]+$/ { count++ } END { print count + 0 }')
        emit_update_count yum "$update_count"
        return
    fi

    if command -v zypper >/dev/null 2>&1; then
        update_output=$(LC_ALL=C zypper --non-interactive --no-refresh list-updates 2>/dev/null) || {
            emit_result updates error 'zypper could not query cached update metadata'
            return
        }
        update_count=$(printf '%s\n' "$update_output" | awk -F '|' '$1 ~ /^[[:space:]]*v[[:space:]]*$/ { count++ } END { print count + 0 }')
        emit_update_count zypper "$update_count"
        return
    fi

    if command -v apk >/dev/null 2>&1; then
        update_output=$(LC_ALL=C apk version -l '<' 2>/dev/null) || {
            emit_result updates error 'apk could not query cached update metadata'
            return
        }
        update_count=$(printf '%s\n' "$update_output" | count_nonempty_lines)
        emit_update_count apk "$update_count"
        return
    fi

    if command -v pacman >/dev/null 2>&1; then
        update_output=$(LC_ALL=C pacman -Qu 2>/dev/null)
        update_status=$?
        if [ "$update_status" -ne 0 ] && [ -n "$update_output" ]; then
            emit_result updates error 'pacman could not query cached update metadata'
            return
        fi
        update_count=$(printf '%s\n' "$update_output" | count_nonempty_lines)
        emit_update_count pacman "$update_count"
        return
    fi

    if command -v brew >/dev/null 2>&1; then
        update_output=$(HOMEBREW_NO_AUTO_UPDATE=1 LC_ALL=C brew outdated 2>/dev/null) || {
            emit_result updates error 'Homebrew could not query installed formula metadata'
            return
        }
        update_count=$(printf '%s\n' "$update_output" | count_nonempty_lines)
        emit_update_count brew "$update_count"
        return
    fi

    emit_result updates unsupported 'no supported package manager was found'
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
