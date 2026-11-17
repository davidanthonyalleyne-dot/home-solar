import SwiftUI

// The five Apple TV screens, laid out for a 1920 by 1080 screen read from across the room.
// Numbers come from the same SolarDB arithmetic as the iPhone.

private let pad: CGFloat = 90

// MARK: - Now

struct TVNow: View {
    @ObservedObject var model: NowModel
    let go: (SolarTab) -> Void

    var body: some View {
        if let d = model.data {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 18) {
                    Text(MonthMath.date(d.day, "EEEE, MMMM d")).font(.system(size: 31, weight: .medium)).foregroundStyle(.secondary)
                    if let w = d.weather, let t = w.temp {
                        Image(systemName: SK.symbol(w.code, day: (w.isDay ?? 1) == 1)).font(.system(size: 29))
                            .symbolRenderingMode(.multicolor)
                        Text("\(iInt(t.rounded()))° \(describe(w.code).lowercased())").font(.system(size: 31)).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(SK.kw(d.nowKw)).font(.system(size: 190, weight: .bold)).monospacedDigit().tracking(-4)
                    Text("kW now").font(.system(size: 46, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(SK.kwh(d.todayKwh)) kWh").font(.system(size: 64, weight: .semibold)).foregroundStyle(SK.sunColor).monospacedDigit()
                        Text(d.expected.map { "today, of \(SK.kwh($0)) expected" } ?? "today").font(.system(size: 27)).foregroundStyle(.secondary)
                    }
                }
                TVDayCurve(curve: d.curve, expected: d.expected, lat: d.lat, lon: d.lon, day: d.day)
                    .frame(height: 300).padding(.top, 10)
                HStack(spacing: 40) {
                    TVTile(title: "Today", value: "\(SK.kwh(d.todayKwh)) kWh", sub: d.expected.map { "\(MonthMath.pct(d.todayKwh, $0))% of expected" } ?? "") { go(.now) }
                    TVTile(title: "\(MonthMath.monthName(String(d.day.prefix(7)))) so far", value: "\(MonthMath.kwh(d.month)) kWh", sub: "Open the month") { go(.month) }
                    TVTile(title: "This year", value: "\(MonthMath.fmt(d.year)) kWh", sub: "\(MonthMath.fmt(d.lifetime)) kWh since \(d.since)") { go(.history) }
                    TVTile(title: "Tomorrow", value: tomorrowValue(d), sub: d.tomorrow.map { t in
                        [t.hi.map { "H \(iInt($0.rounded()))°" }, t.lo.map { "L \(iInt($0.rounded()))°" }].compactMap { $0 }.joined(separator: "  ") } ?? "") { go(.ask) }
                }
                .padding(.top, 34)
            }
            .padding(.horizontal, pad).padding(.top, 20)
        } else {
            ProgressView().scaleEffect(2)
        }
    }

    func tomorrowValue(_ d: NowData) -> String {
        guard let t = d.tomorrow else { return "–" }
        return describe(t.code)
    }
}

struct TVTile: View {
    let title: String, value: String, sub: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 25, weight: .medium)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 44, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(sub).font(.system(size: 22)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 330, height: 170, alignment: .leading)
            .padding(.horizontal, 26)
        }
        .buttonStyle(.card)
    }
}

/// Today's output against the expected dashed curve, from sunrise to sunset
struct TVDayCurve: View {
    let curve: [[Double]]
    let expected: Double?
    let lat: Double, lon: Double, day: String

    var body: some View {
        Canvas { ctx, size in
            let (rise, set) = SK.sun(day, lat: lat, lon: lon)
            var cal = Calendar(identifier: .gregorian); cal.timeZone = SolarConfig.tz
            let h0 = Double(cal.component(.hour, from: rise)) + Double(cal.component(.minute, from: rise)) / 60
            let h1 = Double(cal.component(.hour, from: set)) + Double(cal.component(.minute, from: set)) / 60
            let pts = curve.filter { $0.count > 1 }
            let peak = max(pts.map { $0[1] }.max() ?? 1, (expected ?? 0) / max(1, (h1 - h0)) * 1.6, 0.5)
            let W = size.width, H = size.height - 30
            let X = { (h: Double) in CGFloat((h - h0) / max(0.1, h1 - h0)) * W }
            let Y = { (v: Double) in H - CGFloat(v / peak) * H * 0.92 }
            // expected: a sine-shaped day holding the expected total
            if let e = expected, e > 0 {
                let len = h1 - h0, top = e * Double.pi / (2 * len)
                var p = Path()
                for i in 0...60 {
                    let h = h0 + len * Double(i) / 60, v = top * sin(Double.pi * Double(i) / 60)
                    let pt = CGPoint(x: X(h), y: Y(v))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                ctx.stroke(p, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 2, dash: [6, 8]))
            }
            if pts.count > 1 {
                var line = Path(), area = Path()
                area.move(to: CGPoint(x: X(pts[0][0]), y: Y(0)))
                for (i, p) in pts.enumerated() {
                    let c = CGPoint(x: X(p[0]), y: Y(p[1]))
                    if i == 0 { line.move(to: c) } else { line.addLine(to: c) }
                    area.addLine(to: c)
                }
                area.addLine(to: CGPoint(x: X(pts[pts.count - 1][0]), y: Y(0))); area.closeSubpath()
                ctx.fill(area, with: .color(SK.sunColor.opacity(0.22)))
                ctx.stroke(line, with: .color(SK.sunColor), lineWidth: 5)
            }
            var base = Path(); base.move(to: CGPoint(x: 0, y: Y(0))); base.addLine(to: CGPoint(x: W, y: Y(0)))
            ctx.stroke(base, with: .color(.white.opacity(0.2)), lineWidth: 1)
            ctx.draw(Text(SK.clockAmPm(rise)).font(.system(size: 22)).foregroundStyle(.secondary), at: CGPoint(x: 0, y: size.height - 4), anchor: .bottomLeading)
            ctx.draw(Text(SK.clockAmPm(set)).font(.system(size: 22)).foregroundStyle(.secondary), at: CGPoint(x: W, y: size.height - 4), anchor: .bottomTrailing)
        }
    }
}

// MARK: - Month

struct TVMonth: View {
    @ObservedObject var model: NowModel
    @State private var focusedDay: String?

    var body: some View {
        if let db = model.db, let ym = model.selectedMonth ?? db.defaultMonth {
            let months = db.months
            let i = months.firstIndex(of: ym)
            let days = db.monthDays(ym)
            let grid = db.num(ym, "grid"), saved = db.num(ym, "saved"), without = db.num(ym, "without")
            VStack(alignment: .leading, spacing: 0) {
                // the month, with buttons for the ones either side; left and right on the chart move between days
                HStack(alignment: .center, spacing: 30) {
                    Text(MonthMath.monthYear(ym)).font(.system(size: 64, weight: .bold))
                    Spacer()
                    if let i, i > 0 {
                        Button { model.selectedMonth = months[i - 1]; focusedDay = nil } label: {
                            Label(MonthMath.date(months[i - 1] + "-01", "MMMM"), systemImage: "chevron.left").font(.system(size: 26, weight: .medium))
                        }
                        .accessibilityIdentifier("prevMonth")
                    }
                    if let i, i < months.count - 1 {
                        Button { model.selectedMonth = months[i + 1]; focusedDay = nil } label: {
                            Label(MonthMath.date(months[i + 1] + "-01", "MMMM"), systemImage: "chevron.right").font(.system(size: 26, weight: .medium))
                                .labelStyle(TrailingIcon())
                        }
                        .accessibilityIdentifier("nextMonth")
                    }
                }
                .focusSection()   // up from anywhere on the chart reaches the month buttons
                HStack(alignment: .top, spacing: 90) {
                    TVBig(label: "Paid to the grid", value: grid.map { MonthMath.dollars($0) } ?? "–")
                    TVBig(label: "Saved by solar", value: saved.map { MonthMath.dollars($0) } ?? "–", color: SK.sunColor)
                    if let w = without, w > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Without solar").font(.system(size: 27, weight: .medium)).foregroundStyle(.secondary)
                            Text(MonthMath.dollars(w)).font(.system(size: 76, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                    TVDayReadout(day: days.first { $0.d == focusedDay })
                }
                .padding(.top, 20)
                TVDayBars(days: days, focused: $focusedDay).frame(height: 400).padding(.top, 28)
            }
            .padding(.horizontal, pad).padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ProgressView().scaleEffect(2)
        }
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 10) { configuration.title; configuration.icon } }
}

/// The day the remote is on, large enough to read from the couch
struct TVDayReadout: View {
    let day: SolarDB.Day?
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let r = day {
                Text(MonthMath.date(r.d, "EEEE, MMMM d")).font(.system(size: 27, weight: .medium)).foregroundStyle(.secondary)
                Text(r.prod.map { "\(MonthMath.kwh($0)) kWh solar" } ?? "No solar reading").font(.system(size: 44, weight: .semibold)).foregroundStyle(SK.sunColor)
                Text([r.imp.map { "\(MonthMath.kwh($0)) from the grid" }, r.home.map { "\(MonthMath.kwh($0)) used in all" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 25)).foregroundStyle(.secondary)
            } else {
                Text("Move down to the chart to see a day").font(.system(size: 25)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 560, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dayReadout")
    }
}

struct TVBig: View {
    let label: String, value: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 27, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 76, weight: .semibold)).foregroundStyle(color).monospacedDigit()
        }
    }
}

/// Grid and solar per day. Each day is a full-height column, so the remote lands on it easily,
/// and only days that have happened take focus. The one in focus is lit and read out above.
struct TVDayBars: View {
    let days: [SolarDB.Day]
    @Binding var focused: String?
    @FocusState private var focus: String?

    var body: some View {
        let today = SK.day(Date())
        let mx = max(1, days.map { ($0.imp ?? 0) + ($0.selfUse ?? $0.prod ?? 0) }.max() ?? 1)
        let start = days.last { $0.d <= today && ($0.prod != nil || $0.imp != nil) }?.d ?? days.last { $0.d <= today }?.d
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(days, id: \.d) { r in
                let g = r.imp ?? 0, s = r.selfUse ?? r.prod ?? 0, on = focus == r.d, past = r.d <= today
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        Rectangle().fill(SK.sunColor).frame(height: 320 * CGFloat(s / mx))
                        Rectangle().fill(Color.white.opacity(0.75)).frame(height: 320 * CGFloat(g / mx))
                    }
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .opacity(focus == nil || on ? 1 : 0.5)
                    Text(String(Int(r.d.suffix(2)) ?? 0))
                        .font(.system(size: on ? 22 : 18, weight: on ? .bold : .regular)).foregroundStyle(on ? .primary : .secondary)
                }
                .padding(.horizontal, 3).padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(on ? 0.16 : 0)))
                .contentShape(Rectangle())
                .focusable(past)
                .focused($focus, equals: r.d)
                .accessibilityIdentifier("day-\(r.d)")
                .animation(.easeOut(duration: 0.12), value: on)
            }
        }
        .focusSection()
        .defaultFocus($focus, start)
        .onChange(of: focus) { _, v in focused = v }
    }
}

// MARK: - History

struct TVHistory: View {
    @ObservedObject var model: NowModel
    let openMonth: (String) -> Void
    @State private var view = "cost"

    var body: some View {
        if let db = model.db {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("History").font(.system(size: 64, weight: .bold))
                    Spacer()
                    Picker("Show", selection: $view) {
                        Text("Cost").tag("cost")
                        Text("Energy").tag("energy")
                        if db.hasClimate { Text("Climate").tag("climate") }
                    }
                    .pickerStyle(.segmented).frame(width: 640)
                }
                if view == "climate" { TVClimate(db: db).padding(.top, 30) } else { TVYears(db: db, energy: view == "energy").padding(.top, 30) }
            }
            .padding(.horizontal, pad).padding(.top, 20)
        } else {
            ProgressView().scaleEffect(2)
        }
    }
}

/// Each year a row of twelve months on one scale; this year's months still to come show last
/// year's figure as a dashed outline.
struct TVYears: View {
    let db: SolarDB
    let energy: Bool

    var body: some View {
        let pm = db.prodByMonth(), ytot = db.yearTotals()
        let years = Array((energy ? Set(pm.keys.map { String($0.prefix(4)) }).sorted() : ytot.keys.sorted()).reversed().prefix(4))
        let val = { (ym: String) -> Double? in
            if energy { return pm[ym] }
            guard db.money[ym] != nil else { return nil }
            return (db.num(ym, "grid") ?? 0) + max(0, db.num(ym, "saved") ?? 0)
        }
        let mx = max(1, years.flatMap { y in (1...12).compactMap { val(String(format: "%@-%02d", y, $0)) } }.max() ?? 1)
        let cur = String(SK.day(Date()).prefix(7))
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 26) {
                if energy { TVKey(color: SK.sunColor, text: "Generated, kWh") } else { TVKey(color: .white.opacity(0.75), text: "Paid to the grid"); TVKey(color: SK.sunColor, text: "Saved by solar") }
            }
            ForEach(years, id: \.self) { y in
                HStack(alignment: .bottom, spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(y).font(.system(size: 30, weight: .semibold))
                        Text(energy ? "\(MonthMath.fmt(ytot[y]?.prod ?? (1...12).compactMap { pm[String(format: "%@-%02d", y, $0)] }.reduce(0, +))) kWh"
                                    : "\(MonthMath.dollars(ytot[y]?.saved ?? 0)) saved")
                            .font(.system(size: 22)).foregroundStyle(.secondary)
                    }
                    .frame(width: 190, alignment: .leading)
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(1...12, id: \.self) { m in
                            let ym = String(format: "%@-%02d", y, m)
                            TVYearBar(db: db, ym: ym, energy: energy, mx: mx, value: val(ym), ghost: ym > cur ? val(String(format: "%04d-%02d", (Int(y) ?? 0) - 1, m)) : nil, pm: pm)
                        }
                    }
                }
                .frame(height: 140)
            }
        }
    }
}

struct TVYearBar: View {
    let db: SolarDB, ym: String, energy: Bool, mx: Double, value: Double?, ghost: Double?
    let pm: [String: Double]
    var body: some View {
        let H: CGFloat = 120
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                if let g = ghost, value == nil {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5, 5])).foregroundStyle(.white.opacity(0.35))
                        .frame(height: H * CGFloat(g / mx))
                }
                if value != nil {
                    VStack(spacing: 0) {
                        if energy {
                            Rectangle().fill(SK.sunColor).frame(height: H * CGFloat((pm[ym] ?? 0) / mx))
                        } else {
                            Rectangle().fill(SK.sunColor).frame(height: H * CGFloat(max(0, db.num(ym, "saved") ?? 0) / mx))
                            Rectangle().fill(Color.white.opacity(0.75)).frame(height: H * CGFloat((db.num(ym, "grid") ?? 0) / mx))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(height: H, alignment: .bottom)
            Text(MonthMath.date(ym + "-01", "MMMMM")).font(.system(size: 18)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TVKey: View {
    let color: Color, text: String
    var body: some View {
        HStack(spacing: 10) { RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 22, height: 22); Text(text).font(.system(size: 24)).foregroundStyle(.secondary) }
    }
}

/// Heat pump, backup heat and cooling hours by month, with the outdoor temperature under each
struct TVClimate: View {
    let db: SolarDB
    var body: some View {
        let cd = db.climateData(nil)
        let byM = Dictionary(grouping: cd.days, by: { String($0.d.prefix(7)) })
        let ms = byM.keys.sorted()
        let tot = { (k: KeyPath<ClimDay, Double>, m: String) in byM[m]?.reduce(0) { $0 + $1[keyPath: k] } ?? 0 }
        let mx = max(1, ms.map { max(tot(\.heat, $0) + tot(\.aux, $0), tot(\.cool, $0)) }.max() ?? 1)
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 26) { TVKey(color: Palette.heat, text: "Heat pump"); TVKey(color: Palette.aux, text: "Backup heat"); TVKey(color: Palette.cool, text: "Cooling"); Text("hours a month").font(.system(size: 24)).foregroundStyle(.secondary) }
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(ms, id: \.self) { m in
                    let h = tot(\.heat, m), a = tot(\.aux, m), c = tot(\.cool, m)
                    let outs = (byM[m] ?? []).compactMap(\.out)
                    VStack(spacing: 8) {
                        VStack(spacing: 0) {
                            if c > h + a { Rectangle().fill(Palette.cool).frame(height: 440 * CGFloat(c / mx)) }
                            else {
                                Rectangle().fill(Palette.aux).frame(height: 440 * CGFloat(a / mx))
                                Rectangle().fill(Palette.heat).frame(height: 440 * CGFloat(h / mx))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(MonthMath.date(m + "-01", "MMM")).font(.system(size: 20)).foregroundStyle(.secondary)
                        Text(outs.isEmpty ? " " : "\(iInt((outs.reduce(0, +) / Double(outs.count)).rounded()))°".replacingOccurrences(of: "-", with: "−"))
                            .font(.system(size: 20, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 540, alignment: .bottom)
        }
    }
}

// MARK: - Ask

struct TVAsk: View {
    @ObservedObject var model: NowModel
    @StateObject private var ask = AskModel()
    @State private var question = ""

    var body: some View {
        let json = model.json
        let hasKey = (json?["askKey"] as? String)?.isEmpty == false
        HStack(alignment: .top, spacing: 70) {
            VStack(alignment: .leading, spacing: 24) {
                Text("Ask Sunny").font(.system(size: 64, weight: .bold))
                if !hasKey {
                    Text("Ask needs a Claude API key in the encrypted data. Add it on GitHub as ANTHROPIC_API_KEY.").font(.system(size: 29)).foregroundStyle(.secondary)
                } else {
                    TextField("Ask about your home's energy", text: $question)
                        .onSubmit { let q = question; question = ""; Task { await ask.send(q, json: json, spoken: true) } }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(Array(ask.msgs.suffix(6).enumerated()), id: \.offset) { _, m in
                                if m.role == "user" {
                                    Text(m.text).font(.system(size: 29, weight: .semibold)).foregroundStyle(.secondary)
                                } else {
                                    richText(m.text.replacingOccurrences(of: "```chart[\\s\\S]*?```", with: "", options: .regularExpression)
                                        .trimmingCharacters(in: .whitespacesAndNewlines), size: 33)
                                }
                            }
                            if ask.busy { ProgressView() }
                            if let n = ask.note { Text(n).font(.system(size: 26)).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hasKey, let db = model.db {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Try asking").font(.system(size: 27, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(AskData.suggestions(db).prefix(4), id: \.self) { q in
                        Button { Task { await ask.send(q, json: json, spoken: true) } } label: {
                            Text(q).font(.system(size: 27)).frame(width: 520, alignment: .leading).padding(.vertical, 6)
                        }
                    }
                    if !ask.msgs.isEmpty { Button("New conversation") { ask.newChat() }.padding(.top, 10) }
                }
                .frame(width: 600)
            }
        }
        .padding(.horizontal, pad).padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Settings

struct TVSettings: View {
    @ObservedObject var model: NowModel
    let onForget: () -> Void
    @State private var confirm = false

    var body: some View {
        HStack(alignment: .top, spacing: 70) {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(.system(size: 64, weight: .bold))
                if let j = model.json, let st = SolarStatus.items(j), let c = SolarStatus.chain(j) {
                    ChainView(links: c.links, big: true).frame(maxWidth: 900).padding(.top, 10)
                    Text(c.line).font(.system(size: 28)).foregroundStyle(c.level == "bad" ? Palette.bad : .secondary).frame(maxWidth: 900, alignment: .leading)
                    ForEach(Array(st.items.filter { $0.level == "bad" || $0.level == "warn" }.dropFirst().prefix(3).enumerated()), id: \.offset) { _, it in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(it.title).font(.system(size: 28, weight: .semibold))
                            Text(it.note).font(.system(size: 24)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Solar on Apple TV reads the same encrypted data as the iPhone app. Bills, meter files and alerts are handled on the iPhone.")
                    .font(.system(size: 25)).foregroundStyle(.secondary).padding(.top, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 20) {
                Button("Refresh now") { Task { await model.refresh(force: true) } }
                Button(confirm ? "Press again to forget it" : "Forget the passphrase on this Apple TV") {
                    if confirm { SharedVault.passphrase = nil; onForget() } else { confirm = true }
                }
            }
            .frame(width: 620)
            .padding(.top, 110)
        }
        .padding(.horizontal, pad).padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Ambient

/// After ten minutes untouched: the time, the sun on today's arc from sunrise to sunset, the live number.
struct TVAmbient: View {
    let d: NowData
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 30) {
                Text(Date(), style: .time).font(.system(size: 150, weight: .thin)).foregroundStyle(.white.opacity(0.8))
                TVSunArc(lat: d.lat, lon: d.lon, day: d.day).frame(width: 1100, height: 260)
                Text("\(SK.kw(d.nowKw)) kW now · \(SK.kwh(d.todayKwh)) kWh today").font(.system(size: 40, weight: .medium)).foregroundStyle(SK.sunColor.opacity(0.9))
            }
        }
    }
}

struct TVSunArc: View {
    let lat: Double, lon: Double, day: String
    var body: some View {
        Canvas { ctx, size in
            let (rise, set) = SK.sun(day, lat: lat, lon: lon)
            let t = max(0, min(1, Date().timeIntervalSince(rise) / max(1, set.timeIntervalSince(rise))))
            let w = size.width, h = size.height - 40, top: CGFloat = 20, cy = top - (h - top)
            var arc = Path(); arc.move(to: CGPoint(x: 0, y: h)); arc.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w / 2, y: cy))
            ctx.stroke(arc, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 3, dash: [6, 10]))
            var base = Path(); base.move(to: CGPoint(x: 0, y: h)); base.addLine(to: CGPoint(x: w, y: h))
            ctx.stroke(base, with: .color(.white.opacity(0.25)), lineWidth: 2)
            let x = 2 * (1 - t) * t * (w / 2) + t * t * w, y = (1 - t) * (1 - t) * h + 2 * (1 - t) * t * cy + t * t * h
            ctx.fill(Path(ellipseIn: CGRect(x: x - 22, y: y - 22, width: 44, height: 44)), with: .color(SK.sunColor))
            ctx.draw(Text(SK.clockAmPm(rise)).font(.system(size: 26)).foregroundStyle(.white.opacity(0.5)), at: CGPoint(x: 0, y: size.height), anchor: .bottomLeading)
            ctx.draw(Text(SK.clockAmPm(set)).font(.system(size: 26)).foregroundStyle(.white.opacity(0.5)), at: CGPoint(x: w, y: size.height), anchor: .bottomTrailing)
        }
    }
}
