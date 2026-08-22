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

OUTPUT_PATH="${SCRIPT_DIR}/${APP_NAME}_appstore.mobileprovision"
FORCE=""

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Generate an App Store distribution provisioning profile via App Store Connect API."
    echo ""
    echo "Looks up the bundle ID and distribution certificate, creates (or re-downloads)"
    echo "an App Store profile, and saves it as ${APP_NAME}_appstore.mobileprovision."
    echo ""
    echo "Options:"
    echo "  -k, --key-id ID       API Key ID (default: \$ASC_API_KEY_ID)"
    echo "  -i, --issuer ID       API Issuer ID (default: \$ASC_API_ISSUER)"
    echo "  -d, --key-dir PATH    Directory containing .p8 key (default: ~/.appstoreconnect/private_keys)"
    echo "  -b, --bundle-id ID    Bundle identifier (default: ${BUNDLE_ID})"
    echo "  -n, --name NAME       Profile name (default: \"${PROFILE_NAME}\")"
    echo "  -o, --output PATH     Output path (default: ${APP_NAME}_appstore.mobileprovision)"
    echo "  -f, --force           Re-create profile even if output file already exists"
    echo "  -h, --help            Show this help message"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -k|--key-id)    API_KEY_ID="$2";    shift 2 ;;
        -i|--issuer)    API_ISSUER="$2";    shift 2 ;;
        -d|--key-dir)   API_KEY_DIR="$2";   shift 2 ;;
        -b|--bundle-id) BUNDLE_ID="$2";     shift 2 ;;
        -n|--name)      PROFILE_NAME="$2";  shift 2 ;;
        -o|--output)    OUTPUT_PATH="$2";   shift 2 ;;
        -f|--force)     FORCE="1";          shift   ;;
        -h|--help)      usage; exit 0       ;;
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

if [[ -f "$OUTPUT_PATH" && -z "$FORCE" ]]; then
    echo "Profile already exists at: $OUTPUT_PATH"
    echo "Run with --force to re-download."
    exit 0
fi

# Generate a JWT for the App Store Connect API (ES256).
# Called once at the top level to avoid heredoc issues in nested subshells.
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

    sig=$(python3 - "$sig_file" <<'EOF'
import sys, base64

data = open(sys.argv[1], 'rb').read()

idx = 1
if data[idx] & 0x80:
    idx += 1 + (data[idx] & 0x7f)
else:
    idx += 1

def read_int(data, idx):
    assert data[idx] == 0x02
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

# $1 = jwt, $2 = url
api_get() {
    local jwt="$1" url="$2"
    local body_file http_code body
    body_file=$(mktemp)
    http_code=$(curl -sg -o "$body_file" -w "%{http_code}" \
        "$url" \
        -H "Authorization: Bearer ${jwt}")
    body=$(cat "$body_file")
    rm -f "$body_file"
    if [[ "$http_code" != "200" ]]; then
        echo "Error: GET $url returned HTTP ${http_code}" >&2
        echo "$body" >&2
        exit 1
    fi
    echo "$body"
}

# $1 = jwt, $2 = url, $3 = json payload, $4 = output file for body
api_post() {
    local jwt="$1" url="$2" payload="$3" out_file="$4"
    local http_code
    http_code=$(curl -sg -o "$out_file" -w "%{http_code}" -X POST \
        "$url" \
        -H "Authorization: Bearer ${jwt}" \
        -H "Content-Type: application/json" \
        -d "$payload")
    echo "$http_code"
}

save_profile() {
    local body="$1"
    python3 -c "
import json, sys, base64
d = json.load(sys.stdin)
content = d['data']['attributes']['profileContent']
with open(sys.argv[1], 'wb') as f:
    f.write(base64.b64decode(content))
" "$OUTPUT_PATH" <<< "$body"
}

echo "Generating API token..."
JWT=$(generate_jwt)

# Look up bundle ID record
echo "Looking up bundle ID: ${BUNDLE_ID}..."
BUNDLE_RESPONSE=$(api_get "$JWT" "https://api.appstoreconnect.apple.com/v1/bundleIds?filter[identifier]=${BUNDLE_ID}&filter[platform]=IOS")
BUNDLE_RECORD_ID=$(python3 -c "
import json, sys
d = json.load(sys.stdin)
items = d.get('data', [])
if not items:
    print('Bundle ID not found: ${BUNDLE_ID}', file=sys.stderr)
    sys.exit(1)
print(items[0]['id'])
" <<< "$BUNDLE_RESPONSE")
echo "  Found: ${BUNDLE_RECORD_ID}"

# Look up distribution certificate
echo "Looking up distribution certificate..."
CERT_RESPONSE=$(api_get "$JWT" "https://api.appstoreconnect.apple.com/v1/certificates?filter[certificateType]=IOS_DISTRIBUTION")
CERT_ID=$(python3 -c "
import json, sys
d = json.load(sys.stdin)
items = d.get('data', [])
if not items:
    print('No IOS_DISTRIBUTION certificate found. Run gencert.sh first.', file=sys.stderr)
    sys.exit(1)
print(items[0]['id'])
" <<< "$CERT_RESPONSE")
echo "  Found: ${CERT_ID}"

# Check if a profile with this name already exists
echo "Checking for existing profile: \"${PROFILE_NAME}\"..."
ENCODED_NAME=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$PROFILE_NAME")
EXISTING_RESPONSE=$(api_get "$JWT" "https://api.appstoreconnect.apple.com/v1/profiles?filter[name]=${ENCODED_NAME}&filter[profileType]=IOS_APP_STORE")
EXISTING_ID=$(python3 -c "
import json, sys
d = json.load(sys.stdin)
items = d.get('data', [])
print(items[0]['id'] if items else '')
" <<< "$EXISTING_RESPONSE")

if [[ -n "$EXISTING_ID" && -z "$FORCE" ]]; then
    echo "  Profile exists (${EXISTING_ID}), downloading..."
    PROFILE_RESPONSE=$(api_get "$JWT" "https://api.appstoreconnect.apple.com/v1/profiles/${EXISTING_ID}")
    save_profile "$PROFILE_RESPONSE"
else
    # Delete all existing profiles with this name before creating a new one
    if [[ -n "$EXISTING_ID" ]]; then
        echo "  Deleting existing profiles with name \"${PROFILE_NAME}\"..."
        python3 -c "
import json, sys
d = json.load(sys.stdin)
for item in d.get('data', []):
    print(item['id'])
" <<< "$EXISTING_RESPONSE" | while read -r pid; do
            echo "    Deleting ${pid}..."
            JWT=$(generate_jwt)
            curl -sg -o /dev/null -w "" -X DELETE \
                "https://api.appstoreconnect.apple.com/v1/profiles/${pid}" \
                -H "Authorization: Bearer ${JWT}"
        done
    fi
    [[ -n "$EXISTING_ID" ]] \
        && echo "  Creating new profile..." \
        || echo "  Not found, creating new profile..."

    POST_BODY=$(python3 -c "
import json, sys
print(json.dumps({
    'data': {
        'type': 'profiles',
        'attributes': {'name': sys.argv[1], 'profileType': 'IOS_APP_STORE'},
        'relationships': {
            'bundleId':    {'data': {'type': 'bundleIds',    'id': sys.argv[2]}},
            'certificates':{'data': [{'type': 'certificates','id': sys.argv[3]}]},
            'devices':     {'data': []}
        }
    }
}))
" "$PROFILE_NAME" "$BUNDLE_RECORD_ID" "$CERT_ID")

    BODY_FILE=$(mktemp)
    HTTP_CODE=$(api_post "$JWT" "https://api.appstoreconnect.apple.com/v1/profiles" "$POST_BODY" "$BODY_FILE")
    BODY=$(cat "$BODY_FILE")
    rm -f "$BODY_FILE"

    if [[ "$HTTP_CODE" != "201" ]]; then
        echo "Error: API returned HTTP ${HTTP_CODE}"
        echo "$BODY" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for e in d.get('errors', []):
    print(f\"  {e.get('title','Unknown')}: {e.get('detail','')}\")" 2>/dev/null || echo "$BODY"
        exit 1
    fi

    save_profile "$BODY"
fi

echo ""
echo "Saved: ${OUTPUT_PATH}"
echo ""
echo "Next step: ./distribute.sh"
