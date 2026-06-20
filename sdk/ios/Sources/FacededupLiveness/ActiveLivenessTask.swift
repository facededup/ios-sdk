#if canImport(UIKit)
import Foundation

/// Native active-liveness challenge for iOS — mirror of the Android `ActiveLiveness`.
/// Driven by Vision head yaw + a smile proxy (mouth width) from `FacededupVisionDetector`.
/// The server (/v1/offline/submit) still makes the authoritative liveness decision; this
/// only drives the on-device UX and selects which frames to submit.
final class ActiveLivenessTask {

    enum Directive: Equatable {
        case positioning, turnLeft, turnRight, smile, done
        /// `proves_action` value sent with the captured frame.
        var proves: String? {
            switch self {
            case .turnLeft: return "turn_left"
            case .turnRight: return "turn_right"
            case .smile: return "smile"
            default: return nil
            }
        }
    }

    private enum K {
        static let turnYaw = 22.0      // deg — a clear head turn
        static let smile = 0.55        // mouth-width smile proxy (0..1)
        static let neutralYaw = 10.0   // must return near-frontal between actions
        // Vision yaw sign vs the user's left/right on the FRONT camera.
        // Flip to -1 if a device test shows turn left/right swapped.
        static let yawSign = 1.0
    }

    private let steps: [Directive]
    private var index = 0
    private var sawNeutral = false

    init(actions: [String]) {
        let map: [String: Directive] = ["turn_left": .turnLeft, "turn_right": .turnRight, "smile": .smile]
        let picked = actions.compactMap { map[$0] }
        steps = picked.isEmpty ? [.turnLeft, .turnRight, .smile] : picked
    }

    var isFinished: Bool { index >= steps.count }
    var current: Directive { isFinished ? .done : steps[index] }
    var total: Int { steps.count }
    var progress: Int { index }
    func actionKeys() -> [String] { steps.compactMap { $0.proves } }

    func hint(facePresent: Bool) -> String {
        if !facePresent { return "Center your face in the oval" }
        switch current {
        case .turnLeft: return "Slowly turn your head left"
        case .turnRight: return "Slowly turn your head right"
        case .smile: return "Smile"
        default: return "Hold still"
        }
    }

    /// Feed one detection (yaw in degrees, smile proxy 0..1, facePresent). Returns true
    /// exactly when the current directive was just satisfied — capture a frame + advance.
    func update(yaw rawYaw: Double, smile: Double, facePresent: Bool) -> Bool {
        guard !isFinished, facePresent else { return false }
        let yaw = rawYaw * K.yawSign
        if abs(yaw) < K.neutralYaw { sawNeutral = true }
        let satisfied: Bool
        switch current {
        case .turnLeft:  satisfied = sawNeutral && yaw >  K.turnYaw
        case .turnRight: satisfied = sawNeutral && yaw < -K.turnYaw
        case .smile:     satisfied = smile > K.smile
        default:         satisfied = false
        }
        if satisfied { index += 1; sawNeutral = false }
        return satisfied
    }
}
#endif
