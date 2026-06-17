# Facededup iOS SDK — `FacededupLiveness`

Drop-in face-liveness + identity verification for iOS (Swift Package / xcframework).
Hosted flow in a managed `WKWebView`; the integrator gets a typed result.

- Add via SPM: this repo's URL (Package.swift at root, sources in `sdk/ios/Sources`).
- Prebuilt binary: signed xcframework on S3 (see `Package.swift` `binaryURL`/`binaryChecksum`,
  rebuilt by `scripts/build-ios-xcframework.sh`).
- Docs: https://facededup.ai/docs#ios

Extracted from the Facededup mono-repo (`facededup/nablr-liveness`).
