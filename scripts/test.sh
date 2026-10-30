#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p work/modules work/cache
export CLANG_MODULE_CACHE_PATH="$PWD/work/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/work/modules"
swift test --build-system native --cache-path "$PWD/work/cache" --disable-sandbox
python3 scripts/audit-source.py
