#!/bin/sh

# Validate the hosted runner selected by the workflow. This script reads only
# local runner metadata and deliberately avoids executing project entry points.

set -u

fail()
{
    printf 'runner validation failed: %s\n' "$1" >&2
    exit 1
}

[ -n "${RUNNER_LABEL:-}" ] || fail "RUNNER_LABEL is not set"
[ -n "${EXPECTED_RUNNER_OS:-}" ] || fail "EXPECTED_RUNNER_OS is not set"
[ -n "${EXPECTED_RUNNER_ARCH:-}" ] || fail "EXPECTED_RUNNER_ARCH is not set"
[ -n "${EXPECTED_OS_VERSION:-}" ] || fail "EXPECTED_OS_VERSION is not set"
[ -n "${EXPECTED_XCODE_MAJOR:-}" ] || fail "EXPECTED_XCODE_MAJOR is not set"
[ -n "${ACTUAL_RUNNER_OS:-}" ] || fail "ACTUAL_RUNNER_OS is not set"
[ -n "${ACTUAL_RUNNER_ARCH:-}" ] || fail "ACTUAL_RUNNER_ARCH is not set"

[ "$ACTUAL_RUNNER_OS" = "$EXPECTED_RUNNER_OS" ] ||
    fail "expected runner OS $EXPECTED_RUNNER_OS, got $ACTUAL_RUNNER_OS"
[ "$ACTUAL_RUNNER_ARCH" = "$EXPECTED_RUNNER_ARCH" ] ||
    fail "expected runner architecture $EXPECTED_RUNNER_ARCH, got $ACTUAL_RUNNER_ARCH"

kernel_name=$(uname -s 2>/dev/null) || fail "uname -s failed"
machine_arch=$(uname -m 2>/dev/null) || fail "uname -m failed"

case "$EXPECTED_RUNNER_OS" in
    Linux)
        [ "$kernel_name" = Linux ] || fail "expected Linux kernel, got $kernel_name"

        case "$EXPECTED_RUNNER_ARCH:$machine_arch" in
            X64:x86_64|ARM64:aarch64|ARM64:arm64)
                ;;
            *)
                fail "unexpected Linux machine architecture $machine_arch"
                ;;
        esac

        [ -r /etc/os-release ] || fail "/etc/os-release is unavailable"
        detected_id=unknown
        detected_version=unknown
        while IFS='=' read -r release_key release_value; do
            case "$release_value" in
                \"*\")
                    release_value=${release_value#\"}
                    release_value=${release_value%\"}
                    ;;
                \'*\')
                    release_value=${release_value#\'}
                    release_value=${release_value%\'}
                    ;;
            esac

            case "$release_key" in
                ID) detected_id=$release_value ;;
                VERSION_ID) detected_version=$release_value ;;
            esac
        done < /etc/os-release

        [ "$detected_id" = ubuntu ] ||
            fail "expected Ubuntu distribution ID, got $detected_id"

        if [ "$EXPECTED_OS_VERSION" != any ]; then
            [ "$detected_version" = "$EXPECTED_OS_VERSION" ] ||
                fail "expected Ubuntu $EXPECTED_OS_VERSION, got $detected_version"
        fi
        ;;
    macOS)
        [ "$kernel_name" = Darwin ] || fail "expected Darwin kernel, got $kernel_name"

        case "$EXPECTED_RUNNER_ARCH:$machine_arch" in
            X64:x86_64|ARM64:arm64)
                ;;
            *)
                fail "unexpected macOS machine architecture $machine_arch"
                ;;
        esac

        command -v sw_vers >/dev/null 2>&1 || fail "sw_vers is unavailable"
        detected_version=$(sw_vers -productVersion 2>/dev/null) ||
            fail "sw_vers -productVersion failed"
        case "$detected_version" in
            "$EXPECTED_OS_VERSION"|"$EXPECTED_OS_VERSION".*)
                ;;
            *)
                fail "expected macOS $EXPECTED_OS_VERSION, got $detected_version"
                ;;
        esac

        if [ "$EXPECTED_XCODE_MAJOR" != none ]; then
            command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is unavailable"
            xcode_version=$(xcodebuild -version 2>/dev/null) ||
                fail "xcodebuild -version failed"
            xcode_first_line=$(printf '%s\n' "$xcode_version" | sed -n '1p')
            case "$xcode_first_line" in
                "Xcode $EXPECTED_XCODE_MAJOR"|"Xcode $EXPECTED_XCODE_MAJOR".*)
                    ;;
                *)
                    fail "expected Xcode $EXPECTED_XCODE_MAJOR"
                    ;;
            esac
        fi
        ;;
    *)
        fail "unsupported expected runner OS $EXPECTED_RUNNER_OS"
        ;;
esac

printf 'runner label: %s\n' "$RUNNER_LABEL"
printf 'runner context: %s/%s\n' "$ACTUAL_RUNNER_OS" "$ACTUAL_RUNNER_ARCH"
printf 'kernel: %s %s\n' "$kernel_name" "$machine_arch"
printf 'operating system version: %s\n' "$detected_version"
