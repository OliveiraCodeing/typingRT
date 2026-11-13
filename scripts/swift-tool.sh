#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p .build/module-cache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"
command_name="${1:-build}"
if [ "$#" -gt 0 ]; then shift; fi
if [ "$command_name" = "test" ]; then
    # CLT 6.4's Swift Build engine can omit TestingMacros after switching
    # between build and test. Explicitly load the installed toolchain plugin.
    developer_directory="$(xcode-select -p)"
    testing_macros="$developer_directory/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    if [ -f "$testing_macros" ]; then
        set -- -Xswiftc -load-plugin-library -Xswiftc "$testing_macros" "$@"
    fi
fi
exec swift "$command_name" --disable-sandbox \
    --cache-path "$project_root/.build/cache" \
    --config-path "$project_root/.build/config" \
    --security-path "$project_root/.build/security" \
    -Xswiftc -module-cache-path -Xswiftc "$project_root/.build/module-cache" "$@"
