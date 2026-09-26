#!/usr/bin/env bash
# Build the fork from this checkout and package it as an ad-hoc signed app.
#
#   fork/build.sh              # build + package into build/out/
#   fork/package.sh            # repackage/re-sign an existing build only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/build}"
export WORK

# Fork identity: upstream's xcconfigs #include? this file last.
cp "$ROOT/fork/Fork.xcconfig" "$ROOT/macOS/LocalOverrides.xcconfig"

# Build the macOS project, not the workspace: the workspace pulls
# DuckDuckGo's private iOS font package and fails to resolve.
xcodebuild \
    -project "$ROOT/macOS/DuckDuckGo-macOS.xcodeproj" \
    -scheme "macOS Browser" \
    -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$WORK/DD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    ONLY_ACTIVE_ARCH=YES \
    -skipPackagePluginValidation -skipMacroValidation \
    build

"$ROOT/fork/package.sh"
