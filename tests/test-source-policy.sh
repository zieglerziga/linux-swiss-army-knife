#!/bin/sh

set -u

fail()
{
    printf 'source-policy test failed: %s\n' "$1" >&2
    exit 1
}

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) ||
    fail 'cannot resolve repository root'
command -v python3 >/dev/null 2>&1 || fail 'python3 is required for structural source audit'

python3 "$repository_root/scripts/audit-posix-commands.py" \
    "$repository_root/schema/posix-command-allowlist.txt" \
    "$repository_root/swiss.sh" ||
    fail 'swiss.sh command allowlist audit failed'

test_directory=$(mktemp -d "${TMPDIR:-/tmp}/swiss-policy.XXXXXX") ||
    fail 'cannot create source-policy test directory'
trap 'rm -rf "$test_directory"' EXIT HUP INT TERM
for unsafe_snippet in \
    'unsafe() { mv /tmp/a /tmp/b; }' \
    'unsafe() { printf data > /tmp/output; }' \
    "unsafe() { \"\$probe\" --run; }"; do
    cp "$repository_root/swiss.sh" "$test_directory/unsafe.sh"
    printf '\n%s\n' "$unsafe_snippet" >>"$test_directory/unsafe.sh"
    if python3 "$repository_root/scripts/audit-posix-commands.py" \
        "$repository_root/schema/posix-command-allowlist.txt" \
        "$test_directory/unsafe.sh" >/dev/null 2>&1; then
        fail "structural allowlist accepted: $unsafe_snippet"
    fi
done

policy_input=$(sed '
    /^[[:space:]]*#/d
    /^[[:space:]]*for elevation_tool in sudo doas su pkexec; do$/d
' "$repository_root/swiss.sh")
posix_forbidden='(^|[^[:alnum:]_.-])(sudo|doas|pkexec|pacman|apt|apt-get|dnf|yum|zypper|brew|curl|wget|ping|nmap|nc|ssh|sftp|ftp|socat|telnet|mount|umount|systemctl|service|reboot|shutdown|poweroff|rm|mv|cp|touch|truncate|dd|tee|chmod|chown|kill|mkfs|networksetup|defaults|eval|exec)([^[:alnum:]_.-]|$)'
if printf '%s\n' "$policy_input" | grep -En "$posix_forbidden"; then
    fail 'swiss.sh contains a forbidden command invocation'
fi
if printf '%s\n' "$policy_input" | grep -En '(^|[^[:alnum:]_.-])(sh|bash|dash|ash)[[:space:]]+-c([^[:alnum:]_.-]|$)'; then
    fail 'swiss.sh invokes a nested command string'
fi

[ -f "$repository_root/swiss.ps1" ] || fail 'swiss.ps1 is missing'
windows_forbidden='Start-Process[[:space:]].*-Verb[[:space:]]+RunAs|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Invoke-WebRequest|Invoke-RestMethod|Test-Connection|Install-Package|Install-Module|Mount-DiskImage|Dismount-DiskImage|Restart-Computer|Stop-Computer|Start-Service|Stop-Service|Remove-Item|New-Item|Move-Item|Copy-Item|Set-Content|Add-Content|Out-File|Format-Volume|Set-NetAdapter|System\.Net\.|System\.IO\.File'
if sed '/^[[:space:]]*#/d' "$repository_root/swiss.ps1" |
    grep -Eini "$windows_forbidden"; then
    fail 'swiss.ps1 contains a forbidden operation'
fi

for workflow_path in \
    "$repository_root/.github/workflows/"*.yml \
    "$repository_root/.github/workflows/"*.yaml; do
    [ -e "$workflow_path" ] || continue
    if grep -En 'pull_request_target|permissions:[[:space:]]*write-all|persist-credentials:[[:space:]]*true' \
        "$workflow_path"; then
        fail 'workflow violates the read-only security policy'
    fi
done

printf '%s\n' 'Source-policy checks passed.'
