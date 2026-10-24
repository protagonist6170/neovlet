#!/bin/bash
# Produces local signed/notarized assets. Upload and publication are separate actions.
set -euo pipefail

if [[ ${1:-} == --help ]]; then
  echo 'Usage: bash scripts/release.sh VERSION BUILD_NUMBER DEVELOPER_ID_IDENTITY NOTARY_KEYCHAIN_PROFILE [OUTPUT_DIRECTORY]'
  exit 0
fi
if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo 'Use --help for release arguments.' >&2
  exit 2
fi
release_version=$1
release_build=$2
release_identity=$3
notary_profile=$4
if [[ ! $release_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! $release_build =~ ^[0-9]+$ || $release_identity == - || -z $notary_profile ]]; then
  echo 'A numeric version/build, Developer ID identity and Keychain profile are required.' >&2
  exit 2
fi
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Validate before writing assets, including when the output directory is inside the checkout.
source_commit=$(git -C "$project_root" rev-parse --verify "refs/tags/v$release_version^{commit}")
test "$(git -C "$project_root" rev-parse HEAD)" = "$source_commit"
test -z "$(git -C "$project_root" status --porcelain)"
release_directory=${5:-$(mktemp -d "${TMPDIR:-/tmp}/neovlet-release.XXXXXX")}
mkdir -p -- "$release_directory"
release_directory=$(cd -- "$release_directory" && pwd)
asset="$release_directory/Neovlet-$release_version-macos-arm64.zip"
if [[ -e "$asset" || -e "$release_directory/SHA256SUMS" ]]; then
  echo 'Release assets already exist; choose a fresh output directory.' >&2
  exit 2
fi
# Pin the source and require a clean worktree for a traceable public build.
printf '%s\n' "$source_commit" > "$release_directory/source-commit.txt"
export CLANG_MODULE_CACHE_PATH="$release_directory/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$release_directory/module-cache"
xcrun swift test --package-path "$project_root" --scratch-path "$release_directory/tests" \
  --cache-path "$release_directory/cache" --config-path "$release_directory/config" \
  --security-path "$release_directory/security" --disable-sandbox
bash "$project_root/scripts/build.sh" --distribution --identity "$release_identity" \
  --version "$release_version" --build-number "$release_build" > "$release_directory/build.log"
app_path=$(tail -n 1 "$release_directory/build.log")
test -d "$app_path"
submission="$release_directory/notary-submission.zip"
ditto -c -k --keepParent "$app_path" "$submission"
xcrun notarytool submit "$submission" --keychain-profile "$notary_profile" --wait \
  --output-format json > "$release_directory/notary-result.json"
submission_id=$(plutil -extract id raw "$release_directory/notary-result.json")
xcrun notarytool log "$submission_id" --keychain-profile "$notary_profile" "$release_directory/notary-log.json"
test "$(plutil -extract status raw "$release_directory/notary-result.json")" = Accepted
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
codesign --verify --deep --strict "$app_path"
spctl --assess --type execute --verbose "$app_path"
ditto -c -k --keepParent "$app_path" "$asset"
(cd -- "$release_directory" && shasum -a 256 "$(basename -- "$asset")" > SHA256SUMS)
echo "Assets ready for distribution acceptance (not uploaded): $asset"
