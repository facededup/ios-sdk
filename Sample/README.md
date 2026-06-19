# Facededup iOS sample (offline test app)

A one-screen app that launches the liveness flow with the demo license, branded to
match the field integration (green `#1E9C69` / black). Use it to verify the **offline**
flow end-to-end on a real device.

## Run it

```bash
open Sample/FacededupSample.xcodeproj
```

1. Select the **FacededupSample** scheme + your device.
2. Signing & Capabilities → pick your **Team** (any free Apple ID works).
3. **Run** (⌘R).

The project pulls the SDK from the local package at the repo root (from source), so it
always reflects the code in this checkout. To regenerate the `.xcodeproj` after editing
`project.yml`:

```bash
brew install xcodegen   # once
cd Sample && xcodegen generate
```

## Test the offline flow

1. **Airplane mode** → launch → the UI should open from the app (no "no connection"
   screen), complete the capture → status shows **OFFLINE → QUEUED**.
2. **Turn network back on** → the queued capture submits to `/v1/offline/submit`; the
   verdict is delivered to the tenant's configured webhook.
3. **Voice / read-a-number:** allow the mic prompt at launch, fail liveness 3× to switch
   to the number challenge, and confirm it records your spoken digits.

> Requires `NSCameraUsageDescription` + `NSMicrophoneUsageDescription` in Info.plist —
> already set here; your real app must add them too.
