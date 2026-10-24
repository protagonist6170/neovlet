#!/bin/bash
# Builds a fresh candidate in temporary storage; never installs or launches it.
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/neovlet-build.XXXXXX")
export CLANG_MODULE_CACHE_PATH="$work_directory/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$work_directory/module-cache"
exec /usr/bin/xcrun swift "$project_root/scripts/build.swift" "$work_directory" "$@"
