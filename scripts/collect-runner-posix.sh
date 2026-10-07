#!/bin/sh

# Collect public, read-only specifications from a GitHub-hosted Linux or macOS
# runner. The workflow supplies the selected label and Actions context.

set -u

fail()
{
    printf 'runner collection failed: %s\n' "$1" >&2
    exit 1
}

json_string()
{
    # GitHub image metadata and OS product strings are data, never shell code.
    # The collector emits them as JSON strings without evaluating their content.
    printf '%s' "$1" |
        tr '\r\n\t' '   ' |
        sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_field()
{
    printf '"%s":"%s"' "$1" "$(json_string "$2")"
}

read_os_release()
{
    release_key=$1
    release_value=

    [ -r /etc/os-release ] || return 0

    while IFS='=' read -r key value; do
        case "$key" in
            "$release_key")
                case "$value" in
                    \"*\") value=${value#\"}; value=${value%\"} ;;
                    \'*\') value=${value#\'}; value=${value%\'} ;;
                esac
                release_value=$value
                break
                ;;
        esac
    done < /etc/os-release

    printf '%s' "$release_value"
}

[ -n "${RUNNER_LABEL:-}" ] || fail 'RUNNER_LABEL is not set'
[ -n "${RUNNER_OS:-}" ] || fail 'RUNNER_OS is not set'
[ -n "${RUNNER_ARCH:-}" ] || fail 'RUNNER_ARCH is not set'

kernel_name=$(uname -s 2>/dev/null) || fail 'uname -s failed'
kernel_release=$(uname -r 2>/dev/null) || fail 'uname -r failed'
machine_architecture=$(uname -m 2>/dev/null) || fail 'uname -m failed'

system_name=
system_version=
system_build=
xcode_version=

case "$kernel_name" in
    Linux)
        system_name=$(read_os_release PRETTY_NAME)
        system_version=$(read_os_release VERSION_ID)
        [ -n "$system_name" ] || system_name=$(read_os_release NAME)
        ;;
    Darwin)
        command -v sw_vers >/dev/null 2>&1 || fail 'sw_vers is unavailable'
        system_name=$(sw_vers -productName 2>/dev/null) ||
            fail 'sw_vers -productName failed'
        system_version=$(sw_vers -productVersion 2>/dev/null) ||
            fail 'sw_vers -productVersion failed'
        system_build=$(sw_vers -buildVersion 2>/dev/null) ||
            fail 'sw_vers -buildVersion failed'
        if command -v xcodebuild >/dev/null 2>&1; then
            xcode_version=$(xcodebuild -version 2>/dev/null | sed -n '1p') ||
                fail 'xcodebuild -version failed'
        fi
        ;;
    *)
        fail "unsupported POSIX runner kernel $kernel_name"
        ;;
esac

collected_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
    fail 'date failed'

printf '{'
json_field schema_version 1
printf ','
json_field collected_at "$collected_at"
printf ',"runner":{'
json_field label "$RUNNER_LABEL"
printf ','
json_field os "$RUNNER_OS"
printf ','
json_field architecture "$RUNNER_ARCH"
printf '},"image":{'
json_field os "${ImageOS:-}"
printf ','
json_field version "${ImageVersion:-}"
printf '},"system":{'
json_field name "$system_name"
printf ','
json_field version "$system_version"
printf ','
json_field build "$system_build"
printf ','
json_field kernel_name "$kernel_name"
printf ','
json_field kernel_release "$kernel_release"
printf ','
json_field machine_architecture "$machine_architecture"
printf '},"tools":{'
json_field xcode_version "$xcode_version"
printf '}}\n'
