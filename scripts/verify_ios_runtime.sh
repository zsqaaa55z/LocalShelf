#!/bin/bash
# Run synthetic app checks in an explicitly selected, already booted simulator.
# No physical-device commands, real NAS requests, erasure or preference resets.
set -euo pipefail
if [ "$#" -ne 3 ]; then
    printf 'Usage: bash verify_ios_runtime.sh SIMULATOR_UUID BUILT_APP NEW_LOG_DIRECTORY\n' >&2
    exit 2
fi
simulator_id=$1
built_app=$2
log_directory=$3
if [ ! -d "$built_app" ] || [ -e "$log_directory" ]; then
    printf 'Built app must exist; choose a new log directory to preserve prior evidence.\n' >&2
    exit 2
fi
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built_app/Info.plist")
platform=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$built_app/Info.plist")
if [ "$bundle_id" != local.shelf.reader ] || [ "$platform" != iPhoneSimulator ]; then
    printf 'Use the LocalShelf simulator build, not an iPhone install package.\n' >&2
    exit 2
fi
xcrun simctl getenv "$simulator_id" SIMULATOR_UDID >/dev/null
mkdir "$log_directory"
xcrun simctl install "$simulator_id" "$built_app"
scenarios=(
    diagnostic-checks
    manual-library-checks
    cache-efficiency-checks
    related-checks
    local-update-checks
    connection-recovery-test pairing-checks nas-checks nas-password-checks
    nas-thumbnail-contract-checks nas-library-cache-checks
    shelf-update-checks shelf-jump-checks reader-update-checks
    native-pager-checks rapid-pager-checks slider-checks animation-checks animation-policy-checks
    cover-v2-checks disk-cover-checks scheduling-checks body-cache-checks
    manifest-conditional-checks page-cache-checks parsing-checks p34-checks
    performance-checks cover-checks
)
for scenario in "${scenarios[@]}"; do
    printf 'Running %s\n' "$scenario"
    log="$log_directory/$scenario.log"
    if ! xcrun simctl launch --terminate-running-process --console "$simulator_id" local.shelf.reader "--$scenario" >"$log" 2>&1; then
        printf 'Launch failed; inspect %s\n' "$log" >&2
        exit 1
    fi
    # simctl may exit zero even if the app crashes: require its final success marker.
    if rg -q 'Fatal error:|Precondition failed|Assertion failed' "$log" ||
       ! rg -q '^[0-9]+ .*(checks|scenarios) passed' "$log"; then
        printf 'Check did not complete successfully; inspect %s\n' "$log" >&2
        exit 1
    fi
    rg '^[0-9]+ .*(checks|scenarios) passed' "$log"
done
printf 'All %s synthetic runtime scenarios passed.\n' "${#scenarios[@]}"
