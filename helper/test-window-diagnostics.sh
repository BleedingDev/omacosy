#!/bin/bash
# Offline only. Build output and fixtures belong to owned-temp-dir.
set -euo pipefail
: "${OWNED_TEMP_DIR:?run with owned-temp-dir --run omacosy-diagnostics -- bash helper/test-window-diagnostics.sh}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$OWNED_TEMP_DIR/build"
mkdir "$build"
owner="omacosy-diagnostics-$$"
"$HOME/bin/disk-guardian-artifacts" register "$build" --owner "$owner" --owner-pid "$$" --grace-hours 24 --kind build >/dev/null
cleanup() {
  "$HOME/bin/disk-guardian-artifacts" release "$build" --owner "$owner" >/dev/null
  "$HOME/bin/disk-guardian-artifacts" cleanup --only "$build" --no-caches --apply >/dev/null
}
trap cleanup EXIT
cache="$build/module-cache"
swiftc -O -module-cache-path "$cache" -o "$build/diagnostics-tests" \
  "$repo/helper/test-window-diagnostics.swift" "$repo/helper/window-diagnostics.swift" "$repo/helper/zone-monitor-policy.swift"
"$build/diagnostics-tests"
swiftc -O -module-cache-path "$cache" -F /System/Library/PrivateFrameworks -framework DisplayServices \
  -o "$build/omacosy-helper" "$repo/helper/main.swift" "$repo/helper/zones.swift" "$repo/helper/pins.swift" \
  "$repo/helper/zone-monitor-policy.swift" "$repo/helper/window-diagnostics.swift"
"$build/omacosy-helper" zones self-test
"$build/omacosy-helper" pins self-test
swiftc -O -module-cache-path "$cache" -F /System/Library/PrivateFrameworks -framework SkyLight \
  -o "$build/omacosy-ffm" "$repo/helper/ffm.swift" "$repo/helper/window-lifecycle.swift" "$repo/helper/window-diagnostics.swift"
bash -n "$repo/install.sh"
# A retained release is only produced when explicitly requested. No live
# executable, launch agent, configuration or symlink is ever changed here.
if [ -n "${OMACOSY_PENDING_RELEASE:-}" ]; then
  test ! -e "$OMACOSY_PENDING_RELEASE"
  for component in helper ffm; do
    "$repo/bin/omacosy-sign" "$build/omacosy-$component" "com.omacosy.$component"
  done
  mkdir -p "$OMACOSY_PENDING_RELEASE"
  printf '%s\n' 'Pending user-requested release; NOT ACTIVE.' \
    'Owner: omacosy-iina-20260927. Retain until activation or rejection.' \
    'Cleanup: remove this exact release directory after acceptance or rejection; never delete live executables.' \
    > "$OMACOSY_PENDING_RELEASE/OWNER.txt"
  cp "$build/omacosy-helper" "$build/omacosy-ffm" "$OMACOSY_PENDING_RELEASE/"
fi
printf '%s\n' 'PASS: both production executables compile; offline checks complete; nothing activated'
