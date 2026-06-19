#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
import AVFoundation

/// Delegate for the drop-in flow. `onFinish` closure is an alternative.
public protocol FacededupDelegate: AnyObject {
    func facededup(_ controller: FacededupVerificationController, didFinish result: FacededupResult)
    func facededupDidCancel(_ controller: FacededupVerificationController)
}

public extension FacededupDelegate {
    func facededupDidCancel(_ controller: FacededupVerificationController) {}
}

/// Drop-in verification UI: hosts the hosted Facededup flow in a managed `WKWebView`,
/// grants camera/mic to the page, supplies the demo HTTP Basic password, runs device
/// attestation on request, and reports a typed ``FacededupResult``.
///
/// ```swift
/// let vc = FacededupVerificationController(config: .init(
///     baseURL: URL(string: "https://…")!, password: "…", subjectId: "user-123")) { result in
///     if result.passed { /* verified */ }
/// }
/// present(vc, animated: true)
/// ```
public final class FacededupVerificationController: UIViewController,
        WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {

    private let config: FacededupConfig
    public weak var delegate: FacededupDelegate?
    private let onFinish: ((FacededupResult) -> Void)?
    private var webView: WKWebView!
    private var finished = false
    private var offlineView: UIView?
    private let detector = FacededupVisionDetector()
    private let detectQueue = DispatchQueue(label: "ng.facededup.vision", qos: .userInitiated)

    public init(config: FacededupConfig, onFinish: ((FacededupResult) -> Void)? = nil) {
        self.config = config
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        let content = WKUserContentController()
        // Weak proxy so the WebView -> content controller -> handler chain doesn't
        // retain this view controller (otherwise it leaks after dismissal).
        let proxy = WeakScriptMessageHandler(self)
        content.add(proxy, name: "facededup")        // result bridge (postToHost)
        content.add(proxy, name: "facededupAttest")  // attestation request bridge
        content.add(proxy, name: "facededupDetect")  // hybrid: frame -> native Vision
        content.add(proxy, name: "facededupHaptic")  // haptic cue on action success (iOS has no navigator.vibrate)
        content.add(proxy, name: "facededupQueueOffline")  // offline capture -> deferred /v1/offline/submit

        // HYBRID DETECTION: tell the web flow to route on-device detection through
        // native Apple Vision (reliable in WKWebView) instead of the WASM Worker.
        // The page then ships frames to "facededupDetect" and reads results back from
        // window.__facededupPose(). The camera/preview/capture stay in the WebView.
        content.addUserScript(WKUserScript(source: "window.__FACEDEDUP_NATIVE_DETECT = true;",
            injectionTime: .atDocumentStart, forMainFrameOnly: false))

        // The page is gated by HTTP Basic. The navigation auth handler covers the
        // document load, but the page's own fetch() API calls need the header too —
        // inject window.__API_AUTH at document start (parity with Android) so every
        // /v1 call authenticates. Without this, verify/enroll calls 401 and the
        // flow "fails to pick the face".
        if let pw = config.password, !pw.isEmpty {
            let b64 = Data("facededup:\(pw)".utf8).base64EncodedString()  // username ignored server-side
            let js = "window.__API_AUTH = 'Basic \(b64)';"
            content.addUserScript(WKUserScript(source: js,
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }

        let cfg = WKWebViewConfiguration()
        cfg.userContentController = content
        cfg.allowsInlineMediaPlayback = true                    // no fullscreen takeover
        cfg.mediaTypesRequiringUserActionForPlayback = []       // camera can auto-start

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.uiDelegate = self
        wv.navigationDelegate = self
        wv.scrollView.bounces = false
        wv.allowsBackForwardNavigationGestures = false
        webView = wv
        view = wv
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        // Drain any captures queued offline in a previous session, and keep submitting
        // whenever connectivity returns while this controller is alive.
        FacededupOfflineStore.shared.startMonitoring()
        FacededupOfflineStore.shared.flush()
        primeCaptureThenLoad()
    }

    /// Prime camera + mic permission BEFORE the WebView calls getUserMedia.
    ///
    /// iOS only lets WKWebView capture audio/video if the app already holds (or can
    /// prompt for) the permission — which REQUIRES a usage string in the *host app's*
    /// Info.plist: `NSCameraUsageDescription` for video, `NSMicrophoneUsageDescription`
    /// for the mic. The read-a-number / voice challenge does `getUserMedia({audio:true})`,
    /// so without the microphone key it silently fails to record.
    ///
    /// We must NOT call `AVCaptureDevice.requestAccess` for a media type whose usage
    /// string is absent — iOS hard-crashes (TCC) in that case. So we guard on the key:
    /// prime when present, and log a loud warning when the mic key is missing so the
    /// integrator knows exactly why voice capture doesn't work.
    private func primeCaptureThenLoad() {
        func hasKey(_ k: String) -> Bool {
            (Bundle.main.object(forInfoDictionaryKey: k) as? String)?.isEmpty == false
        }
        // Best-effort audio session so WebKit can record alongside playback (TTS prompts).
        if hasKey("NSMicrophoneUsageDescription") {
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord,
                mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try? AVAudioSession.sharedInstance().setActive(true)
        } else {
            NSLog("[Facededup] ⚠️ NSMicrophoneUsageDescription is missing from Info.plist — "
                + "the read-a-number / voice challenge cannot record audio. Add it to enable voice.")
        }
        let group = DispatchGroup()
        if hasKey("NSCameraUsageDescription") {
            group.enter(); AVCaptureDevice.requestAccess(for: .video) { _ in group.leave() }
        }
        if hasKey("NSMicrophoneUsageDescription") {
            group.enter(); AVCaptureDevice.requestAccess(for: .audio) { _ in group.leave() }
        }
        group.notify(queue: .main) { [weak self] in self?.loadFlow() }
    }

    private func loadFlow() {
        var base = config.baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        var comps = URLComponents(string: base + "/demo/")
        var q = config.queryItems()
        // Cache-bust: a unique param per launch forces a fresh fetch of the HTML so a
        // cached page can't pin the device to an OLD build. We DON'T purge the data
        // store anymore — heavy static assets (9MB WASM, model, fonts) stay cached for
        // fast repeat launches; .useProtocolCachePolicy honours the HTML's no-store.
        q.append(URLQueryItem(name: "_cb", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        comps?.queryItems = q
        let pageURL = comps?.url

        // Load the verification UI from the SELF-CONTAINED bundled copy (no network) so
        // it opens even in airplane mode — no "no connection" screen. `pageURL` is the
        // BASE URL, so the page's origin stays the API host (secure context for
        // getUserMedia, same-origin /v1 calls). Only /v1 API calls go out; offline they
        // fail and the capture is queued (facededupQueueOffline -> /v1/offline/submit).
        // The offline flow is COMPILED IN (OfflineFlowHTML.swift, base64) so it's always
        // present — no resource bundle, no Bundle.module (which crashed). If decoding ever
        // fails, fall back to loading the hosted flow over the network.
        if let html = FacededupOfflineFlow.html {
            webView.loadHTMLString(html, baseURL: pageURL)
        } else if let url = pageURL {
            webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy))
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !finished && (isBeingDismissed || isMovingFromParent) {
            finished = true
            delegate?.facededupDidCancel(self)
        }
    }

    // MARK: camera/mic grant (iOS 15+)
    @available(iOS 15.0, *)
    public func webView(_ webView: WKWebView,
                        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo,
                        type: WKMediaCaptureType,
                        decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    // MARK: HTTP Basic password (server ignores the username)
    public func webView(_ webView: WKWebView,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
           let pw = config.password, !pw.isEmpty {
            completionHandler(.useCredential,
                              URLCredential(user: "facededup", password: pw, persistence: .forSession))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: offline / load-failure handling
    // The flow is server-hosted (verification needs the backend anyway), so a
    // failed load — e.g. airplane mode — shows a native "no connection · Retry"
    // screen instead of WebKit's raw error page.
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        clearOffline()
    }

    public func webView(_ webView: WKWebView,
                        didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showOfflineIfNetworkError(error)
    }

    public func webView(_ webView: WKWebView,
                        didFail navigation: WKNavigation!, withError error: Error) {
        showOfflineIfNetworkError(error)
    }

    private func showOfflineIfNetworkError(_ error: Error) {
        let code = (error as NSError).code
        if code == NSURLErrorCancelled { return }          // navigation superseded, not a failure
        guard offlineView == nil else { return }

        let container = UIView()
        container.backgroundColor = .systemBackground
        container.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "No internet connection"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "Verification needs a connection. Check your network and try again."
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0
        subtitle.textAlignment = .center

        let retry = UIButton(type: .system)
        retry.setTitle("Retry", for: .normal)
        retry.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, subtitle, retry])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
        ])
        offlineView = container
    }

    private func clearOffline() {
        offlineView?.removeFromSuperview()
        offlineView = nil
    }

    @objc private func retryTapped() {
        clearOffline()
        loadFlow()
    }

    // MARK: bridge messages
    public func userContentController(_ controller: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        switch message.name {
        case "facededup":
            guard !finished else { return }
            let result: FacededupResult
            if let s = message.body as? String {
                result = FacededupResult.from(json: s)
            } else if let d = message.body as? [String: Any] {
                result = FacededupResult.from(obj: d)
            } else {
                return
            }
            finished = true
            delegate?.facededup(self, didFinish: result)
            onFinish?(result)

        case "facededupAttest":
            let nonce = (message.body as? String) ?? ""
            Task { await self.handleAttestation(nonce: nonce) }

        case "facededupHaptic":
            // iOS WebKit has no navigator.vibrate, so the web flow asks us to buzz.
            let kind = (message.body as? String) ?? "tick"
            DispatchQueue.main.async {
                if kind == "success" {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    let g = UIImpactFeedbackGenerator(style: .medium)
                    g.prepare(); g.impactOccurred()
                }
            }

        case "facededupQueueOffline":
            // Device is offline: persist the capture and submit it to /v1/offline/submit
            // when connectivity returns. The verdict is delivered to the tenant's webhook.
            guard let payload = message.body as? String else { return }
            FacededupOfflineStore.shared.enqueue(
                payload: payload,
                base: config.baseURL.absoluteString,
                license: config.licenseKey ?? "")

        case "facededupDetect":
            guard let body = message.body as? [String: Any],
                  let b64 = body["jpeg"] as? String else { return }
            // Run Vision off the main thread, post the result back to the page.
            detectQueue.async { [weak self] in
                guard let self = self else { return }
                let res = self.detector.detect(base64JPEG: b64)
                guard let data = try? JSONSerialization.data(withJSONObject: res),
                      let json = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self.webView.evaluateJavaScript(
                        "window.__facededupPose && window.__facededupPose(\(json))",
                        completionHandler: nil)
                }
            }

        default:
            break
        }
    }

    /// Mint an attestation token for `nonce` (if a provider is configured) and hand
    /// it back to the web flow via `window.__onFacededupAttestation(token)`.
    private func handleAttestation(nonce: String) async {
        let token = await config.attestationProvider?(nonce)
        let arg = FacededupVerificationController.jsStringLiteral(token)
        await MainActor.run {
            self.webView.evaluateJavaScript(
                "window.__onFacededupAttestation && window.__onFacededupAttestation(\(arg))",
                completionHandler: nil)
        }
    }

    /// Encode `s` as a safe JS string literal, or the literal `null`.
    static func jsStringLiteral(_ s: String?) -> String {
        guard let s = s,
              let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else { return "null" }
        // ["<escaped>"] -> "<escaped>"
        return String(json.dropFirst().dropLast())
    }
}

/// Breaks the retain cycle WKWebView -> WKUserContentController -> handler.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
#endif
