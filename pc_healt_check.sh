#!/bin/sh

# Compatibility entry point for the original misspelled prototype name.
# New callers should use health-check.sh directly.

set -u

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 2
printf '%s\n' 'pc_healt_check.sh is deprecated; use health-check.sh' >&2
exec "$script_directory/health-check.sh" "$@"
