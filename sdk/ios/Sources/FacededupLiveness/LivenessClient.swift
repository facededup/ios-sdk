import Foundation

/// Async HTTP client for the liveness flow (consent -> request -> challenge ->
/// verify), mirroring the web/android SDKs. STARTER CODE.
public final class LivenessClient {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Liveness", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(path): \(text)"])
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    public func grantConsent(subjectId: String, signalScopes: [String]) async throws -> String {
        let r = try await post("/v1/consent", [
            "subject_id": subjectId, "accepted": true, "signal_scopes": signalScopes,
        ])
        return r["consent_id"] as? String ?? ""
    }

    public func openRequest(subjectId: String, consentId: String,
                            deviceContext: [String: Any]?) async throws -> [String: Any] {
        var body: [String: Any] = [
            "subject_id": subjectId, "consent_id": consentId, "reason": "issuance",
        ]
        if let dc = deviceContext { body["device_context"] = dc }
        return try await post("/v1/request", body)
    }

    public func challenge(requestId: String) async throws -> [String: Any] {
        try await post("/v1/challenge", ["request_id": requestId])
    }

    /// frames: array of ["image_b64": String, "proves_action": String?].
    public func verify(requestId: String, challenge: [String: Any],
                       frames: [[String: Any]], attestationToken: String?) async throws -> [String: Any] {
        var body: [String: Any] = [
            "request_id": requestId,
            "session_id": challenge["session_id"] as? String ?? "",
            "nonce": challenge["nonce"] as? String ?? "",
            "frames": frames,
        ]
        if let t = attestationToken { body["attestation_token"] = t }
        return try await post("/v1/verify", body)
    }
}
