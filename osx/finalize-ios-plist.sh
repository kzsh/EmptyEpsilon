#!/usr/bin/env bash
#
# Inject the Info.plist keys that Xcode's "Process Info.plist" step would
# normally add, but that a plain Ninja/clang iOS build omits. Without these,
# iOS installd rejects the bundle (misleadingly: "Missing bundle ID").
#
# Usage: finalize-ios-plist.sh <Info.plist> <SupportedPlatform> <MinOS> <DTPlatformName>
#   SupportedPlatform: iPhoneOS | iPhoneSimulator
#   MinOS:             e.g. 13.0
#   DTPlatformName:    iphoneos | iphonesimulator
#
set -euo pipefail

PLIST="$1"
SUPPORTED_PLATFORM="$2"
MIN_OS="$3"
DTPLATFORM="$4"
PB=/usr/libexec/PlistBuddy

# Delete-then-Add makes this idempotent across incremental rebuilds.
set_string() {
    "$PB" -c "Delete :$1" "$PLIST" 2>/dev/null || true
    "$PB" -c "Add :$1 string $2" "$PLIST"
}

set_string MinimumOSVersion "$MIN_OS"
set_string DTPlatformName "$DTPLATFORM"

"$PB" -c "Delete :CFBundleSupportedPlatforms" "$PLIST" 2>/dev/null || true
"$PB" -c "Add :CFBundleSupportedPlatforms array" "$PLIST"
"$PB" -c "Add :CFBundleSupportedPlatforms:0 string $SUPPORTED_PLATFORM" "$PLIST"

"$PB" -c "Delete :UIDeviceFamily" "$PLIST" 2>/dev/null || true
"$PB" -c "Add :UIDeviceFamily array" "$PLIST"
"$PB" -c "Add :UIDeviceFamily:0 integer 1" "$PLIST"
"$PB" -c "Add :UIDeviceFamily:1 integer 2" "$PLIST"

echo "Finalized iOS Info.plist: $PLIST ($SUPPORTED_PLATFORM, min $MIN_OS)"
