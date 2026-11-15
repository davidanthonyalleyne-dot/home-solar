import SwiftUI
import WebKit
import WidgetKit

// Phase two of the native app: Now is drawn in SwiftUI from the same encrypted data.json the
// website uses; Month, History, Ask and Settings are still the web app, shown under a native
// tab bar. One web view serves those four tabs and moves into whichever tab is open.

// MARK: - Tabs

enum SolarTab: String, CaseIterable { case now, month, history, ask, settings }

struct MainTabs: View {
    let web: WKWebView
    @State private var tab: SolarTab = .now
    @StateObject private var now = NowModel()

    var body: some View {
        TabView(selection: $tab) {
            NowScreen(model: now) { open in
                // the status dot opens the SolarEdge page in Settings
                tab = .settings
                if open { WebTabs.openSolarEdge(web) }
            }
            .tabItem { Label("Now", systemImage: "sun.max") }
            .tag(SolarTab.now)
            ForEach([SolarTab.month, .history, .ask, .settings], id: \.self) { t in
                WebTab(web: web, tab: t, active: tab == t)
                    .ignoresSafeArea(edges: .top)
                    .tabItem { Label(t.title, systemImage: t.symbol) }
                    .tag(t)
            }
        }
        .tint(.primary)
    }
}

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

enum WebTabs {
    static func show(_ web: WKWebView, _ tab: SolarTab) {
        web.evaluateJavaScript("if (location.hash !== '#\(tab.rawValue)') location.hash = '#\(tab.rawValue)';")
    }
    static func openSolarEdge(_ web: WKWebView) {
        // the page's own handler: Settings, opened on SolarEdge
        let js = """
        (() => { const v = document.getElementById('view') || document.querySelector('main'); if (!v) return;
          const b = document.createElement('button'); b.setAttribute('data-gosolar', ''); b.hidden = true;
          v.appendChild(b); b.click(); b.remove(); })();
        """
        web.evaluateJavaScript(js)
    }
}

/// Holds the one web view; whichever web tab is showing takes it.
struct WebTab: UIViewRepresentable {
    let web: WKWebView
    let tab: SolarTab
    let active: Bool

    func makeUIView(context: Context) -> UIView {
        let v = UIView(); v.backgroundColor = .systemBackground
        return v
    }
    func updateUIView(_ host: UIView, context: Context) {
        guard active else { return }
        if web.superview !== host {
            web.removeFromSuperview()
            web.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(web)
            NSLayoutConstraint.activate([web.topAnchor.constraint(equalTo: host.topAnchor), web.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                         web.leadingAnchor.constraint(equalTo: host.leadingAnchor), web.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
        }
        WebTabs.show(web, tab)
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
    private var loadedAt: Date?

    func refresh(force: Bool = false) async {
        if !force, let t = loadedAt, Date().timeIntervalSince(t) < 120 { return }
        guard let snap = await Snapshot.build(), let json = SolarCrypto.lastJSON else { failed = data == nil; return }
        snap.cache()
        WidgetCenter.shared.reloadAllTimelines()
        loadedAt = Date()
        failed = false
        data = NowModel.make(snap, json)
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

// MARK: - The screen

struct NowScreen: View {
    @ObservedObject var model: NowModel
    let openStatus: (Bool) -> Void
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ScrollView {
            if let d = model.data {
                NowContent(d: d, openStatus: openStatus)
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            } else {
                VStack(spacing: 12) {
                    if model.failed {
                        Text("Solar can't reach your numbers right now.").foregroundStyle(.secondary)
                        Button("Try again") { Task { await model.refresh(force: true) } }
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity).padding(.top, 200)
            }
        }
        .refreshable { await model.refresh(force: true) }
        .task {
            await model.refresh(force: true)
            // keep the numbers current while Now is open; the build updates them every 10 to 15 minutes
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await model.refresh(force: true)
            }
        }
        .onChange(of: phase) { _, p in if p == .active { Task { await model.refresh() } } }
    }
}

struct NowContent: View {
    let d: NowData
    let openStatus: (Bool) -> Void

    private var sun: (rise: Date, set: Date) { SK.sun(d.day, lat: d.lat, lon: d.lon) }

    var body: some View {
        let now = Date(), st = sun
        let nowKw = d.fresh && now < st.set.addingTimeInterval(1800) ? d.nowKw : 0
        let todayKwh = d.fresh ? d.todayKwh : 0
        let liveGone = d.offline && now > st.rise && now < st.set
        let nowNote = liveGone ? "no live reading" : nowKw > 0 ? (d.peakKw.map { "of \(String(format: "%.2f", $0)) kW" } ?? "")
            : now < st.rise ? "sunrise \(clock(st.rise))" : now > st.set ? "sun set at \(clock(st.set))" : "not producing"
        let smallDay = todayKwh > 0 && todayKwh < 1
        let todayBig = d.offline && !d.fresh ? "–" : smallDay ? String(format: "%.0f", todayKwh * 1000) : String(format: "%.1f", todayKwh)
        let todayNote: String? = d.offline ? (d.fresh ? d.updated.map { "as of \(clock($0))" } : "waiting for SolarEdge")
            : d.expected.map { "\(String(format: "%.0f", $0)) kWh expected" }

        VStack(alignment: .leading, spacing: 0) {
            // header: date and the weather now, the title, the status dot
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(dateLine(now)).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        if let w = d.weather, let t = w.temp {
                            HStack(spacing: 4) {
                                WeatherGlyph(code: w.code, day: (w.isDay ?? 1) == 1, size: 13)
                                Text("\(Int(t.rounded()))° \(describe(w.code).lowercased())")
                            }
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                    Text("Now").font(.system(size: 34, weight: .bold)).tracking(-0.5)
                }
                Spacer()
                Button { openStatus(true) } label: {
                    Circle().fill(statusColor).frame(width: 10, height: 10).frame(width: 44, height: 44)
                }
                .accessibilityLabel("\(d.status.label). Open SolarEdge settings")
            }

            // generating now and so far today
            HStack(alignment: .top, spacing: 16) {
                Stat(label: "Generating now", value: liveGone ? "–" : (nowKw > 0 ? String(format: "%.2f", nowKw) : "0"), unit: "kW",
                     note: nowNote, sun: nowKw > 0 && !d.offline)
                Stat(label: "So far today", value: todayBig, unit: smallDay && !(d.offline && !d.fresh) ? "Wh" : "kWh",
                     note: todayNote, sun: false, dim: d.offline)
            }
            .padding(.top, 20)

            TodayChart(d: d, sun: st)
                .frame(height: 210)
                .padding(.top, 18)

            if let t = d.tomorrow {
                Divider().padding(.top, 20)
                HStack {
                    WeatherGlyph(code: t.code, size: 17)
                    Text("Tomorrow, \(describe(t.code).lowercased())").font(.system(size: 17))
                    Spacer()
                    if let hi = t.hi { Text("H \(Int(hi.rounded()))°").font(.system(size: 17)) }
                    if let lo = t.lo { Text("L \(Int(lo.rounded()))°").font(.system(size: 17)).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 12)
                Divider()
            }

            Text("Generated by solar").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.top, 24)
            HStack(alignment: .top, spacing: 0) {
                Total(label: "This month", value: SK.kwh(d.month))
                Divider().padding(.horizontal, 10)
                Total(label: "This year", value: grouped(d.year))
                Divider().padding(.horizontal, 10)
                Total(label: "Since \(d.since)", value: grouped(d.lifetime))
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)

            if let u = d.updated {
                Text("Updated \(ago(u))").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 16)
            }
        }
    }

    private var statusColor: Color {
        switch d.status.level {
        case "bad": return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.42, blue: 0.37, alpha: 1) : UIColor(red: 0.83, green: 0.23, blue: 0.17, alpha: 1) })
        case "warn": return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1) : UIColor(red: 0.9, green: 0.72, blue: 0, alpha: 1) })
        case "unknown": return .secondary
        default: return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1) : UIColor(red: 0.18, green: 0.62, blue: 0.36, alpha: 1) })
        }
    }
    private func dateLine(_ t: Date) -> String {
        let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "EEEE, MMMM d"; return f.string(from: t)
    }
    private func clock(_ t: Date) -> String {
        let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "h:mm a"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f.string(from: t)
    }
    private func grouped(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f.string(from: NSNumber(value: v)) ?? "\(Int(v))"
    }
    private func ago(_ t: Date) -> String {
        let m = Int(Date().timeIntervalSince(t) / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m) min ago" }
        if m < 24 * 60 { return "\(Int((Double(m) / 60).rounded())) hr ago" }
        let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "MMMM d, h:mm a"; f.amSymbol = "am"; f.pmSymbol = "pm"
        return f.string(from: t)
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

struct Stat: View {
    let label: String
    let value: String
    let unit: String
    let note: String?
    var sun = false
    var dim = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 44, weight: .semibold)).tracking(-1.2).monospacedDigit()
                    .foregroundStyle(sun ? SK.sunColor : (dim ? Color.secondary : Color.primary))
                Text(unit).font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            if let note, !note.isEmpty { Text(note).font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Total: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold)).tracking(-0.3).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text("kWh").font(.system(size: 15)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Today's output against what the forecast says the day should give, sunrise to sunset,
/// drawn the way the web app's chart is.
struct TodayChart: View {
    let d: NowData
    let sun: (rise: Date, set: Date)

    struct Layout { var rise, setH, nowH, expPeak, acMax, ymax, x0, x1: Double; var isDay: Bool; var pts: [[Double]]; var lastPt: [Double]? }

    func layout() -> Layout {
        let rise = SK.hours(sun.rise), set = SK.hours(sun.set), nowH = SK.hours(Date())
        let isDay = Date() > sun.rise && Date() < sun.set
        var pts = (d.fresh ? d.curve : []).filter { $0.count == 2 }
        // SolarEdge reports the unfinished quarter hour as 0; drop it while the sun is up
        if pts.count > 1, pts[pts.count - 1][1] == 0, pts[pts.count - 2][1] > 0.3 { pts.removeLast() }
        if nowH < set { while pts.count > 1, pts[pts.count - 1][1] == 0, pts.contains(where: { $0[1] > 0 }) { pts.removeLast() } }
        pts = pts.filter { $0[0] >= rise - 0.75 && $0[0] <= set + 0.75 }
        let expPeak = (d.expected ?? 0) * Double.pi / (2 * max(1, set - rise))
        let acMax = d.acKw ?? Double.infinity
        let ymax = max(1, min(expPeak, acMax), pts.map { $0[1] }.max() ?? 0) * 1.15
        let last = pts.last.flatMap { nowH < set + 0.5 && $0[1] > 0 ? $0 : nil }
        return Layout(rise: rise, setH: set, nowH: nowH, expPeak: expPeak, acMax: acMax, ymax: ymax, x0: rise - 0.6, x1: set + 0.6,
                      isDay: isDay, pts: pts, lastPt: last)
    }

    var body: some View {
        let L = layout()
        let rise = L.rise, set = L.setH, expPeak = L.expPeak, acMax = L.acMax, ymax = L.ymax, x0 = L.x0, x1 = L.x1
        let pts = L.pts, lastPt = L.lastPt, isDay = L.isDay
        Canvas { ctx, size in
            let top: CGFloat = 22, bot: CGFloat = 26, W = size.width, H = size.height
            let X = { (h: Double) in CGFloat((h - x0) / (x1 - x0)) * W }
            let Y = { (v: Double) in top + (H - top - bot) * CGFloat(1 - v / ymax) }
            let muted = Color.secondary
            // kW gridlines
            let step = ymax > 5 ? 2.0 : 1.0
            var v = step
            while v < ymax {
                var g = Path(); g.move(to: CGPoint(x: 0, y: Y(v))); g.addLine(to: CGPoint(x: W, y: Y(v)))
                ctx.stroke(g, with: .color(muted.opacity(0.25)), lineWidth: 0.5)
                ctx.draw(Text("\(Int(v)) kW").font(.system(size: 11)).foregroundStyle(muted), at: CGPoint(x: 0, y: Y(v) - 4), anchor: .bottomLeading)
                v += step
            }
            var axis = Path(); axis.move(to: CGPoint(x: 0, y: Y(0))); axis.addLine(to: CGPoint(x: W, y: Y(0)))
            ctx.stroke(axis, with: .color(muted.opacity(0.5)), lineWidth: 1)
            // the expected day, dashed
            if expPeak > 0 {
                var e = Path()
                for i in 0...48 {
                    let p = CGPoint(x: X(rise + (set - rise) * Double(i) / 48), y: Y(min(acMax, expPeak * sin(Double.pi * Double(i) / 48))))
                    if i == 0 { e.move(to: p) } else { e.addLine(to: p) }
                }
                ctx.stroke(e, with: .color(muted.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
            }
            // what the panels made
            if pts.contains(where: { $0[1] > 0 }) {
                var line = Path(), area = Path()
                area.move(to: CGPoint(x: X(pts[0][0]), y: Y(0)))
                for (i, p) in pts.enumerated() {
                    let c = CGPoint(x: X(p[0]), y: Y(p[1]))
                    if i == 0 { line.move(to: c) } else { line.addLine(to: c) }
                    area.addLine(to: c)
                }
                area.addLine(to: CGPoint(x: X(pts.last![0]), y: Y(0))); area.closeSubpath()
                ctx.fill(area, with: .color(SK.washColor))
                ctx.stroke(line, with: .color(SK.sunColor), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
                if let l = lastPt {
                    let c = CGPoint(x: X(l[0]), y: Y(l[1]))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)), with: .color(SK.sunColor))
                    let hh = Int(l[0]), mm = Int(((l[0] - Double(hh)) * 60).rounded())
                    let lab = "\(hh % 12 == 0 ? 12 : hh % 12):\(String(format: "%02d", mm))"
                    let right = c.x > W - 50
                    ctx.draw(Text(lab).font(.system(size: 12, weight: .semibold)).foregroundStyle(SK.sunColor),
                             at: CGPoint(x: c.x + (right ? -8 : 8), y: max(12, c.y - 7)), anchor: right ? .bottomTrailing : .bottomLeading)
                }
            }
            // sunrise, noon, sunset under the axis
            let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "h:mm"
            for (h, t, up) in [(rise, sun.rise, true), (set, sun.set, false)] {
                let x = X(h), y = Y(0) + 13
                var g = Path()
                g.move(to: CGPoint(x: x - 7, y: y + 3)); g.addLine(to: CGPoint(x: x + 7, y: y + 3))
                g.addArc(center: CGPoint(x: x, y: y + 3), radius: 4.2, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                ctx.stroke(g, with: .color(muted), lineWidth: 1.2)
                ctx.draw(Text(f.string(from: t)).font(.system(size: 11)).foregroundStyle(muted),
                         at: CGPoint(x: up ? x + 11 : x - 11, y: Y(0) + 17), anchor: up ? .leading : .trailing)
            }
            ctx.draw(Text("noon").font(.system(size: 11)).foregroundStyle(muted), at: CGPoint(x: X((rise + set) / 2), y: Y(0) + 17), anchor: .center)
        }
        .overlay(alignment: .topTrailing) {
            if !isDay {
                Image(systemName: moonSymbol(Date())).font(.system(size: 20)).foregroundStyle(.secondary).padding(.trailing, 4)
                    .accessibilityLabel("Moon")
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Solar power today, from sunrise to sunset")
    }

    private func moonSymbol(_ t: Date) -> String {
        let p = 29.530588853
        var ref = DateComponents(); ref.year = 2000; ref.month = 1; ref.day = 6; ref.hour = 18; ref.minute = 14
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let age = ((t.timeIntervalSince(cal.date(from: ref)!) / 86400).truncatingRemainder(dividingBy: p) + p).truncatingRemainder(dividingBy: p)
        switch age {
        case ..<1, (p - 1)...: return "moonphase.new.moon"
        case ..<(p / 4 - 1): return "moonphase.waxing.crescent"
        case ..<(p / 4 + 1): return "moonphase.first.quarter"
        case ..<(p / 2 - 1): return "moonphase.waxing.gibbous"
        case ..<(p / 2 + 1): return "moonphase.full.moon"
        case ..<(3 * p / 4 - 1): return "moonphase.waning.gibbous"
        case ..<(3 * p / 4 + 1): return "moonphase.last.quarter"
        default: return "moonphase.waning.crescent"
        }
    }
}
