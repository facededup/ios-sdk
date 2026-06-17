#!/usr/bin/env bash
# Build a DISTRIBUTABLE FacededupLiveness.xcframework that EXPOSES the Swift
# module (.swiftmodule + .swiftinterface inside each slice's Modules/ dir) so
# `import FacededupLiveness` resolves for binary (SPM binaryTarget / drag-in)
# consumers.
#
# Run on macOS with Xcode 15+ (this cannot be produced off a Mac). The previous
# published xcframework was built without library evolution, so it shipped only
# the binary — no Modules/, no module.modulemap — and `import` failed.
#
#   ./scripts/build-ios-xcframework.sh
#   -> build/xcf/FacededupLiveness.xcframework  (+ .zip + SPM checksum)
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=FacededupLiveness
OUT="$(pwd)/build/xcf"
rm -rf "$OUT"; mkdir -p "$OUT"

# Archive each platform (separate derived-data dirs so the per-arch emitted
# .swiftinterface files survive for both platforms). BUILD_LIBRARY_FOR_DISTRIBUTION
# emits the .swiftinterface; the root product is .dynamic so it archives as a
# .framework (SPM installs it under Products/usr/local/lib).
archive() {  # $1 = destination, $2 = archive path, $3 = derived-data path
  xcodebuild archive \
    -scheme "$NAME" \
    -destination "$1" \
    -archivePath "$2" \
    -derivedDataPath "$3" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    OTHER_SWIFT_FLAGS="-no-verify-emitted-module-interface"
}
archive "generic/platform=iOS"            "$OUT/ios.xcarchive"  "$OUT/dd-ios"
archive "generic/platform=iOS Simulator"  "$OUT/sim.xcarchive"  "$OUT/dd-sim"

# SPM archives the dynamic framework WITHOUT a Modules/ dir — assemble it from the
# emitted per-arch .swiftinterface/.swiftmodule so `import FacededupLiveness`
# resolves. $1 = archive, $2 = derived-data, $3.. = "arch:triple" pairs.
assemble_module() {
  local arch="$1" dd="$2"; shift 2
  local fw mods objbase
  fw="$(find "$arch/Products" -type d -name "$NAME.framework" | head -1)"
  [ -n "$fw" ] || { echo "ERROR: framework not found in $arch" >&2; exit 1; }
  mods="$fw/Modules/$NAME.swiftmodule"; mkdir -p "$mods"
  objbase="$(dirname "$(find "$dd" -path "*Objects-normal*/$NAME.swiftinterface" | head -1)")"
  objbase="$(dirname "$objbase")"   # .../Objects-normal
  for pair in "$@"; do
    local a="${pair%%:*}"
    local triple="${pair##*:}"
    local src="$objbase/$a"
    [ -d "$src" ] || { echo "ERROR: no intermediates for arch $a in $dd" >&2; exit 1; }
    for ext in swiftinterface private.swiftinterface swiftmodule swiftdoc abi.json; do
      [ -f "$src/$NAME.$ext" ] && cp "$src/$NAME.$ext" "$mods/$triple.$ext"
    done
  done
  echo "$fw"
}
FW_IOS="$(assemble_module "$OUT/ios.xcarchive" "$OUT/dd-ios" "arm64:arm64-apple-ios")"
FW_SIM="$(assemble_module "$OUT/sim.xcarchive" "$OUT/dd-sim" \
            "arm64:arm64-apple-ios-simulator" "x86_64:x86_64-apple-ios-simulator")"

rm -rf "$OUT/$NAME.xcframework"
xcodebuild -create-xcframework \
  -framework "$FW_IOS" \
  -framework "$FW_SIM" \
  -output "$OUT/$NAME.xcframework"

# Sanity: each slice MUST now contain a Swift module.
for slice in "$OUT/$NAME.xcframework"/*/; do
  if ! ls "$slice$NAME.framework/Modules/$NAME.swiftmodule" >/dev/null 2>&1; then
    echo "ERROR: $slice is missing Modules/$NAME.swiftmodule — module not exposed." >&2
    exit 1
  fi
done
echo "OK: Swift module present in every slice."

# Zip + checksum for the SPM binaryTarget.
( cd "$OUT" && rm -f "$NAME.xcframework.zip" && zip -qry "$NAME.xcframework.zip" "$NAME.xcframework" )
ZIP="$OUT/$NAME.xcframework.zip"
SUM="$(swift package compute-checksum "$ZIP")"
echo "zip:      $ZIP"
echo "checksum: $SUM"

# Version + S3 location (override: VERSION=0.7.0 ./scripts/build-ios-xcframework.sh)
VERSION="${VERSION:-0.6.8}"
BUCKET="${MEDIA_ASSETS_BUCKET:-swiftend-assets-348761024048}"
REGION="${AWS_REGION:-eu-west-2}"
KEY="sdk/ios/$NAME-$VERSION.xcframework.zip"
URL="https://$BUCKET.s3.$REGION.amazonaws.com/$KEY"

# Upload (needs the swiftend AWS profile) — skip with NO_UPLOAD=1.
if [ "${NO_UPLOAD:-0}" != "1" ]; then
  AWS_PROFILE="${AWS_PROFILE:-swiftend}" aws s3 cp "$ZIP" "s3://$BUCKET/$KEY" --region "$REGION"
  echo "uploaded: $URL"
fi

# Rewrite the two managed lines in the root Package.swift so binaryTarget points
# at this freshly-built, module-exposing zip (FACEDEDUP_USE_BINARY=1 to use it).
PKG="Package.swift"
perl -pi -e "s|^let binaryURL = \".*\"|let binaryURL = \"$URL\"|;" "$PKG"
perl -pi -e "s|^let binaryChecksum = \".*\".*|let binaryChecksum = \"$SUM\"|;" "$PKG"
echo "patched:  $PKG (binaryURL + binaryChecksum)"
echo
echo "Done. Commit Package.swift. Consumers can now opt into the binary with"
echo "  FACEDEDUP_USE_BINARY=1   (default stays from-source)."
