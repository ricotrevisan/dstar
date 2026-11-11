#!/usr/bin/env bash
# Prints the CHANGELOG.md section for version $1 (without the heading).
# Exits 1 when the section is missing or empty.
set -euo pipefail
version=$1
notes=$(awk -v v="$version" '
  index($0, "## " v " ") == 1 { found = 1; next }
  found && /^## / { exit }
  found { print }
' CHANGELOG.md)
if [ -z "${notes//[[:space:]]/}" ]; then
  echo "::error::No '## $version' section in CHANGELOG.md" >&2
  exit 1
fi
printf '%s\n' "$notes"
