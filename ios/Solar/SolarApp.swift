import SwiftUI
import UIKit
import BackgroundTasks
import AuthenticationServices
import LocalAuthentication
import WidgetKit

// Solar for iPhone and iPad, all SwiftUI. It reads the same encrypted data.json the website
// publishes. Opening it takes Sign in with Apple (once, then checked on every launch) and Face
// ID; the passphrase is entered once and kept in the keychain, shared with the widgets.

let solarURL = URL(string: "https://davidanthonyalleyne-dot.github.io/home-solar/")!

@main
struct SolarApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var gate = Gate()
    @Environment(\.scenePhase) private var phase

    init() { CrashReports.shared.start() }

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
        .onChange(of: phase) { _, now in
            gate.phaseChanged(now)
            if now == .background { BackgroundRefresh.schedule() }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.id)) { await BackgroundRefresh.run() }
    }
}

/// While Solar isn't open, iOS wakes it now and then (it decides when; roughly every half hour or
/// more) to fetch the latest numbers, so the widgets, Live Activity and Siri stay current.
enum BackgroundRefresh {
    static let id = "ca.davidalleyne.solar.refresh"
    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date().addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
    static func run() async {
        schedule()
        guard let snap = await Snapshot.build(), let json = SolarCrypto.lastJSON else { return }
        snap.cache()
        WidgetCenter.shared.reloadAllTimelines()
        await SolarActivity.update(snap)
        let s = json["solar"] as? [String: Any]
        await GitHub.nudgeIfLate(updated: SK.iso(s?["updated"] as? String), token: json["uploadToken"] as? String)
    }
}

// iPhone: a tab bar. iPad: a sidebar, the way iPad apps do it.
struct Unlocked: View {
    let onLock: () -> Void
    @Environment(\.horizontalSizeClass) private var size

    var body: some View {
        if size == .compact { MainTabs(onLock: onLock) } else { SidebarRoot(onLock: onLock) }
    }
}

// MARK: - Sign in with Apple + Face ID or Touch ID

/// What this device unlocks with: Face ID, Touch ID (older iPads and iPhones with a home
/// button, iPad Air and mini with the sensor in the top button), or Optic ID.
enum Bio {
    static let kind: LABiometryType = {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return c.biometryType
    }()
    static var name: String {
        switch kind {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .faceID: return "Face ID"
        default: return "your passcode"
        }
    }
    static var symbol: String {
        switch kind {
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .faceID: return "faceid"
        default: return "lock"
        }
    }
    static var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
}

@MainActor
final class Gate: ObservableObject {
    @Published var unlocked = false
    @Published var signedIn = Keychain.get("appleUser") != nil
    @Published var message: String?
    @Published var busy = false
    @Published var needsPassphrase = false   // Face ID passed, but this phone doesn't have the passphrase yet
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
        needsPassphrase = false
        message = nil
    }

    // the passphrase, once per phone; it's checked against the data before it's kept
    func submit(passphrase: String) async {
        busy = true; message = nil
        let ok = await SolarCrypto.adopt(passphrase: passphrase)
        busy = false
        if ok { needsPassphrase = false; unlocked = true; WidgetCenter.shared.reloadAllTimelines() }
        else { message = "That passphrase didn't work." }
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
        guard !busy else { return }   // one prompt at a time
        guard let user = Keychain.get("appleUser") else { signedIn = false; return }
        busy = true
        defer { busy = false }
        message = nil

        // Apple's check can hang with no answer (seen on an iPad); after a few seconds go on to
        // Touch ID or Face ID anyway, which still guards the app
        let state: ASAuthorizationAppleIDProvider.CredentialState = await withTaskGroup(of: ASAuthorizationAppleIDProvider.CredentialState?.self) { g in
            g.addTask {
                await withCheckedContinuation { (c: CheckedContinuation<ASAuthorizationAppleIDProvider.CredentialState?, Never>) in
                    ASAuthorizationAppleIDProvider().getCredentialState(forUserID: user) { s, _ in c.resume(returning: s) }
                }
            }
            g.addTask { try? await Task.sleep(for: .seconds(4)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first ?? .transferred   // unknown: treated as "couldn't check"
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
            // offline or Apple unreachable: open anyway
            break
        }

        // No Face ID or Touch ID: once the Apple Account checks out, Solar opens. The device's
        // own passcode is what guards it.
        if SharedVault.passphrase == nil { needsPassphrase = true } else { unlocked = true }
    }
}

struct LockView: View {
    @ObservedObject var gate: Gate
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            SunMark().frame(width: 92, height: 92)
            Text("Solar").font(.largeTitle.weight(.bold))
            Spacer()
            if gate.needsPassphrase {
                PassphraseEntry(gate: gate)
            } else if gate.signedIn {
                Button {
                    Task { await gate.unlock() }
                } label: {
                    Label("Open Solar", systemImage: "lock.open")
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
        // only once the app is really on screen; asked earlier, iOS cancels the prompt
        .onChange(of: phase, initial: true) { _, p in
            if p == .active, gate.signedIn, !gate.unlocked, !gate.busy, gate.autoPrompt { Task { await gate.unlock() } }
        }
    }
}

struct PassphraseEntry: View {
    @ObservedObject var gate: Gate
    @State private var pass = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 12) {
            Text("Enter your passphrase once. Solar keeps it in this \(Bio.device)'s keychain, so after this it opens straight away, and the widgets can read your numbers.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField("Passphrase", text: $pass)
                .textContentType(.password).submitLabel(.go).focused($focused)
                .padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .onSubmit { go() }
            Button(action: go) {
                Text(gate.busy ? "Checking…" : "Continue").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent).tint(.orange).disabled(gate.busy || pass.isEmpty)
        }
        .onAppear { focused = true }
    }
    private func go() { guard !pass.isEmpty else { return }; Task { await gate.submit(passphrase: pass) } }
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
