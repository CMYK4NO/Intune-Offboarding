#!/bin/bash
# Builds "Device Offboarding.app" (ad-hoc signed, not notarized) and wraps it in an installer package.
# Usage: scripts/build-pkg.sh [version]      Output: build/DeviceOffboarding-<version>.pkg
# Exit codes: 0 ok, 1 build failed, 2 packaging failed, 3 verification failed.
# Needs: Xcode command line tools (xcodebuild, pkgbuild, codesign). No interactive prompts.

appname="onBoarding"
logandmetadir="/Library/Logs/Microsoft/IntuneScripts/$appname"

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-1.0}"
out="$root/build"
app="Device Offboarding.app"
identifier="com.example.deviceoffboarding"

# Log to the standard folder when writable (run with sudo or after granting access), otherwise next to the build.
if ! mkdir -p "$logandmetadir" 2>/dev/null || [ ! -w "$logandmetadir" ]; then
  logandmetadir="$out"
  mkdir -p "$logandmetadir"
fi
log="$logandmetadir/build-pkg.log"
echo "$(date '+%F %T') build-pkg start, version $version" >> "$log"
case "$version" in *[!0-9A-Za-z._-]*|"") echo "Invalid version: use letters, digits, dot, dash or underscore"; echo "$(date '+%F %T') invalid version, stopped" >> "$log"; exit 1 ;; esac

rm -rf "$out/products" "$out/payload"
mkdir -p "$out/products" "$out/payload"

# 1. Build, ad-hoc signed ("-"), no provisioning, no notarization.
xcodebuild -project "$root/DeviceOffboarding.xcodeproj" -target DeviceOffboarding -configuration Release \
  CONFIGURATION_BUILD_DIR="$out/products" MARKETING_VERSION="$version" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual build >> "$log" 2>&1 || { echo "Build failed, see $log"; exit 1; }

# 2. Check the app is intact and signed (ad-hoc).
codesign --verify --deep --strict "$out/products/$app" >> "$log" 2>&1 || { echo "Signature check failed, see $log"; exit 3; }

# 3. Component package that installs into /Applications.
cp -R "$out/products/$app" "$out/payload/"
pkgbuild --root "$out/payload" --identifier "$identifier" --version "$version" \
  --install-location /Applications "$out/DeviceOffboarding-$version.pkg" >> "$log" 2>&1 || { echo "pkgbuild failed, see $log"; exit 2; }

echo "Created $out/DeviceOffboarding-$version.pkg (unsigned package, ad-hoc signed app)"
echo "$(date '+%F %T') build-pkg done" >> "$log"
exit 0
