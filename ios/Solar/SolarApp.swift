import SwiftUI
import WebKit
import AuthenticationServices
import LocalAuthentication
import WidgetKit

// Solar for iPhone: a native shell around the Solar web app on GitHub Pages.
// The web app stays the single source of truth; every build of the site shows up here
// on the next launch or pull to refresh, with no new TestFlight build needed.
//
// Opening it takes Sign in with Apple (once, then checked on every launch) and Face ID.
// After that the app hands the site its passphrase, so it's never typed here.

let solarURL = URL(string: "https://davidanthonyalleyne-dot.github.io/home-solar/")!

@main
struct SolarApp: App {
    @StateObject private var gate = Gate()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if PreviewNow.on {
                    PreviewNow()
                } else if gate.unlocked {
                    Unlocked(onLock: { gate.lock() })
                } else {
                    LockView(gate: gate)
                }
            }
            .background(Color(uiColor: .systemBackground))
        }
        .onChange(of: phase) { _, now in gate.phaseChanged(now) }
    }
}

// On iPhone: native tabs, with Now drawn natively. On iPad: the web app as it is, sidebar and all.
struct Unlocked: View {
    let onLock: () -> Void
    @Environment(\.horizontalSizeClass) private var size
    @StateObject private var host = WebHost()

    var body: some View {
        if size == .compact {
            MainTabs(web: host.web(onLock: onLock))
        } else {
            SolarWebView(url: solarURL, passphrase: Secrets.passphrase, onLock: onLock)
                .ignoresSafeArea()
        }
    }
}

/// The one web view the iPhone's Month, History, Ask and Settings tabs share.
@MainActor
final class WebHost: ObservableObject {
    private var made: (WKWebView, SolarWebView.Coordinator)?
    func web(onLock: @escaping () -> Void) -> WKWebView {
        if let made { return made.0 }
        let c = SolarWebView.Coordinator(onLock: onLock)
        let w = SolarWebView.build(url: solarURL, passphrase: Secrets.passphrase, coordinator: c, nativeTabs: true)
        made = (w, c)
        return w
    }
}

// MARK: - Sign in with Apple + Face ID

@MainActor
final class Gate: ObservableObject {
    @Published var unlocked = false
    @Published var signedIn = Keychain.get("appleUser") != nil
    @Published var message: String?
    @Published var busy = false
    var autoPrompt = true   // Face ID comes up by itself on launch and on return, not right after Lock
    private var backgroundedAt: Date?
    private let relockAfter: TimeInterval = 120

    func phaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = Date()
            autoPrompt = true
            WidgetCenter.shared.reloadAllTimelines()   // the widgets catch up with what you just saw
        case .active:
            if let t = backgroundedAt, unlocked, Date().timeIntervalSince(t) > relockAfter { lock() }
            backgroundedAt = nil
            if !unlocked && signedIn && !busy && autoPrompt { Task { await unlock() } }
        default: break
        }
    }

    func lock() {
        autoPrompt = false
        unlocked = false
        message = nil
    }

    // Sign in with Apple finished: remember which Apple Account this is, then Face ID.
    func finishSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else { return }
            if let pinned = Keychain.get("appleUser"), pinned != cred.user {
                message = "That Apple Account isn't the one Solar is set up for."
                return
            }
            Keychain.set("appleUser", cred.user)
            signedIn = true
            Task { await unlock() }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                message = "Sign in with Apple didn't finish. Try again."
            }
        }
    }

    // Every launch: is the Apple Account still signed in and still allowed, then Face ID.
    func unlock() async {
        guard let user = Keychain.get("appleUser") else { signedIn = false; return }
        busy = true
        defer { busy = false }
        message = nil

        let state = await withCheckedContinuation { (c: CheckedContinuation<ASAuthorizationAppleIDProvider.CredentialState, Never>) in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: user) { s, _ in c.resume(returning: s) }
        }
        switch state {
        case .authorized:
            break
        case .revoked, .notFound:
            Keychain.delete("appleUser")
            signedIn = false
            message = "Sign in with Apple again to open Solar."
            return
        default:
            // offline or Apple unreachable: Face ID still guards it
            break
        }

        let ctx = LAContext()
        ctx.localizedCancelTitle = "Not now"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            message = "Turn on Face ID or a passcode for this iPhone to open Solar."
            return
        }
        do {
            try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Solar")
            unlocked = true
        } catch {
            message = nil   // cancelled: the button stays there to try again
        }
    }
}

struct LockView: View {
    @ObservedObject var gate: Gate
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            SunMark().frame(width: 92, height: 92)
            Text("Solar").font(.largeTitle.weight(.bold))
            Spacer()
            if gate.signedIn {
                Button {
                    Task { await gate.unlock() }
                } label: {
                    Label("Unlock with Face ID", systemImage: "faceid")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(gate.busy)
            } else {
                SignInWithAppleButton(.signIn) { req in
                    req.requestedScopes = []
                } onCompletion: { gate.finishSignIn($0) }
                .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                .frame(height: 50)
            }
            Text(gate.message ?? " ")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 36)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .task { if gate.signedIn && !gate.unlocked && !gate.busy && gate.autoPrompt { await gate.unlock() } }
    }
}

// Solar's mark: the sun on the horizon
struct SunMark: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, cy = w * 0.63, r = w * 0.23
            ZStack {
                Path { p in
                    p.addArc(center: CGPoint(x: w / 2, y: cy), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                    p.closeSubpath()
                }.fill(Color.orange)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.16, y: cy)); p.addLine(to: CGPoint(x: w * 0.84, y: cy))
                }.stroke(Color.primary, style: StrokeStyle(lineWidth: w * 0.04, lineCap: .round))
            }
        }
    }
}

// MARK: - Keychain (this device only, never synced or backed up elsewhere)

enum Keychain {
    private static let service = "ca.davidalleyne.solar"
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - The web app

struct SolarWebView: UIViewRepresentable {
    let url: URL
    let passphrase: String
    let onLock: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLock: onLock) }

    func makeUIView(context: Context) -> WKWebView {
        SolarWebView.build(url: url, passphrase: passphrase, coordinator: context.coordinator, nativeTabs: false)
    }

    /// Makes the web view. With nativeTabs the page's own tab bar is hidden, because the app's is used.
    static func build(url: URL, passphrase: String, coordinator: Coordinator, nativeTabs: Bool) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()   // keeps saved Ask chats between launches

        // hand the site its passphrase (lock.js uses it instead of asking) and a way to lock
        let ctl = WKUserContentController()
        if !passphrase.isEmpty, let json = try? JSONSerialization.data(withJSONObject: [passphrase]),
           let arr = String(data: json, encoding: .utf8) {
            let js = "window.SolarNative = Object.freeze({ app: true, passphrase: \(arr)[0] });"
            ctl.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        } else {
            ctl.addUserScript(WKUserScript(source: "window.SolarNative = Object.freeze({ app: true });",
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if nativeTabs {
            let css = "const s = document.createElement('style'); s.textContent = '.tabs{display:none !important}'; document.head.appendChild(s);"
            ctl.addUserScript(WKUserScript(source: css, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        ctl.add(coordinator, name: "solar")
        config.userContentController = ctl

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = coordinator
        web.uiDelegate = coordinator
        web.allowsBackForwardNavigationGestures = false
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.scrollView.backgroundColor = .systemBackground
        // the page handles the notch and home bar itself (viewport-fit=cover)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = true

        let refresh = UIRefreshControl()
        refresh.addTarget(coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        coordinator.webView = web

        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "solar")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        let onLock: () -> Void
        init(onLock: @escaping () -> Void) { self.onLock = onLock }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.body as? String == "lock" { DispatchQueue.main.async { self.onLock() } }
        }

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

        // if the page fails to load (offline), offer to try again
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
