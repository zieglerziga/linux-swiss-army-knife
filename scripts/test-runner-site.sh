#!/bin/sh

# Exercise the static-site assembler with committed, non-identifying fixtures.

set -eu

fail()
{
    printf 'runner site test failed: %s\n' "$1" >&2
    exit 1
}

script_path=$0
case "$script_path" in
    */*) script_directory=${script_path%/*} ;;
    *) script_directory=. ;;
esac

repository_root=$(CDPATH='' cd "$script_directory/.." 2>/dev/null && pwd) ||
    fail 'cannot locate repository root'
fixture_directory=$repository_root/tests/runner-data
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/runner-site.XXXXXX") ||
    fail 'cannot create temporary directory'
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

sh "$repository_root/scripts/build-runner-site.sh" \
    "$fixture_directory" "$temporary_directory/site"

for expected_file in index.html style.css app.js data/runners.json; do
    [ -f "$temporary_directory/site/$expected_file" ] ||
        fail "missing generated file: $expected_file"
done

command -v ruby >/dev/null 2>&1 || fail 'Ruby is required to validate JSON fixtures'
ruby -rjson -e '
  data = JSON.parse(File.read(ARGV.fetch(0)))
  abort "unexpected schema version" unless data.fetch("schema_version") == "1"
  records = data.fetch("runners")
  abort "expected three fixture records" unless records.length == 3
  abort "runner schema versions must be numeric" unless records.all? { |record| record.fetch("schema_version") == 1 }
  labels = records.map { |record| record.fetch("runner").fetch("label") }.sort
  abort "unexpected fixture labels" unless labels == ["macos-15", "ubuntu-24.04", "windows-2025"]
' "$temporary_directory/site/data/runners.json" || fail 'generated dataset is invalid'

workflow_path=$repository_root/.github/workflows/publish-runner-specifications.yml
grep -F "if: github.ref == format('refs/heads/{0}', github.event.repository.default_branch)" \
    "$workflow_path" >/dev/null || fail 'Pages deploy is not restricted to the default branch'
grep -F 'Filter runners' "$repository_root/site/index.html" >/dev/null ||
    fail 'runner filter label is missing'

printf '%s\n' 'Static runner report tests passed.'
