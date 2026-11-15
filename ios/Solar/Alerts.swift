import SwiftUI
import UIKit
import UserNotifications
import CryptoKit

// Alerts for the iPhone app, through Apple's push service. The app asks iOS for a device token
// and sends it, encrypted with the passphrase, through data/inbox with the kinds of alert you
// want; the hourly build keeps it encrypted in data/push.enc and sends each new alert once.
// The same five kinds as the Home Screen version.

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if UserDefaults.standard.bool(forKey: "alertsOn") { application.registerForRemoteNotifications() }   // tokens can change
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in Alerts.shared.gotToken(hex) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in Alerts.shared.gotToken(nil) }
    }
    // show alerts even while Solar is open
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@MainActor
final class Alerts: ObservableObject {
    static let shared = Alerts()
    static let kinds: [(key: String, title: String, note: String)] = [
        ("production", "Production or inverter problems", "No output on a sunny day, a fault, a SolarEdge alert"),
        ("connection", "No live data", "SolarEdge stops sending numbers for a couple of hours"),
        ("files", "Bills and meter files", "When a file you added is in, or couldn't be read"),
        ("summary", "Monthly summary", "On the 1st: what solar made, what you paid and saved"),
        ("winter", "Winter use", "A day when the house used far more than usual, and how cold it was"),
    ]

    @Published var prefs: [String: Bool]
    @Published var busy = false
    @Published var status: String?
    @Published var statusBad = false
    @Published private(set) var on: Bool

    private let ud = UserDefaults.standard
    private var token: String? { ud.string(forKey: "apnsToken") }
    private var waiting: CheckedContinuation<String?, Never>?

    private init() {
        prefs = (UserDefaults.standard.dictionary(forKey: "alertPrefs") as? [String: Bool])
            ?? Dictionary(uniqueKeysWithValues: Alerts.kinds.map { ($0.key, true) })
        on = UserDefaults.standard.bool(forKey: "alertsOn")
    }

    /// This phone's id as the build lists it in data.json
    var deviceID: String? {
        guard let t = token else { return nil }
        return SHA256.hash(data: Data("apns:\(t)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }
    /// Whether the build has this phone on its list yet
    func confirmed(_ json: [String: Any]?) -> Bool {
        guard let id = deviceID, let devs = (json?["push"] as? [String: Any])?["devices"] as? [[String: Any]] else { return false }
        return devs.contains { $0["id"] as? String == id }
    }

    func gotToken(_ hex: String?) {
        if let hex {
            if hex != token, on { ud.set(true, forKey: "alertsResend") }   // a new token: tell the build on the next refresh
            ud.set(hex, forKey: "apnsToken")
        }
        waiting?.resume(returning: hex); waiting = nil
    }

    private func requestToken() async -> String? {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return nil }
        return await withCheckedContinuation { c in
            waiting = c
            UIApplication.shared.registerForRemoteNotifications()
            Task { try? await Task.sleep(for: .seconds(20)); if let w = waiting { waiting = nil; w.resume(returning: token) } }
        }
    }

    /// Turns alerts on (with the kinds in prefs) or off, and tells the build.
    func save(turnOn: Bool, json: [String: Any]?) async {
        guard let upload = json?["uploadToken"] as? String else { fail("Solar can't send settings until the data has loaded."); return }
        if turnOn && !prefs.values.contains(true) { fail("Pick at least one kind of alert."); return }
        busy = true; status = turnOn ? "Asking iOS…" : "Turning off…"; statusBad = false
        defer { busy = false }
        var t = token
        if turnOn {
            t = await requestToken()
            guard t != nil else {
                fail("Notifications are off for Solar. Turn them on in the iPhone's Settings, Notifications, Solar, then try again.")
                return
            }
        }
        guard let t else { on = false; ud.set(false, forKey: "alertsOn"); status = "Alerts are off."; return }
        do {
            try await send(token: t, prefs: turnOn ? prefs : prefs.mapValues { _ in false }, upload: upload)
            on = turnOn
            ud.set(turnOn, forKey: "alertsOn"); ud.set(prefs, forKey: "alertPrefs"); ud.set(false, forKey: "alertsResend")
            status = turnOn ? "Saved. A first alert saying they're on arrives within the hour, when the next update runs." : "Alerts are off for this iPhone."
        } catch {
            fail("Couldn't reach GitHub: \(error.localizedDescription)")
        }
    }

    /// After a token change, sends the new one with the same choices.
    func resendIfNeeded(_ json: [String: Any]) async {
        guard on, ud.bool(forKey: "alertsResend"), let t = token, let upload = json["uploadToken"] as? String else { return }
        if (try? await send(token: t, prefs: prefs, upload: upload)) != nil { ud.set(false, forKey: "alertsResend") }
    }

    private func send(token t: String, prefs p: [String: Bool], upload: String) async throws {
        let msg: [String: Any] = ["apns": t, "prefs": p, "name": UIDevice.current.name]
        var box = try SolarCrypto.seal(try JSONSerialization.data(withJSONObject: msg))
        box["kind"] = "alerts"; box["ext"] = "json"
        try await GitHub.toInbox(box, kind: "alerts", message: p.values.contains(true) ? "Alerts from the iPhone app" : "Turn off alerts on an iPhone", token: upload)
    }

    private func fail(_ s: String) { status = s; statusBad = true }
}

/// Settings, Alerts
struct AlertsPage: View {
    let json: [String: Any]
    @ObservedObject private var alerts = Alerts.shared

    var body: some View {
        Section {
            ForEach(Alerts.kinds, id: \.key) { k in
                Toggle(isOn: Binding(get: { alerts.prefs[k.key] ?? false }, set: { alerts.prefs[k.key] = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(k.title)
                        Text(k.note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .tint(SK.sunColor)
            }
        } footer: {
            Text("Each alert comes once, when the hourly update finds it. Nothing about your energy is shown on the Lock Screen beyond the alert itself.")
        }
        Section {
            Button(alerts.on ? "Save" : "Turn on alerts") { Task { await alerts.save(turnOn: true, json: json) } }
                .disabled(alerts.busy)
            if alerts.on {
                Button("Turn off alerts on this iPhone", role: .destructive) { Task { await alerts.save(turnOn: false, json: json) } }
                    .disabled(alerts.busy)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let s = alerts.status { Text(s).foregroundStyle(alerts.statusBad ? Color.red : Color.secondary) }
                if alerts.on { Text(alerts.confirmed(json) ? "This iPhone is on the alert list." : "Waiting for the next update to add this iPhone.") }
            }
        }
    }
}
