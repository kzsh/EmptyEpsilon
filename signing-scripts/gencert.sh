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

CERT_TYPE="IOS_DISTRIBUTION"
OUTPUT_DIR="$HOME/.appstoreconnect/certs"
INSTALL="1"
REVOKE=""

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Generate an iOS distribution certificate via App Store Connect API."
    echo ""
    echo "Generates a private key and CSR locally, submits the CSR to Apple,"
    echo "downloads the signed certificate, and installs it to your keychain."
    echo ""
    echo "Options:"
    echo "  -k, --key-id ID       API Key ID (default: \$ASC_API_KEY_ID)"
    echo "  -i, --issuer ID       API Issuer ID (default: \$ASC_API_ISSUER)"
    echo "  -d, --key-dir PATH    Directory containing .p8 key (default: ~/.appstoreconnect/private_keys)"
    echo "  -t, --type TYPE       Certificate type (default: IOS_DISTRIBUTION)"
    echo "                        Other: IOS_DEVELOPMENT, MAC_APP_DISTRIBUTION"
    echo "  -o, --output PATH     Directory for cert/key output (default: ~/.appstoreconnect/certs)"
    echo "  --no-install          Skip keychain installation"
    echo "  --revoke              Revoke existing certificate, clean up, and regenerate"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "Prerequisite: Create an API key at App Store Connect > Users and Access >"
    echo "  Integrations > App Store Connect API, then save the .p8 file as:"
    echo "  ${API_KEY_DIR}/AuthKey_<key-id>.p8"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -k|--key-id)   API_KEY_ID="$2";   shift 2 ;;
        -i|--issuer)   API_ISSUER="$2";   shift 2 ;;
        -d|--key-dir)  API_KEY_DIR="$2";  shift 2 ;;
        -t|--type)     CERT_TYPE="$2";    shift 2 ;;
        -o|--output)   OUTPUT_DIR="$2";   shift 2 ;;
        --no-install)  INSTALL="";        shift   ;;
        --revoke)      REVOKE="1";        shift   ;;
        -h|--help)     usage; exit 0      ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

require_asc_credentials || exit 1

API_KEY_PATH="${API_KEY_DIR}/AuthKey_${API_KEY_ID}.p8"

if [[ ! -f "$API_KEY_PATH" ]]; then
    echo "Error: API key not found at: $API_KEY_PATH"
    echo ""
    echo "Download from App Store Connect > Users and Access > Integrations > App Store Connect API"
    exit 1
fi

# Generate a JWT for the App Store Connect API (ES256).
# The .p8 key produces a DER-encoded ECDSA signature; JWT requires raw R||S format.
generate_jwt() {
    local now exp header payload sig_file sig

    now=$(date +%s)
    exp=$((now + 1200))

    header=$(printf '{"alg":"ES256","kid":"%s"}' "$API_KEY_ID" \
        | openssl base64 | tr -d '=\n' | tr '+/' '-_')
    payload=$(printf '{"iss":"%s","iat":%d,"exp":%d,"aud":"appstoreconnect-v1"}' \
        "$API_ISSUER" "$now" "$exp" \
        | openssl base64 | tr -d '=\n' | tr '+/' '-_')

    sig_file=$(mktemp)
    printf '%s.%s' "$header" "$payload" \
        | openssl dgst -sha256 -sign "$API_KEY_PATH" -out "$sig_file"

    # Convert DER ECDSA signature to raw R||S (required by JWT ES256)
    sig=$(python3 - "$sig_file" <<'EOF'
import sys, base64

data = open(sys.argv[1], 'rb').read()

idx = 1
if data[idx] & 0x80:
    idx += 1 + (data[idx] & 0x7f)
else:
    idx += 1

def read_int(data, idx):
    assert data[idx] == 0x02  # INTEGER tag
    idx += 1
    length = data[idx]; idx += 1
    return int.from_bytes(data[idx:idx+length], 'big'), idx + length

r, idx = read_int(data, idx)
s, _   = read_int(data, idx)

raw = r.to_bytes(32, 'big') + s.to_bytes(32, 'big')
print(base64.urlsafe_b64encode(raw).decode().rstrip('='), end='')
EOF
    )

    rm -f "$sig_file"
    printf '%s.%s.%s' "$header" "$payload" "$sig"
}

save_cert() {
    local body="$1"
    python3 -c "
import json, sys, base64
d = json.load(sys.stdin)
cert_b64 = d['data']['attributes']['certificateContent']
with open(sys.argv[1], 'wb') as f:
    f.write(base64.b64decode(cert_b64))
" "$CERT_PATH" <<< "$body"
}

mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"

KEY_PATH="${OUTPUT_DIR}/distribution.key"
CSR_PATH="${OUTPUT_DIR}/distribution.csr"
CERT_PATH="${OUTPUT_DIR}/distribution.cer"

# --revoke: delete the existing certificate from Apple, clean up local files and keychain
if [[ -n "$REVOKE" ]]; then
    echo "Fetching existing certificate to revoke..."
    JWT=$(generate_jwt)
    BODY_FILE=$(mktemp)
    HTTP_CODE=$(curl -sg -o "$BODY_FILE" -w "%{http_code}" \
        "https://api.appstoreconnect.apple.com/v1/certificates?filter[certificateType]=${CERT_TYPE}" \
        -H "Authorization: Bearer ${JWT}")
    BODY=$(cat "$BODY_FILE")
    rm -f "$BODY_FILE"

    CERT_ID=$(python3 -c "
import json, sys
d = json.load(sys.stdin)
items = d.get('data', [])
if not items:
    print('No existing certificate found.', file=sys.stderr)
    sys.exit(1)
print(items[0]['id'])
" <<< "$BODY")

    echo "Revoking certificate ${CERT_ID}..."
    JWT=$(generate_jwt)
    BODY_FILE=$(mktemp)
    HTTP_CODE=$(curl -sg -o "$BODY_FILE" -w "%{http_code}" -X DELETE \
        "https://api.appstoreconnect.apple.com/v1/certificates/${CERT_ID}" \
        -H "Authorization: Bearer ${JWT}")
    rm -f "$BODY_FILE"

    if [[ "$HTTP_CODE" != "204" ]]; then
        echo "Error: failed to revoke certificate (HTTP ${HTTP_CODE})"
        exit 1
    fi
    echo "Certificate revoked."

    # Remove from keychain (best effort — extract CN from cert file before deleting it)
    if [[ -f "$CERT_PATH" ]]; then
        CERT_CN=$(openssl x509 -in "$CERT_PATH" -inform DER -noout -subject 2>/dev/null \
            | sed 's/.*CN *= *//' | sed 's/,.*//' | tr -d '\n')
        if [[ -n "$CERT_CN" ]]; then
            echo "Removing \"${CERT_CN}\" from keychain..."
            security delete-certificate -c "$CERT_CN" ~/Library/Keychains/login.keychain-db 2>/dev/null \
                || echo "  (not found in keychain)"
        fi
    fi

    # Remove local files
    rm -f "$KEY_PATH" "$CSR_PATH" "$CERT_PATH"
    echo "Local files removed."
    echo ""
fi

if [[ -f "$KEY_PATH" && -f "$CERT_PATH" ]]; then
    echo "Certificate and key already exist, skipping generation."
else
    echo "Generating private key..."
    openssl genrsa -out "$KEY_PATH" 2048 2>/dev/null
    chmod 600 "$KEY_PATH"

    echo "Generating certificate signing request..."
    openssl req -new -key "$KEY_PATH" -out "$CSR_PATH" \
        -subj "/CN=iOS Distribution/O=${CERT_ORG}/C=US" 2>/dev/null

    echo "Generating API token..."
    JWT=$(generate_jwt)

    echo "Submitting CSR to App Store Connect..."
    CSR_JSON=$(python3 -c "import json, sys; print(json.dumps(open(sys.argv[1]).read()))" "$CSR_PATH")

    BODY_FILE=$(mktemp)
    HTTP_CODE=$(curl -sg -o "$BODY_FILE" -w "%{http_code}" -X POST \
        "https://api.appstoreconnect.apple.com/v1/certificates" \
        -H "Authorization: Bearer ${JWT}" \
        -H "Content-Type: application/json" \
        -d "{\"data\":{\"type\":\"certificates\",\"attributes\":{\"certificateType\":\"${CERT_TYPE}\",\"csrContent\":${CSR_JSON}}}}")
    BODY=$(cat "$BODY_FILE")
    rm -f "$BODY_FILE"

    if [[ "$HTTP_CODE" == "201" ]]; then
        echo "Certificate issued. Saving..."
        save_cert "$BODY"
    elif [[ "$HTTP_CODE" == "409" ]]; then
        echo "Error: a certificate already exists in App Store Connect."
        echo ""
        echo "This means the existing certificate was issued for a different private key."
        echo "Run with --revoke to revoke it and generate a fresh matching pair:"
        echo "  $0 --revoke"
        exit 1
    else
        echo "Error: API returned HTTP ${HTTP_CODE}"
        echo "$BODY" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for e in d.get('errors', []):
    print(f\"  {e.get('title','Unknown')}: {e.get('detail','')}\")" 2>/dev/null || echo "$BODY"
        exit 1
    fi
fi

echo ""
echo "Private key : $KEY_PATH"
echo "Certificate : $CERT_PATH"

if [[ -n "$INSTALL" ]]; then
    echo ""
    read -r -s -p "Keychain password: " KEYCHAIN_PASS
    echo
    security unlock-keychain -p "$KEYCHAIN_PASS" ~/Library/Keychains/login.keychain-db

    # Install Apple WWDR intermediate certificate (required for valid signing identity)
    echo "Installing Apple WWDR intermediate certificate..."
    WWDR_FILE=$(mktemp /tmp/AppleWWDRCA.XXXXXX.cer)
    curl -s -o "$WWDR_FILE" "https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer"
    security import "$WWDR_FILE" -k ~/Library/Keychains/login.keychain-db 2>/dev/null \
        || echo "  (already installed)"
    rm -f "$WWDR_FILE"

    security import "$KEY_PATH" -k ~/Library/Keychains/login.keychain-db \
        -T /usr/bin/codesign -T /usr/bin/security 2>/dev/null \
        || echo "  (key already in keychain)"
    security import "$CERT_PATH" -k ~/Library/Keychains/login.keychain-db 2>/dev/null \
        || echo "  (certificate already in keychain)"

    # Grant codesign partition-list access to the key (prevents errSecInternalComponent)
    echo "Setting key partition list for codesign access..."
    security set-key-partition-list -S apple-tool:,apple: -s \
        -k "$KEYCHAIN_PASS" ~/Library/Keychains/login.keychain-db
    unset KEYCHAIN_PASS

    echo ""
    echo "Done. Verify with:"
    echo "  security find-identity -v -p codesigning | grep Distribution"
fi
