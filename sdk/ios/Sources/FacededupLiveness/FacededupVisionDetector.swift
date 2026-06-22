#if canImport(Vision) && canImport(UIKit)
import Vision
import CoreGraphics
import ImageIO

/// On-device face detection for the iOS hybrid flow.
///
/// The hosted web flow (sdk/web/demo/index.html) normally runs MediaPipe in a WASM
/// Worker, which is unreliable inside WKWebView. Instead, when the SDK sets
/// `window.__FACEDEDUP_NATIVE_DETECT`, the page ships each throttled frame here and
/// we run Apple Vision natively, returning the EXACT signal shape the page consumes
/// (see `processLandmarks` / `actionProgress` in the web flow).
///
/// IMPORTANT — coordinate / sign conventions (so detection matches the web logic):
///  • The page sends a MIRRORED (selfie) JPEG, so all geometry here is in that mirror
///    space. `noseOff` (nose-x minus eye-midpoint-x, over face width) therefore matches
///    the page's convention by construction: turn to the user's left ⇒ noseOff < 0.
///  • `coverage/cx/cy` use the face bounding box (cy flipped to the page's top-left
///    origin).
///  • `pitch` comes from Vision's Euler angle; MediaPipe's convention is look-UP =
///    negative, look-DOWN = positive. `pitchSign` calibrates Vision to that. If a
///    device test shows up/down inverted, flip `pitchSign` — turn + blink + smile are
///    landmark-based and are sign-correct regardless, and tilt actions fall back to
///    timed capture if pitch is wrong, so the flow never breaks on this.
final class FacededupVisionDetector {

    /// Flip to -1 if a device test shows look-up/look-down inverted.
    private static let pitchSign: Double = 1.0

    private let handler = VNSequenceRequestHandler()

    // Geometric-pitch neutral calibration. The eye/nose/mouth foreshortening ratio is
    // ~0.5–0.65 for a NEUTRAL forward face, so reporting `ratio * 150` made a forward
    // face read ~75–95° and the page's positioning gate (|pitch| > 22) never cleared.
    // We learn the user's neutral ratio during the forward-hold and report pitch as a
    // DELTA from it, so forward ≈ 0° and look up/down move it. Serial detect queue, so
    // these need no locking. (calibrated on the first frontal frames, then frozen.)
    private var neutralRatio: Double?
    private var neutralSamples = 0
    // Smile is approximated from outer-lip WIDTH (Vision has no smile blendshape).
    // Neutral width varies per face, so a fixed baseline made many users unable to
    // cross the page's smile gate. Learn the neutral width during the forward-hold and
    // report smile as a scaled delta from it.
    private var neutralMouthWidth: Double?

    /// Decode a base64 JPEG (as sent by the web flow) and detect. Returns a dict
    /// ready to hand to `window.__facededupPose(...)`. `{"face": false}` when no face.
    func detect(base64JPEG: String) -> [String: Any] {
        guard let data = Data(base64Encoded: base64JPEG),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return ["face": false]
        }
        return detect(cgImage: cg)
    }

    func detect(cgImage: CGImage) -> [String: Any] {
        let req = VNDetectFaceLandmarksRequest()
        do { try handler.perform([req], on: cgImage, orientation: .up) }
        catch { return ["face": false] }
        guard let face = (req.results)?.first else { return ["face": false] }

        let bb = face.boundingBox            // normalised, bottom-left origin
        var out: [String: Any] = [
            "face": true,
            "coverage": Double(bb.height),
            "cx": Double(bb.midX),
            "cy": Double(1.0 - bb.midY),     // flip to top-left origin (page convention)
            "yaw":  ((face.yaw?.doubleValue) ?? 0) * 180.0 / .pi,
            "roll": ((face.roll?.doubleValue) ?? 0) * 180.0 / .pi,
        ]
        if #available(iOS 15.0, *) {
            out["pitch"] = Self.pitchSign * (((face.pitch?.doubleValue) ?? 0) * 180.0 / .pi)
        } else {
            out["pitch"] = 0.0
        }

        guard let lm = face.landmarks else {
            out["noseOff"] = 0.0
            return out
        }

        // Landmark regions are normalised to the face box; x/y ratios within the box
        // are therefore already fractions of the face. (No box transform needed.)
        func centroidX(_ r: VNFaceLandmarkRegion2D?) -> Double? {
            guard let pts = r?.normalizedPoints, !pts.isEmpty else { return nil }
            return Double(pts.reduce(0) { $0 + $1.x } / CGFloat(pts.count))
        }

        // noseOff: nose-x minus eye-midpoint-x (fraction of face width, mirror space).
        if let nx = centroidX(lm.nose) ?? centroidX(lm.noseCrest),
           let lx = centroidX(lm.leftEye), let rx = centroidX(lm.rightEye) {
            out["noseOff"] = nx - (lx + rx) / 2.0
        } else {
            out["noseOff"] = 0.0
        }

        // GEOMETRIC PITCH (look up/down). Vision's `face.pitch` is coarse and frequently
        // 0/unpopulated, so up/down never registered. Derive pitch from FORESHORTENING
        // instead — the vertical split between eye→nose and nose→mouth shifts as the head
        // pitches (same landmark approach as noseOff for turns). Output ~degrees; the page
        // judges it as a DELTA from neutral, so only sign + scale matter. Sign matches
        // MediaPipe (look-UP negative, look-DOWN positive) — flip pitchSign if inverted.
        func centroidY(_ r: VNFaceLandmarkRegion2D?) -> Double? {
            guard let pts = r?.normalizedPoints, !pts.isEmpty else { return nil }
            return Double(pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count))   // bottom-left origin (y up)
        }
        if let ly = centroidY(lm.leftEye), let ry = centroidY(lm.rightEye),
           let ny = centroidY(lm.nose) ?? centroidY(lm.noseCrest),
           let my = centroidY(lm.outerLips) ?? centroidY(lm.innerLips) {
            let eyeMidY = (ly + ry) / 2.0
            let eyeToNose = eyeMidY - ny          // eyes above nose above mouth (y up)
            let noseToMouth = ny - my
            let denom = eyeToNose + noseToMouth
            if denom > 1e-4 {
                let ratio = eyeToNose / denom     // look-down raises it, look-up lowers it
                // Learn the neutral ratio during the forward-hold (small yaw), for the
                // first ~25 frontal frames, then freeze it. Report pitch as a delta from
                // neutral so a forward face is ~0° (was ~75–95°, which jammed positioning).
                let yawDeg = abs(((face.yaw?.doubleValue) ?? 0) * 180.0 / .pi)
                if neutralSamples < 25 && yawDeg < 14 {
                    neutralRatio = (neutralRatio ?? ratio) * 0.8 + ratio * 0.2
                    neutralSamples += 1
                }
                let base = neutralRatio ?? ratio
                out["pitch"] = Self.pitchSign * (ratio - base) * 150.0
            }
        }

        // Blink: eye-aspect-ratio (height/width) → blink score (1 = closed). Open ≈ 0.28.
        func blink(_ eye: VNFaceLandmarkRegion2D?) -> Double {
            guard let pts = eye?.normalizedPoints, pts.count >= 4 else { return 0 }
            var minX = CGFloat.greatestFiniteMagnitude, maxX = -minX, minY = minX, maxY = -minX
            for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
            let w = max(maxX - minX, 1e-4)
            let ear = Double((maxY - minY) / w)
            return max(0, min(1, 1 - ear / 0.28))
        }
        out["eyeBlinkLeft"]  = blink(lm.leftEye)
        out["eyeBlinkRight"] = blink(lm.rightEye)

        // Smile: outer-lip WIDTH delta from the user's calibrated neutral (Vision has
        // no smile blendshape). The page passes at avg smile >= 0.40, so we scale the
        // width increase so a genuine smile clears it regardless of natural mouth size.
        if let lips = lm.outerLips?.normalizedPoints, lips.count >= 4 {
            var minX = CGFloat.greatestFiniteMagnitude, maxX = -minX, minY = minX, maxY = -minX
            for p in lips { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
            let width = Double(maxX - minX)
            // Calibrate neutral width during the forward-hold (small yaw), then freeze.
            let yawDeg2 = abs(((face.yaw?.doubleValue) ?? 0) * 180.0 / .pi)
            if neutralSamples <= 25 && yawDeg2 < 14 {
                neutralMouthWidth = (neutralMouthWidth ?? width) * 0.8 + width * 0.2
            }
            let baseW = neutralMouthWidth ?? width
            let smile = max(0, min(1, (width - baseW) / 0.09))   // +0.036 width -> passes (0.40)
            out["mouthSmileLeft"]  = smile
            out["mouthSmileRight"] = smile
            out["jawOpen"] = max(0, min(1, (Double(maxY - minY) - 0.06) / 0.14))
        }

        return out
    }
}
#endif
