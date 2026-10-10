#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
build_dir="${TOKENZ_BUILD_DIR:-$PWD/.build}"
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache"
# Tokenz is local-only: fail if networking code appears.
if grep -rnE 'URLSession|import Network|NWConnection|socket\(' Sources; then
    print -u2 "Networking code found in Sources/; Tokenz must stay local-only."
    exit 1
fi
swift test --disable-sandbox --scratch-path "$build_dir" --cache-path "$build_dir/cache"
