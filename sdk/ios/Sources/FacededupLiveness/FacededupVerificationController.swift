#if canImport(UIKit)
import UIKit
import AVFoundation
import Vision
import CoreImage
import CoreVideo

/// Delegate for the drop-in flow. `onFinish` closure is an alternative.
public protocol FacededupDelegate: AnyObject {
    func facededup(_ controller: FacededupVerificationController, didFinish result: FacededupResult)
    func facededupDidCancel(_ controller: FacededupVerificationController)
}

public extension FacededupDelegate {
    func facededupDidCancel(_ controller: FacededupVerificationController) {}
}

/// NATIVE verification UI (2.0) — AVFoundation camera + Vision face detection drive an
/// active-liveness challenge ([ActiveLivenessTask]); proving frames submit to the
/// Facededup backend and a typed ``FacededupResult`` is reported. Replaces the 1.x
/// WKWebView host (no WebView, no getUserMedia, no offline-page bundling).
///
/// ```swift
/// let vc = FacededupVerificationController(config: .init(
///     baseURL: URL(string: "https://facededup.ai")!, licenseKey: "fdk_…", subjectId: "u1"))
/// vc.delegate = self
/// present(vc, animated: true)
/// ```
public final class FacededupVerificationController: UIViewController,
        AVCaptureVideoDataOutputSampleBufferDelegate {

    private let config: FacededupConfig
    public weak var delegate: FacededupDelegate?
    private let onFinish: ((FacededupResult) -> Void)?
    private var finished = false

    private let session = AVCaptureSession()
    private let detector = FacededupVisionDetector()
    private let camQueue = DispatchQueue(label: "ng.facededup.camera", qos: .userInitiated)
    private let ciContext = CIContext(options: nil)
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var overlay: OvalOverlayView!
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()

    private lazy var task = ActiveLivenessTask(actions: [])
    private var portrait: String?
    private var frames: [NativeLivenessSubmit.Frame] = []
    private var capturing = true
    private var lastAnalyze = Date.distantPast

    public init(config: FacededupConfig, onFinish: ((FacededupResult) -> Void)? = nil) {
        self.config = config
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = color(config.theme?.backgroundColor ?? config.backgroundColor) ?? .black
        buildUI()
        FacededupOfflineStore.shared.startMonitoring()
        FacededupOfflineStore.shared.flush()   // drain anything queued from a prior session
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async { if ok { self?.startSession() }
                    else { self?.report("{\"type\":\"liveness\",\"outcome\":\"error\",\"error\":\"camera_denied\"}") } }
            }
        default:
            report("{\"type\":\"liveness\",\"outcome\":\"error\",\"error\":\"camera_denied\"}")
        }
    }

    // MARK: UI

    private func buildUI() {
        overlay = OvalOverlayView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.ringColor = color(config.theme?.primaryColor ?? config.primaryColor) ?? UIColor(red: 0x1E/255, green: 0x9C/255, blue: 0x69/255, alpha: 1)
        view.addSubview(overlay)

        titleLabel.text = "Position your face"
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        hintLabel.text = "Center your face in the oval"
        hintLabel.font = .systemFont(ofSize: 16)
        for (i, l) in [titleLabel, hintLabel].enumerated() {
            l.textColor = .white; l.textAlignment = .center; l.numberOfLines = 0
            l.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                l.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
                l.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: i == 0 ? 32 : 76),
            ])
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: camera

    private func startSession() {
        camQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            let position: AVCaptureDevice.Position = (self.config.agentMode == true) ? .back : .front
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input)
            else { DispatchQueue.main.async { self.report("{\"type\":\"liveness\",\"outcome\":\"error\",\"error\":\"camera_init\"}") }; return }
            self.session.addInput(input)
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: self.camQueue)
            if self.session.canAddOutput(out) { self.session.addOutput(out) }
            self.session.commitConfiguration()

            DispatchQueue.main.async {
                let pl = AVCaptureVideoPreviewLayer(session: self.session)
                pl.videoGravity = .resizeAspectFill
                pl.frame = self.view.bounds
                pl.connection?.videoOrientation = .portrait
                self.view.layer.insertSublayer(pl, at: 0)
                self.previewLayer = pl
            }
            self.session.startRunning()
        }
    }

    private var orientation: CGImagePropertyOrientation { (config.agentMode == true) ? .right : .leftMirrored }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard capturing, !finished else { return }
        // Throttle detection to ~8 fps.
        if Date().timeIntervalSince(lastAnalyze) < 0.12 { return }
        lastAnalyze = Date()
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let res = detector.detect(pixelBuffer: pb, orientation: orientation)
        let present = (res["face"] as? Bool) ?? false
        let yaw = (res["yaw"] as? Double) ?? 0
        let smile = ((res["mouthSmileLeft"] as? Double) ?? 0)

        let proves = task.current.proves
        let satisfied = task.update(yaw: yaw, smile: smile, facePresent: present)
        if portrait == nil && present && abs(yaw) < 10 { portrait = jpeg(pb) }
        if satisfied, let b64 = jpeg(pb) { frames.append(.init(imageB64: b64, provesAction: proves)) }

        let finishedNow = task.isFinished
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.finished else { return }
            self.overlay.ringColor = present ? (self.color(self.config.theme?.primaryColor ?? self.config.primaryColor) ?? .systemGreen) : UIColor(red: 0xE2/255, green: 0x4B/255, blue: 0x4A/255, alpha: 1)
            self.titleLabel.text = finishedNow ? "Great" : "Step \(self.task.progress + 1) of \(self.task.total)"
            self.hintLabel.text = self.task.hint(facePresent: present)
        }
        if finishedNow && capturing { capturing = false; DispatchQueue.main.async { [weak self] in self?.submit() } }
    }

    private func jpeg(_ pb: CVPixelBuffer) -> String? {
        let ci = CIImage(cvPixelBuffer: pb).oriented(orientation)
        let opts: [CIImageRepresentationOption: Any] =
            [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85]
        guard let data = ciContext.jpegRepresentation(of: ci, colorSpace: CGColorSpaceCreateDeviceRGB(), options: opts)
        else { return nil }
        return data.base64EncodedString()
    }

    // MARK: submit + report

    private func submit() {
        if finished { return }
        titleLabel.text = "Checking…"; hintLabel.text = "One moment"
        session.stopRunning()
        var all: [NativeLivenessSubmit.Frame] = []
        if let p = portrait { all.append(.init(imageB64: p, provesAction: nil)) }
        all.append(contentsOf: frames)
        NativeLivenessSubmit.submit(base: config.baseURL.absoluteString, license: config.licenseKey ?? "",
                                    subjectId: config.subjectId ?? "user", method: config.method ?? "face_liveness",
                                    actions: task.actionKeys(), frames: all) { [weak self] json in
            DispatchQueue.main.async { self?.report(json) }
        }
    }

    private func report(_ json: String) {
        if finished { return }
        finished = true
        if session.isRunning { camQueue.async { self.session.stopRunning() } }
        let result = FacededupResult.from(json: json)
        delegate?.facededup(self, didFinish: result)
        onFinish?(result)
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if session.isRunning { camQueue.async { self.session.stopRunning() } }
        if !finished && (isBeingDismissed || isMovingFromParent) {
            finished = true
            delegate?.facededupDidCancel(self)
        }
    }

    private func color(_ hex: String?) -> UIColor? {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return nil }
        h.removeFirst()
        guard let v = UInt32(h, radix: 16), h.count == 6 else { return nil }
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Scrim with a centred oval cut-out + a coloured ring (native oval, replaces the web one).
final class OvalOverlayView: UIView {
    var ringColor: UIColor = .systemGreen { didSet { setNeedsDisplay() } }
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let ow = bounds.width * 0.66, oh = bounds.width * 0.66 * 1.32
        let oval = CGRect(x: (bounds.width - ow) / 2, y: bounds.height * 0.46 - oh / 2, width: ow, height: oh)
        ctx.setFillColor(UIColor(red: 0x0B/255, green: 0x1F/255, blue: 0x3A/255, alpha: 0.8).cgColor)
        ctx.fill(bounds)
        ctx.setBlendMode(.clear); ctx.fillEllipse(in: oval)
        ctx.setBlendMode(.normal)
        ctx.setStrokeColor(ringColor.cgColor); ctx.setLineWidth(5)
        ctx.strokeEllipse(in: oval)
    }
}
#endif
