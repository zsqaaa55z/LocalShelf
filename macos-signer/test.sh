#!/bin/bash
set -euo pipefail
signer_source="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$signer_source/.build/module-cache"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  -module-cache-path "$signer_source/.build/module-cache" \
  "$signer_source/Sources/Core.swift" "$signer_source/Tests/CoreChecks.swift" \
  -framework Security -o "$signer_source/.build/CoreChecks"
"$signer_source/.build/CoreChecks" "$@"
