#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
runtime="${TRAVELSELECT_TEST_BUILD_PATH:-/private/tmp/TravelSelect-tests-$UID}"
mkdir -p "$runtime"
export CLANG_MODULE_CACHE_PATH="$runtime/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$runtime/ModuleCache"
swift test --scratch-path "$runtime/swift" --cache-path "$runtime/package-cache" --disable-sandbox "$@"
