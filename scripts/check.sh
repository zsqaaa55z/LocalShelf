#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 scripts/release_check.py
mkdir -p build/protocol/module-cache
swiftc -module-cache-path build/protocol/module-cache \
  ios/LibraryModels.swift ios/ProtocolChecks.swift -o build/protocol/checks
build/protocol/checks
