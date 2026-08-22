#!/bin/bash

set -e

# Resolve the script's source path, handling symbolic links
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  # Resolve symbolic link
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  # If the symbolic link points to a relative path, resolve it relative to the symlink's directory
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done

# Get the script's directory
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

APP_PATH="${SCRIPT_DIR}/xtool/${APP_NAME}.app"
ENTITLEMENTS_PATH="${SCRIPT_DIR}/${APP_NAME}.entitlements"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Sign the ${APP_NAME}.app bundle using codesign."
    echo ""
    echo "Options:"
    echo "  -i, --identity IDENTITY   Signing identity (certificate name or SHA-1 hash)"
    echo "                            Use 'security find-identity -v -p codesigning' to list available"
    echo "  -e, --entitlements FILE   Path to entitlements file (default: ${APP_NAME}.entitlements if exists)"
    echo "  -a, --app PATH            Path to .app bundle (default: xtool/${APP_NAME}.app)"
    echo "  -f, --force               Replace any existing signature"
    echo "  -v, --verify              Verify signature after signing"
    echo "  -l, --list                List available signing identities and exit"
    echo "  -h, --help                Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -i \"Apple Development: you@example.com\" -v"
    echo "  $0 -i ABCD1234... --force --verify"
    echo "  $0 --list"
}

list_identities() {
    echo "Available signing identities:"
    echo ""
    security find-identity -v -p codesigning
}

IDENTITY=""
FORCE=""
VERIFY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--identity)
            IDENTITY="$2"
            shift 2
            ;;
        -e|--entitlements)
            ENTITLEMENTS_PATH="$2"
            shift 2
            ;;
        -a|--app)
            APP_PATH="$2"
            shift 2
            ;;
        -f|--force)
            FORCE="--force"
            shift
            ;;
        -v|--verify)
            VERIFY="1"
            shift
            ;;
        -l|--list)
            list_identities
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$IDENTITY" ]]; then
    echo "Error: Signing identity is required."
    echo ""
    echo "Use -l to list available identities, then specify one with -i"
    echo ""
    usage
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: App bundle not found at: $APP_PATH"
    echo ""
    echo "Run package.sh or install.sh first to build the app."
    exit 1
fi

ENTITLEMENTS_ARG=""
if [[ -f "$ENTITLEMENTS_PATH" ]]; then
    echo "Using entitlements: $ENTITLEMENTS_PATH"
    ENTITLEMENTS_ARG="--entitlements $ENTITLEMENTS_PATH"
fi

# Unlock the keychain to avoid errSecInternalComponent errors
echo "Unlocking keychain (you may be prompted for your password)..."
security unlock-keychain ~/Library/Keychains/login.keychain-db

echo "Signing: $APP_PATH"
echo "Identity: $IDENTITY"

# Sign any frameworks/dylibs first (nested code must be signed before the main bundle)
if [[ -d "$APP_PATH/Frameworks" ]]; then
    echo "Signing embedded frameworks..."
    find "$APP_PATH/Frameworks" -type d -name "*.framework" -o -type f -name "*.dylib" 2>/dev/null | while read -r item; do
        if [[ -e "$item" ]]; then
            echo "  Signing: $(basename "$item")"
            codesign --sign "$IDENTITY" $FORCE --timestamp "$item"
        fi
    done
fi

# Sign the main app bundle
echo "Signing main bundle..."
codesign --sign "$IDENTITY" $FORCE --timestamp --deep $ENTITLEMENTS_ARG "$APP_PATH"

echo "Signing complete."

if [[ -n "$VERIFY" ]]; then
    echo ""
    echo "Verifying signature..."
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    echo ""
    echo "Checking signature details..."
    codesign -dv --verbose=4 "$APP_PATH" 2>&1 | head -20
fi
