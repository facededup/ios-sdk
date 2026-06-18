// swift-tools-version:5.7
import PackageDescription
import Foundation

// FacededupLiveness is consumable two ways from this one root manifest:
//
//  • FROM SOURCE (default): compiles `sdk/ios/Sources` — always exposes the
//    Swift module, no prebuilt binary needed. Recommended path.
//
//  • PREBUILT BINARY: set FACEDEDUP_USE_BINARY=1 when resolving and SPM uses the
//    signed xcframework on S3 instead of compiling. The url + checksum below are
//    maintained by `scripts/build-ios-xcframework.sh`, which rebuilds the
//    xcframework (with library evolution so it exposes the module), uploads it to
//    S3, and rewrites these two lines.
//
// The binary slices are iOS-only, so binary mode is for iOS app builds in Xcode;
// `swift build` on macOS uses the from-source path (the default).

// --- BINARY DISTRIBUTION (managed by scripts/build-ios-xcframework.sh) -------
let binaryURL = "https://swiftend-assets-348761024048.s3.eu-west-2.amazonaws.com/sdk/ios/FacededupLiveness-1.0.5.xcframework.zip"
let binaryChecksum = "2dc9e0ec1e1ff4fe75c1d686cbaefa8f41d9dc107c1a5123d20be36a88303de3"
// ----------------------------------------------------------------------------

let useBinary = ProcessInfo.processInfo.environment["FACEDEDUP_USE_BINARY"] == "1"
    && binaryChecksum != "PENDING_REBUILD"

let livenessTarget: Target = useBinary
    ? .binaryTarget(name: "FacededupLiveness", url: binaryURL, checksum: binaryChecksum)
    : .target(name: "FacededupLiveness", path: "sdk/ios/Sources/FacededupLiveness")

// From-source product is DYNAMIC so the xcframework build (xcodebuild archive)
// emits a real .framework; for the binary path the xcframework already is one.
let livenessProduct: Product = useBinary
    ? .library(name: "FacededupLiveness", targets: ["FacededupLiveness"])
    : .library(name: "FacededupLiveness", type: .dynamic, targets: ["FacededupLiveness"])

let package = Package(
    name: "FacededupLiveness",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        livenessProduct,
    ],
    targets: [
        livenessTarget,
    ]
)
