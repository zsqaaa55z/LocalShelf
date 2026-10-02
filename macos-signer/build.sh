#!/bin/bash
set -euo pipefail
source_dir=$(cd "$(dirname "$0")" && pwd)
build_dir="$source_dir/.build"
signer_app="$build_dir/LocalShelf Signer.app"
mkdir -p "$signer_app/Contents/MacOS" "$signer_app/Contents/Resources" "$build_dir/module-cache"
xcrun swift -module-cache-path "$build_dir/module-cache" "$source_dir/tools/render-icon.swift" "$build_dir/Assets"
iconutil -c icns "$build_dir/Assets/RenewIcon.iconset" -o "$build_dir/RenewIcon.icns"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -module-cache-path "$build_dir/module-cache" "$source_dir/Sources/Core.swift" "$source_dir/Sources/SignerApp.swift" -framework SwiftUI -framework AppKit -framework Security -framework ServiceManagement -framework UserNotifications -o "$signer_app/Contents/MacOS/LocalShelfSigner"
cp "$source_dir/Info.plist" "$signer_app/Contents/Info.plist"
cp "$source_dir/Defaults.json" "$signer_app/Contents/Resources/Defaults.json"
cp "$source_dir/LICENSE" "$signer_app/Contents/Resources/LICENSE.txt"
cp "$build_dir/RenewIcon.icns" "$signer_app/Contents/Resources/RenewIcon.icns"
codesign --force --sign - "$signer_app"
codesign --verify --deep --strict "$signer_app"
printf '%s\n' "$signer_app"
