import SwiftUI
import WebKit

struct RealtimeWebRTCBridgeView: NSViewRepresentable {
    @Environment(RealtimeWebRTCService.self) private var realtime

    func makeCoordinator() -> Coordinator {
        Coordinator(realtime: realtime)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.userContentController.add(context.coordinator, name: "realtimeBridge")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        realtime.attach(webView: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        realtime.attach(webView: webView)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
        private weak var realtime: RealtimeWebRTCService?

        init(realtime: RealtimeWebRTCService) {
            self.realtime = realtime
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            Task { @MainActor [weak self] in
                self?.realtime?.handleBridgeMessage(message.body)
            }
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.grant)
        }
    }
}
