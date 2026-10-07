#!/bin/sh

# Assemble the dependency-free static runner report. Collector records are
# already JSON objects; this script only packages them into an array and copies
# the hand-authored static assets.

set -eu

fail()
{
    printf 'runner site build failed: %s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 2 ] || fail 'usage: build-runner-site.sh INPUT_DIRECTORY OUTPUT_DIRECTORY'

input_directory=$1
output_directory=$2

[ -d "$input_directory" ] || fail "input directory is unavailable: $input_directory"

script_path=$0
case "$script_path" in
    */*) script_directory=${script_path%/*} ;;
    *) script_directory=. ;;
esac

repository_root=$(CDPATH= cd "$script_directory/.." 2>/dev/null && pwd) ||
    fail 'cannot locate repository root'
site_directory=$repository_root/site

[ -f "$site_directory/index.html" ] || fail 'site/index.html is unavailable'
[ -f "$site_directory/style.css" ] || fail 'site/style.css is unavailable'
[ -f "$site_directory/app.js" ] || fail 'site/app.js is unavailable'

mkdir -p "$output_directory/data"
cp "$site_directory/index.html" "$site_directory/style.css" "$site_directory/app.js" \
    "$output_directory/"

records=$(find "$input_directory" -type f -name '*.json' -print | LC_ALL=C sort) ||
    fail 'cannot enumerate collector records'
[ -n "$records" ] || fail 'no collector records were found'

dataset_path=$output_directory/data/runners.json
generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || fail 'date failed'

printf '{"schema_version":"1","generated_at":"%s","runners":[' \
    "$generated_at" > "$dataset_path"

first_record=true
printf '%s\n' "$records" |
while IFS= read -r record_path; do
    [ -n "$record_path" ] || continue
    record=$(tr -d '\r\n' < "$record_path") ||
        fail "cannot read collector record: $record_path"
    [ -n "$record" ] || fail "collector record is empty: $record_path"

    if [ "$first_record" = true ]; then
        first_record=false
    else
        printf ','
    fi
    printf '%s' "$record"
done >> "$dataset_path"

printf ']}\n' >> "$dataset_path"
printf 'Built static runner report from %s record(s).\n' \
    "$(printf '%s\n' "$records" | wc -l | tr -d ' ')"
