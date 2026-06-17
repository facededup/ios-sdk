import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Collects the canonical DeviceContext (same shape as app/signals/schema.py
/// and the web/android SDKs). Maximum-signal posture; every field is gated by
/// the consent scopes the host app obtained.
///
/// STARTER CODE: builds the JSON contract + device signals. Wire App Attest /
/// DeviceCheck (attestation, A3e) and CoreLocation (precise location) where
/// marked, then build/test on-device.
public enum SignalCollector {

    public struct LocationFix {
        public let lat: Double
        public let lng: Double
        public let accuracyM: Double
        public let source: String
        public let time: Date
        public init(lat: Double, lng: Double, accuracyM: Double, source: String, time: Date) {
            self.lat = lat; self.lng = lng; self.accuracyM = accuracyM
            self.source = source; self.time = time
        }
    }

    private static func iso(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public static func collect(
        attestationToken: String? = nil,
        location: LocationFix? = nil,
        appVersion: String? = nil
    ) -> [String: Any] {
        var device: [String: Any] = [
            "platform": "ios",
            "os": "ios",
            "sdk_version": "0.1.0",
            "is_emulator": isSimulator(),
            "is_rooted_jailbroken": Jailbreak.isJailbroken(),
            "is_debugger_attached": Debugger.isAttached(),
        ]
        #if canImport(UIKit)
        device["os_version"] = UIDevice.current.systemVersion
        device["model"] = modelIdentifier()
        device["manufacturer"] = "Apple"
        device["device_id"] = UIDevice.current.identifierForVendor?.uuidString
        let scale = UIScreen.main.scale
        let b = UIScreen.main.bounds
        device["screen"] = "\(Int(b.width))x\(Int(b.height))@\(scale)"
        #endif
        device["locale"] = Locale.current.identifier
        device["timezone"] = TimeZone.current.identifier
        if let appVersion { device["app_version"] = appVersion }

        var root: [String: Any] = [
            "device": device,
            "network": ["connection_type": Network.connectionType()],
            "timing": ["client_timestamp": iso()],
        ]
        if let loc = location {
            root["location"] = [
                "lat": loc.lat, "lng": loc.lng, "accuracy_m": loc.accuracyM,
                "source": loc.source, "captured_at": iso(loc.time),
            ]
        }
        if let token = attestationToken { root["attestation_token"] = token }
        return root
    }

    private static func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private static func modelIdentifier() -> String {
        var sysinfo = utsname(); uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
