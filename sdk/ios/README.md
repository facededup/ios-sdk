# FacededupLiveness — iOS SDK (Swift Package)

A **drop-in** SPM package that runs the full hosted Facededup flow (Enroll / Validate
with Government IDs / Authenticate — liveness, document scan, MRZ, face match) inside a
managed `WKWebView` and hands you back a typed result. One call; no WebView, camera,
HTTP-auth, or attestation plumbing for the integrator. This is the iOS counterpart of
the Android `:swiftend` SDK.

> The flow runs as the hosted web experience inside the package — `import` it like any
> Swift dependency. (SPM is the *distribution*; the WebView is an internal detail —
> the same pattern Onfido / Persona / Stripe Identity ship.)

## Install (SPM)

The package manifest is at the **repo root** (`Package.swift`); the sources live under
`sdk/ios/Sources`. SPM resolves it directly from the git URL — you don't point at a
subfolder.

**Option 1 — Xcode UI (recommended)**
1. File → **Add Package Dependencies…**
2. In the search box paste: `https://github.com/surdykbaba/facededup-liveliness.git`
3. Dependency Rule: **Branch → `main`** (until tags are published), then **Add Package**.
4. Tick the **FacededupLiveness** library → add it to your app target.

**Option 2 — `Package.swift`**
```swift
dependencies: [
    .package(url: "https://github.com/surdykbaba/facededup-liveliness.git", branch: "main"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "FacededupLiveness", package: "facededup-liveliness"),
    ]),
]
```

**Option 3 — local path (development, no network)**
```swift
.package(path: "../facededup-liveliness")   // path to the repo root
```

> Tags aren't published yet, so pin to `branch: "main"`. Once you cut a release
> (e.g. `git tag 0.1.0 && git push --tags`), switch to `from: "0.1.0"`.

**Info.plist** — add `NSCameraUsageDescription` and `NSMicrophoneUsageDescription`
(both required for the camera/mic).

## Use it
```swift
import FacededupLiveness

let vc = FacededupVerificationController(config: .init(
    baseURL: URL(string: "https://facededup.ai")!,
    password: "…",                 // demo gate; omit once you use API keys
    subjectId: "user-123"
)) { result in
    if result.passed {
        // verified — result.outcome / result.score / result.enrollmentId
    } else {
        // not verified — show result.outcome
    }
}
present(vc, animated: true)
```
Or set `vc.delegate` and implement `FacededupDelegate` (`didFinish` / `swiftendDidCancel`).

`FacededupResult` → `type` (liveness | identity | document | enroll), `outcome`, `isLive`,
`score`, `decision`, `enrollmentId`, `raw`, and a `passed` convenience.

## How it works
- Hosts `<baseURL>/demo/`; grants camera/mic to the page's getUserMedia
  (`requestMediaCapturePermissionFor`) and supplies the demo HTTP Basic password
  (`didReceive challenge`).
- The flow reports its final result via the JS bridge `postToHost` →
  `window.webkit.messageHandlers.swiftend`; the SDK parses it into `FacededupResult`.

## Online requirement & offline behaviour
This is a **hybrid** SDK: the verification UI is the hosted web flow inside a managed
`WKWebView`. It needs a network connection — and that is **not** a limitation of being
hybrid: liveness, anti-spoof, document/MRZ and the NIN/BVN face match all run on the
backend, so **no SDK (native or hybrid) can complete a verification offline.**

What "native" would change is only the *shell* (capture + UI render) when offline, not
the ability to verify. To avoid the raw WebKit error your engineer saw on airplane mode,
the SDK now detects a failed load (`didFailProvisionalNavigation`) and shows a native
**"No internet connection · Retry"** screen instead; tapping Retry reloads when back online.

> If a fully-native, no-WebView capture experience is a hard requirement (vs. nicer
> polish), that's the larger "Option B" rewrite — native AVFoundation capture + Vision/
> MediaPipe-iOS detection + native challenge UI calling the same `/v1/*` API. It still
> can't verify offline. See `docs/ios-sdk-spm-vs-native.md`.

## Device attestation (Annex A3e)
Supply `config.attestationProvider` — an `async (nonce) -> String?` that returns an App
Attest token bound to the challenge nonce. The web flow requests it via the
`swiftendAttest` bridge and the SDK replies through `window.__onFacededupAttestation`.
Returning nil sends no token (server records `unverified`). The App Attest token
provider + the server-side verifier are a separate module (iOS App Attest).

## Layout
- `Sources/FacededupLiveness/FacededupVerificationController.swift` — the drop-in UI.
- `Sources/FacededupLiveness/Facededup.swift` — `FacededupConfig` / `FacededupResult`.
- `Sources/FacededupLiveness/LivenessClient.swift` — low-level REST client (if you want
  to drive `/v1/*` yourself instead of the hosted flow).
- `sample/` — a minimal app that embeds the package (`xcodegen generate` to build).
