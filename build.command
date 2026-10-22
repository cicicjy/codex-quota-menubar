#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-quota-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
app_dir="$PWD/Codex Quota.app"
mkdir -p "$app_dir/Contents/MacOS"
cp Source/Info.plist "$app_dir/Contents/Info.plist"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

for target_arch in arm64 x86_64; do
  xcrun swiftc -parse-as-library -O -framework AppKit \
    -sdk "$sdk_path" -target "${target_arch}-apple-macosx13.0" \
    -module-cache-path "$build_dir/module-cache-$target_arch" \
    Source/App.swift -o "$build_dir/CodexQuota-$target_arch"
done
xcrun lipo -create "$build_dir/CodexQuota-arm64" "$build_dir/CodexQuota-x86_64" \
  -output "$app_dir/Contents/MacOS/CodexQuota"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
echo "构建完成：$app_dir"
