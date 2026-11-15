import SwiftUI
#if canImport(WidgetKit) && os(iOS)
import WidgetKit
#endif

enum SolarTab: String, CaseIterable { case now, month, history, ask, settings }

extension SolarTab {
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var symbol: String {
        switch self {
        case .now: return "sun.max"
        case .month: return "calendar"
        case .history: return "chart.bar"
        case .ask: return "bubble.left"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Data for Now

struct NowData {
    var day: String
    var nowKw: Double
    var todayKwh: Double
    var fresh: Bool
    var offline: Bool
    var updated: Date?
    var peakKw: Double?
    var acKw: Double?
    var month: Double
    var year: Double
    var lifetime: Double
    var since: String
    var curve: [[Double]]
    var expected: Double?
    var lat: Double
    var lon: Double
    var weather: Snapshot.Weather?
    var tomorrow: (code: Int?, hi: Double?, lo: Double?)?
    var status: (level: String, label: String)
}

@MainActor
final class NowModel: ObservableObject {
    @Published var data: NowData?
    @Published var failed = false
    @Published var json: [String: Any]? { didSet { db = json.map(SolarDB.init) } }
    /// The data, parsed once when it arrives, for every screen to share
    private(set) var db: SolarDB?
    @Published var selectedMonth: String?   // Month's month; History sets it when you tap a month
    @Published var settingsPath: [String] = []   // the Settings page that's open; the status dot opens SolarEdge
    var preview = false
    private var loadedAt: Date?
    private var loading = false

    /// Opens on the last data saved on this iPhone (still encrypted on disk), so Now shows at once,
    /// even with no signal; refresh() then brings it up to date.
    init(cached: Bool = true) {
        guard cached, let json = SolarCrypto.cached(), let snap = Snapshot.cached() else { return }
        self.json = json
        db = SolarDB(json)
        data = NowModel.make(snap, json)
    }

    func refresh(force: Bool = false) async {
        if preview || loading { return }
        if !force, let t = loadedAt, Date().timeIntervalSince(t) < 120 { return }
        loading = true; defer { loading = false }
        guard let snap = await Snapshot.build(), let json = SolarCrypto.lastJSON else { failed = data == nil; return }
        snap.cache()
        #if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        Task { await SolarActivity.update(snap, canStart: true) }
        #endif
        loadedAt = Date()
        failed = false
        // only hand the screens new data when it really changed, so nothing redraws for nothing
        if self.json.map({ !NSDictionary(dictionary: $0).isEqual(to: json) }) ?? true { self.json = json }
        data = NowModel.make(snap, json)
        let s = json["solar"] as? [String: Any]
        Task.detached { await GitHub.nudgeIfLate(updated: SK.iso(s?["updated"] as? String), token: json["uploadToken"] as? String) }
        #if os(iOS)
        Task.detached { await CrashReports.send(token: json["uploadToken"] as? String) }
        #endif
    }

    static func make(_ snap: Snapshot, _ json: [String: Any]) -> NowData {
        let s = json["solar"] as? [String: Any] ?? [:]
        let w = json["weather"] as? [String: Any] ?? [:]
        let num = { (x: Any?) in (x as? NSNumber)?.doubleValue }
        let day = SK.day(Date())
        let offline = (s["needsConnect"] as? Bool ?? false) || s["authTroubleSince"] as? String != nil
        let updated = SK.iso(s["updated"] as? String)
        let sys = (json["system"] as? [String: Any])?["inverter"] as? [String: Any]
        var tomorrow: (Int?, Double?, Double?)? = nil
        if let t = w["tomorrow"] as? [Any], t.count >= 4 { tomorrow = ((t[3] as? NSNumber)?.intValue, num(t[1]), num(t[2])) }

        // the status dot, as the web app works it out
        let sun = SK.sun(day, lat: snap.lat ?? 43.64, lon: snap.lon ?? -79.43), now = Date()
        let daylight = now > sun.rise && now < sun.set
        let age = updated.map { now.timeIntervalSince($0) } ?? 0
        let wd = (w["daily"] as? [String: [Any]])?[day]
        let snowy = wd.map { (num($0.count > 5 ? $0[5] : nil) ?? 0) > 0 || [71, 73, 75, 77, 85, 86].contains(($0.count > 2 ? $0[2] as? NSNumber : nil)?.intValue ?? -1) } ?? false
        let fresh = (s["todayDate"] as? String ?? day) == day
        var status = (level: "ok", label: "System normal")
        if s["alertsChecked"] == nil { status = ("unknown", "Alerts not checked yet") }
        if !offline, age > 90 * 60, age < 36 * 3600 { status = ("warn", "Numbers are late") }
        if offline { status = ("warn", s["needsConnect"] as? Bool == true ? "SolarEdge needs you to sign in again" : "No live data from SolarEdge") }
        if fresh, daylight, !offline, age < 75 * 60, now.timeIntervalSince(sun.rise) > 3 * 3600, snap.todayKwh < 0.05, !snowy { status = ("bad", "No production today") }
        if let alerts = s["alerts"] as? [Any], !alerts.isEmpty { status = ("bad", "SolarEdge alert") }

        return NowData(day: day, nowKw: snap.nowKw, todayKwh: snap.todayKwh, fresh: fresh, offline: offline, updated: updated,
                       peakKw: num(s["peakKw"]), acKw: num(sys?["acKw"]), month: num(s["month"]) ?? 0, year: num(s["year"]) ?? 0,
                       lifetime: num(s["lifetime"]) ?? 0, since: String((s["installed"] as? String ?? "install").prefix(4)),
                       curve: snap.curve, expected: snap.expectedKwh, lat: snap.lat ?? 43.64, lon: snap.lon ?? -79.43,
                       weather: snap.weather, tomorrow: tomorrow, status: status)
    }
}


func describe(_ code: Int?) -> String {
    switch code ?? -1 {
    case 0: return "Clear"
    case 1: return "Mostly clear"
    case 2: return "Partly cloudy"
    case 3: return "Cloudy"
    case 45, 48: return "Fog"
    case 51, 53, 55, 56, 57: return "Drizzle"
    case 61, 63, 65, 66, 67, 80, 81, 82: return "Rain"
    case 71, 73, 75, 77, 85, 86: return "Snow"
    case 95, 96, 99: return "Thunderstorms"
    default: return "—"
    }
}
