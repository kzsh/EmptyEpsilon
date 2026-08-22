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

cd "$SCRIPT_DIR"

echo "=== Step 1/3: Building ==="
xtool dev build

echo ""
echo "=== Step 2/3: Distributing ==="
./distribute.sh "$@"

echo ""
echo "=== Step 3/3: Submitting ==="
./submit.sh

echo ""
echo "=== Release complete ==="
