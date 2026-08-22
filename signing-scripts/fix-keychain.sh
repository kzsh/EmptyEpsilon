#!/bin/bash

set -e

read -r -s -p "Keychain password: " KEYCHAIN_PASS
echo
security set-key-partition-list -S apple-tool:,apple: -s \
    -k "$KEYCHAIN_PASS" ~/Library/Keychains/login.keychain-db
unset KEYCHAIN_PASS
echo "Done."
