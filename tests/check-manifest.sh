#!/bin/bash
# Checks manifest.json against the rules of `omarchy plugin validate` plus the
# marketplace listing rules, so CI catches problems without an Omarchy install.

set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
M="$DIR/manifest.json"

fail() { echo "manifest: $*" >&2; exit 1; }

jq -e . "$M" >/dev/null || fail "not valid JSON"
jq -e '.schemaVersion == 1' "$M" >/dev/null || fail "schemaVersion must be 1"

for f in id name version author description kinds entryPoints; do
  jq -e --arg f "$f" 'has($f) and (.[$f] != "")' "$M" >/dev/null || fail "missing field '$f'"
done

ID=$(jq -r .id "$M")
[[ $ID =~ ^[a-z0-9][a-z0-9._-]*$ ]] || fail "id must be lowercase and namespaced: '$ID'"
[[ $ID != *".."* && $ID != omarchy.* ]] || fail "invalid or reserved id '$ID'"

jq -e '(.name | length) <= 64 and (.version | length) <= 64' "$M" >/dev/null \
  || fail "name and version must be at most 64 characters"
jq -e '(.kinds | type) == "array" and (.kinds | length) > 0' "$M" >/dev/null \
  || fail "'kinds' must be a non-empty array"

declare -A KEY=([bar]=bar [bar-widget]=barWidget [menu]=menu [overlay]=overlay [panel]=panel [service]=service)
for kind in $(jq -r '.kinds[]' "$M"); do
  key=${KEY[$kind]:-}
  [[ -n $key ]] || continue
  ep=$(jq -r --arg k "$key" '.entryPoints[$k] // ""' "$M")
  [[ -n $ep ]] || fail "kind '$kind' needs entryPoints.$key"
  [[ $ep != /* && $ep != *".."* ]] || fail "unsafe entry point '$ep'"
  [[ -f "$DIR/$ep" ]] || fail "entry point not found: $ep"
done

link=$(find "$DIR" -name .git -prune -o -type l -print -quit)
[[ -z $link ]] || fail "symlinks are not allowed: $link"

for f in README.md LICENSE; do
  [[ -f "$DIR/$f" ]] || fail "missing $f"
done

echo "manifest OK: $ID $(jq -r .version "$M")"
