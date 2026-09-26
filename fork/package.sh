#!/usr/bin/env bash
# Copy the built app out under the fork's name, drop the parts that need
# DuckDuckGo's team ID, and ad-hoc sign it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/build}"
DERIVED="$WORK/DD"
OUT="$WORK/out"
APP_NAME="${APP_NAME:-$(cat "$ROOT/fork/APP_NAME")}"

BUILT="$DERIVED/Build/Products/Release/DuckDuckGo.app"
APP="$OUT/$APP_NAME.app"
rm -rf "$APP" && mkdir -p "$OUT"
ditto "$BUILT" "$APP"

# VPN and Personal Information Removal need DuckDuckGo's team ID to run at all.
rm -rf "$APP/Contents/Library/LoginItems"

plist="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleName $APP_NAME" \
    -c "Delete :CFBundleDisplayName" -c "Add :CFBundleDisplayName string $APP_NAME" \
    -c "Delete :SUFeedURL" -c "Delete :SUPublicEDKey" \
    -c "Set :SUEnableAutomaticChecks false" \
    "$plist" 2>/dev/null || true

if [[ -f "$ROOT/fork/AppIcon.icns" ]]; then
    icon="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist" 2>/dev/null || echo AppIcon)"
    cp "$ROOT/fork/AppIcon.icns" "$APP/Contents/Resources/${icon%.icns}.icns"
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$plist" 2>/dev/null || true
fi

# Ad-hoc sign, inside out. No hardened runtime: library validation would
# reject the prebuilt OpenSSL framework under an ad-hoc signature.
find "$APP/Contents" -depth \( -name "*.framework" -o -name "*.dylib" -o -name "*.app" -o -name "*.xpc" -o -name "*.appex" \) -print0 |
    while IFS= read -r -d '' item; do codesign --force --sign - "$item"; done
codesign --force --sign - --entitlements "$ROOT/fork/adhoc.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> $APP"
