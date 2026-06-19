# Facededup iOS SDK — `FacededupLiveness`

Drop-in face-liveness + identity verification for iOS (Swift Package / xcframework).
Hosted flow in a managed `WKWebView`; the integrator gets a typed result.

- Add via SPM: this repo's URL (Package.swift at root, sources in `sdk/ios/Sources`).
- Prebuilt binary: signed xcframework on S3 (see `Package.swift` `binaryURL`/`binaryChecksum`,
  rebuilt by `scripts/build-ios-xcframework.sh`).
- Docs: https://facededup.ai/docs#ios

## Required Info.plist keys

The flow captures the camera, and the **read-a-number / voice challenge** captures the
mic via `getUserMedia({audio:true})`. iOS will not grant `WKWebView` capture unless the
**host app** declares these usage strings in its `Info.plist` — without the microphone
key the voice/number challenge silently fails to record (and `requestAccess` would
hard-crash, so the SDK skips priming it and logs a warning instead):

```xml
<key>NSCameraUsageDescription</key>
<string>Used to verify it's really you (face liveness).</string>
<key>NSMicrophoneUsageDescription</key>
<string>Used for the read-a-number voice check during verification.</string>
```

Extracted from the Facededup mono-repo (`facededup/nablr-liveness`).
