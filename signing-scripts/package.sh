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

echo "Building release IPA with xtool..."
cd "$SCRIPT_DIR"
xtool dev build --configuration release --ipa

echo ""
echo "Build complete: xtool/${APP_NAME}.ipa"
echo ""
echo "Note: This creates a development-signed IPA."
echo "For App Store/TestFlight, run: ./distribute.sh -i \"Apple Distribution: ...\""
