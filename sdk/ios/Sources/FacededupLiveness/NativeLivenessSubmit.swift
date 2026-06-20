#if canImport(UIKit)
import Foundation

/// Submits captured liveness frames for the 2.0 NATIVE iOS flow. ONLINE: POST
/// /v1/offline/submit and return the server's signed verdict immediately (the endpoint
/// runs the same decision as /v1/verify). OFFLINE / failure: persist to
/// `FacededupOfflineStore` for deferred submit on reconnect (verdict → tenant webhook).
/// The server stays authoritative — the device never decides liveness.
enum NativeLivenessSubmit {

    struct Frame { let imageB64: String; let provesAction: String? }

    /// Returns the result JSON to report to the host (verdict, or a `queued` placeholder).
    static func submit(base: String, license: String, subjectId: String, method: String,
                       actions: [String], frames: [Frame], completion: @escaping (String) -> Void) {
        let txn = "cap_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0..<1_000_000))"
        let body: [String: Any] = [
            "subject_id": subjectId, "method": method, "client_actions": actions,
            "client_txn_id": txn, "captured_at": isoNow(),
            "frames": frames.map { ["image_b64": $0.imageB64, "proves_action": $0.provesAction as Any] },
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(queued(txn)); return
        }
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: b + "/v1/offline/submit") else { completion(queued(txn)); return }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !license.isEmpty { req.setValue(license, forHTTPHeaderField: "X-License-Key") }
        req.httpBody = bodyData
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code), let d = data, let s = String(data: d, encoding: .utf8) {
                completion(s)
            } else {
                // offline / server unreachable / non-2xx → queue for deferred submit.
                if let s = String(data: bodyData, encoding: .utf8) {
                    FacededupOfflineStore.shared.enqueue(payload: s, base: base, license: license)
                }
                completion(queued(txn))
            }
        }.resume()
    }

    private static func queued(_ txn: String) -> String {
        let obj: [String: Any] = ["type": "liveness", "outcome": "queued",
                                  "client_txn_id": txn, "queued_offline": true]
        return (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"type\":\"liveness\",\"outcome\":\"queued\"}"
    }

    private static func isoNow() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
#endif
