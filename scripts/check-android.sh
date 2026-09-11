#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Set GRADLE_USER_HOME to an existing cache after resolving app dependencies.
cache="${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2/files-2.1"
http_jar=$(find "$cache/org.nanohttpd/nanohttpd/2.3.1" -name 'nanohttpd-2.3.1.jar' -type f | head -n 1)
qr_jar=$(find "$cache/com.google.zxing/core/3.5.3" -name 'core-3.5.3.jar' -type f | head -n 1)
test -n "$http_jar" && test -n "$qr_jar"
classpath="$http_jar:$qr_jar"
mkdir -p build/android-checks
src=android/app/src/main/java/local/shelf
javac -cp "$classpath" -d build/android-checks \
  "$src/BoundedInput.java" "$src/PairingIdentity.java" "$src/PairingWindow.java" \
  "$src/PairingEndpoint.java" "$src/IndexStore.java" "$src/IndexWriter.java" \
  "$src/PageIndexes.java" "$src/CoverLocations.java" "$src/CoverRevision.java" \
  "$src/IdlePolicy.java" "$src/StaleFileOpener.java" tests/android/*.java
for name in BoundedInputCheck PairingIdentityCheck PairingWindowCheck \
  PairingEndpointCheck IndexStoreCheck PerformanceCheck CoverLocationsCheck \
  CoverRevisionCheck StaleFileOpenerCheck; do
  java -cp "build/android-checks:$classpath" "local.shelf.$name"
done
java -cp "build/android-checks:$classpath" PairingQRCheck
