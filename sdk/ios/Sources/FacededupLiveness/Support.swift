import Foundation
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

/// Heuristic jailbreak detection (defense-in-depth; App Attest is authoritative).
enum Jailbreak {
    static func isJailbroken() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let paths = ["/Applications/Cydia.app", "/bin/bash", "/usr/sbin/sshd",
                     "/etc/apt", "/private/var/lib/apt/", "/usr/bin/ssh"]
        if paths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            return true
        }
        // Can we write outside the sandbox?
        let probe = "/private/jailbreak_probe.txt"
        do {
            try "x".write(toFile: probe, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(atPath: probe)
            return true
        } catch { return false }
        #endif
    }
}

/// Detects an attached debugger via sysctl (P_TRACED).
enum Debugger {
    static func isAttached() -> Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard rc == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}

enum Network {
    /// Coarse connection type. For carrier/cellular detail use CTTelephonyNetworkInfo.
    static func connectionType() -> String {
        // STARTER: integrate Reachability/NWPathMonitor for wifi vs cellular.
        return "unknown"
    }
}
