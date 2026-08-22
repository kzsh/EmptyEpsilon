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

stage "$SCRIPT_DIR"
NAME="$(basename "$SCRIPT_DIR")"
rx  <<< "cd staging/$NAME && /opt/homebrew/bin/xtool dev"
