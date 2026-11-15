import SwiftUI

// Phase three: Month in SwiftUI. The arithmetic is the web app's (web/app.js: months, monthDays,
// totals, monthStats, facts, heatingBlock, ledger, daySheet, billSheet), ported line for line so
// both show the same numbers.

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
    func factorAround(_ d: String) -> Double? {
        guard let t = SK.date(d) else { return factor }
        var r: [Double] = []
        for (day, p) in daily {
            guard let rad = w(day, 4), rad >= 2, p >= 0.5, (w(day, 5) ?? 0) <= 0, ![71, 73, 75, 77, 85, 86].contains(Int(w(day, 2) ?? 0)),
                  let dt = SK.date(day), abs(dt.timeIntervalSince(t)) <= 30 * 86400 else { continue }
            r.append(p / rad)
        }
        r.sort()
        return r.count >= 7 ? r[r.count / 2] : factor
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
    static func pct(_ a: Double, _ b: Double) -> Int { b > 0 ? Int((a / b * 100).rounded()) : 0 }
    static func change(_ a: Double, _ b: Double) -> Int { Int(((a - b) / b * 100).rounded()) }
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
        let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = format; return f.string(from: t)
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

// MARK: - The screen

struct MonthScreen: View {
    @ObservedObject var model: NowModel
    private var ym: String? { model.selectedMonth }
    @State private var day: String? = nil
    @State private var sheet: SheetKind? = nil
    @State private var ledgerOpen = false

    enum SheetKind: Identifiable { case day(String), bill(String); var id: String { switch self { case .day(let d): return "d" + d; case .bill(let m): return "b" + m } } }

    var body: some View {
        ScrollView {
            if let j = model.json {
                let db = SolarDB(j)
                if let cur = ym ?? db.defaultMonth {
                    MonthBody(db: db, ym: cur, day: day, ledgerOpen: $ledgerOpen,
                              go: { model.selectedMonth = $0; day = nil },
                              tapDay: { day = $0; sheet = .day($0) },
                              openBill: { sheet = .bill(cur) })
                        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
                } else {
                    Text("No data yet.").foregroundStyle(.secondary).padding(.top, 200)
                }
            } else {
                ProgressView().padding(.top, 200)
            }
        }
        .refreshable { await model.refresh(force: true) }
        .task { await model.refresh() }
        .sheet(item: $sheet) { k in
            if let j = model.json {
                let db = SolarDB(j)
                NavigationStack {
                    ScrollView {
                        switch k {
                        case .day(let d): DaySheet(db: db, d: d).padding(20)
                        case .bill(let m): BillSheet(db: db, ym: m).padding(20)
                        }
                    }
                    .navigationTitle({ switch k { case .day(let d): return MonthMath.dayName(d); case .bill(let m): return "\(MonthMath.monthName(m)) bill" } }())
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}

struct MonthBody: View {
    let db: SolarDB
    let ym: String
    let day: String?
    @Binding var ledgerOpen: Bool
    let go: (String) -> Void
    let tapDay: (String) -> Void
    let openBill: () -> Void

    var body: some View {
        let all = db.months, i = all.firstIndex(of: ym) ?? 0
        let prev = i > 0 ? all[i - 1] : nil, next = i < all.count - 1 ? all[i + 1] : nil, latest = db.defaultMonth
        VStack(alignment: .leading, spacing: 0) {
            // header
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(ym.prefix(4))).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Text(MonthMath.monthName(ym)).font(.system(size: 34, weight: .bold)).tracking(-0.5)
                }
                Spacer()
                HStack(spacing: 8) {
                    StepButton(symbol: "chevron.left", label: "Previous month", target: prev, go: go)
                    StepButton(symbol: "chevron.right", label: "Next month", target: next, go: go)
                    if let latest, ym < latest { StepButton(symbol: "forward.end", label: "Latest month", target: latest, go: go) }
                }
                .padding(.bottom, 4)
            }
            YearStrip(db: db, ym: ym, go: go).padding(.top, 14)
            Rectangle().fill(Palette.rule).frame(height: 1).padding(.top, 14)
            MoneyBlock(db: db, ym: ym, openBill: openBill).padding(.top, 22)
            DayChart(db: db, ym: ym, selected: day, tap: tapDay).padding(.top, 28)
            Facts(db: db, ym: ym).padding(.top, 26)
            Heating(db: db, ym: ym).padding(.top, 26)
            Ledger(db: db, ym: ym, open: $ledgerOpen).padding(.top, 26)
        }
    }
}

struct StepButton: View {
    let symbol: String, label: String, target: String?
    let go: (String) -> Void
    var body: some View {
        Button { if let target { go(target) } } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36).background(Palette.well, in: Circle())
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .foregroundStyle(target == nil ? Palette.faint : Color.primary)
        .disabled(target == nil)
        .accessibilityLabel(label)
    }
}

struct YearStrip: View {
    let db: SolarDB, ym: String
    let go: (String) -> Void
    var body: some View {
        let year = String(ym.prefix(4)), all = Set(db.months)
        let yms = (1...12).map { String(format: "%@-%02d", year, $0) }
        let cost = { (m: String) -> Double? in guard let g = db.num(m, "grid") else { return nil }; return g + max(0, db.num(m, "saved") ?? 0) }
        let useMoney = yms.contains { cost($0) != nil }
        let energy = { (m: String) -> Double? in let t = db.stats(m).t; return t.hDays > 0 ? t.imp + t.selfUse : (t.prod > 0 ? t.prod : nil) }
        let vals = yms.map { all.contains($0) ? (useMoney ? cost($0) : energy($0)) : nil }
        let mx = max(1, vals.compactMap { $0 }.max() ?? 1)
        HStack(spacing: 3) {
            ForEach(Array(yms.enumerated()), id: \.offset) { i, m in
                let on = m == ym, has = all.contains(m)
                Button { go(m) } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            Color.clear.frame(height: 34)
                            if let v = vals[i] {
                                RoundedRectangle(cornerRadius: 2).fill(on ? Color.primary : Palette.faint.opacity(0.55)).frame(height: 4 + 30 * v / mx)
                            } else if has {
                                RoundedRectangle(cornerRadius: 2).fill(on ? Color.primary : Palette.faint.opacity(0.55)).frame(height: 3)
                            } else {
                                RoundedRectangle(cornerRadius: 2).strokeBorder(Palette.rule, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(height: 8)
                            }
                        }
                        Text(MonthMath.date(m + "-01", "MMMMM")).font(.system(size: 11, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.primary : Palette.faint)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!has)
                .accessibilityLabel(MonthMath.monthYear(m))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

struct MoneyBlock: View {
    let db: SolarDB, ym: String
    let openBill: () -> Void
    @State private var showNote = false

    var body: some View {
        let grid = db.num(ym, "grid"), saved = db.num(ym, "saved"), without = db.num(ym, "without")
        let isBill = db.m(ym)?["gridSource"] as? String == "bill", sofar = db.m(ym)?["complete"] as? Bool == false
        let credits = db.num(ym, "credits") ?? 0, selfValue = db.num(ym, "selfValue") ?? 0
        let t = db.totals(db.monthDays(ym))
        let sentBack = t.hDays >= 25 ? t.exp : (db.num(ym, "exp") ?? 0)
        let note: String? = credits >= 1 && db.num(ym, "exp") != nil
            ? "Includes an estimated \(MonthMath.dollars(credits)) in net metering credits for \(MonthMath.fmt(sentBack)) kWh sent back\(selfValue >= 1 ? ", and \(MonthMath.dollars(selfValue)) of power the house took straight from the panels" : "")."
            : nil
        if db.m(ym) != nil, grid != nil || saved != nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paid to the grid").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        Text(grid.map { MonthMath.dollars($0) } ?? "–").font(.system(size: 44, weight: .semibold)).tracking(-1.2).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { if note != nil { showNote = true } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 2) {
                                Text("Saved by solar\(sofar ? " so far" : "")").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                if note != nil { Text("*").font(.system(size: 13, weight: .semibold)).foregroundStyle(SK.sunColor) }
                            }
                            Text(saved.map { MonthMath.dollars($0) } ?? "–").font(.system(size: 44, weight: .semibold)).tracking(-1.2).monospacedDigit()
                                .foregroundStyle(SK.sunColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showNote) {
                        Text(note ?? "").font(.system(size: 13)).foregroundStyle(.secondary).padding(16).frame(width: 260)
                            .presentationCompactAdaptation(.popover)
                    }
                }
                if let g = grid, let s = saved, let w = without, w > 0 {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            Rectangle().fill(Palette.grid).frame(width: max(2, (geo.size.width - 2) * g / max(0.01, g + max(0, s))))
                            Rectangle().fill(SK.sunColor)
                        }
                    }
                    .frame(height: 10).clipShape(Capsule()).padding(.top, 18)
                    (Text("Without solar, \(MonthMath.monthName(ym)) would have cost ") + Text(MonthMath.dollars(w)).fontWeight(.bold) + Text("."))
                        .font(.system(size: 17)).padding(.top, 14)
                } else if grid == nil {
                    Text(sofar ? "The grid cost shows once the month is over and the meter data is in." : "No meter data or bill for this month, so the grid cost isn't known.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 8)
                }
                if isBill, db.bill(ym) != nil {
                    Button(action: openBill) {
                        HStack { Text("From your Toronto Hydro bill"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.faint) }
                            .font(.system(size: 15)).foregroundStyle(.secondary).padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.top, 6)
                } else if grid != nil {
                    Text("\(t.hDays > 0 ? "Estimated from your meter" : "Estimated from the kWh on your later bills"). No bill on file for \(MonthMath.monthName(ym)).")
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
        }
    }
}

struct DayChart: View {
    let db: SolarDB, ym: String, selected: String?
    let tap: (String) -> Void

    var body: some View {
        let days = db.monthDays(ym)
        let hasHome = days.contains { $0.home != nil }, hasImp = days.contains { $0.imp != nil }, hasProd = days.contains { $0.prod != nil }
        if hasImp || hasProd {
            let segs: (SolarDB.Day) -> [(Double, Color)]? = { r in
                if r.home != nil { return [(r.imp ?? 0, Palette.grid), (r.selfUse ?? 0, SK.sunColor)] }
                if let i = r.imp { return [(i, Palette.grid)] }
                if !hasImp, let p = r.prod { return [(p, SK.sunColor)] }
                return nil
            }
            let val = { (r: SolarDB.Day) -> Double? in segs(r).map { s in s.reduce(0) { $0 + $1.0 } } }
            let vals = days.compactMap(val)
            let avg = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
            let step = MonthMath.niceStep(vals.max() ?? 1), ymax = max(step, ceil((vals.max() ?? 1) / step) * step)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    if hasImp { LegendDot(color: Palette.grid, text: "Grid") }
                    if hasHome || !hasImp { LegendDot(color: SK.sunColor, text: "Solar") }
                    Spacer()
                    Text("kWh a day").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    let W = geo.size.width, H: CGFloat = 214, top: CGFloat = 28, bot: CGFloat = 20, right: CGFloat = 44
                    let pw = W - right, n = CGFloat(days.count), bw = pw / n
                    let Y = { (v: Double) in top + (H - top - bot) * CGFloat(1 - v / ymax) }
                    Canvas { ctx, _ in
                        var v = step
                        while v <= ymax + 1e-9 {
                            var g = Path(); g.move(to: CGPoint(x: 0, y: Y(v))); g.addLine(to: CGPoint(x: pw, y: Y(v)))
                            ctx.stroke(g, with: .color(Palette.rule), lineWidth: 1)
                            if abs(Y(v) - Y(avg)) > 12 {
                                ctx.draw(Text(MonthMath.fmt(v)).font(.system(size: 11)).foregroundStyle(.secondary), at: CGPoint(x: pw + 6, y: Y(v)), anchor: .leading)
                            }
                            v += step
                        }
                        for (i, r) in days.enumerated() {
                            let x = CGFloat(i) * bw
                            if r.d == selected {
                                ctx.fill(Path(roundedRect: CGRect(x: x, y: top - 6, width: bw, height: H - bot + 8 - top), cornerRadius: 3), with: .color(Palette.well))
                                let cx = min(pw - 40, max(40, x + bw / 2))
                                let lab = "\(MonthMath.shortDay(r.d)): \(val(r).map { MonthMath.kwh($0) + " kWh" } ?? "no data")"
                                ctx.draw(Text(lab).font(.system(size: 12, weight: .semibold)), at: CGPoint(x: cx, y: 10), anchor: .center)
                            }
                            var acc = 0.0
                            for (v, c) in segs(r) ?? [] {
                                ctx.fill(Path(CGRect(x: x + 1, y: Y(acc + v), width: max(1.5, bw - 2), height: max(0, Y(acc) - Y(acc + v)))), with: .color(c))
                                acc += v
                            }
                        }
                        var a = Path(); a.move(to: CGPoint(x: 0, y: Y(avg))); a.addLine(to: CGPoint(x: pw, y: Y(avg)))
                        ctx.stroke(a, with: .color(.primary), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        ctx.draw(Text("avg \(avg < 10 ? MonthMath.fmt(avg, 1) : MonthMath.fmt(avg))").font(.system(size: 11, weight: .semibold)),
                                 at: CGPoint(x: pw + 6, y: Y(avg)), anchor: .leading)
                        for d in [1, 8, 15, 22, 29] where d <= days.count {
                            ctx.draw(Text("\(d)").font(.system(size: 11)).foregroundStyle(.secondary), at: CGPoint(x: (CGFloat(d) - 0.5) * bw, y: H - 6), anchor: .center)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { p in
                        let i = Int(p.x / bw)
                        if i >= 0, i < days.count { tap(days[i].d) }
                    }
                }
                .frame(height: 214)
                .accessibilityElement()
                .accessibilityLabel("Daily chart. Average \(MonthMath.kwh(avg)) kWh a day.")
                Text("Tap a day to see it.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }
}

struct LegendDot: View {
    let color: Color, text: String
    var body: some View {
        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12); Text(text).font(.system(size: 13)).foregroundStyle(.secondary) }
    }
}

struct Facts: View {
    let db: SolarDB, ym: String

    var lines: [String] {
        let days = db.monthDays(ym), cur = db.stats(ym)
        let all = db.months, i = all.firstIndex(of: ym) ?? 0
        let prev = i > 0 ? db.stats(all[i - 1]) : nil, pn = prev.map { MonthMath.monthName($0.ym) } ?? ""
        let mo = Int(ym.suffix(2)) ?? 1
        var out: [(Int, String)] = []
        let today = SK.day(Date())

        let prodDays = days.filter { ($0.prod ?? 0) > 0.5 }
        let typical = prodDays.isEmpty ? 0 : prodDays.reduce(0) { $0 + ($1.prod ?? 0) } / Double(prodDays.count)
        let dead = days.filter { $0.imp != nil && ($0.exp ?? 0) < 0.05 && ($0.prod ?? 0) < 0.5 && typical > 8 }
        if dead.count >= 2 {
            let range = dead.count > 2 ? "\(MonthMath.shortDay(dead[0].d)) to \(MonthMath.shortDay(dead.last!.d))" : dead.map { MonthMath.shortDay($0.d) }.joined(separator: " and ")
            out.append((0, "!!No solar on \(dead.count) days!!, \(range). The meter shows nothing sent back either, so the system was likely off. That's about **\(MonthMath.fmt(typical * Double(dead.count)))** kWh missed."))
        }
        let perf = days.compactMap { r -> (SolarDB.Day, Double)? in
            guard r.prod != nil, let e = db.expected(r.d), e > 1, r.d < today else { return nil }; return (r, e)
        }
        if perf.count >= 7 {
            let act = perf.reduce(0) { $0 + ($1.0.prod ?? 0) }, ex = perf.reduce(0) { $0 + $1.1 }, p = MonthMath.pct(act, ex)
            let weak = perf.filter { $0.1 >= 8 && ($0.0.prod ?? 0) < 0.6 * $0.1 && (db.w($0.0.d, 5) ?? 0) <= 0 }
            let overall = p >= 95 ? "Overall your solar output matched the available sunshine."
                : p >= 85 ? "Overall your solar output was a little under the available sunshine, at **\(p)%**."
                : "Overall your solar output fell short of the available sunshine, at !!\(p)%!!."
            let names = weak.prefix(3).map { MonthMath.shortDay($0.0.d) }, more = weak.count - names.count
            let list = more > 0 ? "\(names.joined(separator: ", ")) and \(more) more \(more == 1 ? "day" : "days")"
                : names.count > 1 ? "\(names.dropLast().joined(separator: ", ")) and \(names.last!)" : names.first ?? ""
            out.append((p < 85 ? 1 : 4, overall + (weak.isEmpty ? "" : " \(list) underperformed.")))
        }
        let curUse = cur.home ?? cur.imp
        let prevUse = prev.flatMap { cur.home != nil ? $0.home : $0.imp }
        if let c0 = curUse, let p0 = prevUse, p0 > 0 {
            let c = MonthMath.change(c0, p0), what = cur.home != nil ? "Home use" : "Grid use"
            if abs(c) >= 5 {
                let extra = c > 15 && mo >= 9 ? " Heating has started." : c < -15 && mo <= 6 ? " Less heating as it warms up." : ""
                out.append((2, "\(what) \(c > 0 ? "rose" : "fell") **\(abs(c))%** on \(pn), to **\(MonthMath.fmt(c0))** kWh a day.\(extra)"))
            } else {
                out.append((6, "\(what) held steady at **\(MonthMath.fmt(c0))** kWh a day."))
            }
        }
        if let cv = cur.cover {
            let p = prev?.cover
            out.append((3, "Solar covered **\(cv)%** of the house\(p != nil && p != cv ? ", \(cv > p! ? "up" : "down") from \(p!)%" : "")."))
        }
        let ly = "\((Int(ym.prefix(4)) ?? 0) - 1)\(ym.dropFirst(4))", lys = db.stats(ly)
        if let cp = cur.prod, let lp = lys.prod, lp > 0, lys.t.pDays >= 20 {
            let c = MonthMath.change(cp, lp)
            out.append((5, "Solar was **\(abs(c))%** \(c >= 0 ? "higher" : "lower") than \(MonthMath.monthYear(ly)), \(MonthMath.fmt(cp, 1)) kWh a day against \(MonthMath.fmt(lp, 1))."))
        }
        if let cp = cur.prod, let pp = prev?.prod, pp > 0, cur.home == nil {
            let c = MonthMath.change(cp, pp)
            out.append((5, "Solar was **\(abs(c))%** \(c >= 0 ? "up" : "down") on \(pn)."))
        }
        return out.sorted { $0.0 < $1.0 }.prefix(3).map { $0.1 }
    }

    var body: some View {
        let ls = lines
        if !ls.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("What changed").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 2)
                ForEach(Array(ls.enumerated()), id: \.offset) { i, l in
                    richText(l).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 11)
                    if i < ls.count - 1 { Rectangle().fill(Palette.rule).frame(height: 1) }
                }
            }
        }
    }
}

struct Heating: View {
    let db: SolarDB, ym: String
    var body: some View {
        let ds = db.thermostat.keys.filter { $0.hasPrefix(ym) }.sorted()
        if ds.count >= 3 {
            let sum = { (k: Int) in ds.reduce(0) { $0 + (db.th($1, k) ?? 0) } }
            let heat = sum(0), aux = sum(1), cool = sum(2)
            let sets = ds.compactMap { db.th($0, 4) }, setAvg = sets.isEmpty ? nil : sets.reduce(0, +) / Double(sets.count)
            let outOf = { (d: String) -> Double? in db.th(d, 6) ?? { guard let a = db.w(d, 0), let b = db.w(d, 1) else { return nil }; return (a + b) / 2 }() }
            let dd = ds.reduce(0) { $0 + max(0, 18 - (outOf($1) ?? 18)) }
            let fanAll = ds.filter { (db.th($0, 3) ?? 0) >= 23.5 }.count
            let n = MonthMath.daysIn(ym)
            let most = max(1, ds.map { (db.th($0, 0) ?? 0) + (db.th($0, 1) ?? 0) }.max() ?? 1)
            let step = MonthMath.niceStep(most), ymax = ceil(most / step) * step
            VStack(alignment: .leading, spacing: 10) {
                Text("Heating").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 0) {
                    MiniTotal(label: "Heat pump", value: MonthMath.fmt(heat), unit: "hours")
                    Divider().padding(.horizontal, 10)
                    MiniTotal(label: "Backup heat", value: MonthMath.fmt(aux, aux > 0 && aux < 10 ? 1 : 0), unit: "hours", bad: aux > 0.5)
                    Divider().padding(.horizontal, 10)
                    if cool > heat { MiniTotal(label: "Cooling", value: MonthMath.fmt(cool), unit: "hours") }
                    else { MiniTotal(label: "Set to", value: MonthMath.fmt(setAvg, 1), unit: "⌀ °C") }
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    LegendDot(color: Palette.heat, text: "Heat pump")
                    if aux > 0 { LegendDot(color: Palette.aux, text: "Backup heat") }
                    Spacer()
                    Text("hours a day").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                Canvas { ctx, size in
                    let H = size.height, top: CGFloat = 26, bot: CGFloat = 20, pw = size.width - 44, bw = pw / CGFloat(n)
                    let Y = { (v: Double) in top + (H - top - bot) * CGFloat(1 - v / ymax) }
                    var v = step
                    while v <= ymax + 1e-9 {
                        var g = Path(); g.move(to: CGPoint(x: 0, y: Y(v))); g.addLine(to: CGPoint(x: pw, y: Y(v)))
                        ctx.stroke(g, with: .color(Palette.rule), lineWidth: 1)
                        ctx.draw(Text("\(MonthMath.fmt(v)) h").font(.system(size: 11)).foregroundStyle(.secondary), at: CGPoint(x: pw + 6, y: Y(v)), anchor: .leading)
                        v += step
                    }
                    for i in 0..<n {
                        let d = String(format: "%@-%02d", ym, i + 1)
                        guard db.thermostat[d] != nil else { continue }
                        let x = CGFloat(i) * bw, hp = db.th(d, 0) ?? 0, ax = db.th(d, 1) ?? 0
                        ctx.fill(Path(CGRect(x: x + 1, y: Y(hp), width: max(1.5, bw - 2), height: Y(0) - Y(hp))), with: .color(Palette.heat))
                        if ax > 0 { ctx.fill(Path(CGRect(x: x + 1, y: Y(hp + ax), width: max(1.5, bw - 2), height: Y(hp) - Y(hp + ax))), with: .color(Palette.aux)) }
                    }
                    for d in [1, 8, 15, 22, 29] where d <= n {
                        ctx.draw(Text("\(d)").font(.system(size: 11)).foregroundStyle(.secondary), at: CGPoint(x: (CGFloat(d) - 0.5) * bw, y: H - 6), anchor: .center)
                    }
                }
                .frame(height: 150)
                Group {
                    if dd > 15 && heat + aux > 0 { richText("About **\(MonthMath.fmt((heat + aux) / dd, 1)) hours** of heating for each degree the day averaged below 18°C.", size: 13) }
                    if aux > 0.5 { richText("!!Backup heat ran \(MonthMath.fmt(aux, 1)) hours.!! It uses two to three times the power of the heat pump for the same warmth.", size: 13) }
                    else if heat > 5 { Text("No backup heat this month; the heat pump did it all.").font(.system(size: 13)) }
                    if fanAll >= 3 { richText("The fan ran all day on **\(fanAll) days**, which adds a few kWh a day.", size: 13) }
                    Text("From your ecobee thermostat's history.").font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct MiniTotal: View {
    let label: String, value: String, unit: String
    var bad = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(bad ? Palette.bad : .primary)
            Text(unit).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Ledger: View {
    let db: SolarDB, ym: String
    @Binding var open: Bool
    var body: some View {
        let days = db.monthDays(ym), t = db.totals(days), n = MonthMath.daysIn(ym)
        let perDay = { (v: Double, k: Int) in k > 0 ? MonthMath.fmt(v / Double(k), 1) : "" }
        var rows: [(String, String, String, String, Bool, Bool)] = []   // symbol, label, month, a day, sun, indented
        if t.hDays > 0 { rows.append(("bolt", "Bought from grid", MonthMath.kwh(t.imp), perDay(t.imp, t.hDays), false, false)) }
        else if let gm = db.gridMonthly[ym] { rows.append(("bolt", "Bought from grid (bill)", MonthMath.fmt(gm), "", false, false)) }
        if t.pDays > 0 { rows.append(("sun.max", "Produced", MonthMath.kwh(t.prod), perDay(t.prod, t.pDays), true, false)) }
        if t.bothDays > 0 { rows.append(("house", "Used immediately", MonthMath.kwh(t.selfUse), perDay(t.selfUse, t.bothDays), false, true)) }
        if t.hDays > 0 { rows.append(("arrow.uturn.right", "Sent back to grid", MonthMath.kwh(t.exp), perDay(t.exp, t.hDays), false, true)) }
        let thisMonth = String(SK.day(Date()).prefix(7))
        let gaps = [t.hDays > 0 && t.hDays < n ? "Meter data for \(t.hDays) of \(n) days" : "",
                    t.pDays > 0 && t.pDays < n && ym < thisMonth ? "SolarEdge data for \(t.pDays) days" : ""].filter { !$0.isEmpty }
        return Group {
            if !rows.isEmpty {
                DisclosureGroup(isExpanded: $open) {
                    VStack(spacing: 0) {
                        HStack { Spacer(); Text("Month").frame(width: 80, alignment: .trailing); Text("A day").frame(width: 64, alignment: .trailing) }
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.vertical, 8)
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                            Rectangle().fill(Palette.rule).frame(height: 1)
                            HStack {
                                Image(systemName: r.0).font(.system(size: 14)).foregroundStyle(r.4 ? SK.sunColor : .secondary).frame(width: 20)
                                Text(r.1).font(.system(size: 15)).foregroundStyle(r.5 ? .secondary : .primary)
                                Spacer()
                                Text(r.2).frame(width: 80, alignment: .trailing)
                                Text(r.3).frame(width: 64, alignment: .trailing)
                            }
                            .font(.system(size: 15, weight: r.4 ? .semibold : .regular)).monospacedDigit()
                            .foregroundStyle(r.4 ? SK.sunColor : .primary)
                            .padding(.leading, r.5 ? 14 : 0)
                            .padding(.vertical, 10)
                        }
                        if !gaps.isEmpty {
                            Text(gaps.joined(separator: ", ") + ".").font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        }
                    }
                } label: {
                    Text("Energy Consumption (in kWh)").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                }
                .tint(.secondary)
            }
        }
    }
}

// MARK: - Sheets

struct InfoRows: View {
    let rows: [(String, String, Color?)]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if i > 0 { Rectangle().fill(Palette.rule).frame(height: 1) }
                HStack {
                    Text(r.0).foregroundStyle(r.2 == Palette.bad ? Palette.bad : .primary)
                    Spacer()
                    Text(r.1).monospacedDigit().foregroundStyle(r.2 ?? Color.secondary)
                }
                .font(.system(size: 15)).padding(.vertical, 11)
            }
        }
        .padding(.horizontal, 14)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DaySheet: View {
    let db: SolarDB, d: String
    var body: some View {
        let r = db.monthDays(String(d.prefix(7))).first { $0.d == d } ?? SolarDB.Day(d: d)
        var p: [(String, String, Color?)] = []
        if let h = r.home { p.append(("Home used", "\(MonthMath.kwh(h)) kWh", .primary)) }
        if let i = r.imp { p.append(("Bought from grid", "\(MonthMath.kwh(i)) kWh", nil)) }
        if let pr = r.prod { p.append(("Solar produced", "\(MonthMath.kwh(pr)) kWh", SK.sunColor)) }
        if let pr = r.prod, let ex = db.expected(d), ex > 0.5 { p.append(("Expected from the sunlight", "\(MonthMath.kwh(ex)) kWh · \(MonthMath.pct(pr, ex))%", nil)) }
        if let s = r.selfUse { p.append(("Used immediately", "\(MonthMath.kwh(s)) kWh", nil)) }
        if let e = r.exp { p.append(("Sent back to grid", "\(MonthMath.kwh(e)) kWh", nil)) }
        if p.isEmpty { p.append(("No data for this day", "", nil)) }
        let sun = SK.sun(d, lat: db.lat, lon: db.lon)
        let clock = { (t: Date) -> String in let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "h:mm a"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f.string(from: t) }
        var w: [(String, String, Color?)] = []
        if let hi = db.w(d, 0), let lo = db.w(d, 1) {
            w.append((describe(db.w(d, 2).map { Int($0) }), "H \(Int(hi.rounded()))°  L \(Int(lo.rounded()))°", nil))
            if let sh = db.w(d, 3) { w.append(("Sunshine", "\(MonthMath.fmt(sh, 1)) h", nil)) }
        }
        let mins = Int(sun.set.timeIntervalSince(sun.rise) / 60)
        w.append(("Sunrise and sunset", "\(clock(sun.rise)) · \(clock(sun.set))", nil))
        w.append(("Daylight", "\(mins / 60) h \(mins % 60) min", nil))
        var t: [(String, String, Color?)] = []
        if db.thermostat[d] != nil {
            t.append(("Heat pump ran", "\(MonthMath.fmt(db.th(d, 0), 1)) h", nil))
            if let a = db.th(d, 1), a > 0 { t.append(("Backup heat ran", "\(MonthMath.fmt(a, 1)) h", Palette.bad)) }
            if let c = db.th(d, 2), c > 0 { t.append(("Cooling ran", "\(MonthMath.fmt(c, 1)) h", nil)) }
            if let s = db.th(d, 4) { t.append(("Thermostat set to", "⌀ \(MonthMath.fmt(s, 1))°", nil)) }
            if let ins = db.th(d, 5) { t.append(("Inside", "⌀ \(MonthMath.fmt(ins, 1))°\(db.th(d, 7).map { "  \(MonthMath.fmt($0))% humidity" } ?? "")", nil)) }
        }
        return VStack(spacing: 16) {
            InfoRows(rows: p)
            InfoRows(rows: w)
            if !t.isEmpty { InfoRows(rows: t) }
        }
    }
}

struct BillSheet: View {
    let db: SolarDB, ym: String
    var body: some View {
        if let b = db.bill(ym) {
            let n = { (x: Any?) in (x as? NSNumber)?.doubleValue ?? 0 }
            let lines = { (k: String) -> [String: [Double]] in (b[k] as? [String: [Any]] ?? [:]).mapValues { $0.map { n($0) } } }
            let buy = lines("buy"), credit = lines("credit")
            let lineSum = { (l: [String: [Double]]) in l.values.reduce(0) { $0 + (($1.first ?? 0) * ($1.count > 1 ? $1[1] : 0) * 100).rounded() / 100 } }
            let pBuy = lineSum(buy), pCredit = lineSum(credit), kwh = buy.values.reduce(0) { $0 + ($1.first ?? 0) }
            let current = ((n(b["due"]) - n(b["previous"])) * 100).rounded() / 100
            let from = b["from"] as? String ?? "", to = b["to"] as? String ?? ""
            let days = Int(((SK.date(to)?.timeIntervalSince(SK.date(from) ?? Date()) ?? 0) / 86400).rounded())
            var r: [(String, String, Color?)] = [("Electricity bought, \(MonthMath.fmt(kwh)) kWh", MonthMath.money(pBuy), .primary)]
            for (k, name) in [("on", "On-peak"), ("mid", "Mid-peak"), ("off", "Off-peak")] {
                if let x = buy[k], x.count > 1 { r.append(("   \(name), \(MonthMath.fmt(x[0])) kWh at \(MonthMath.fmt(x[1] * 100, 1))¢", MonthMath.money(x[0] * x[1]), nil)) }
            }
            if pCredit > 0 { r.append(("Energy credit, \(MonthMath.fmt(n(b["generated"]))) kWh sent back", MonthMath.money(-pCredit), SK.sunColor)) }
            r.append(("Delivery", MonthMath.money(n(b["delivery"])), .primary))
            r.append(("Regulatory", MonthMath.money(n(b["regulatory"])), .primary))
            if n(b["other"]) != 0 { r.append(("Late payment charge", MonthMath.money(n(b["other"])), .primary)) }
            r.append(("HST", MonthMath.money(n(b["hst"])), .primary))
            if n(b["rebate"]) != 0 { r.append(("Ontario Electricity Rebate", MonthMath.money(-n(b["rebate"])), .primary)) }
            r.append(("\(MonthMath.monthName(ym)) charges", MonthMath.money(current), .primary))
            let dc = db.num(ym, "deliveryCredit") ?? 0
            let prevBal = n(b["previous"])
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                Text("\(MonthMath.shortDay(from)) to \(MonthMath.shortDay(to)), \(to.prefix(4))").font(.system(size: 20, weight: .semibold))
                Text("\(days) days\((b["statement"] as? String).map { ", issued \(MonthMath.date($0, "MMMM d"))" } ?? "") · \(MonthMath.fmt(kwh > 0 ? current / kwh * 100 : 0, 1))¢ per kWh all in · \(b["season"] as? String ?? "") prices")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                InfoRows(rows: r)
                if pCredit > 0.5 {
                    richText("Net metering also takes about **\(MonthMath.money(dc))** off the delivery and regulatory lines, because those are charged on what you bought minus what you sent back. Toronto Hydro folds that into the lines rather than printing it. HST is charged as if neither credit applied, while the rebate is worked out after both.", size: 13)
                        .foregroundStyle(.secondary)
                }
                if abs(prevBal) >= 0.5 {
                    Text(prevBal > 0 ? "The amount due was \(MonthMath.money(n(b["due"]))), including \(MonthMath.money(prevBal)) carried over unpaid from the bill before."
                         : "The amount due was \(MonthMath.money(n(b["due"]))) after a \(MonthMath.money(-prevBal)) credit from the bill before.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            })
        } else {
            return AnyView(Text("No bill on file for this month.").foregroundStyle(.secondary))
        }
    }
}
