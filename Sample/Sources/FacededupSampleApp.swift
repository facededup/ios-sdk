import SwiftUI
import UIKit
import FacededupLiveness

@main
struct FacededupSampleApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var present = false
    @State private var status = "Tap to verify. The UI loads from the app — works even in airplane mode (capture queues, verdict arrives by webhook on reconnect)."

    var body: some View {
        VStack(spacing: 24) {
            Text("Facededup Demo 1.1.0")
                .font(.title2).bold()
            Text(status)
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            Button {
                status = "Launching…"
                present = true
            } label: {
                Text("Verify your identity")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(red: 0x1E/255, green: 0x9C/255, blue: 0x69/255))
                    .cornerRadius(12)
            }
            .padding(.horizontal)
        }
        .padding()
        .fullScreenCover(isPresented: $present) {
            FacededupView { result in
                present = false
                status = render(result)
            }
            .ignoresSafeArea()
        }
    }

    private func render(_ r: FacededupResult?) -> String {
        guard let r = r else { return "Cancelled or no result." }
        if r.outcome == "queued" {
            return "OFFLINE → QUEUED ✓\nCapture stored on-device. Reconnect and the verdict is delivered to your webhook."
        }
        return "outcome = \(r.outcome ?? "nil")\nlive = \(String(describing: r.isLive))\nscore = \(String(describing: r.score))\npassed = \(r.passed)"
    }
}

/// Bridges the UIKit `FacededupVerificationController` into SwiftUI.
struct FacededupView: UIViewControllerRepresentable {
    let onFinish: (FacededupResult?) -> Void

    func makeUIViewController(context: Context) -> FacededupVerificationController {
        let config = FacededupConfig(
            baseURL: URL(string: "https://facededup.ai")!,
            licenseKey: "fdk_40cT6S_lWEpiCjd22ls8bLsL_YQnZNzq",
            subjectId: "demo-user-1",
            // Grouped, typed branding via the new FacededupTheme API.
            theme: FacededupTheme(primaryColor: "#1E9C69", backgroundColor: "#000000",
                                  textColor: "#FFFFFF", productName: "Facededup")
        )
        // Use the delegate only (it reports both finish AND cancel); passing the
        // onFinish closure too would double-fire on success.
        let vc = FacededupVerificationController(config: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: FacededupVerificationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, FacededupDelegate {
        let onFinish: (FacededupResult?) -> Void
        init(onFinish: @escaping (FacededupResult?) -> Void) { self.onFinish = onFinish }
        func facededup(_ controller: FacededupVerificationController, didFinish result: FacededupResult) {
            onFinish(result)
        }
        func facededupDidCancel(_ controller: FacededupVerificationController) {
            onFinish(nil)
        }
    }
}
