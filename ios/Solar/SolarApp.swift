import SwiftUI
import WebKit

// Solar for iPhone: a native shell around the Solar web app on GitHub Pages.
// The web app stays the single source of truth; every build of the site shows up here
// on the next launch or pull to refresh, with no new TestFlight build needed.

let solarURL = URL(string: "https://davidanthonyalleyne-dot.github.io/home-solar/")!

@main
struct SolarApp: App {
    var body: some Scene {
        WindowGroup {
            SolarWebView(url: solarURL)
                .ignoresSafeArea()
                .background(Color(uiColor: .systemBackground))
        }
    }
}

struct SolarWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()   // keeps the unlock and saved chats between launches

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.scrollView.backgroundColor = .systemBackground
        // the page handles the notch and home bar itself (viewport-fit=cover)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = true
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif

        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        context.coordinator.webView = web

        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?

        @objc func reload(_ sender: UIRefreshControl) {
            webView?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { sender.endRefreshing() }
        }

        // Solar's own pages stay in the app. Anything else (SolarEdge sign-in, GitHub,
        // Toronto Hydro) opens in Safari.
        private func isSolar(_ url: URL) -> Bool {
            url.host == solarURL.host && url.path.hasPrefix(solarURL.path)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "about" || scheme == "blob" || scheme == "data" { return decisionHandler(.allow) }
            if action.targetFrame?.isMainFrame == false { return decisionHandler(.allow) }
            if isSolar(url) { return decisionHandler(.allow) }
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }

        // target="_blank" links
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url {
                if isSolar(url) { webView.load(action.request) } else { UIApplication.shared.open(url) }
            }
            return nil
        }

        // the Ask tab's mic button
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(origin.host == solarURL.host ? .grant : .deny)
        }

        // alert() / confirm() from the page
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            present(message, ok: { completionHandler() }, cancel: nil)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            present(message, ok: { completionHandler(true) }, cancel: { completionHandler(false) })
        }

        private func present(_ message: String, ok: @escaping () -> Void, cancel: (() -> Void)?) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            if let cancel { alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cancel() }) }
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in ok() })
            guard let root = webView?.window?.rootViewController else { ok(); return }
            var top = root
            while let next = top.presentedViewController { top = next }
            top.present(alert, animated: true)
        }

        // if the page fails to load (offline), try again when the app comes back
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let html = """
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <body style="font:17px -apple-system;display:flex;height:90vh;align-items:center;justify-content:center;text-align:center;color:#888">
            <div>Solar can't reach the internet.<br><br><a href="\(solarURL.absoluteString)">Try again</a></div></body>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}
