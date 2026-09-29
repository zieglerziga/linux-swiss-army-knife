#!/bin/sh

# Linux Swiss Army Knife read-only system inspector.
# Runtime dependencies are limited to /bin/sh and ordinary operating-system
# utilities. Every command in this file is a query; the collector never
# elevates privileges, installs software, or changes host state.

set -u

COLLECTOR_NAME=linux-swiss-army-knife
COLLECTOR_VERSION=0.1.0
SCHEMA_VERSION=1
OUTPUT_MODE=human
COLLECTION_MODE=normal
DEBUG_OUTPUT=0
COLOR_OUTPUT=0
JSON_FIRST_FACT=1
PLATFORM_ADAPTER=unknown
COLLECTION_TIMESTAMP=unknown
SWISS_FIXTURE_ROOT=${SWISS_FIXTURE_ROOT:-}
SWISS_TEST_PLATFORM=${SWISS_TEST_PLATFORM:-}
SWISS_TEST_ALLOW_COMMAND=${SWISS_TEST_ALLOW_COMMAND:-}
FIXTURE_MODE=0
ICONV_AVAILABLE=0
[ -z "$SWISS_FIXTURE_ROOT" ] || FIXTURE_MODE=1
command -v iconv >/dev/null 2>&1 && ICONV_AVAILABLE=1

usage()
{
    cat <<'EOF'
Usage: swiss.sh [OPTIONS]

Collect read-only local system information without elevation or network traffic.

Options:
  --plain       Stable, uncolored tab-separated output
  --json        Versioned JSON output for automation
  --debug       Include each fact's source in human/plain output
  --full        Include additional safe, potentially slower local queries
  -h, --help    Show this help
  --version     Show the collector version
EOF
}

fail_usage()
{
    printf 'swiss.sh: %s\n' "$1" >&2
    printf 'Try swiss.sh --help for usage.\n' >&2
    exit 2
}

parse_arguments()
{
    output_option_seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --plain)
                output_option_seen=$((output_option_seen + 1))
                OUTPUT_MODE=plain
                ;;
            --json)
                output_option_seen=$((output_option_seen + 1))
                OUTPUT_MODE=json
                ;;
            --debug)
                DEBUG_OUTPUT=1
                ;;
            --full)
                COLLECTION_MODE=full
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --version)
                printf '%s %s\n' "$COLLECTOR_NAME" "$COLLECTOR_VERSION"
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

    [ "$output_option_seen" -le 1 ] ||
        fail_usage '--plain and --json are mutually exclusive'
}

has_command()
{
    if [ "$FIXTURE_MODE" -eq 1 ]; then
        [ "$SWISS_TEST_ALLOW_COMMAND" = "$1" ] || return 1
    fi
    command -v "$1" >/dev/null 2>&1
}

host_path()
{
    if [ -n "$SWISS_FIXTURE_ROOT" ]; then
        printf '%s%s' "$SWISS_FIXTURE_ROOT" "$1"
    else
        printf '%s' "$1"
    fi
}

sanitize_value()
{
    # Host metadata is untrusted. Keep facts on one line and remove JSON-invalid
    # control bytes. iconv drops malformed UTF-8; the dependency-free fallback
    # replaces all non-ASCII bytes so JSON remains valid on minimal systems.
    if [ "$ICONV_AVAILABLE" -eq 1 ]; then
        printf '%s' "$1" | LC_ALL=C tr '\001-\037\177' ' ' |
            iconv -f UTF-8 -t UTF-8 -c 2>/dev/null
    else
        printf '%s' "$1" | LC_ALL=C tr '\001-\037\177\200-\377' ' '
    fi
}

inventory_escape()
{
    sanitize_value "$1" | sed 's/%/%25/g; s/;/%3B/g; s/|/%7C/g; s/=/%3D/g'
}

json_escape()
{
    sanitize_value "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

status_color()
{
    case "$1" in
        ok) printf '\033[0;32m' ;;
        unknown|missing|unsupported) printf '\033[0;33m' ;;
        denied|error) printf '\033[0;31m' ;;
        *) printf '\033[0m' ;;
    esac
}

emit_fact()
{
    fact_key=$1
    fact_value=$(sanitize_value "$2")
    fact_status=$3
    fact_source=$(sanitize_value "$4")
    fact_confidence=$5

    case "$fact_status" in
        ok|unknown|unsupported|missing|denied|error) ;;
        *) fact_status=error ;;
    esac
    case "$fact_confidence" in
        exact|derived|heuristic) ;;
        *) fact_confidence=derived ;;
    esac

    case "$OUTPUT_MODE" in
        json)
            [ "$JSON_FIRST_FACT" -eq 1 ] || printf ',\n'
            JSON_FIRST_FACT=0
            printf '    {"key":"%s","value":"%s","status":"%s","source":"%s","confidence":"%s"}' \
                "$(json_escape "$fact_key")" \
                "$(json_escape "$fact_value")" \
                "$fact_status" \
                "$(json_escape "$fact_source")" \
                "$fact_confidence"
            ;;
        plain)
            if [ "$DEBUG_OUTPUT" -eq 1 ]; then
                printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$fact_key" "$fact_status" "$fact_confidence" \
                    "$fact_value" "$fact_source"
            else
                printf '%s\t%s\t%s\t%s\n' \
                    "$fact_key" "$fact_status" "$fact_confidence" "$fact_value"
            fi
            ;;
        *)
            if [ "$COLOR_OUTPUT" -eq 1 ]; then
                fact_color=$(status_color "$fact_status")
                printf '%s%-34s\033[0m %s' "$fact_color" "$fact_key" "$fact_value"
            else
                printf '%-34s %s' "$fact_key" "$fact_value"
            fi
            [ "$fact_status" = ok ] || printf ' [%s]' "$fact_status"
            if [ "$DEBUG_OUTPUT" -eq 1 ]; then
                printf ' {%s; %s}' "$fact_source" "$fact_confidence"
            fi
            printf '\n'
            ;;
    esac
}

emit_detected()
{
    if [ -n "$2" ]; then
        emit_fact "$1" "$2" ok "$3" "$4"
    else
        emit_fact "$1" '' unknown "$3" "$4"
    fi
}

output_begin()
{
    case "$OUTPUT_MODE" in
        json)
            printf '{\n'
            printf '  "schema_version":"%s",\n' "$SCHEMA_VERSION"
            printf '  "collector":{"name":"%s","version":"%s","mode":"%s","platform":"%s","timestamp":"%s"},\n' \
                "$(json_escape "$COLLECTOR_NAME")" \
                "$(json_escape "$COLLECTOR_VERSION")" \
                "$COLLECTION_MODE" \
                "$(json_escape "$PLATFORM_ADAPTER")" \
                "$(json_escape "$COLLECTION_TIMESTAMP")"
            printf '  "facts":[\n'
            ;;
        human)
            printf '%s %s — read-only report\n' "$COLLECTOR_NAME" "$COLLECTOR_VERSION"
            printf 'Mode: %s | Platform: %s | Collected: %s\n\n' \
                "$COLLECTION_MODE" "$PLATFORM_ADAPTER" "$COLLECTION_TIMESTAMP"
            ;;
    esac
}

output_end()
{
    if [ "$OUTPUT_MODE" = json ]; then
        printf '\n  ],\n  "warnings":[]\n}\n'
    fi
}

read_path_text()
{
    READ_SOURCE=$1
    READ_PATH=$(host_path "$1")
    READ_VALUE=
    READ_STATUS=missing

    if [ -r "$READ_PATH" ]; then
        READ_VALUE=$(LC_ALL=C sed -n '1p' "$READ_PATH" 2>/dev/null | tr -d '\000')
        if [ -n "$READ_VALUE" ]; then
            READ_STATUS=ok
        else
            READ_STATUS=unknown
        fi
    elif [ -f "$READ_PATH" ] || [ -d "$READ_PATH" ] || [ -L "$READ_PATH" ]; then
        READ_STATUS=denied
    fi
}

emit_path_fact()
{
    read_path_text "$2"
    emit_fact "$1" "$READ_VALUE" "$READ_STATUS" "$2" "$3"
}

read_release_value()
{
    RELEASE_VALUE=
    release_key=$1
    release_path=$2

    [ -r "$release_path" ] || return 1
    while IFS= read -r release_line || [ -n "$release_line" ]; do
        case "$release_line" in
            "$release_key="*)
                release_raw=${release_line#*=}
                case "$release_raw" in
                    \"*\")
                        release_raw=${release_raw#\"}
                        release_raw=${release_raw%\"}
                        release_raw=$(printf '%s' "$release_raw" |
                            sed 's/\\"/"/g; s/\\\\/\\/g')
                        ;;
                    \'*\')
                        release_raw=${release_raw#\'}
                        release_raw=${release_raw%\'}
                        ;;
                esac
                RELEASE_VALUE=$release_raw
                return 0
                ;;
        esac
    done < "$release_path"
    return 1
}

detect_platform()
{
    if [ "$FIXTURE_MODE" -eq 1 ] && [ -n "$SWISS_TEST_PLATFORM" ]; then
        detected_kernel=$SWISS_TEST_PLATFORM
        PLATFORM_ADAPTER=$SWISS_TEST_PLATFORM
        return
    elif [ "$FIXTURE_MODE" -eq 1 ]; then
        detected_kernel=Linux
    elif has_command uname; then
        detected_kernel=$(uname -s 2>/dev/null || printf unknown)
    else
        detected_kernel=unknown
    fi

    case "$detected_kernel" in
        Linux) PLATFORM_ADAPTER=linux ;;
        Darwin) PLATFORM_ADAPTER=macos ;;
        FreeBSD|OpenBSD|NetBSD|DragonFly) PLATFORM_ADAPTER=bsd ;;
        *) PLATFORM_ADAPTER=unknown ;;
    esac
}

collect_metadata()
{
    emit_fact collector.name "$COLLECTOR_NAME" ok 'built-in' exact
    emit_fact collector.version "$COLLECTOR_VERSION" ok 'built-in' exact
    emit_fact collector.schema_version "$SCHEMA_VERSION" ok 'built-in' exact
    emit_fact collector.timestamp "$COLLECTION_TIMESTAMP" ok 'date -u' exact
    emit_fact collector.mode "$COLLECTION_MODE" ok 'arguments' exact
    emit_fact collector.platform_adapter "$PLATFORM_ADAPTER" ok 'uname -s' exact
}

collect_identity()
{
    if [ "$FIXTURE_MODE" -eq 1 ]; then
        identity_hostname=fixture-host
        identity_hostname_source='sanitized fixture'
    elif has_command hostname; then
        identity_hostname=$(hostname 2>/dev/null || printf '')
        identity_hostname_source=hostname
    elif has_command uname; then
        identity_hostname=$(uname -n 2>/dev/null || printf '')
        identity_hostname_source='uname -n'
    else
        identity_hostname=
        identity_hostname_source='hostname/uname'
    fi
    emit_detected identity.hostname "$identity_hostname" "$identity_hostname_source" exact

    if [ "$FIXTURE_MODE" -eq 1 ]; then
        identity_username=fixture-user
        identity_uid=1000
        identity_gid=1000
        emit_fact identity.username "$identity_username" ok 'sanitized fixture' exact
        emit_fact identity.uid "$identity_uid" ok 'sanitized fixture' exact
        emit_fact identity.primary_gid "$identity_gid" ok 'sanitized fixture' exact
        emit_fact identity.is_privileged false ok 'sanitized fixture' exact
    elif has_command id; then
        identity_username=$(id -un 2>/dev/null || printf '')
        identity_uid=$(id -u 2>/dev/null || printf '')
        identity_gid=$(id -g 2>/dev/null || printf '')
        emit_detected identity.username "$identity_username" 'id -un' exact
        emit_detected identity.uid "$identity_uid" 'id -u' exact
        emit_detected identity.primary_gid "$identity_gid" 'id -g' exact
        if [ "$identity_uid" = 0 ]; then
            emit_fact identity.is_privileged true ok 'id -u' exact
        elif [ -n "$identity_uid" ]; then
            emit_fact identity.is_privileged false ok 'id -u' exact
        else
            emit_fact identity.is_privileged '' unknown 'id -u' exact
        fi
    else
        emit_fact identity.username "${USER:-}" missing id derived
        emit_fact identity.uid '' missing id exact
        emit_fact identity.primary_gid '' missing id exact
        emit_fact identity.is_privileged '' missing id exact
    fi

    elevation_tools=
    for elevation_tool in sudo doas su pkexec; do
        if has_command "$elevation_tool"; then
            if [ -n "$elevation_tools" ]; then
                elevation_tools="$elevation_tools,$elevation_tool"
            else
                elevation_tools=$elevation_tool
            fi
        fi
    done
    emit_fact identity.elevation_tools "$elevation_tools" ok 'command -v (not invoked)' exact
}

collect_kernel()
{
    if [ "$FIXTURE_MODE" -eq 1 ]; then
        kernel_name=Linux
        read_path_text /proc/sys/kernel/osrelease
        kernel_release=$READ_VALUE
        machine_arch=fixture64
        emit_fact system.kernel.name "$kernel_name" ok 'sanitized fixture' exact
        emit_detected system.kernel.release "$kernel_release" /proc/sys/kernel/osrelease exact
        emit_fact system.architecture.machine "$machine_arch" ok 'sanitized fixture' exact
    elif has_command uname; then
        kernel_name=$(uname -s 2>/dev/null || printf '')
        kernel_release=$(uname -r 2>/dev/null || printf '')
        machine_arch=$(uname -m 2>/dev/null || printf '')
        emit_detected system.kernel.name "$kernel_name" 'uname -s' exact
        emit_detected system.kernel.release "$kernel_release" 'uname -r' exact
        emit_detected system.architecture.machine "$machine_arch" 'uname -m' exact
    else
        machine_arch=
        emit_fact system.kernel.name '' missing uname exact
        emit_fact system.kernel.release '' missing uname exact
        emit_fact system.architecture.machine '' missing uname exact
    fi

    if [ "$FIXTURE_MODE" -eq 1 ]; then
        userspace_bits=64
    elif has_command getconf; then
        userspace_bits=$(getconf LONG_BIT 2>/dev/null || printf '')
    else
        userspace_bits=
    fi
    if [ -z "$userspace_bits" ]; then
        case "$machine_arch" in
            *64*) userspace_bits=64 ;;
            i?86|armv[4-8]*) userspace_bits=32 ;;
        esac
        userspace_bits_confidence=derived
        userspace_bits_source='uname -m'
    else
        userspace_bits_confidence=exact
        if [ "$FIXTURE_MODE" -eq 1 ]; then
            userspace_bits_source='sanitized fixture'
        else
            userspace_bits_source='getconf LONG_BIT'
        fi
    fi
    if [ -n "$userspace_bits" ]; then
        emit_fact system.architecture.userspace_bits "$userspace_bits" ok \
            "$userspace_bits_source" "$userspace_bits_confidence"
    else
        emit_fact system.architecture.userspace_bits '' unknown \
            'getconf LONG_BIT/uname -m' derived
    fi
}

collect_filesystems()
{
    if [ "$FIXTURE_MODE" -eq 1 ]; then
        filesystem_fixture=$(host_path /fixtures/filesystems.txt)
        if [ -r "$filesystem_fixture" ]; then
            filesystem_summary=$(sed -n '1p' "$filesystem_fixture")
            emit_detected hardware.filesystems "$filesystem_summary" \
                'sanitized fixture' exact
            return
        elif [ "$SWISS_TEST_ALLOW_COMMAND" != df ]; then
            emit_fact hardware.filesystems '' missing 'sanitized fixture' exact
            return
        fi
    fi
    if ! has_command df; then
        emit_fact hardware.filesystems '' missing df exact
        return
    fi

    filesystem_output=
    filesystem_source=
    if filesystem_output=$(LC_ALL=C df -Pkl 2>/dev/null); then
        filesystem_source='df -Pkl (local filesystems only)'
    else
        mounts_path=$(host_path /proc/mounts)
        if [ -r "$mounts_path" ]; then
            filesystem_output=$(awk '
                $3 ~ /^(ext2|ext3|ext4|xfs|btrfs|f2fs|vfat|exfat|ntfs|ntfs3|zfs|tmpfs|devtmpfs|overlay|squashfs|erofs|ramfs|proc|sysfs|cgroup|cgroup2|devpts|mqueue|pstore|debugfs|tracefs|securityfs|efivarfs|configfs)$/ {
                    print $2
                }
            ' "$mounts_path" | while IFS= read -r escaped_mount; do
                mount_path=$(printf '%s' "$escaped_mount" |
                    sed 's/\\040/ /g; s/\\011/\	/g; s/\\134/\\/g')
                LC_ALL=C df -Pk "$mount_path" 2>/dev/null | sed -n '2p'
            done)
            filesystem_source='df -Pk for local /proc/mounts entries'
        fi
    fi

    filesystem_summary=$(printf '%s\n' "$filesystem_output" | awk '
        function escape(value) {
            gsub(/%/, "%25", value)
            gsub(/;/, "%3B", value)
            gsub(/\|/, "%7C", value)
            gsub(/=/, "%3D", value)
            return value
        }
        $2 ~ /^[0-9]+$/ && NF >= 6 {
            mount_point=$6
            for (field=7; field<=NF; field++) mount_point=mount_point " " $field
            total=$2 * 1024
            used=$3 * 1024
            available=$4 * 1024
            item=escape(mount_point) "|total=" sprintf("%.0f", total) "|used=" \
                sprintf("%.0f", used) "|available=" sprintf("%.0f", available) \
                "|capacity=" $5
            if (!seen[item]++) {
                if (output != "") output=output ";"
                output=output item
            }
        }
        END { print output }
    ')
    if [ -n "$filesystem_summary" ]; then
        emit_fact hardware.filesystems "$filesystem_summary" ok "$filesystem_source" exact
    elif [ -z "$filesystem_source" ]; then
        emit_fact hardware.filesystems '' unsupported 'local-only df mode unavailable' exact
    else
        emit_fact hardware.filesystems '' error "$filesystem_source" exact
    fi
}

collect_dns_resolvers()
{
    resolver_source=/etc/resolv.conf
    resolver_path=$(host_path "$resolver_source")
    if [ -r "$resolver_path" ]; then
        dns_resolvers=$(awk '
            $1 == "nameserver" && NF >= 2 {
                if (output != "") output=output ","
                output=output $2
            }
            END { print output }
        ' "$resolver_path" 2>/dev/null)
        if [ -n "$dns_resolvers" ]; then
            emit_fact network.dns.resolvers "$dns_resolvers" ok "$resolver_source" exact
        else
            emit_fact network.dns.resolvers '' unknown "$resolver_source" exact
        fi
    elif [ -f "$resolver_path" ] || [ -L "$resolver_path" ]; then
        emit_fact network.dns.resolvers '' denied "$resolver_source" exact
    else
        emit_fact network.dns.resolvers '' missing "$resolver_source" exact
    fi
}

classify_interface()
{
    interface_name=$1
    interface_type_code=$2
    interface_device_path=$3
    case "$interface_name" in
        lo|lo0) INTERFACE_CLASS=loopback ;;
        wl*|wifi*|ath*) INTERFACE_CLASS=wifi ;;
        en*|eth*) INTERFACE_CLASS=wired ;;
        tun*|tap*|wg*|tailscale*|utun*) INTERFACE_CLASS=tunnel ;;
        br*|docker*|virbr*|veth*) INTERFACE_CLASS=bridge-virtual ;;
        *)
            if [ "$interface_type_code" = 772 ]; then
                INTERFACE_CLASS=loopback
            elif [ -n "$interface_device_path" ] && [ ! -e "$interface_device_path" ]; then
                INTERFACE_CLASS=virtual
            else
                INTERFACE_CLASS=unknown
            fi
            ;;
    esac
}

collect_network_addresses()
{
    network_addresses=
    network_addresses_source=
    network_addresses_attempted=0
    network_addresses_succeeded=0
    network_addresses_failed=0

    if [ "$FIXTURE_MODE" -eq 1 ]; then
        network_address_fixture=$(host_path /fixtures/network-addresses.txt)
        if [ -r "$network_address_fixture" ]; then
            network_addresses_attempted=1
            network_addresses_succeeded=1
            network_addresses=$(sed -n '1p' "$network_address_fixture")
            network_addresses_source='sanitized fixture'
        fi
    elif has_command ip; then
        network_addresses_attempted=1
        if ip_address_output=$(ip -o addr show 2>/dev/null); then
            network_addresses_succeeded=1
            network_addresses=$(printf '%s\n' "$ip_address_output" | awk '
            function escape(value) {
                gsub(/%/, "%25", value); gsub(/;/, "%3B", value)
                gsub(/\|/, "%7C", value); gsub(/=/, "%3D", value)
                return value
            }
            $3 == "inet" || $3 == "inet6" {
                if (output != "") output=output ";"
                output=output escape($2) "|" $3 "|" escape($4)
            }
            END { print output }
            ')
            network_addresses_source='ip -o addr show'
        else
            network_addresses_failed=1
        fi
    fi
    if [ -z "$network_addresses" ] && [ "$FIXTURE_MODE" -eq 0 ] && has_command ifconfig; then
        network_addresses_attempted=1
        if ifconfig_output=$(ifconfig -a 2>/dev/null); then
            network_addresses_succeeded=1
            network_addresses=$(printf '%s\n' "$ifconfig_output" | awk '
            function escape(value) {
                gsub(/%/, "%25", value); gsub(/;/, "%3B", value)
                gsub(/\|/, "%7C", value); gsub(/=/, "%3D", value)
                return value
            }
            /^[[:alnum:]_.:-]+:/ {
                interface_name=$1
                sub(/:$/, "", interface_name)
            }
            $1 == "inet" && interface_name != "" {
                address=$2
                sub(/^addr:/, "", address)
                if (output != "") output=output ";"
                output=output escape(interface_name) "|inet|" escape(address)
            }
            $1 == "inet6" && interface_name != "" {
                address=$2
                sub(/^addr:/, "", address)
                if (output != "") output=output ";"
                output=output escape(interface_name) "|inet6|" escape(address)
            }
            END { print output }
            ')
            network_addresses_source='ifconfig -a'
        else
            network_addresses_failed=1
        fi
    fi
    if [ -z "$network_addresses" ] && [ "$FIXTURE_MODE" -eq 0 ] && has_command hostname; then
        network_addresses_attempted=1
        if hostname_address_output=$(hostname -I 2>/dev/null); then
            network_addresses_succeeded=1
            network_addresses=$(printf '%s\n' "$hostname_address_output" |
                awk '{$1=$1; gsub(/ /, ","); print}')
            network_addresses_source='hostname -I (interfaces unavailable)'
        else
            network_addresses_failed=1
        fi
    fi

    if [ -n "$network_addresses" ]; then
        emit_fact network.addresses "$network_addresses" ok \
            "$network_addresses_source" exact
    elif [ "$network_addresses_succeeded" -eq 1 ]; then
        emit_fact network.addresses '' unknown "$network_addresses_source" exact
    elif [ "$network_addresses_attempted" -eq 1 ] && [ "$network_addresses_failed" -eq 1 ]; then
        emit_fact network.addresses '' error 'ip/ifconfig/hostname' exact
    else
        emit_fact network.addresses '' missing 'ip/ifconfig/hostname' exact
    fi
}

collect_linux_os()
{
    emit_fact system.os.family linux ok 'uname -s' exact
    os_release_source=/etc/os-release
    os_release_path=$(host_path "$os_release_source")

    os_product=
    os_version=
    os_build=
    if [ -r "$os_release_path" ]; then
        read_release_value PRETTY_NAME "$os_release_path" || true
        os_product=$RELEASE_VALUE
        if [ -z "$os_product" ]; then
            read_release_value NAME "$os_release_path" || true
            os_product=$RELEASE_VALUE
        fi
        read_release_value VERSION_ID "$os_release_path" || true
        os_version=$RELEASE_VALUE
        if [ -z "$os_version" ]; then
            read_release_value VERSION "$os_release_path" || true
            os_version=$RELEASE_VALUE
        fi
        read_release_value BUILD_ID "$os_release_path" || true
        os_build=$RELEASE_VALUE

        emit_detected system.os.product "$os_product" "$os_release_source" exact
        emit_detected system.os.version "$os_version" "$os_release_source" exact
        emit_detected system.os.build "$os_build" "$os_release_source" exact
    elif [ -f "$os_release_path" ] || [ -L "$os_release_path" ]; then
        emit_fact system.os.product '' denied "$os_release_source" exact
        emit_fact system.os.version '' denied "$os_release_source" exact
        emit_fact system.os.build '' denied "$os_release_source" exact
    else
        emit_fact system.os.product Linux missing "$os_release_source" derived
        emit_fact system.os.version '' missing "$os_release_source" exact
        emit_fact system.os.build '' missing "$os_release_source" exact
    fi
}

collect_linux_environment()
{
    environment_type=unknown
    environment_source='local heuristics'
    environment_confidence=heuristic
    osrelease_path=$(host_path /proc/sys/kernel/osrelease)
    cgroup_path=$(host_path /proc/1/cgroup)
    dockerenv_path=$(host_path /.dockerenv)

    if [ -r "$osrelease_path" ] &&
        LC_ALL=C grep -qi microsoft "$osrelease_path" 2>/dev/null; then
        environment_type=wsl
        environment_source=/proc/sys/kernel/osrelease
        environment_confidence=derived
    elif [ -f "$dockerenv_path" ]; then
        environment_type=container
        environment_source=/.dockerenv
        environment_confidence=derived
    elif [ -r "$cgroup_path" ] &&
        LC_ALL=C grep -Eqi 'docker|containerd|kubepods|lxc|podman' "$cgroup_path" 2>/dev/null; then
        environment_type=container
        environment_source=/proc/1/cgroup
        environment_confidence=derived
    else
        read_path_text /sys/class/dmi/id/product_name
        dmi_product=$READ_VALUE
        read_path_text /sys/class/dmi/id/sys_vendor
        dmi_vendor=$READ_VALUE
        case "$dmi_vendor $dmi_product" in
            *[Vv][Mm][Ww]are*|*[Vv]irtual[Bb]ox*|*[Qq][Ee][Mm][Uu]*|*[Kk][Vv][Mm]*|*[Xx]en*|*[Hh]yper-[Vv]*)
                environment_type=virtual-machine
                environment_source='/sys/class/dmi/id'
                environment_confidence=heuristic
                ;;
            *Steam*Deck*|*Valve*Jupiter*|*Valve*Galileo*)
                environment_type=physical
                environment_source='/sys/class/dmi/id'
                environment_confidence=heuristic
                ;;
            *)
                if [ -n "$dmi_product$dmi_vendor" ]; then
                    environment_type=physical
                    environment_source='/sys/class/dmi/id'
                    environment_confidence=heuristic
                fi
                ;;
        esac
    fi
    if [ "$environment_type" = unknown ]; then
        emit_fact system.environment.type "$environment_type" unknown \
            "$environment_source" "$environment_confidence"
    else
        emit_fact system.environment.type "$environment_type" ok \
            "$environment_source" "$environment_confidence"
    fi
}

collect_linux_uptime()
{
    uptime_path=$(host_path /proc/uptime)
    if [ -r "$uptime_path" ]; then
        IFS=' ' read -r uptime_seconds _ < "$uptime_path" || true
        uptime_seconds=${uptime_seconds%%.*}
        emit_detected system.uptime_seconds "$uptime_seconds" /proc/uptime exact
    elif [ -f "$uptime_path" ]; then
        emit_fact system.uptime_seconds '' denied /proc/uptime exact
    else
        emit_fact system.uptime_seconds '' missing /proc/uptime exact
    fi
}

collect_linux_hardware()
{
    read_path_text /sys/class/dmi/id/sys_vendor
    if [ "$READ_STATUS" = missing ]; then
        read_path_text /proc/device-tree/manufacturer
    fi
    emit_fact hardware.manufacturer "$READ_VALUE" "$READ_STATUS" "$READ_SOURCE" exact

    read_path_text /sys/class/dmi/id/product_name
    if [ "$READ_STATUS" = missing ]; then
        read_path_text /proc/device-tree/model
    fi
    emit_fact hardware.model "$READ_VALUE" "$READ_STATUS" "$READ_SOURCE" exact

    emit_path_fact hardware.firmware.vendor /sys/class/dmi/id/bios_vendor exact
    emit_path_fact hardware.firmware.version /sys/class/dmi/id/bios_version exact
    emit_path_fact hardware.firmware.date /sys/class/dmi/id/bios_date exact

    cpuinfo_path=$(host_path /proc/cpuinfo)
    cpu_model=
    if [ -r "$cpuinfo_path" ]; then
        cpu_model=$(sed -n '
            /^model name[[:space:]]*:/ { s/^[^:]*:[[:space:]]*//; p; q; }
            /^Hardware[[:space:]]*:/ { s/^[^:]*:[[:space:]]*//; p; q; }
            /^Processor[[:space:]]*:/ { s/^[^:]*:[[:space:]]*//; p; q; }
        ' "$cpuinfo_path")
        emit_detected hardware.cpu.model "$cpu_model" /proc/cpuinfo exact
    else
        emit_fact hardware.cpu.model '' missing /proc/cpuinfo exact
    fi

    cpu_count=
    if [ "$FIXTURE_MODE" -eq 0 ] && has_command getconf; then
        cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '')
    fi
    if [ -z "$cpu_count" ] && [ -r "$cpuinfo_path" ]; then
        cpu_count=$(awk '/^processor[[:space:]]*:/ { count++ } END { if (count) print count }' \
            "$cpuinfo_path")
        cpu_count_source=/proc/cpuinfo
    else
        cpu_count_source='getconf _NPROCESSORS_ONLN'
    fi
    emit_detected hardware.cpu.logical_count "$cpu_count" "$cpu_count_source" exact

    meminfo_path=$(host_path /proc/meminfo)
    if [ -r "$meminfo_path" ]; then
        memory_total=$(awk '$1 == "MemTotal:" { printf "%.0f", $2 * 1024; exit }' \
            "$meminfo_path")
        emit_detected hardware.memory.total_bytes "$memory_total" /proc/meminfo exact
    else
        emit_fact hardware.memory.total_bytes '' missing /proc/meminfo exact
    fi

    collect_linux_battery
    collect_filesystems
    collect_linux_storage
}

collect_linux_battery()
{
    power_root=$(host_path /sys/class/power_supply)
    battery_found=0
    battery_state=
    battery_capacity=
    if [ -d "$power_root" ]; then
        for power_path in "$power_root"/*; do
            [ -d "$power_path" ] || continue
            power_type=$(sed -n '1p' "$power_path/type" 2>/dev/null || printf '')
            [ "$power_type" = Battery ] || continue
            battery_found=1
            battery_state=$(sed -n '1p' "$power_path/status" 2>/dev/null || printf '')
            battery_capacity=$(sed -n '1p' "$power_path/capacity" 2>/dev/null || printf '')
            break
        done
        if [ "$battery_found" -eq 1 ]; then
            emit_fact hardware.battery.present true ok /sys/class/power_supply exact
            emit_detected hardware.battery.state "$battery_state" /sys/class/power_supply exact
            emit_detected hardware.battery.charge_percent "$battery_capacity" \
                /sys/class/power_supply exact
        else
            emit_fact hardware.battery.present false ok /sys/class/power_supply exact
            emit_fact hardware.battery.state '' unsupported /sys/class/power_supply exact
            emit_fact hardware.battery.charge_percent '' unsupported \
                /sys/class/power_supply exact
        fi
    else
        emit_fact hardware.battery.present '' missing /sys/class/power_supply exact
        emit_fact hardware.battery.state '' missing /sys/class/power_supply exact
        emit_fact hardware.battery.charge_percent '' missing /sys/class/power_supply exact
    fi
}

collect_linux_storage()
{
    block_root=$(host_path /sys/class/block)
    storage_summary=
    if [ -d "$block_root" ]; then
        for block_path in "$block_root"/*; do
            [ -d "$block_path" ] || continue
            block_name=$(inventory_escape "${block_path##*/}")
            block_type=disk
            [ ! -f "$block_path/partition" ] || block_type=partition
            block_sectors=$(sed -n '1p' "$block_path/size" 2>/dev/null || printf '')
            case "$block_sectors" in
                ''|*[!0-9]*) block_bytes=unknown ;;
                *) block_bytes=$((block_sectors * 512)) ;;
            esac
            block_model=$(sed -n '1p' "$block_path/device/model" 2>/dev/null |
                sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || printf '')
            block_model=$(inventory_escape "$block_model")
            storage_item="$block_name|type=$block_type|bytes=$block_bytes"
            [ -z "$block_model" ] || storage_item="$storage_item|model=$block_model"
            if [ -n "$storage_summary" ]; then
                storage_summary="$storage_summary;$storage_item"
            else
                storage_summary=$storage_item
            fi
        done
        if [ -n "$storage_summary" ]; then
            emit_fact hardware.storage "$storage_summary" ok /sys/class/block exact
        else
            emit_fact hardware.storage '' unknown /sys/class/block exact
        fi
    else
        emit_fact hardware.storage '' missing /sys/class/block exact
    fi
}

collect_linux_network()
{
    emit_fact network.hostname "$identity_hostname" \
        "$(if [ -n "$identity_hostname" ]; then printf ok; else printf unknown; fi)" \
        "$identity_hostname_source" exact

    network_root=$(host_path /sys/class/net)
    interface_summary=
    if [ -d "$network_root" ]; then
        for interface_path in "$network_root"/*; do
            [ -d "$interface_path" ] || continue
            interface_name=${interface_path##*/}
            interface_state=$(sed -n '1p' "$interface_path/operstate" 2>/dev/null || printf unknown)
            interface_mac=$(sed -n '1p' "$interface_path/address" 2>/dev/null || printf '')
            interface_type_code=$(sed -n '1p' "$interface_path/type" 2>/dev/null || printf '')
            classify_interface "$interface_name" "$interface_type_code" "$interface_path/device"
            interface_item="$(inventory_escape "$interface_name")|state=$(inventory_escape "$interface_state")|type=$INTERFACE_CLASS"
            [ -z "$interface_mac" ] || interface_item="$interface_item|mac=$(inventory_escape "$interface_mac")"
            if [ -n "$interface_summary" ]; then
                interface_summary="$interface_summary;$interface_item"
            else
                interface_summary=$interface_item
            fi
        done
        emit_detected network.interfaces "$interface_summary" /sys/class/net exact
    else
        emit_fact network.interfaces '' missing /sys/class/net exact
    fi

    collect_network_addresses
    collect_linux_default_route
    collect_dns_resolvers
}

collect_linux_default_route()
{
    route_source=/proc/net/route
    route_path=$(host_path "$route_source")
    route_data=
    route_probe_attempted=0
    route_probe_succeeded=0
    route_probe_failed=0
    if [ -r "$route_path" ]; then
        route_probe_attempted=1
        route_probe_succeeded=1
        route_data=$(awk '
            function hex_digit(character) {
                return index("0123456789ABCDEF", toupper(character)) - 1
            }
            function hex_byte(value, position) {
                return hex_digit(substr(value, position, 1)) * 16 + \
                    hex_digit(substr(value, position + 1, 1))
            }
            NR > 1 && $2 == "00000000" {
                gateway=$3
                printf "%s|%d.%d.%d.%d\n", $1, hex_byte(gateway, 7), \
                    hex_byte(gateway, 5), hex_byte(gateway, 3), hex_byte(gateway, 1)
                exit
            }
        ' "$route_path")
    fi

    if [ -z "$route_data" ]; then
        ipv6_route_source=/proc/net/ipv6_route
        ipv6_route_path=$(host_path "$ipv6_route_source")
        if [ -r "$ipv6_route_path" ]; then
            route_probe_attempted=1
            route_probe_succeeded=1
            route_data=$(awk '
                function hex_value(value, result, position, digit) {
                    result=0
                    for (position=1; position<=length(value); position++) {
                        digit=index("0123456789ABCDEF", toupper(substr(value,position,1))) - 1
                        if (digit < 0) return -1
                        result=result * 16 + digit
                    }
                    return result
                }
                $1 == "00000000000000000000000000000000" && $2 == "00" {
                    metric=hex_value($6)
                    flags=hex_value($9)
                    reject=int(flags / 512) % 2
                    if (metric < 0 || metric == 4294967295 || reject == 1) next
                    if (selected && metric >= selected_metric) next
                    gateway=$5
                    formatted=substr(gateway,1,4)
                    for (position=5; position<=32; position+=4) {
                        formatted=formatted ":" substr(gateway,position,4)
                    }
                    selected=$10 "|" formatted
                    selected_metric=metric
                }
                END { print selected }
            ' "$ipv6_route_path")
            [ -z "$route_data" ] || route_source=$ipv6_route_source
        fi
    fi

    route_interface=
    route_gateway=
    if [ -z "$route_data" ] && has_command ip; then
        route_probe_attempted=1
        if ip_route_output=$(ip route show default 2>/dev/null); then
            route_probe_succeeded=1
            route_data=$(printf '%s\n' "$ip_route_output" | sed -n '1p')
            route_gateway=$(printf '%s\n' "$route_data" |
                awk '{ for (i=1; i<=NF; i++) if ($i == "via") { print $(i+1); exit } }')
            route_interface=$(printf '%s\n' "$route_data" |
                awk '{ for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }')
            route_source='ip route show default'
        else
            route_probe_failed=1
        fi
    fi

    if [ -n "$route_data" ]; then
        if [ -z "$route_interface" ]; then
            route_interface=${route_data%%|*}
            route_gateway=${route_data#*|}
        fi
        emit_fact network.default_route.exists true ok "$route_source" exact
        emit_detected network.default_route.interface "$route_interface" "$route_source" exact
        emit_detected network.default_route.gateway "$route_gateway" "$route_source" exact
    elif [ "$route_probe_succeeded" -eq 1 ]; then
        emit_fact network.default_route.exists false ok "$route_source" exact
        emit_fact network.default_route.interface '' unknown "$route_source" exact
        emit_fact network.default_route.gateway '' unknown "$route_source" exact
    elif [ "$route_probe_attempted" -eq 1 ] && [ "$route_probe_failed" -eq 1 ]; then
        emit_fact network.default_route.exists '' error "$route_source/ip" exact
        emit_fact network.default_route.interface '' error "$route_source/ip" exact
        emit_fact network.default_route.gateway '' error "$route_source/ip" exact
    else
        emit_fact network.default_route.exists '' missing "$route_source/ip" exact
        emit_fact network.default_route.interface '' missing "$route_source/ip" exact
        emit_fact network.default_route.gateway '' missing "$route_source/ip" exact
    fi
}

sysctl_value()
{
    SYSCTL_VALUE=
    if has_command sysctl; then
        SYSCTL_VALUE=$(sysctl -n "$1" 2>/dev/null || printf '')
    fi
}

collect_macos_os()
{
    emit_fact system.os.family macos ok 'uname -s' exact
    if has_command sw_vers; then
        mac_product=$(sw_vers -productName 2>/dev/null || printf '')
        mac_version=$(sw_vers -productVersion 2>/dev/null || printf '')
        mac_build=$(sw_vers -buildVersion 2>/dev/null || printf '')
        emit_detected system.os.product "$mac_product" 'sw_vers -productName' exact
        emit_detected system.os.version "$mac_version" 'sw_vers -productVersion' exact
        emit_detected system.os.build "$mac_build" 'sw_vers -buildVersion' exact
    else
        emit_fact system.os.product macOS missing sw_vers derived
        emit_fact system.os.version '' missing sw_vers exact
        emit_fact system.os.build '' missing sw_vers exact
    fi
}

collect_macos_hardware()
{
    emit_fact hardware.manufacturer 'Apple Inc.' ok 'platform definition' exact
    sysctl_value hw.model
    emit_detected hardware.model "$SYSCTL_VALUE" 'sysctl -n hw.model' exact

    emit_fact hardware.firmware.vendor Apple ok 'platform definition' exact
    if [ "$COLLECTION_MODE" = full ] && has_command system_profiler; then
        firmware_version=$(system_profiler SPHardwareDataType 2>/dev/null |
            sed -n 's/^[[:space:]]*System Firmware Version: //p' | sed -n '1p')
        emit_detected hardware.firmware.version "$firmware_version" \
            'system_profiler SPHardwareDataType' exact
    else
        emit_fact hardware.firmware.version '' unsupported \
            'use --full with system_profiler' exact
    fi
    emit_fact hardware.firmware.date '' unsupported 'macOS does not expose a portable value' exact

    sysctl_value machdep.cpu.brand_string
    emit_detected hardware.cpu.model "$SYSCTL_VALUE" \
        'sysctl -n machdep.cpu.brand_string' exact
    sysctl_value hw.logicalcpu
    emit_detected hardware.cpu.logical_count "$SYSCTL_VALUE" 'sysctl -n hw.logicalcpu' exact
    sysctl_value hw.memsize
    emit_detected hardware.memory.total_bytes "$SYSCTL_VALUE" 'sysctl -n hw.memsize' exact

    collect_macos_battery
    collect_filesystems
    if [ "$COLLECTION_MODE" = full ] && has_command diskutil; then
        mac_storage=$(diskutil list physical 2>/dev/null |
            awk '
                function escape(value) {
                    gsub(/%/, "%25", value); gsub(/;/, "%3B", value)
                    gsub(/\|/, "%7C", value); gsub(/=/, "%3D", value)
                    return value
                }
                /^\/dev\// { device=$1 }
                /[0-9]+\.[0-9]+ [KMGT]B/ {
                    line=$0; gsub(/^[[:space:]]+/, "", line)
                    if (out != "") out=out ";"
                    out=out escape(device) "|description=" escape(line)
                }
                END { print out }
            ')
        emit_detected hardware.storage "$mac_storage" 'diskutil list physical' exact
    elif [ "$COLLECTION_MODE" != full ]; then
        emit_fact hardware.storage '' unsupported 'use --full for diskutil list physical' exact
    else
        emit_fact hardware.storage '' missing diskutil exact
    fi
}

collect_macos_system()
{
    sysctl_value hw.model
    mac_system_model=$SYSCTL_VALUE
    case "$mac_system_model" in
        VirtualMac*) emit_fact system.environment.type virtual-machine ok 'sysctl -n hw.model' heuristic ;;
        '') emit_fact system.environment.type unknown unknown 'sysctl -n hw.model' heuristic ;;
        *) emit_fact system.environment.type physical ok 'sysctl -n hw.model' heuristic ;;
    esac

    if has_command sysctl; then
        sysctl_value kern.boottime
        boot_epoch=$(printf '%s\n' "$SYSCTL_VALUE" |
            sed -n 's/.*{[[:space:]]*sec = \([0-9][0-9]*\).*/\1/p')
        now_epoch=$(date +%s 2>/dev/null || printf '')
        case "$boot_epoch:$now_epoch" in
            *[!0-9:]*|:*) mac_uptime= ;;
            *) mac_uptime=$((now_epoch - boot_epoch)) ;;
        esac
        emit_detected system.uptime_seconds "$mac_uptime" 'sysctl -n kern.boottime' derived
    else
        emit_fact system.uptime_seconds '' missing sysctl exact
    fi
}

collect_macos_battery()
{
    if has_command pmset; then
        if ! battery_output=$(pmset -g batt 2>/dev/null); then
            emit_fact hardware.battery.present '' error 'pmset -g batt' exact
            emit_fact hardware.battery.state '' error 'pmset -g batt' exact
            emit_fact hardware.battery.charge_percent '' error 'pmset -g batt' exact
        elif printf '%s\n' "$battery_output" | grep -q 'InternalBattery'; then
            battery_capacity=$(printf '%s\n' "$battery_output" |
                sed -n 's/.*[[:space:]]\([0-9][0-9]*\)%;.*/\1/p' | sed -n '1p')
            battery_state=$(printf '%s\n' "$battery_output" |
                sed -n 's/.*%;[[:space:]]*\([^;]*\);.*/\1/p' | sed -n '1p')
            emit_fact hardware.battery.present true ok 'pmset -g batt' exact
            emit_detected hardware.battery.state "$battery_state" 'pmset -g batt' exact
            emit_detected hardware.battery.charge_percent "$battery_capacity" \
                'pmset -g batt' exact
        else
            emit_fact hardware.battery.present false ok 'pmset -g batt' exact
            emit_fact hardware.battery.state '' unsupported 'pmset -g batt' exact
            emit_fact hardware.battery.charge_percent '' unsupported 'pmset -g batt' exact
        fi
    else
        emit_fact hardware.battery.present '' missing pmset exact
        emit_fact hardware.battery.state '' missing pmset exact
        emit_fact hardware.battery.charge_percent '' missing pmset exact
    fi
}

collect_macos_network()
{
    emit_fact network.hostname "$identity_hostname" \
        "$(if [ -n "$identity_hostname" ]; then printf ok; else printf unknown; fi)" \
        "$identity_hostname_source" exact

    mac_interfaces=
    if has_command ifconfig; then
        mac_interface_names=$(ifconfig -l 2>/dev/null || printf '')
        for interface_name in $mac_interface_names; do
            interface_output=$(ifconfig "$interface_name" 2>/dev/null || printf '')
            interface_state=$(printf '%s\n' "$interface_output" |
                awk '$1 == "status:" { print $2; exit }')
            [ -n "$interface_state" ] || interface_state=unknown
            interface_mac=$(printf '%s\n' "$interface_output" |
                awk '$1 == "ether" { print $2; exit }')
            classify_interface "$interface_name" '' ''
            case "$interface_name:$INTERFACE_CLASS" in
                en*:wired) INTERFACE_CLASS=unknown ;;
            esac
            interface_item="$(inventory_escape "$interface_name")|state=$(inventory_escape "$interface_state")|type=$INTERFACE_CLASS"
            [ -z "$interface_mac" ] || interface_item="$interface_item|mac=$(inventory_escape "$interface_mac")"
            if [ -n "$mac_interfaces" ]; then
                mac_interfaces="$mac_interfaces;$interface_item"
            else
                mac_interfaces=$interface_item
            fi
        done
        emit_detected network.interfaces "$mac_interfaces" 'ifconfig -l/ifconfig' heuristic
    else
        emit_fact network.interfaces '' missing ifconfig exact
    fi

    collect_network_addresses
    collect_macos_default_route
    collect_macos_dns
}

collect_macos_default_route()
{
    if has_command route; then
        mac_route=$(route -n get default 2>/dev/null || printf '')
        route_source='route -n get default'
        if [ -z "$mac_route" ]; then
            mac_route=$(route -n get -inet6 default 2>/dev/null || printf '')
            route_source='route -n get -inet6 default'
        fi
        route_gateway=$(printf '%s\n' "$mac_route" |
            awk '$1 == "gateway:" { print $2; exit }')
        route_interface=$(printf '%s\n' "$mac_route" |
            awk '$1 == "interface:" { print $2; exit }')
        if [ -n "$route_gateway$route_interface" ]; then
            emit_fact network.default_route.exists true ok "$route_source" exact
            emit_detected network.default_route.interface "$route_interface" \
                "$route_source" exact
            emit_detected network.default_route.gateway "$route_gateway" \
                "$route_source" exact
        else
            emit_fact network.default_route.exists false ok "$route_source" exact
            emit_fact network.default_route.interface '' unknown "$route_source" exact
            emit_fact network.default_route.gateway '' unknown "$route_source" exact
        fi
    else
        emit_fact network.default_route.exists '' missing route exact
        emit_fact network.default_route.interface '' missing route exact
        emit_fact network.default_route.gateway '' missing route exact
    fi
}

collect_macos_dns()
{
    if has_command scutil; then
        mac_dns=$(scutil --dns 2>/dev/null |
            awk '$1 == "nameserver[0]" || $1 ~ /^nameserver\[[0-9]+\]$/ { if (seen[$3]++) next; if (out != "") out=out ","; out=out $3 } END { print out }')
        if [ -n "$mac_dns" ]; then
            emit_fact network.dns.resolvers "$mac_dns" ok 'scutil --dns' exact
            return
        fi
    fi
    collect_dns_resolvers
}

collect_bsd()
{
    emit_fact system.os.family bsd ok 'uname -s' exact
    emit_fact system.os.product "$detected_kernel" ok 'uname -s' exact
    emit_fact system.os.version "$kernel_release" ok 'uname -r' exact
    emit_fact system.os.build '' unsupported 'portable BSD baseline' exact
    emit_fact system.environment.type unknown unknown 'portable BSD baseline' heuristic
    emit_fact system.uptime_seconds '' unsupported 'portable BSD baseline' exact
    emit_fact hardware.manufacturer '' unsupported 'portable BSD baseline' exact
    emit_fact hardware.model '' unsupported 'portable BSD baseline' exact
    emit_fact hardware.firmware.vendor '' unsupported 'portable BSD baseline' exact
    emit_fact hardware.firmware.version '' unsupported 'portable BSD baseline' exact
    emit_fact hardware.firmware.date '' unsupported 'portable BSD baseline' exact
    emit_fact hardware.cpu.model '' unsupported 'portable BSD baseline' exact
    if has_command getconf; then
        bsd_cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '')
        emit_detected hardware.cpu.logical_count "$bsd_cpu_count" \
            'getconf _NPROCESSORS_ONLN' exact
    else
        emit_fact hardware.cpu.logical_count '' missing getconf exact
    fi
    emit_fact hardware.memory.total_bytes '' unsupported 'portable BSD baseline' exact
    emit_fact hardware.battery.present '' unsupported 'portable BSD baseline' exact
    emit_fact hardware.battery.state '' unsupported 'portable BSD baseline' exact
    emit_fact hardware.battery.charge_percent '' unsupported 'portable BSD baseline' exact
    collect_filesystems
    emit_fact hardware.storage '' unsupported 'portable BSD baseline' exact
    emit_fact network.hostname "$identity_hostname" ok "$identity_hostname_source" exact
    emit_fact network.interfaces '' unsupported 'portable BSD baseline' exact
    collect_network_addresses
    collect_macos_default_route
    collect_dns_resolvers
}

collect_unknown()
{
    emit_fact system.os.family unknown unknown 'uname -s' exact
    emit_fact system.os.product '' unsupported 'unknown platform' exact
    emit_fact system.os.version '' unsupported 'unknown platform' exact
    emit_fact system.os.build '' unsupported 'unknown platform' exact
    emit_fact system.environment.type unknown unknown 'unknown platform' heuristic
    emit_fact system.uptime_seconds '' unsupported 'unknown platform' exact
    for unknown_key in \
        hardware.manufacturer hardware.model hardware.firmware.vendor \
        hardware.firmware.version hardware.firmware.date hardware.cpu.model \
        hardware.cpu.logical_count hardware.memory.total_bytes \
        hardware.battery.present hardware.battery.state \
        hardware.battery.charge_percent hardware.filesystems hardware.storage; do
        emit_fact "$unknown_key" '' unsupported 'unknown platform' exact
    done
    emit_fact network.hostname "$identity_hostname" unknown "$identity_hostname_source" exact
    for unknown_key in \
        network.interfaces network.addresses network.default_route.exists \
        network.default_route.interface network.default_route.gateway \
        network.dns.resolvers; do
        emit_fact "$unknown_key" '' unsupported 'unknown platform' exact
    done
}

main()
{
    parse_arguments "$@"

    if [ "$OUTPUT_MODE" = human ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        COLOR_OUTPUT=1
    fi

    detect_platform
    if [ "$FIXTURE_MODE" -eq 1 ]; then
        COLLECTION_TIMESTAMP=1970-01-01T00:00:00Z
    elif has_command date; then
        COLLECTION_TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf unknown)
    fi

    output_begin
    collect_metadata
    collect_identity
    collect_kernel

    case "$PLATFORM_ADAPTER" in
        linux)
            collect_linux_os
            collect_linux_environment
            collect_linux_uptime
            collect_linux_hardware
            collect_linux_network
            ;;
        macos)
            collect_macos_os
            collect_macos_system
            collect_macos_hardware
            collect_macos_network
            ;;
        bsd)
            collect_bsd
            ;;
        *)
            collect_unknown
            ;;
    esac
    output_end
}

main "$@"
