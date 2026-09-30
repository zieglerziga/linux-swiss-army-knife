#!/bin/sh

# Parse project shell scripts without executing them. The repository currently
# contains interactive management code, so syntax validation must stay strictly
# separate from runtime smoke tests.

set -u

fail()
{
    printf 'POSIX validation failed: %s\n' "$1" >&2
    exit 1
}

script_path=$0
case "$script_path" in
    */*) script_directory=${script_path%/*} ;;
    *) script_directory=. ;;
esac

repository_root=$(CDPATH='' cd "$script_directory/.." 2>/dev/null && pwd) ||
    fail "cannot locate repository root"
cd "$repository_root" || fail "cannot enter repository root"

command -v git >/dev/null 2>&1 || fail "git is unavailable"

shell_files=$(git ls-files --cached --others --exclude-standard -- '*.sh') ||
    fail "cannot enumerate shell scripts"

[ -n "$shell_files" ] || fail "no shell scripts were found"

printf '%s\n' "$shell_files" |
while IFS= read -r shell_file; do
    [ -n "$shell_file" ] || continue
    [ -f "$shell_file" ] || fail "tracked script is missing: $shell_file"

    printf 'parsing with /bin/sh: %s\n' "$shell_file"
    /bin/sh -n "$shell_file" || fail "/bin/sh rejected $shell_file"

    if command -v dash >/dev/null 2>&1; then
        printf 'parsing with dash: %s\n' "$shell_file"
        dash -n "$shell_file" || fail "dash rejected $shell_file"
    fi

    if command -v bash >/dev/null 2>&1; then
        printf 'parsing with Bash POSIX mode: %s\n' "$shell_file"
        bash --posix -n "$shell_file" || fail "Bash rejected $shell_file"
    fi
done || exit 1

printf '%s\n' 'All shell files passed parse-only validation.'
