#!/bin/sh

set -u

fail()
{
    printf 'source-policy test failed: %s\n' "$1" >&2
    exit 1
}

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) ||
    fail 'cannot resolve repository root'

policy_input=$(sed '
    /^[[:space:]]*#/d
    /^[[:space:]]*for elevation_tool in sudo doas su pkexec; do$/d
' "$repository_root/swiss.sh")
posix_forbidden='(^|[^[:alnum:]_.-])(sudo|doas|pkexec|pacman|apt|apt-get|dnf|yum|zypper|brew|curl|wget|ping|nmap|nc|mount|umount|systemctl|service|reboot|shutdown|poweroff|rm|dd|tee|chmod|chown|kill|mkfs)([^[:alnum:]_.-]|$)'
if printf '%s\n' "$policy_input" | grep -En "$posix_forbidden"; then
    fail 'swiss.sh contains a forbidden command invocation'
fi
if printf '%s\n' "$policy_input" | grep -En '(^|[^[:alnum:]_.-])(sh|bash|dash|ash)[[:space:]]+-c([^[:alnum:]_.-]|$)'; then
    fail 'swiss.sh invokes a nested command string'
fi

[ -f "$repository_root/swiss.ps1" ] || fail 'swiss.ps1 is missing'
windows_forbidden='Start-Process[[:space:]].*-Verb[[:space:]]+RunAs|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Invoke-WebRequest|Invoke-RestMethod|Test-Connection|Install-Package|Install-Module|Mount-DiskImage|Dismount-DiskImage|Restart-Computer|Stop-Computer|Start-Service|Stop-Service|Remove-Item|Set-Content|Add-Content|Out-File'
if sed '/^[[:space:]]*#/d' "$repository_root/swiss.ps1" |
    grep -Eini "$windows_forbidden"; then
    fail 'swiss.ps1 contains a forbidden operation'
fi

if grep -En 'pull_request_target|permissions:[[:space:]]*write-all|persist-credentials:[[:space:]]*true' \
    "$repository_root/.github/workflows/"*.yml \
    "$repository_root/.github/workflows/"*.yaml 2>/dev/null; then
    fail 'workflow violates the read-only security policy'
fi

printf '%s\n' 'Source-policy checks passed.'
