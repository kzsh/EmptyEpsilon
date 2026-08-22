#!/bin/bash

set -e

# Resolve the script's source path, handling symbolic links
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done

SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

# xtool dev build puts the app at xtool/${APP_NAME}.app;
# xtool dev build --ipa puts it inside xtool/Payload/
if [[ -d "${SCRIPT_DIR}/xtool/${APP_NAME}.app" ]]; then
    APP_PATH="${SCRIPT_DIR}/xtool/${APP_NAME}.app"
else
    APP_PATH="${SCRIPT_DIR}/xtool/Payload/${APP_NAME}.app"
fi

IPA_PATH="${SCRIPT_DIR}/xtool/${APP_NAME}.ipa"
PROVISIONING_PROFILE="${SCRIPT_DIR}/${APP_NAME}_appstore.mobileprovision"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"iPhone Distribution[^"]*"\|"Apple Distribution[^"]*"' | head -1 | tr -d '"')"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Prepare ${APP_NAME}.app for App Store / TestFlight distribution."
    echo ""
    echo "This script patches the app bundle, embeds a provisioning profile,"
    echo "signs with a distribution certificate, and packages as an IPA."
    echo ""
    echo "Options:"
    echo "  -i, --identity IDENTITY       Signing identity (auto-detected if omitted)"
    echo "  -p, --profile PATH            Path to .mobileprovision file"
    echo "                                (default: ${APP_NAME}_appstore.mobileprovision)"
    echo "  -a, --app PATH                Path to .app bundle (auto-detected if omitted)"
    echo "  -o, --output PATH             Output IPA path (default: xtool/${APP_NAME}.ipa)"

    echo "  -l, --list                    List available signing identities"
    echo "  -h, --help                    Show this help message"
}

list_identities() {
    echo "Available signing identities:"
    echo ""
    security find-identity -v -p codesigning | grep -i "distribution"
    echo ""
    echo "If no distribution identities appear, you may need to install your"
    echo "distribution certificate from Apple Developer Portal."
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--identity)   IDENTITY="$2";          shift 2 ;;
        -p|--profile)    PROVISIONING_PROFILE="$2"; shift 2 ;;
        -a|--app)        APP_PATH="$2";           shift 2 ;;
        -o|--output)     IPA_PATH="$2";           shift 2 ;;
-l|--list)       list_identities; exit 0  ;;
        -h|--help)       usage; exit 0            ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "$IDENTITY" ]]; then
    echo "Error: No Apple Distribution identity found in keychain."
    echo ""
    echo "Run gencert.sh to generate one, or specify manually with -i"
    echo "Use -l to list available identities."
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: App bundle not found at: $APP_PATH"
    echo ""
    echo "Run: xtool dev build"
    exit 1
fi

if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
    echo "Error: Provisioning profile not found at: $PROVISIONING_PROFILE"
    echo "Run: ./genprovision.sh"
    exit 1
fi

echo "App:      $APP_PATH"
echo "Profile:  $PROVISIONING_PROFILE"
echo "Identity: $IDENTITY"
echo "Output:   $IPA_PATH"
echo ""

# Unlock keychain
echo "Unlocking keychain (you may be prompted for your password)..."
security unlock-keychain ~/Library/Keychains/login.keychain-db

# Copy Info.plist from project root into bundle if missing
if [[ ! -f "$APP_PATH/Info.plist" ]]; then
    echo "Info.plist missing from bundle, copying from project root..."
    cp "${SCRIPT_DIR}/Info.plist" "$APP_PATH/Info.plist"
fi

# Patch Info.plist: fix bundle ID and inject SDK metadata required by App Store Connect
echo "Patching Info.plist..."
SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo "18.0")
XCODE_BUILD=$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}')
DTXCODE=$(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}' \
    | python3 -c "import sys; v=sys.stdin.read().strip().split('.'); \
      print(str(int(v[0]))+str(int(v[1]) if len(v)>1 else 0)+str(int(v[2]) if len(v)>2 else 0))")

pb() { /usr/libexec/PlistBuddy "$@"; }

for key_val in \
    "DTPlatformName:iphoneos" \
    "DTPlatformVersion:${SDK_VERSION}" \
    "DTSDKName:iphoneos${SDK_VERSION}" \
    "DTXcode:${DTXCODE}" \
    "DTXcodeBuild:${XCODE_BUILD}"; do
    key="${key_val%%:*}"
    val="${key_val#*:}"
    pb -c "Add :${key} string ${val}" "$APP_PATH/Info.plist" 2>/dev/null \
        || pb -c "Set :${key} ${val}" "$APP_PATH/Info.plist"
done

# Patch the binary's LC_BUILD_VERSION sdk field.
# xtool sets sdk = minos (deployment target) rather than the installed SDK version,
# so Apple reports "built with iOS 18.0 SDK". vtool corrects this to the real SDK.
MIN_OS=$(pb -c "Print :MinimumOSVersion" "$APP_PATH/Info.plist" 2>/dev/null || echo "18.0")
echo "Patching binary SDK version ($MIN_OS → $SDK_VERSION)..."
BINARY="$APP_PATH/${APP_NAME}"
BINARY_TMP=$(mktemp "/tmp/${APP_NAME}-binary.XXXXXX")
if vtool -arch arm64 \
    -set-build-version ios "$MIN_OS" "$SDK_VERSION" \
    -replace \
    -output "$BINARY_TMP" \
    "$BINARY" 2>/dev/null; then
    mv "$BINARY_TMP" "$BINARY"
    chmod +x "$BINARY"
else
    rm -f "$BINARY_TMP"
    echo "vtool: skipped (binary may already have correct SDK version)"
fi

# Compile asset catalog into Assets.car so App Store Connect finds the icons.
# xtool copies xcassets into a resource bundle uncompiled; Apple requires an
# asset catalog (Assets.car) for apps targeting iOS 11+. Without --app-icon,
# actool silently produces an empty catalog.
XCASSETS_PATH="${SCRIPT_DIR}/Sources/${APP_NAME}/Assets.xcassets"
if [[ -d "$XCASSETS_PATH" ]]; then
    echo "Compiling asset catalog (actool)..."
    PARTIAL_INFO=$(mktemp /tmp/actool-partial-info.XXXXXX.plist)
    xcrun actool \
        --output-format human-readable-text \
        --notices --warnings \
        --platform iphoneos \
        --minimum-deployment-target 18.0 \
        --target-device iphone \
        --target-device ipad \
        --app-icon AppIcon \
        --compress-pngs \
        --output-partial-info-plist "$PARTIAL_INFO" \
        --compile "$APP_PATH" \
        "$XCASSETS_PATH"

    # Merge actool's partial Info.plist into the bundle's Info.plist.
    # This writes the correct CFBundleIcons structure (including CFBundleIconName
    # inside CFBundlePrimaryIcon) that Apple's validator requires.
    if [[ -s "$PARTIAL_INFO" ]]; then
        python3 - "$APP_PATH/Info.plist" "$PARTIAL_INFO" <<'PYEOF'
import sys, plistlib
with open(sys.argv[1], 'rb') as f:
    info = plistlib.load(f)
with open(sys.argv[2], 'rb') as f:
    partial = plistlib.load(f)
info.update(partial)
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(info, f, fmt=plistlib.FMT_XML)
PYEOF
    fi
    rm -f "$PARTIAL_INFO"
    echo "Assets.car written to app bundle."
fi

# Extract entitlements from provisioning profile
echo "Extracting entitlements from provisioning profile..."
ENTITLEMENTS_FILE=$(mktemp /tmp/entitlements.XXXXXX.plist)
trap 'rm -f "$ENTITLEMENTS_FILE"' EXIT
security cms -D -i "$PROVISIONING_PROFILE" | python3 -c "
import sys, plistlib
profile = plistlib.loads(sys.stdin.buffer.read())
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(profile['Entitlements'], f)
" "$ENTITLEMENTS_FILE"

# Embed provisioning profile
echo "Embedding provisioning profile..."
cp "$PROVISIONING_PROFILE" "$APP_PATH/embedded.mobileprovision"

# Sign any frameworks/dylibs first
if [[ -d "$APP_PATH/Frameworks" ]]; then
    echo "Signing embedded frameworks..."
    find "$APP_PATH/Frameworks" -type d -name "*.framework" -o -type f -name "*.dylib" 2>/dev/null | while read -r item; do
        if [[ -e "$item" ]]; then
            echo "  Signing: $(basename "$item")"
            codesign --sign "$IDENTITY" --force --timestamp "$item"
        fi
    done
fi

# Sign the main app bundle
echo "Signing app bundle..."
codesign --sign "$IDENTITY" --force --timestamp --deep \
    --entitlements "$ENTITLEMENTS_FILE" "$APP_PATH"

# Verify signature
echo "Verifying signature..."
if codesign --verify --deep --strict "$APP_PATH"; then
    echo "Signature valid."
else
    echo "Error: Signature verification failed."
    exit 1
fi

# Create IPA
echo "Creating IPA..."
PAYLOAD_DIR=$(mktemp -d)
mkdir -p "$PAYLOAD_DIR/Payload"
cp -R "$APP_PATH" "$PAYLOAD_DIR/Payload/"
rm -f "$IPA_PATH"
pushd "$PAYLOAD_DIR" > /dev/null
zip -r -q "$IPA_PATH" Payload
popd > /dev/null
rm -rf "$PAYLOAD_DIR"

echo ""
echo "Distribution IPA created: $IPA_PATH"
echo ""
echo "Next step: ./submit.sh"
