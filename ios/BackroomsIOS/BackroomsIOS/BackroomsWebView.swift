import SwiftUI
import UIKit
import WebKit
import CoreMotion

/// Hosts the existing locally bundled Three.js game. Native-only services are
/// exposed deliberately through one message handler, rather than allowing the
/// page to navigate to arbitrary web content.
struct BackroomsWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "backroomsNative")

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = true
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        #if DEBUG
        view.isInspectable = true   // Safari → Develop → device → index.html
        #endif
        context.coordinator.webView = view
        context.coordinator.observeApplicationLifecycle()

        guard let gameURL = Bundle.main.url(
            forResource: "index", withExtension: "html", subdirectory: "web"
        ) else {
            assertionFailure("The bundled web/index.html game resource is missing.")
            return view
        }

        // `web/index.html` refers to ../assets, so grant its parent bundle
        // directory read access instead of granting access to the whole device.
        view.loadFileURL(gameURL, allowingReadAccessTo: gameURL.deletingLastPathComponent().deletingLastPathComponent())
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        private let motionManager = CMMotionManager()
        private var lifecycleObservers: [NSObjectProtocol] = []

        deinit {
            motionManager.stopDeviceMotionUpdates()
            lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        }
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "backroomsNative",
                  let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else { return }

            switch type {
            case "haptic":
                playHaptic(pattern: payload["pattern"])
            case "gyro":
                setGyroEnabled(payload["enabled"] as? Bool ?? false)
            default:
                break
            }
        }

        func observeApplicationLifecycle() {
            guard lifecycleObservers.isEmpty else { return }
            let center = NotificationCenter.default
            lifecycleObservers.append(center.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.stopGyro()
                self?.dispatchGameEvent("backrooms:nativePause")
            })
            lifecycleObservers.append(center.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // The game re-arms gyro from its own settings state on this event.
                self?.dispatchGameEvent("backrooms:nativeResume")
            })
        }

        // Cached and pre-warmed: Taptic latency is the difference between a
        // hit that lands and a buzz that arrives after the scare is over.
        private let lightImpact = UIImpactFeedbackGenerator(style: .light)
        private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
        private let notice = UINotificationFeedbackGenerator()

        private func playHaptic(pattern: Any?) {
            let maximum = maxPatternValue(pattern)
            if maximum >= 100 {
                notice.notificationOccurred(.error)
                notice.prepare()
            } else if maximum >= 60 {
                heavyImpact.impactOccurred()
                heavyImpact.prepare()
            } else {
                lightImpact.impactOccurred()
                lightImpact.prepare()
            }
        }

        private func maxPatternValue(_ pattern: Any?) -> Int {
            if let value = pattern as? NSNumber { return value.intValue }
            if let values = pattern as? [NSNumber] { return values.map(\.intValue).max() ?? 0 }
            return 0
        }

        private func setGyroEnabled(_ enabled: Bool) {
            guard enabled, motionManager.isDeviceMotionAvailable else {
                stopGyro()
                return
            }
            guard !motionManager.isDeviceMotionActive else { return }

            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
            motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
                guard let self, let rotation = motion?.rotationRate else { return }
                // Device-frame rotation rates flip with the landscape direction,
                // so resolve the live interface orientation and mirror both axes —
                // the camcorder then feels identical however the phone is held.
                let orientation = self.webView?.window?.windowScene?.interfaceOrientation ?? .landscapeRight
                let mirror: Double = (orientation == .landscapeLeft) ? -1 : 1
                self.dispatchMotion(yaw: -rotation.y * mirror, pitch: rotation.x * mirror)
            }
        }

        private func stopGyro() {
            if motionManager.isDeviceMotionActive { motionManager.stopDeviceMotionUpdates() }
        }

        private func dispatchMotion(yaw: Double, pitch: Double) {
            guard yaw.isFinite, pitch.isFinite else { return }
            dispatchGameEvent(
                "backrooms:nativeMotion",
                detail: "{yaw:\(yaw),pitch:\(pitch),interval:\(motionManager.deviceMotionUpdateInterval)}"
            )
        }

        private func dispatchGameEvent(_ name: String, detail: String? = nil) {
            let detailExpression = detail.map { ",{detail:\($0)}" } ?? ""
            webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('\(name)'\(detailExpression)));")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The shipped game is local. Open external links only in Safari.
            if let url = navigationAction.request.url, !url.isFileURL, navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
