import SwiftUI

// The data and the arithmetic every screen shares (iPhone, iPad and Apple TV), ported from web/app.js.

// MARK: - The data, read from data.json

struct SolarDB {
    let json: [String: Any]
    let hydro: [String: [Double]]
    let daily: [String: Double]
    let money: [String: [String: Any]]
    let bills: [[String: Any]]
    let weather: [String: [Any]]
    let factor: Double?
    let thermostat: [String: [Any]]
    let gridMonthly: [String: Double]
    let lat: Double, lon: Double

    init(_ j: [String: Any]) {
        json = j
        let n = { (x: Any?) in (x as? NSNumber)?.doubleValue }
        hydro = (j["hydro"] as? [String: [Any]] ?? [:]).mapValues { $0.map { n($0) ?? 0 } }
        daily = ((j["solar"] as? [String: Any])?["daily"] as? [String: Any] ?? [:]).compactMapValues { n($0) }
        money = (j["money"] as? [String: Any])?["months"] as? [String: [String: Any]] ?? [:]
        bills = j["bills"] as? [[String: Any]] ?? []
        let w = j["weather"] as? [String: Any] ?? [:]
        weather = w["daily"] as? [String: [Any]] ?? [:]
        factor = n(w["factor"])
        lat = n(w["lat"]) ?? 43.64; lon = n(w["lon"]) ?? -79.43
        thermostat = (j["thermostat"] as? [String: Any])?["daily"] as? [String: [Any]] ?? [:]
        gridMonthly = (j["gridMonthly"] as? [String: Any] ?? [:]).compactMapValues { n($0) }
        let keys = daily.keys.sorted()
        range = (keys.first ?? "", keys.last ?? "")
    }
    let range: (String, String)

    func m(_ ym: String) -> [String: Any]? { money[ym] }
    func num(_ ym: String, _ k: String) -> Double? { (money[ym]?[k] as? NSNumber)?.doubleValue }
    func w(_ d: String, _ i: Int) -> Double? { guard let r = weather[d], r.count > i else { return nil }; return (r[i] as? NSNumber)?.doubleValue }
    func th(_ d: String, _ i: Int) -> Double? { guard let r = thermostat[d], r.count > i else { return nil }; return (r[i] as? NSNumber)?.doubleValue }

    var months: [String] {
        var s = Set(hydro.keys.map { String($0.prefix(7)) })
        daily.keys.forEach { s.insert(String($0.prefix(7))) }
        for (k, v) in money where (v["preSolar"] as? Bool) != true { s.insert(k) }
        return s.sorted()
    }
    var defaultMonth: String? {
        let all = months
        let both = all.filter { ym in hydro.keys.contains { $0.hasPrefix(ym) } && daily.keys.contains { $0.hasPrefix(ym) } }
        return both.last ?? hydro.keys.map { String($0.prefix(7)) }.max() ?? all.last
    }

    struct Day { var d: String; var imp, exp, prod, selfUse, home: Double? }
    func monthDays(_ ym: String) -> [Day] {
        (1...MonthMath.daysIn(ym)).map { i -> Day in
            let d = String(format: "%@-%02d", ym, i)
            let h = hydro[d]
            var p = daily[d]
            if p == nil, !daily.isEmpty, let h, h.count > 1, h[1] < 0.05, d >= range.0, d <= range.1 { p = 0 }
            var r = Day(d: d, imp: h?.first, exp: h.flatMap { $0.count > 1 ? $0[1] : nil }, prod: p)
            if let p = r.prod, let e = r.exp, let i = r.imp { r.selfUse = max(0, p - e); r.home = i + r.selfUse! }
            return r
        }
    }
    struct Totals { var imp = 0.0, exp = 0.0, prod = 0.0, selfUse = 0.0, home = 0.0; var hDays = 0, pDays = 0, bothDays = 0 }
    func totals(_ days: [Day]) -> Totals {
        var t = Totals()
        for r in days {
            if let i = r.imp { t.imp += i; t.exp += r.exp ?? 0; t.hDays += 1 }
            if let p = r.prod { t.prod += p; t.pDays += 1 }
            if let s = r.selfUse { t.selfUse += s; t.home += r.home ?? 0; t.bothDays += 1 }
        }
        return t
    }
    struct Stats { var ym: String; var t: Totals; var home, imp, prod: Double?; var cover: Int? }
    func stats(_ ym: String) -> Stats {
        let t = totals(monthDays(ym))
        return Stats(ym: ym, t: t, home: t.bothDays > 0 ? t.home / Double(t.bothDays) : nil, imp: t.hDays > 0 ? t.imp / Double(t.hDays) : nil,
                     prod: t.pDays > 0 ? t.prod / Double(t.pDays) : nil, cover: t.bothDays > 0 ? MonthMath.pct(t.selfUse, t.home) : nil)
    }
    /// Each clear day's kWh per unit of sunlight, worked out once and shared by every lookup
    final class Memo { var ratios: [(day: Int, k: Double)]?; var factor: [String: Double?] = [:] }
    let memo = Memo()

    func factorAround(_ d: String) -> Double? {
        if let hit = memo.factor[d] { return hit }
        if memo.ratios == nil {
            memo.ratios = daily.compactMap { day, p in
                guard let rad = w(day, 4), rad >= 2, p >= 0.5, (w(day, 5) ?? 0) <= 0, ![71, 73, 75, 77, 85, 86].contains(iInt(w(day, 2) ?? 0)),
                      let n = SK.dayNum(day) else { return nil }
                return (n, p / rad)
            }
        }
        var out = factor
        if let t = SK.dayNum(d) {
            let r = memo.ratios!.filter { abs($0.day - t) <= 30 }.map(\.k).sorted()
            if r.count >= 7 { out = r[r.count / 2] }
        }
        memo.factor[d] = out
        return out
    }
    func expected(_ d: String) -> Double? { guard let rad = w(d, 4), let k = factorAround(d) else { return nil }; return k * rad }
    func bill(_ ym: String) -> [String: Any]? { bills.first { ($0["preSolar"] as? Bool) != true && ($0["to"] as? String ?? "").hasPrefix(ym) } }
}

enum MonthMath {
    static func daysIn(_ ym: String) -> Int {
        let p = ym.split(separator: "-").compactMap { Int($0) }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        guard p.count == 2, let d = c.date(from: DateComponents(year: p[0], month: p[1])) else { return 30 }
        return c.range(of: .day, in: .month, for: d)?.count ?? 30
    }
    static func pct(_ a: Double, _ b: Double) -> Int { b > 0 ? iInt((a / b * 100).rounded()) : 0 }
    static func change(_ a: Double, _ b: Double) -> Int { iInt(((a - b) / b * 100).rounded()) }
    static func niceStep(_ mx: Double) -> Double {
        let raw = max(mx, 0.0001) / 4, p = pow(10, floor(log10(raw))), f = raw / p
        return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * p
    }
    static func fmt(_ v: Double?, _ dp: Int = 0) -> String {
        guard let v, !v.isNaN else { return "–" }
        let f = NumberFormatter(); f.numberStyle = .decimal; f.minimumFractionDigits = dp; f.maximumFractionDigits = dp
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    static func kwh(_ v: Double) -> String { abs(v) >= 100 ? fmt(v) : fmt(v, 1) }
    static func dollars(_ v: Double) -> String { (v < 0 ? "−$" : "$") + fmt(abs(v).rounded()) }
    static func money(_ v: Double) -> String { (v < 0 ? "−$" : "$") + fmt(abs(v), 2) }
    static func date(_ d: String, _ format: String) -> String {
        guard let t = SK.date(d) else { return d }
        return SK.formatter(format).string(from: t)
    }
    static func shortDay(_ d: String) -> String { date(d, "MMM d") }
    static func dayName(_ d: String) -> String { date(d, "EEEE, MMMM d") }
    static func monthName(_ ym: String) -> String { date(ym + "-01", "MMMM") }
    static func monthYear(_ ym: String) -> String { date(ym + "-01", "MMMM yyyy") }
}

// MARK: - Colours, matching style.css

enum Palette {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        func c(_ x: UInt32) -> UIColor { UIColor(red: CGFloat((x >> 16) & 255) / 255, green: CGFloat((x >> 8) & 255) / 255, blue: CGFloat(x & 255) / 255, alpha: 1) }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? c(dark) : c(light) })
    }
    static let grid = dyn(0x3A3A3C, 0xC7C7CC)
    static let well = dyn(0xF2F2F4, 0x1C1C1E)
    static let faint = dyn(0xAEAEB2, 0x5E5E63)
    static let rule = dyn(0xE6E6E9, 0x2A2A2D)
    static let heat = dyn(0xF2A541, 0xF5B25A)
    static let aux = dyn(0xD9381E, 0xF0553A)
    static let bad = dyn(0xD33A2C, 0xFF6B5E)
}

/// Text with **bold** and !!bold red!! runs, for the "What changed" lines.
func richText(_ s: String, size: CGFloat = 15) -> Text {
    var out = Text("")
    var rest = Substring(s)
    while !rest.isEmpty {
        let b = rest.range(of: "**"), r = rest.range(of: "!!")
        guard let open = [b, r].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) else { out = out + Text(String(rest)); break }
        let mark = String(rest[open]), after = rest[open.upperBound...]
        out = out + Text(String(rest[..<open.lowerBound]))
        guard let close = after.range(of: mark) else { out = out + Text(String(rest[open.lowerBound...])); break }
        let inner = Text(String(after[..<close.lowerBound])).fontWeight(.semibold)
        out = out + (mark == "!!" ? inner.foregroundColor(Palette.bad) : inner)
        rest = after[close.upperBound...]
    }
    return out.font(.system(size: size))
}


extension SolarDB {
    struct YearTotal { var grid = 0.0, saved = 0.0, gridN = 0; var last: String? = nil, first: String? = nil; var prod: Double? = nil }
    func yearTotals() -> [String: YearTotal] {
        var ys: [String: YearTotal] = [:]
        for k in money.keys.sorted() {
            let y = String(k.prefix(4))
            var t = ys[y] ?? YearTotal()
            t.grid += num(k, "grid") ?? 0; t.saved += num(k, "saved") ?? 0
            if num(k, "grid") != nil { t.gridN += 1; t.last = k; if t.first == nil { t.first = k } }
            ys[y] = t
        }
        for (d, v) in daily { let y = String(d.prefix(4)); var t = ys[y] ?? YearTotal(); t.prod = (t.prod ?? 0) + v; ys[y] = t }
        return ys
    }
    func prodByMonth() -> [String: Double] {
        var out: [String: Double] = [:]
        for (d, v) in daily { out[String(d.prefix(7)), default: 0] += v }
        return out
    }
    var solarJSON: [String: Any] { json["solar"] as? [String: Any] ?? [:] }
    var installed: String? { solarJSON["installed"] as? String }
    var lifetime: Double { (solarJSON["lifetime"] as? NSNumber)?.doubleValue ?? daily.values.reduce(0, +) }
    var hasClimate: Bool { thermostat.count >= 20 }
    var isEstimate: (String) -> Bool { { money[$0]?["gridSource"] as? String == "estimate" } }
}

extension Palette {
    static let gridEst = dyn(0x8E8E93, 0x6E6E73)
    static let cool = dyn(0x4F7FA8, 0x6FA3D6)
}

struct ClimDay { var d: String; var heat, aux, cool, fan: Double; var set, inside, out, grid: Double? }

extension SolarDB {
    var climYears: [String] { Set(thermostat.keys.map { String($0.prefix(4)) }).sorted() }
    /// a calendar year, or the last 12 months when year is nil
    func climateData(_ year: String?) -> (days: [ClimDay], auxKw: Double, rate: Double) {
        let ks = thermostat.keys.sorted()
        var from = "", last = ""
        if let year { from = "\(year)-01-01"; last = "\(year)-12-31" }
        else if let l = ks.last, let t = SK.date(l) { last = l; from = SK.day(t.addingTimeInterval(-364 * 86400)) }
        let days = ks.filter { $0 >= from && $0 <= last }.map { d -> ClimDay in
            let out = th(d, 6) ?? { guard let a = w(d, 0), let b = w(d, 1) else { return nil }; return (a + b) / 2 }()
            return ClimDay(d: d, heat: th(d, 0) ?? 0, aux: th(d, 1) ?? 0, cool: th(d, 2) ?? 0, fan: th(d, 3) ?? 0,
                           set: th(d, 4), inside: th(d, 5), out: out, grid: hydro[d]?.first)
        }
        let hs = ((json["system"] as? [String: Any])?["heating"] as? [String: Any])?["backupHeat"] as? [String: Any]
        let auxKw = (hs?["kw"] as? NSNumber)?.doubleValue ?? 7.5
        let ms = money.keys.filter { $0 >= String(from.prefix(7)) && $0 <= String(last.prefix(7)) && num($0, "grid") != nil && (num($0, "imp") ?? 0) > 0 }
        let rate = ms.isEmpty ? 0.15 : ms.reduce(0) { $0 + (num($1, "grid") ?? 0) } / ms.reduce(0) { $0 + (num($1, "imp") ?? 0) }
        return (days, auxKw, rate)
    }
}

