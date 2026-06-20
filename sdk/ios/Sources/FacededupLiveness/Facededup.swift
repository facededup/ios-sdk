import Foundation

/// Configuration for the drop-in Facededup verification flow.
///
/// The flow itself (camera, face-landmark detection, challenge UI) is the hosted
/// web experience rendered inside a managed `WKWebView` — the integrator never
/// touches WebView/permission/auth plumbing. Mirrors the Android `FacededupConfig`.
public struct FacededupConfig {
    public var baseURL: URL
    /// Demo HTTP Basic password (username is ignored server-side). Omit in
    /// production once per-tenant API keys / a session token replace the gate.
    public var password: String?
    /// Per-tenant license key (fdk_…) — production replacement for the demo password.
    public var licenseKey: String?
    public var subjectId: String?
    /// Start screen. Defaults to **"liveness"** — the SDK drops straight into
    /// face capture (no menu). Set "select" for the menu, or
    /// "enroll" / "authenticate" / "address".
    public var flow: String?
    /// "face_liveness" (motion) or "face_number" (read digits aloud).
    public var method: String?
    /// "lenient" | "standard" | "strict".
    public var strictness: String?
    /// true = rear camera (agent points it at the customer).
    public var agentMode: Bool?
    /// Show the in-flow tester Settings panel (default off in production).
    public var showSettings: Bool?
    /// Show the in-flow back button. Defaults to **false** — the SDK has no menu
    /// to return to. Set true if you embed it in your own navigation.
    public var showBack: Bool?
    /// Branding / theme: product name + brand/accent colour (hex, e.g. "#0a3d62").
    public var productName: String?
    public var primaryColor: String?
    /// Theme: UI / font scale (e.g. 1.15 = 15% larger). 1.0 = default.
    public var fontScale: Double?
    /// Theme: body text colour (hex).
    public var textColor: String?
    /// Theme: background colour (hex).
    public var backgroundColor: String?
    /// Grouped, typed branding/theme. Takes precedence over the flat fields above.
    public var theme: FacededupTheme?
    /// Optional hook to mint a device-attestation token (Annex A3e) bound to the
    /// challenge `nonce` — e.g. App Attest. Return nil to send no token (the
    /// server then records attestation as `unverified`, only blocking when it has
    /// `require_attestation` / step-up enabled). Wire your App Attest module here.
    public var attestationProvider: ((_ nonce: String) async -> String?)?

    public init(baseURL: URL,
                password: String? = nil,
                licenseKey: String? = nil,
                subjectId: String? = nil,
                flow: String? = "liveness",
                method: String? = nil,
                strictness: String? = nil,
                agentMode: Bool? = nil,
                showSettings: Bool? = nil,
                showBack: Bool? = false,
                productName: String? = nil,
                primaryColor: String? = nil,
                fontScale: Double? = nil,
                textColor: String? = nil,
                backgroundColor: String? = nil,
                theme: FacededupTheme? = nil,
                attestationProvider: ((_ nonce: String) async -> String?)? = nil) {
        self.baseURL = baseURL
        self.password = password
        self.licenseKey = licenseKey
        self.subjectId = subjectId
        self.flow = flow
        self.method = method
        self.strictness = strictness
        self.agentMode = agentMode
        self.showSettings = showSettings
        self.showBack = showBack
        self.productName = productName
        self.primaryColor = primaryColor
        self.fontScale = fontScale
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.theme = theme
        self.attestationProvider = attestationProvider
    }

    /// Launch options → URL query the web flow reads (`_urlConfig` in the demo).
    func queryItems() -> [URLQueryItem] {
        var q: [URLQueryItem] = []
        if let v = flow, !v.isEmpty { q.append(URLQueryItem(name: "flow", value: v)) }
        if let v = licenseKey, !v.isEmpty { q.append(URLQueryItem(name: "license", value: v)) }
        if let v = method, !v.isEmpty { q.append(URLQueryItem(name: "method", value: v)) }
        if let v = strictness, !v.isEmpty { q.append(URLQueryItem(name: "strictness", value: v)) }
        if let v = agentMode { q.append(URLQueryItem(name: "agent", value: v ? "1" : "0")) }
        if let v = showSettings { q.append(URLQueryItem(name: "settings", value: v ? "1" : "0")) }
        if let v = showBack { q.append(URLQueryItem(name: "back", value: v ? "1" : "0")) }
        // theme (if supplied) wins over the legacy flat fields.
        let product = theme?.productName ?? productName
        let color = theme?.primaryColor ?? primaryColor
        let fScale = theme?.fontScale ?? fontScale
        let text = theme?.textColor ?? textColor
        let bg = theme?.backgroundColor ?? backgroundColor
        if let v = product, !v.isEmpty { q.append(URLQueryItem(name: "product", value: v)) }
        if let v = color, !v.isEmpty { q.append(URLQueryItem(name: "color", value: v)) }
        if let v = fScale { q.append(URLQueryItem(name: "fontScale", value: String(v))) }
        if let v = text, !v.isEmpty { q.append(URLQueryItem(name: "textColor", value: v)) }
        if let v = bg, !v.isEmpty { q.append(URLQueryItem(name: "bg", value: v)) }
        return q
    }
}

/// Branding/theme for the verification UI — group your look-and-feel in one typed value:
///
/// ```swift
/// FacededupConfig(
///   baseURL: URL(string: "https://facededup.ai")!, licenseKey: "fdk_…",
///   theme: FacededupTheme(primaryColor: "#1E9C69", backgroundColor: "#000000",
///                         textColor: "#FFFFFF", productName: "Acme"))
/// ```
/// All fields optional; hex colours like `#1E9C69`. `fontScale` 1.0 = default (1.15 = +15%).
public struct FacededupTheme {
    /// Brand / accent colour (buttons, progress) — hex, e.g. "#1E9C69".
    public var primaryColor: String?
    /// Background colour — hex.
    public var backgroundColor: String?
    /// Body text colour — hex.
    public var textColor: String?
    /// UI / font scale (1.0 = default, 1.15 = 15% larger).
    public var fontScale: Double?
    /// Product name shown in the flow's branding.
    public var productName: String?

    public init(primaryColor: String? = nil, backgroundColor: String? = nil,
                textColor: String? = nil, fontScale: Double? = nil, productName: String? = nil) {
        self.primaryColor = primaryColor
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.fontScale = fontScale
        self.productName = productName
    }
}

/// Result reported by the flow (parsed from the web bridge `postToHost`).
public struct FacededupResult {
    public let type: String            // liveness | identity | document | enroll
    public let outcome: String?        // live | not_live | referred | match | found | enrolled …
    public let isLive: Bool?
    public let score: Double?          // liveness score, or identity/document match score
    public let decision: String?
    public let enrollmentId: String?
    public let raw: [String: Any]      // the full payload

    /// True for a clearly successful verification / enrolment.
    public var passed: Bool {
        if isLive == true { return true }
        if let o = outcome, ["live", "match", "found", "enrolled"].contains(o) { return true }
        if decision == "match" { return true }
        return type == "enroll"
    }

    static func from(json: String) -> FacededupResult {
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return from(obj: obj)
    }

    static func from(obj o: [String: Any]) -> FacededupResult {
        FacededupResult(
            type: o["type"] as? String ?? "liveness",
            outcome: o["outcome"] as? String,
            isLive: o["is_live"] as? Bool,
            score: (o["score"] as? Double) ?? (o["match_score"] as? Double),
            decision: o["decision"] as? String,
            enrollmentId: o["enrollment_id"] as? String,
            raw: o)
    }
}
