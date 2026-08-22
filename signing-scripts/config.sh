#!/bin/bash
#
# Shared configuration for the iOS signing / distribution scripts.
# Sourced by the other scripts in this directory; not meant to be run directly.
#
# Everything here is overridable from the environment, so no account-specific
# identifiers need to live in the repository.
#
#   APP_NAME          product name, used for .app/.ipa/binary paths
#   BUNDLE_ID         CFBundleIdentifier, must match the App Store Connect record
#   PROFILE_NAME      provisioning profile name in App Store Connect
#   CERT_ORG          organisation used in the distribution CSR subject
#   ASC_API_KEY_ID    App Store Connect API key id
#   ASC_API_ISSUER    App Store Connect API issuer id (UUID)
#   ASC_API_KEY_DIR   directory holding AuthKey_<key id>.p8

APP_NAME="${APP_NAME:-EmptyEpsilon}"
BUNDLE_ID="${BUNDLE_ID:-io.github.daid.EmptyEpsilon}"
PROFILE_NAME="${PROFILE_NAME:-${APP_NAME} App Store}"
CERT_ORG="${CERT_ORG:-${APP_NAME}}"

API_KEY_ID="${ASC_API_KEY_ID:-}"
API_ISSUER="${ASC_API_ISSUER:-}"
API_KEY_DIR="${ASC_API_KEY_DIR:-$HOME/.appstoreconnect/private_keys}"

# Fail early when a script needs App Store Connect credentials that the
# environment has not provided.
require_asc_credentials() {
    local missing=0
    if [[ -z "${API_KEY_ID}" ]]; then
        echo "ERROR: ASC_API_KEY_ID is not set (App Store Connect API key id)." >&2
        missing=1
    fi
    if [[ -z "${API_ISSUER}" ]]; then
        echo "ERROR: ASC_API_ISSUER is not set (App Store Connect issuer id)." >&2
        missing=1
    fi
    if [[ ${missing} -ne 0 ]]; then
        echo "       Export both, then re-run. The matching AuthKey_<id>.p8 must" >&2
        echo "       live in ${API_KEY_DIR}." >&2
        return 1
    fi
}
