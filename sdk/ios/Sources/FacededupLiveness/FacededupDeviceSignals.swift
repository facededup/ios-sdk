#if canImport(UIKit)
import Foundation
import UIKit
import AVFoundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Native device/fraud signals the WKWebView (JS) cannot see: exact model + arch,
/// jailbreak/debugger, bundle id + app version, memory, cameras, battery, refresh
/// rate, App Attest support, VPN/proxy. Collected once and injected as
/// `window.__FACEDEDUP_NATIVE_SIGNALS` so the web SDK's collectDeviceContext() merges
/// it. Every field is best-effort — a failure never blocks the flow.
enum FacededupDeviceSignals {

    /// Returns a JSON string `{ "device": {…}, "network": {…} }` for injection.
    static func collectJSON() -> String {
        var device: [String: Any] = [:]
        var network: [String: Any] = [:]

        device["os"] = "ios"
        device["os_version"] = UIDevice.current.systemVersion
        device["model"] = hwMachine()                       // e.g. "iPhone15,2"
        device["model_name"] = UIDevice.current.model
        device["manufacturer"] = "Apple"
        device["system_architecture"] = cpuArchitecture()

        // App identity
        let b = Bundle.main
        device["package_name"] = b.bundleIdentifier
        device["host_application"] = (b.infoDictionary?["CFBundleName"] as? String)
            ?? (b.infoDictionary?["CFBundleDisplayName"] as? String)
        device["app_version"] = b.infoDictionary?["CFBundleShortVersionString"] as? String
        // Stable, app-scoped device id (for device-farm velocity). identifierForVendor
        // is per-vendor per-device — not cross-app trackable.
        device["device_id"] = UIDevice.current.identifierForVendor?.uuidString

        // Privileges / environment
        device["is_rooted_jailbroken"] = isJailbroken()
        device["is_debugger_attached"] = isDebuggerAttached()
        device["is_emulator"] = isSimulator()
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, *) { device["supports_hardware_attestation"] = DCAppAttestService.shared.isSupported }
        #endif

        // Screen
        let scr = UIScreen.main
        device["screen_width_px"] = Int(scr.nativeBounds.width)
        device["screen_height_px"] = Int(scr.nativeBounds.height)
        device["screen_refresh_rate"] = scr.maximumFramesPerSecond
        device["screen_scale"] = scr.nativeScale

        // Memory
        device["total_memory_bytes"] = ProcessInfo.processInfo.physicalMemory
        if let used = appMemoryUsedBytes() { device["app_memory_used_bytes"] = used }

        // Cameras
        let cams = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera, .builtInUltraWideCamera],
            mediaType: .video, position: .unspecified).devices
        device["num_cameras"] = cams.count

        // Battery
        UIDevice.current.isBatteryMonitoringEnabled = true
        if UIDevice.current.batteryLevel >= 0 { device["battery_level"] = UIDevice.current.batteryLevel }
        let bs = UIDevice.current.batteryState
        device["battery_charging"] = (bs == .charging || bs == .full)

        // Locale / timezone
        device["locale"] = Locale.current.identifier
        device["timezone"] = TimeZone.current.identifier
        device["timezone_offset_minutes"] = TimeZone.current.secondsFromGMT() / 60

        // SDK launch count
        let n = UserDefaults.standard.integer(forKey: "facededup.launch_count") + 1
        UserDefaults.standard.set(n, forKey: "facededup.launch_count")
        device["sdk_launch_count"] = n

        // Network: VPN / proxy
        network["vpn_suspected"] = isVPNActive()
        if let proxies = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
           let httpProxy = proxies["HTTPProxy"] as? String, !httpProxy.isEmpty {
            network["proxy_suspected"] = true
        }

        let payload: [String: Any] = ["device": device, "network": network]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: - helpers

    private static func hwMachine() -> String {
        var size = 0; sysctlbyname("hw.machine", nil, &size, nil, 0)
        var m = [CChar](repeating: 0, count: size); sysctlbyname("hw.machine", &m, &size, nil, 0)
        return String(cString: m)
    }

    private static func cpuArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let r = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        return r == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
    }

    private static func isJailbroken() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let paths = ["/Applications/Cydia.app", "/Library/MobileSubstrate/MobileSubstrate.dylib",
                     "/bin/bash", "/usr/sbin/sshd", "/etc/apt", "/private/var/lib/apt/",
                     "/usr/bin/ssh", "/var/jb"]
        if paths.contains(where: { FileManager.default.fileExists(atPath: $0) }) { return true }
        // Sandbox-escape probe: a non-jailbroken app cannot write outside its container.
        let probe = "/private/jb_probe_\(UUID().uuidString)"
        if (try? "x".write(toFile: probe, atomically: true, encoding: .utf8)) != nil {
            try? FileManager.default.removeItem(atPath: probe); return true
        }
        if let url = URL(string: "cydia://"), UIApplication.shared.canOpenURL(url) { return true }
        return false
        #endif
    }

    private static func isVPNActive() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else { return false }
        return scoped.keys.contains { $0.contains("tap") || $0.contains("tun") || $0.contains("ppp") || $0.contains("ipsec") || $0.contains("utun") }
    }

    private static func appMemoryUsedBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return r == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
#endif
