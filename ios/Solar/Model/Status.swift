import SwiftUI

// MARK: - System status, as the status dot works it out

struct StatusItem { var level: String; var title: String; var note: String }

enum SolarStatus {
    static func items(_ json: [String: Any]) -> (level: String, items: [StatusItem], connect: Bool)? {
        guard let s = json["solar"] as? [String: Any] else { return nil }
        let n = { (x: Any?) in (x as? NSNumber)?.doubleValue }
        var items: [StatusItem] = []
        let when = { (iso: Any?) -> String in SK.iso(iso as? String).map { Fmt.timeOf($0) } ?? "" }
        for x in (s["alerts"] as? [[String: Any]] ?? []) {
            var parts: [String] = []
            if let c = x["component"] as? String { parts.append(c) }
            if let i = n(x["impact"]) { parts.append("impact \(iInt(i)) of 9") }
            if let f = x["first"] { parts.append("since \(when(f))") }
            items.append(StatusItem(level: "bad", title: x["type"] as? String ?? "SolarEdge alert",
                                    note: parts.joined(separator: " · ") + ". SolarEdge also opened an issue in your GitHub repo, which emails you."))
        }
        let metrics = (s["inverter"] as? [String: Any])?["metrics"] as? [String: [String: Any]] ?? [:]
        let modeName = metrics.keys.first { $0.range(of: "mode|status|state", options: [.regularExpression, .caseInsensitive]) != nil }
        let mode = modeName.map { "\(metrics[$0]?["latest"] ?? "")".uppercased() } ?? ""
        let day = SK.day(Date()), sun = SK.sun(day), now = Date()
        let daylight = now > sun.rise && now < sun.set
        if daylight, mode.range(of: "FAULT|ERROR|SHUTDOWN|LOCKED", options: .regularExpression) != nil {
            items.append(StatusItem(level: "bad", title: "Inverter fault", note: "The inverter reports \(mode.lowercased().replacingOccurrences(of: "_", with: " ")). Check its light and the SolarEdge app."))
        }
        let updated = SK.iso(s["updated"] as? String)
        let age = updated.map { now.timeIntervalSince($0) } ?? 0
        let needsConnect = s["needsConnect"] as? Bool ?? false, trouble = s["authTroubleSince"] as? String
        let fresh = s["todayDate"] as? String == day && !needsConnect && trouble == nil && age < 75 * 60
        // only in daylight: after sunset the day's last reading stays put until morning, and that's normal
        if daylight, now.timeIntervalSince(sun.rise) > 90 * 60, !needsConnect, trouble == nil, age > 90 * 60, age < 36 * 3600 {
            items.append(StatusItem(level: "warn", title: "Numbers are \(Fmt.ago(updated!).replacingOccurrences(of: " ago", with: "")) old",
                                    note: "GitHub hasn't run the update since \(when(s["updated"])), so today's figures stop there. Solar has asked it to run now; fresh numbers usually follow within a few minutes. Your panels are probably fine."))
        }
        let wd = ((json["weather"] as? [String: Any])?["daily"] as? [String: [Any]])?[day]
        let snowy = wd.map { (n($0.count > 5 ? $0[5] : nil) ?? 0) > 0 || [71, 73, 75, 77, 85, 86].contains((($0.count > 2 ? $0[2] : nil) as? NSNumber)?.intValue ?? -1) } ?? false
        if fresh, daylight, now.timeIntervalSince(sun.rise) > 3 * 3600, (n(s["today"]) ?? 0) < 0.05, !snowy {
            items.append(StatusItem(level: "bad", title: "No production today", note: "Nothing since sunrise at \(Fmt.clock(sun.rise)). Check the inverter's light and the SolarEdge app."))
        }
        var connect = false
        let hasUrl = json["connectUrl"] as? String != nil
        if needsConnect {
            connect = hasUrl
            items.append(StatusItem(level: "warn", title: "SolarEdge needs you to sign in again", note: "The app can't get new numbers until you do. Showing the last ones, from \(when(s["updated"]))."))
        } else if let t = trouble {
            connect = hasUrl
            items.append(StatusItem(level: "warn", title: "No live data from SolarEdge", note: "SolarEdge has refused to renew the app's access since \(when(t)), so the numbers are from \(when(s["updated"])). Your panels are fine. Signing in again usually fixes it."))
        }
        if items.isEmpty {
            items.append(s["alertsChecked"] != nil ? StatusItem(level: "ok", title: "System normal", note: "")
                         : StatusItem(level: "unknown", title: "Alerts not checked yet", note: ""))
        }
        let level = items.contains { $0.level == "bad" } ? "bad" : items.contains { $0.level == "warn" } ? "warn" : items[0].level
        return (level, items, connect)
    }
}

/// One link in the chain from the panels to this app, as Settings shows it
struct ChainLink { var name: String; var symbol: String; var state: String; var level: String }

extension SolarStatus {
    /// Panels → inverter → SolarEdge → Solar, each with its own state, and one line saying what it adds up to
    static func chain(_ json: [String: Any]) -> (links: [ChainLink], line: String, level: String)? {
        guard let st = items(json), let s = json["solar"] as? [String: Any] else { return nil }
        let n = { (x: Any?) in (x as? NSNumber)?.doubleValue }
        let sun = SK.sun(SK.day(Date())), now = Date()
        let daylight = now > sun.rise && now < sun.set
        let has = { (t: String) in st.items.first { $0.title.localizedCaseInsensitiveContains(t) } }
        let needsConnect = s["needsConnect"] as? Bool ?? false, trouble = s["authTroubleSince"] != nil
        let kw = n(s["nowKw"]) ?? 0

        let panels: ChainLink
        if let x = has("No production today") { panels = ChainLink(name: "Panels", symbol: "sun.max", state: "No output", level: x.level) }
        else if !daylight { panels = ChainLink(name: "Panels", symbol: "moon.stars", state: "Resting", level: "rest") }
        else if needsConnect || trouble || has("Numbers are") != nil { panels = ChainLink(name: "Panels", symbol: "sun.max", state: "Can't tell", level: "rest") }
        else { panels = ChainLink(name: "Panels", symbol: "sun.max", state: kw > 0.01 ? "\(String(format: "%.1f", kw)) kW" : "Waking up", level: "ok") }

        let alert = st.items.first { $0.level == "bad" && $0.title != "No production today" }
        let inverter = alert.map { ChainLink(name: "Inverter", symbol: "bolt", state: $0.title == "Inverter fault" ? "Fault" : "Alert", level: "bad") }
            ?? (s["alertsChecked"] == nil ? ChainLink(name: "Inverter", symbol: "bolt", state: "Not checked", level: "unknown")
                : ChainLink(name: "Inverter", symbol: "bolt", state: "No faults", level: "ok"))

        let edge = needsConnect ? ChainLink(name: "SolarEdge", symbol: "cloud", state: "Sign in again", level: "warn")
            : trouble ? ChainLink(name: "SolarEdge", symbol: "cloud", state: "Not answering", level: "warn")
            : ChainLink(name: "SolarEdge", symbol: "cloud", state: "Signed in", level: "ok")

        let stale = has("Numbers are")
        // how fresh the numbers are: yellow when they should be new and aren't (never just because it's night)
        let upd = SK.iso(s["updated"] as? String)
        let fresh: String = upd.map { t in
            let m = Int(now.timeIntervalSince(t) / 60)
            if m < 1 { return "Updated\njust now" }
            if m < 60 { return "Updated\n\(m) min ago" }
            if m < 24 * 60 { return "Updated\n\(iInt((Double(m) / 60).rounded())) hr ago" }
            return "Updated\n" + MonthMath.date(SK.day(t), "MMM d")
        } ?? "No numbers yet"
        let app = ChainLink(name: "Data", symbol: "chart.xyaxis.line", state: fresh,
                            level: upd == nil ? "unknown" : (stale != nil || needsConnect || trouble) ? "warn" : "ok")

        let issue = st.items.first { $0.level == "bad" } ?? st.items.first { $0.level == "warn" }
        let line: String
        if let issue { line = issue.note.isEmpty ? issue.title : issue.note }
        else if !daylight { line = now < sun.rise ? "Night: no new numbers until sunrise at \(Fmt.clock(sun.rise)). That's normal." : "Evening: today's numbers are in. New ones start at sunrise tomorrow. That's normal." }
        else { line = "Everything is working. New numbers come in through the day." }
        return ([panels, inverter, edge, app], line, st.level)
    }
}

/// The four links in a row: an icon for each, coloured by how it's doing, with a word or two under it
struct ChainView: View {
    let links: [ChainLink]
    var big = false
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(links.enumerated()), id: \.offset) { i, l in
                if i > 0 {
                    Rectangle().fill(color(links[i - 1].level == "ok" && l.level == "ok" ? "ok" : "line")).frame(height: big ? 3 : 2)
                        .frame(maxWidth: big ? 60 : 18).padding(.top, big ? 34 : 19)
                }
                VStack(spacing: big ? 8 : 4) {
                    Image(systemName: l.symbol).font(.system(size: big ? 40 : 22, weight: .medium)).foregroundStyle(color(l.level))
                        .frame(height: big ? 68 : 38)
                    Text(l.name).font(.system(size: big ? 26 : 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(l.state).font(.system(size: big ? 22 : 12)).foregroundStyle(color(l.level == "rest" ? "text" : l.level))
                        .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
    }
    func color(_ level: String) -> Color {
        switch level {
        case "ok", "warn", "bad": return Fmt.statusColor(level)
        case "line": return Color.secondary.opacity(0.35)
        default: return .secondary
        }
    }
}

enum Fmt {
    static func clock(_ d: Date) -> String { let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "h:mm a"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f.string(from: d) }
    static func timeOf(_ d: Date) -> String { let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "MMM d 'at' h:mm a"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f.string(from: d) }
    static func ago(_ t: Date) -> String {
        let m = Int(Date().timeIntervalSince(t) / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m) min ago" }
        if m < 24 * 60 { return "\(iInt((Double(m) / 60).rounded())) hr ago" }
        let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "MMMM d, h:mm a"; f.amSymbol = "am"; f.pmSymbol = "pm"
        return f.string(from: t)
    }
    static func span(_ a: String, _ z: String) -> String { "\(MonthMath.shortDay(a)), \(a.prefix(4)) to \(MonthMath.shortDay(z)), \(z.prefix(4))" }
    static func statusColor(_ level: String) -> Color {
        switch level {
        case "bad": return Palette.bad
        case "warn": return Palette.dyn(0xE5B800, 0xFFD60A)
        case "unknown": return Palette.faint
        default: return Palette.dyn(0x2E9E5B, 0x30D158)
        }
    }
}

