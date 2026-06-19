#if canImport(UIKit)
import Foundation
import Network

/// Durable offline-capture queue for iOS — mirror of Android's `OfflineQueue` +
/// `OfflineSubmitWorker`.
///
/// When the device is offline the web flow can't reach `/v1/verify`, so it hands the
/// captured frames to the native bridge (`facededupQueueOffline`). We persist each
/// capture to disk and POST it to `/v1/offline/submit` as soon as connectivity returns
/// (and on every launch, to drain anything left from a previous session). The server
/// runs the decision and delivers the verdict to the tenant's webhook.
final class FacededupOfflineStore {

    static let shared = FacededupOfflineStore()

    private let dir: URL
    private let q = DispatchQueue(label: "ai.facededup.offline.queue")
    private let monitor = NWPathMonitor()
    private var monitoring = false

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        dir = root.appendingPathComponent("FacededupOfflineQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Persist a capture the page handed us. `payload` is the JSON string the flow built
    /// (subject_id, frames, client_actions, client_txn_id, captured_at, method). We staple
    /// the base URL + license needed to submit it later.
    func enqueue(payload: String, base: String, license: String) {
        q.async {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            else { return }
            var item = obj
            item["_base"] = base
            item["_license"] = license
            let id = (item["client_txn_id"] as? String) ?? UUID().uuidString
            let file = self.dir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json")
            if let data = try? JSONSerialization.data(withJSONObject: item) {
                try? data.write(to: file, options: .atomic)
            }
            self.flushLocked()
        }
    }

    /// Number of captures still waiting to submit.
    func pendingCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.count
    }

    /// Try to submit everything queued (no-op when offline — failed POSTs stay on disk).
    func flush() { q.async { self.flushLocked() } }

    /// Submit on every reconnect.
    func startMonitoring() {
        q.async {
            guard !self.monitoring else { return }
            self.monitoring = true
            self.monitor.pathUpdateHandler = { [weak self] path in
                if path.status == .satisfied { self?.flush() }
            }
            self.monitor.start(queue: self.q)
        }
    }

    // MARK: - internals (always called on `q`)

    private func flushLocked() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        for file in files {
            guard
                let data = try? Data(contentsOf: file),
                let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let base = item["_base"] as? String,
                let license = item["_license"] as? String,
                let url = URL(string: base.hasSuffix("/") ? base + "v1/offline/submit"
                                                          : base + "/v1/offline/submit")
            else { try? FileManager.default.removeItem(at: file); continue }   // unparseable -> drop

            var body = item
            body.removeValue(forKey: "_base")
            body.removeValue(forKey: "_license")
            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                try? FileManager.default.removeItem(at: file); continue
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !license.isEmpty { req.setValue(license, forHTTPHeaderField: "X-License-Key") }
            req.httpBody = bodyData

            let sem = DispatchSemaphore(value: 0)
            var drop = false
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                // 2xx delivered, or 4xx (won't ever succeed) -> drop. 5xx / network -> keep & retry.
                drop = (200..<300).contains(code) || (400..<500).contains(code)
                sem.signal()
            }.resume()
            sem.wait()
            if drop { try? FileManager.default.removeItem(at: file) }
        }
    }
}
#endif
