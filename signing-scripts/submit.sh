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

IPA_PATH="${SCRIPT_DIR}/xtool/${APP_NAME}.ipa"

TRANSPORTER="/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Submit ${APP_NAME}.ipa to App Store Connect / TestFlight using iTMSTransporter."
    echo ""
    echo "Options:"
    echo "  -f, --file PATH       Path to IPA file (default: xtool/${APP_NAME}.ipa)"
    echo "  -k, --key-id ID       API Key ID (default: ${API_KEY_ID})"
    echo "  -i, --issuer ID       API Issuer ID (default: ${API_ISSUER})"
    echo "  -d, --key-dir PATH    Directory containing .p8 key (default: ~/.appstoreconnect/private_keys)"
    echo "  -v, --verify          Verify only, don't upload"
    echo "  -q, --quiet           Minimal output"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "Note: Your API key (.p8 file) must be in the key directory as AuthKey_<key-id>.p8"
}

VERIFY_ONLY=""
VERBOSITY="detailed"

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            IPA_PATH="$2"
            shift 2
            ;;
        -k|--key-id)
            API_KEY_ID="$2"
            shift 2
            ;;
        -i|--issuer)
            API_ISSUER="$2"
            shift 2
            ;;
        -d|--key-dir)
            API_KEY_DIR="$2"
            shift 2
            ;;
        -v|--verify)
            VERIFY_ONLY="1"
            shift
            ;;
        -q|--quiet)
            VERBOSITY="off"
            shift
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

require_asc_credentials || exit 1

API_KEY_PATH="${API_KEY_DIR}/AuthKey_${API_KEY_ID}.p8"

if [[ ! -x "$TRANSPORTER" ]]; then
    echo "Error: iTMSTransporter not found at: $TRANSPORTER"
    echo ""
    echo "Install Transporter from the Mac App Store:"
    echo "  https://apps.apple.com/app/transporter/id1450874784"
    exit 1
fi

if [[ ! -f "$IPA_PATH" ]]; then
    echo "Error: IPA not found at: $IPA_PATH"
    echo ""
    echo "Build the IPA first using xtool or your build script."
    exit 1
fi

if [[ ! -f "$API_KEY_PATH" ]]; then
    echo "Error: API key not found at: $API_KEY_PATH"
    echo ""
    echo "Place your .p8 key file at: $API_KEY_PATH"
    echo "Download from App Store Connect > Users and Access > Integrations > App Store Connect API"
    exit 1
fi

echo "IPA: $IPA_PATH"
echo "API Key: $API_KEY_ID"
echo "Issuer: $API_ISSUER"
echo ""

if [[ -n "$VERIFY_ONLY" ]]; then
    echo "Verifying IPA..."
    "$TRANSPORTER" -m verify \
        -f "$IPA_PATH" \
        -apiKey "$API_KEY_ID" \
        -apiIssuer "$API_ISSUER" \
        -v "$VERBOSITY"
    echo ""
    echo "Verification complete."
else
    echo "Uploading to App Store Connect..."
    "$TRANSPORTER" -m upload \
        -assetFile "$IPA_PATH" \
        -apiKey "$API_KEY_ID" \
        -apiIssuer "$API_ISSUER" \
        -v "$VERBOSITY"
    echo ""
    echo "Upload complete. Check App Store Connect for processing status."
fi
