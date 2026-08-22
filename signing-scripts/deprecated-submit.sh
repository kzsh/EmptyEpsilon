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

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Submit ${APP_NAME}.ipa to App Store Connect / TestFlight using altool."
    echo ""
    echo "NOTE: altool is deprecated. Use submit.sh with Transporter when possible."
    echo ""
    echo "Options:"
    echo "  -f, --file PATH       Path to IPA file (default: xtool/${APP_NAME}.ipa)"
    echo "  -k, --key-id ID       API Key ID (default: ${API_KEY_ID})"
    echo "  -i, --issuer ID       API Issuer ID (default: ${API_ISSUER})"
    echo "  -v, --validate        Validate only, don't upload"
    echo "  -h, --help            Show this help message"
}

VALIDATE_ONLY=""

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
        -v|--validate)
            VALIDATE_ONLY="1"
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

if [[ ! -f "$IPA_PATH" ]]; then
    echo "Error: IPA not found at: $IPA_PATH"
    echo ""
    echo "Build the IPA first using xtool or your build script."
    exit 1
fi

echo "WARNING: altool is deprecated. Use submit.sh with Transporter when possible."
echo ""
echo "IPA: $IPA_PATH"
echo "API Key: $API_KEY_ID"
echo "Issuer: $API_ISSUER"
echo ""

if [[ -n "$VALIDATE_ONLY" ]]; then
    echo "Validating IPA..."
    if xcrun altool --validate-app -f "$IPA_PATH" -t ios --apiKey "$API_KEY_ID" --apiIssuer "$API_ISSUER"; then
        echo ""
        echo "Validation complete."
    else
        echo ""
        echo "Validation failed."
        exit 1
    fi
else
    echo "Uploading to App Store Connect..."
    if xcrun altool --upload-app -f "$IPA_PATH" -t ios --apiKey "$API_KEY_ID" --apiIssuer "$API_ISSUER"; then
        echo ""
        echo "Upload complete. Check App Store Connect for processing status."
    else
        echo ""
        echo "Upload failed."
        exit 1
    fi
fi
