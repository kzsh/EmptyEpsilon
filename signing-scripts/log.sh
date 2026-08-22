#!/bin/bash

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

stage "$SCRIPT_DIR"
NAME="$(basename "$SCRIPT_DIR")"
require_asc_credentials || exit 1

rx  <<< "cd staging/$NAME && xcrun notarytool log $1 --key-id ${API_KEY_ID} --issuer ${API_ISSUER} --key ${API_KEY_DIR}/AuthKey_${API_KEY_ID}.p8"

