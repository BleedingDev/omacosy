#!/bin/bash
# Builds omacosy-helper offline and runs its zone self-test. With
# OMACOSY_DEPLOY=1 it signs the build and atomically replaces the live binary.
# It never runs zones sync, moves or focuses windows, or restarts anything;
# the next normal sync picks the new placement up.
set -euo pipefail
: "${OWNED_TEMP_DIR:?run with owned-temp-dir --run omacosy-zones -- bash helper/deploy-zones.sh}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$OWNED_TEMP_DIR/build"
mkdir "$build"
# Same sources as install.sh, so this never drifts from a normal install.
sources=()
while read -r source; do sources+=("$repo/$source"); done < <(
  sed -n 's|.*-o "$HOME/.local/bin/omacosy-helper" ||p' "$repo/install.sh" | grep -o 'helper/[a-z-]*\.swift')
[ "${#sources[@]}" -gt 0 ]
swiftc -O -module-cache-path "$build/module-cache" -F /System/Library/PrivateFrameworks -framework DisplayServices \
  -o "$build/omacosy-helper" "${sources[@]}"
"$build/omacosy-helper" zones self-test
"$build/omacosy-helper" pins self-test
[ "${OMACOSY_DEPLOY:-}" = 1 ] || { echo 'PASS: offline build and self-tests; nothing deployed'; exit 0; }
"$repo/bin/omacosy-sign" "$build/omacosy-helper" com.omacosy.helper
live="$HOME/.local/bin/omacosy-helper"
staged="$(mktemp "$live.XXXXXX")"
trap 'rm -f "$staged"' EXIT
cp "$build/omacosy-helper" "$staged"
chmod 755 "$staged"
/usr/bin/codesign --verify --strict "$staged"
mv -f "$staged" "$live"
/usr/bin/codesign --verify --strict "$live"
shasum -a 256 "$live"
echo 'PASS: deployed omacosy-helper; no sync was triggered'
