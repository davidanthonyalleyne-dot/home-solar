import SwiftUI

// Phase four: History in SwiftUI, ported from web/app.js (historyScreen, historyChart, energyView,
// climateView, coldView, methodSheet). Cost, Energy and Climate, with the same arithmetic.


struct HistoryScreen: View {
    @ObservedObject var model: NowModel
    let openMonth: (String) -> Void
    @AppStorage("histView") private var view = "cost"

    var body: some View {
        NavigationStack {
            ScrollView {
                if let db = model.db {
                    let v = (view == "climate" && !db.hasClimate) || (view == "energy" && db.daily.isEmpty) ? "cost" : view
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(eyebrow(db, v)).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                            Text("History").font(.system(size: 34, weight: .bold)).tracking(-0.5)
                        }
                        if !db.daily.isEmpty {
                            Picker("Show", selection: $view) {
                                Text("Cost").tag("cost")
                                Text("Energy").tag("energy")
                                if db.hasClimate { Text("Climate").tag("climate") }
                            }
                            .pickerStyle(.segmented).padding(.top, 14)
                        }
                        Group {
                            switch v {
                            case "energy": EnergyView(db: db, openMonth: openMonth)
                            case "climate": ClimateView(db: db, openMonth: openMonth)
                            default: CostView(db: db, openMonth: openMonth)
                            }
                        }
                        .padding(.top, 22)
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
                } else {
                    ProgressView().padding(.top, 200)
                }
            }
            .refreshable { await model.refresh(force: true) }
            .task { await model.refresh() }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func eyebrow(_ db: SolarDB, _ v: String) -> String {
        if v == "climate" { return "From your ecobee thermostat" }
        if v == "energy" { return "Since \(MonthMath.monthYear(String((db.installed ?? db.daily.keys.min() ?? "2023-01").prefix(7))))" }
        let first = db.money.filter { ($0.value["preSolar"] as? Bool) != true }.keys.min()
        return first.map { "Since \(MonthMath.monthYear($0))" } ?? ""
    }
}

// MARK: - Cost

struct CostView: View {
    let db: SolarDB
    let openMonth: (String) -> Void
    @State private var method = false

    var body: some View {
        let ms = db.money.filter { ($0.value["preSolar"] as? Bool) != true }
        let grid = ms.keys.reduce(0) { $0 + (db.num($1, "grid") ?? 0) }, saved = ms.keys.reduce(0) { $0 + (db.num($1, "saved") ?? 0) }
        let missing = ms.keys.filter { db.num($0, "grid") == nil && (db.money[$0]?["complete"] as? Bool) != false }.count
        let first = ms.keys.min() ?? ""
        let ys = db.yearTotals(), thisYear = String(SK.day(Date()).prefix(4))
        let long = MonthMath.dollars(grid).count > 6
        let bt = (db.json["money"] as? [String: Any])?["backtest"] as? [[String: Any]] ?? []
        let offs = bt.compactMap { ($0["off"] as? NSNumber).map { abs($0.doubleValue) } }.sorted()
        let typ = offs.isEmpty ? nil : offs[iInt(Double(offs.count) * 0.75)]
        VStack(alignment: .leading, spacing: 0) {
            if ms.isEmpty {
                Text("No cost history yet.").font(.system(size: 17))
            } else {
                HStack(alignment: .top, spacing: 16) {
                    BigStat(label: "Paid to the grid", value: MonthMath.dollars(grid), size: long ? 36 : 44)
                    BigStat(label: "Saved by solar", value: MonthMath.dollars(saved), size: long ? 36 : 44, sun: true)
                }
                SplitBar(a: grid, b: max(0, saved)).padding(.top, 18)
                (Text("Solar has taken about ") + Text("\(MonthMath.pct(saved, grid + saved))%").fontWeight(.bold) + Text(" off what power would have cost."))
                    .font(.system(size: 17)).padding(.top, 14)
                if missing > 0 {
                    Text("\(missing) month\(missing > 1 ? "s" : "") with no meter data or bill \(missing > 1 ? "aren't" : "isn't") counted.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 6)
                }

                (Text("Cost each month, from the ") + Text("grid").fontWeight(.semibold).foregroundColor(.primary)
                 + Text(" and saved by ") + Text("solar").fontWeight(.semibold).foregroundColor(SK.sunColor) + Text(". Same scale every year."))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.top, 28)
                YearRows(db: db, kind: .cost, openMonth: openMonth).padding(.top, 10)
                Text("Paler bars are estimates. Tap a month to open it.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 6)

                // the years
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Text("Paid").frame(width: 70, alignment: .trailing)
                        Text("Saved").frame(width: 64, alignment: .trailing)
                        Text("Generated, kWh").frame(width: 104, alignment: .trailing)
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 8)
                    ForEach(Array(ys.keys.sorted().reversed()), id: \.self) { y in
                        let t = ys[y]!
                        let target = (y == thisYear || t.last == nil)
                            ? (db.money.keys.filter { $0.hasPrefix(y) && db.num($0, "grid") != nil }.max() ?? "\(y)-01") : t.last!
                        let note = y == thisYear && t.last != nil ? "to \(MonthMath.date(t.last! + "-01", "MMM"))"
                            : (t.first.map { !$0.hasSuffix("-01") } ?? false) ? "from \(MonthMath.date(first + "-01", "MMM"))" : ""
                        Rectangle().fill(Palette.rule).frame(height: 1)
                        Button { openMonth(target) } label: {
                            HStack(spacing: 0) {
                                Text(y).font(.system(size: 15))
                                if !note.isEmpty { Text(" \(note)").font(.system(size: 13)).foregroundStyle(.secondary) }
                                Spacer()
                                Text(MonthMath.dollars(t.grid)).frame(width: 70, alignment: .trailing)
                                Text(MonthMath.dollars(t.saved)).frame(width: 64, alignment: .trailing).foregroundStyle(SK.sunColor).fontWeight(.semibold)
                                Text(t.prod.map { MonthMath.fmt($0) } ?? "–").frame(width: 104, alignment: .trailing)
                            }
                            .font(.system(size: 15)).monospacedDigit().padding(.vertical, 10).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 28)
                Button { method = true } label: {
                    HStack(alignment: .top) {
                        Text("Months with a bill use the bill. The rest are estimated\(typ.map { ", usually within \(MonthMath.fmt(max(1, ceil($0 * 100))))% of the real bill" } ?? "").")
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.faint)
                    }
                    .font(.system(size: 15)).foregroundStyle(.secondary).padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.top, 8)
                CO2Line(db: db).padding(.top, 18)
            }
        }
        .sheet(isPresented: $method) { MethodSheet(db: db) }
    }
}

struct BigStat: View {
    let label: String, value: String
    var size: CGFloat = 44
    var sun = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: size, weight: .semibold)).tracking(-1.2).monospacedDigit()
                .foregroundStyle(sun ? SK.sunColor : Color.primary).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SplitBar: View {
    let a: Double, b: Double
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                Rectangle().fill(Palette.grid).frame(width: max(2, (geo.size.width - 2) * a / max(0.01, a + b)))
                Rectangle().fill(SK.sunColor)
            }
        }
        .frame(height: 10).clipShape(Capsule())
    }
}

struct CO2Line: View {
    let db: SolarDB
    var body: some View {
        if db.lifetime > 0 {
            HStack(spacing: 8) {
                Image(systemName: "leaf").foregroundStyle(.secondary)
                Text("Avoided about \(MonthMath.fmt((db.lifetime * 0.03 / 10).rounded() * 10)) kg of CO₂ since \(String((db.installed ?? "install").prefix(4)))")
            }
            .font(.system(size: 15)).foregroundStyle(.secondary)
        }
    }
}

/// One row per year, twelve months across, all on one scale.
struct YearRows: View {
    enum Kind { case cost, energy }
    let db: SolarDB, kind: Kind
    let openMonth: (String) -> Void

    var body: some View {
        let pm = db.prodByMonth()
        let years: [String] = Array((kind == .cost ? db.yearTotals().keys.sorted() : Set(pm.keys.map { String($0.prefix(4)) }).sorted()).reversed())
        let val = { (ym: String) -> Double? in
            if kind == .energy { return pm[ym] }
            guard db.money[ym] != nil else { return nil }
            return (db.num(ym, "grid") ?? 0) + max(0, db.num(ym, "saved") ?? 0)
        }
        let all = years.flatMap { y in (1...12).compactMap { val(String(format: "%@-%02d", y, $0)) } }
        let mx = max(1, all.max() ?? 1)
        let rowH: CGFloat = 64, lab: CGFloat = 54, cur = String(SK.day(Date()).prefix(7))
        let ytot = db.yearTotals()
        VStack(spacing: 0) {
            ForEach(years, id: \.self) { y in
                GeometryReader { geo in
                    let bw = (geo.size.width - lab) / 12, base = rowH - 10
                    let sc = { (v: Double) in (rowH - 16) * CGFloat(v / mx) }
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, size in
                            var axis = Path(); axis.move(to: CGPoint(x: lab, y: base)); axis.addLine(to: CGPoint(x: size.width, y: base))
                            ctx.stroke(axis, with: .color(Palette.rule), lineWidth: 1)
                            for i in 0..<12 {
                                let ym = String(format: "%@-%02d", y, i + 1), x = lab + CGFloat(i) * bw + 2, w = max(2, bw - 4)
                                if kind == .cost {
                                    guard db.money[ym] != nil else { continue }
                                    let gh = db.num(ym, "grid").map { sc($0) } ?? 0, sh = db.num(ym, "saved").map { sc(max(0, $0)) } ?? 0
                                    if gh > 0 { ctx.fill(Path(CGRect(x: x, y: base - gh, width: w, height: gh)), with: .color(db.isEstimate(ym) ? Palette.gridEst : Palette.grid)) }
                                    if sh > 0 { ctx.fill(Path(CGRect(x: x, y: base - gh - sh, width: w, height: sh)), with: .color(SK.sunColor)) }
                                } else if let v = pm[ym] {
                                    let h = max(0.5, sc(v))
                                    ctx.fill(Path(CGRect(x: x, y: base - h, width: w, height: h)), with: .color(SK.sunColor.opacity(ym == cur ? 0.5 : 1)))
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(y).font(.system(size: 13, weight: .semibold))
                            Text(kind == .cost ? MonthMath.dollars(ytot[y]?.grid ?? 0)
                                 : MonthMath.fmt(pm.filter { $0.key.hasPrefix(y) }.values.reduce(0, +)))
                                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .offset(y: base - 32)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { p in
                        guard p.x > lab else { return }
                        let i = min(11, iInt((p.x - lab) / bw)), ym = String(format: "%@-%02d", y, i + 1)
                        if val(ym) != nil, (db.money[ym]?["preSolar"] as? Bool) != true { openMonth(ym) }
                    }
                }
                .frame(height: rowH)
            }
            GeometryReader { geo in
                let bw = (geo.size.width - lab) / 12
                ForEach(0..<12, id: \.self) { i in
                    Text(MonthMath.date(String(format: "2001-%02d-01", i + 1), "MMMMM")).font(.system(size: 11)).foregroundStyle(.secondary)
                        .position(x: lab + CGFloat(i) * bw + bw / 2, y: 8)
                }
            }
            .frame(height: 18)
        }
        .accessibilityElement(children: .contain)
    }
}


struct MethodSheet: View {
    let db: SolarDB
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let mny = db.json["money"] as? [String: Any] ?? [:]
        let byYear = (mny["model"] as? [String: Any])?["byYear"] as? [String: [String: Any]] ?? [:]
        let yr = byYear.keys.max()
        let n = { (x: Any?) in (x as? NSNumber)?.doubleValue ?? 0 }
        let rt = yr.flatMap { byYear[$0] } ?? [:]
        let bt = mny["backtest"] as? [[String: Any]] ?? []
        let carried = db.money.values.contains { n($0["carried"]) != 0 }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Months with a Toronto Hydro bill use what the bill charged. For the other months, the app prices each hour your meter recorded at Ontario's time-of-use rates and applies the net metering rules the way your bills do:")
                    Text("Each kWh sent back earns a credit at the price of the hour it went out. Delivery (in \(yr ?? "the latest year"), \(MonthMath.money(n(rt["fixed"]))) a month plus \(MonthMath.fmt(n(rt["perKwh"]) * 100, 2))¢ per kWh) and regulatory charges (\(MonthMath.fmt(n(rt["reg"]) * 100, 2))¢ per kWh) are charged on what you bought minus what you sent back, so sending power out cuts them too. HST is 13% of the charges as if no credit applied. The Ontario Electricity Rebate is taken off the electricity total after all credits.")
                    Text("If credits ever came to more than a month's electricity charges, the extra would carry forward and be written off after 12 months. \(carried ? "That has happened in some months, and the app carries it." : "That hasn't happened yet. Even your sunniest month still bought more than it sent back, so every credit has been used on the bill it was earned on.")")
                    Text("Solar's saving is what the month would have cost with no panels, minus what it did cost. Power the house used straight from the panels is priced at the hours the sun was out, when time-of-use rates are higher.")
                    if !bt.isEmpty {
                        Text("Estimates checked against your bills").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.top, 8)
                        InfoRows(rows: bt.map { b -> (String, String, Color?) in
                            let off = n(b["off"])
                            return (MonthMath.date((b["month"] as? String ?? "") + "-01", "MMM yyyy"),
                                    "\(MonthMath.money(n(b["estimate"])))  bill \(MonthMath.money(n(b["bill"]))) · \(off >= 0 ? "+" : "−")\(MonthMath.fmt(abs(off) * 100, 1))%", nil)
                        })
                    }
                }
                .font(.system(size: 15)).padding(20)
            }
            .navigationTitle("How costs are worked out").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Energy

struct EnergyView: View {
    let db: SolarDB
    let openMonth: (String) -> Void
    @State private var note = false

    var body: some View {
        let total = db.lifetime
        let since = MonthMath.monthYear(String((db.installed ?? "2023-01").prefix(7)))
        let km = (total / 25 * 100 / 1000).rounded() * 1000
        let recent = db.money.keys.sorted().filter { db.num($0, "imp") != nil && db.num($0, "selfUsed") != nil && (db.money[$0]?["complete"] as? Bool) != false }.suffix(12)
        let perMonth = recent.isEmpty ? 0 : recent.reduce(0) { $0 + (db.num($1, "imp") ?? 0) + (db.num($1, "selfUsed") ?? 0) } / Double(recent.count)
        let houseMonths = perMonth > 0 ? iInt((total / perMonth).rounded()) : nil
        let noteText = "At about 25 kWh per 100 km, what a Taycan uses in mixed driving.\(houseMonths.map { " It's also about \($0) months of what your house uses." } ?? "")"
        VStack(alignment: .leading, spacing: 0) {
            Text("Generated by solar since \(since)").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(MonthMath.fmt(total)).font(.system(size: 44, weight: .semibold)).tracking(-1.2).monospacedDigit().foregroundStyle(SK.sunColor)
                Text("kWh").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
            }
            if total > 0 {
                Button { note = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "car.side").foregroundStyle(.secondary)
                        Text("Enough to drive an EV about \(MonthMath.fmt(km)) km")
                        Text("*").foregroundStyle(SK.sunColor).fontWeight(.semibold)
                    }
                    .font(.system(size: 15)).padding(.vertical, 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.top, 6)
                .popover(isPresented: $note) {
                    Text(noteText).font(.system(size: 13)).foregroundStyle(.secondary).padding(16).frame(width: 260)
                        .presentationCompactAdaptation(.popover)
                }
            }
            Text("kWh generated each month, with the year's total. Same scale every year.")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.top, 24)
            YearRows(db: db, kind: .energy, openMonth: openMonth).padding(.top, 10)
            Text("Tap a month to open it.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 6)
            CO2Line(db: db).padding(.top, 18)
        }
    }
}

// MARK: - Climate

struct ClimateView: View {
    let db: SolarDB
    let openMonth: (String) -> Void
    @State private var year: String? = nil

    struct MonthSum { var heat = 0.0, aux = 0.0, cool = 0.0; var out: [Double] = []; var n = 0 }

    var body: some View {
        let ys = db.climYears
        let yr = (year.flatMap { ys.contains($0) ? $0 : nil }) ?? ys.last ?? ""
        let cd = db.climateData(yr), days = cd.days
        let heat = days.reduce(0) { $0 + $1.heat }, aux = days.reduce(0) { $0 + $1.aux }, cool = days.reduce(0) { $0 + $1.cool }
        let auxCold = days.filter { ($0.out ?? 99) < -5 }.reduce(0) { $0 + $1.aux }
        let auxDays = days.filter { $0.aux > 0.1 }.count
        let mk = (1...12).map { String(format: "%@-%02d", yr, $0) }
        var byM: [String: MonthSum] = [:]
        for r in days { var m = byM[String(r.d.prefix(7))] ?? MonthSum(); m.heat += r.heat; m.aux += r.aux; m.cool += r.cool; m.n += 1; if let o = r.out { m.out.append(o) }; byM[String(r.d.prefix(7))] = m }
        var ghost: [String: MonthSum] = [:]
        if mk.contains(where: { byM[$0] == nil }), let py = Int(yr) {
            for r in db.climateData(String(py - 1)).days {
                let k = String(r.d.dropFirst(5).prefix(2)); var m = ghost[k] ?? MonthSum()
                m.heat += r.heat; m.aux += r.aux; m.cool += r.cool; if let o = r.out { m.out.append(o) }; ghost[k] = m
            }
        }
        let shown = mk.map { k -> (MonthSum?, Bool) in
            if let m = byM[k] { return (m, false) }
            if let g = ghost[String(k.suffix(2))], g.heat + g.aux + g.cool > 0 { return (g, true) }
            return (nil, false)
        }
        let anyGhost = shown.contains { $0.1 }
        let most = max(1, shown.compactMap { $0.0 }.map { max($0.heat + $0.aux, $0.cool) }.max() ?? 1)
        let step = MonthMath.niceStep(most), ymax = ceil(most / step) * step
        let i = ys.firstIndex(of: yr) ?? 0
        let sofar = (days.last?.d ?? "") < "\(yr)-12-31" && yr == ys.last

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Heating and cooling, \(yr)\(sofar ? " so far" : "")").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                StepButton(symbol: "chevron.left", label: "Previous year", target: i > 0 ? ys[i - 1] : nil) { year = $0 }
                StepButton(symbol: "chevron.right", label: "Next year", target: i < ys.count - 1 ? ys[i + 1] : nil) { year = $0 }
            }
            HStack(alignment: .top, spacing: 0) {
                MiniTotal(label: "Heating", value: MonthMath.fmt(heat), unit: "hours")
                Divider().padding(.horizontal, 10)
                MiniTotal(label: "Backup heat", value: MonthMath.fmt(aux), unit: "hours", bad: aux > 1)
                Divider().padding(.horizontal, 10)
                MiniTotal(label: "Cooling", value: MonthMath.fmt(cool), unit: "hours")
            }
            .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            Group {
                if aux > 1 {
                    Text("Backup heat cost about ") + Text(MonthMath.dollars((aux * cd.auxKw * cd.rate / 10).rounded() * 10)).fontWeight(.bold)
                        + Text(". It ran on \(auxDays) days\(aux > 0 && auxCold / aux > 0.5 ? ", and \(MonthMath.pct(auxCold, aux))% of its hours were on days below −5°C" : "").")
                } else {
                    Text("The heat pump did all the heating; backup heat didn't run.")
                }
            }
            .font(.system(size: 17)).padding(.top, 14)

            HStack(spacing: 14) {
                LegendDot(color: Palette.heat, text: "Heating")
                LegendDot(color: Palette.aux, text: "Backup")
                LegendDot(color: Palette.cool, text: "Cooling")
                Spacer()
                Text("hours a month").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.top, 26)
            GeometryReader { geo in
                let H: CGFloat = 210, top: CGFloat = 12, bot: CGFloat = 40, pw = geo.size.width - 40, bw = pw / 12
                let Y = { (v: Double) in top + (H - top - bot) * CGFloat(1 - v / ymax) }
                Canvas { ctx, _ in
                    var v = step
                    while v <= ymax + 1e-9 {
                        var g = Path(); g.move(to: CGPoint(x: 0, y: Y(v))); g.addLine(to: CGPoint(x: pw, y: Y(v)))
                        ctx.stroke(g, with: .color(Palette.rule), lineWidth: 1)
                        ctx.draw(Text("\(MonthMath.fmt(v)) h").font(.system(size: 11)).foregroundStyle(.secondary), at: CGPoint(x: pw + 6, y: Y(v)), anchor: .leading)
                        v += step
                    }
                    for (i, (m, faded)) in shown.enumerated() {
                        let x = CGFloat(i) * bw + 3, w = max(2, bw - 6), cx = x + w / 2, op = faded ? 0.3 : 1.0
                        if let m {
                            let segs: [(Double, Double, Color)] = m.cool > m.heat + m.aux ? [(0, m.cool, Palette.cool)]
                                : [(0, m.heat, Palette.heat), (m.heat, m.heat + m.aux, Palette.aux)]
                            for (a, b, c) in segs where b > a {
                                ctx.fill(Path(roundedRect: CGRect(x: x, y: Y(b), width: w, height: Y(a) - Y(b)), cornerRadius: 2), with: .color(c.opacity(op)))
                            }
                            if !m.out.isEmpty {
                                let o = iInt((m.out.reduce(0, +) / Double(m.out.count)).rounded())
                                ctx.draw(Text("\(o)°".replacingOccurrences(of: "-", with: "−")).font(.system(size: 11)).foregroundStyle(faded ? Palette.faint : Color.secondary),
                                         at: CGPoint(x: cx, y: H - 8), anchor: .center)
                            }
                        }
                        ctx.draw(Text(MonthMath.date(String(format: "2001-%02d-01", i + 1), "MMMMM")).font(.system(size: 11)).foregroundStyle(m == nil || faded ? Palette.faint : Color.primary),
                                 at: CGPoint(x: cx, y: H - 24), anchor: .center)
                    }
                    ctx.draw(Text("⌀").font(.system(size: 11)).foregroundStyle(.secondary), at: CGPoint(x: pw + 6, y: H - 8), anchor: .leading)
                    var axis = Path(); axis.move(to: CGPoint(x: 0, y: Y(0))); axis.addLine(to: CGPoint(x: pw, y: Y(0)))
                    ctx.stroke(axis, with: .color(Palette.rule), lineWidth: 1)
                }
                .contentShape(Rectangle())
                .onTapGesture { p in
                    let i = min(11, max(0, iInt(p.x / bw)))
                    if byM[mk[i]] != nil { openMonth(mk[i]) }
                }
            }
            .frame(height: 210).padding(.top, 10)
            Text("Monthly average outdoor temperatures. Tap a month to open it.\(anyGhost ? " Faded bars are the same months in \((Int(yr) ?? 1) - 1), until this year's readings come in." : "")")
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 6)

            Callout(days: days).padding(.top, 22)
            PerDegree(db: db).padding(.top, 22)

            NavigationLink { ColdView(db: db) } label: {
                HStack { Text("How the house handles cold").font(.system(size: 17)); Spacer(); Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.faint) }
                    .padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.top, 18)
            Text("From your ecobee thermostat's history and your meter readings. Costs are estimates.").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

/// The most recent stretch where the heat ran flat out and the house still fell behind its setting.
struct Callout: View {
    let days: [ClimDay]
    var body: some View {
        var run: [ClimDay] = [], worst: [ClimDay]? = nil
        for r in days {
            let behind = r.heat >= 23.5 && r.inside != nil && r.set != nil && r.inside! < r.set! - 1.5
            if behind { run.append(r) } else { if run.count >= 3 { worst = run }; run = [] }
        }
        if run.count >= 3 { worst = run }
        return Group {
            if let w = worst, let f = w.first, let l = w.last {
                let lo = w.compactMap { $0.inside }.min() ?? 0, hi = w.compactMap { $0.inside }.max() ?? 0, setv = w.compactMap { $0.set }.max() ?? 0
                let kwh: Double? = w.allSatisfy { $0.grid != nil } ? w.reduce(0) { $0 + ($1.grid ?? 0) } : nil
                let span = "\(MonthMath.shortDay(f.d)) to \(f.d.prefix(7) == l.d.prefix(7) ? String(Int(l.d.suffix(2)) ?? 0) : MonthMath.shortDay(l.d))"
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(span): the house couldn't keep up").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.bad)
                    Text("The heat ran all day\(w.allSatisfy { $0.aux > 12 } ? ", backup heat too," : "") and the house still sat at \(MonthMath.fmt(lo)) to \(MonthMath.fmt(hi))°C against a \(MonthMath.fmt(setv))°C setting.\(kwh.map { " Those \(w.count) days drew about \(MonthMath.fmt(($0 / 100).rounded() * 100)) kWh from the grid." } ?? "") Worth a service call before the next cold snap.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.well, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

/// Heating per degree of cold: the latest month with real heating against the same month a year before.
struct PerDegree: View {
    let db: SolarDB
    var body: some View {
        let all = db.thermostat.keys.sorted()
        let stat = { (ym: String) -> (per: Double, set: Double?)? in
            let ds = all.filter { $0.hasPrefix(ym) }
            let outs = ds.map { d -> Double? in db.th(d, 6) ?? { guard let a = db.w(d, 0), let b = db.w(d, 1) else { return nil }; return (a + b) / 2 }() }
            let dd = outs.reduce(0.0) { acc, o in acc + (o.map { max(0, 18 - $0) } ?? 0) }
            guard ds.count >= 20, dd >= 60 else { return nil }
            let sets = ds.compactMap { db.th($0, 4) }
            return (ds.reduce(0) { $0 + (db.th($1, 0) ?? 0) + (db.th($1, 1) ?? 0) } / dd, sets.isEmpty ? nil : sets.reduce(0, +) / Double(sets.count))
        }
        var found: (String, (per: Double, set: Double?), String, (per: Double, set: Double?))? = nil
        for ym in Set(all.map { String($0.prefix(7)) }).sorted().reversed() {
            let prevYm = "\((Int(ym.prefix(4)) ?? 0) - 1)\(ym.dropFirst(4))"
            if let a = stat(ym), let b = stat(prevYm) { found = (ym, a, prevYm, b); break }
        }
        return Group {
            if let f = found {
                let ym = f.0, a = f.1, pym = f.2, b = f.3
                let ch = iInt(((a.per / b.per - 1) * 100).rounded())
                let sd = (a.set != nil && b.set != nil) ? a.set! - b.set! : 0
                let why = abs(sd) >= 1 ? (sd > 0 && ch > 0 ? ", much of it from the warmer setting" : sd < 0 && ch < 0 ? ", much of it from the cooler setting" : "") : ""
                VStack(alignment: .leading, spacing: 8) {
                    Text("Heating per degree of cold").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    InfoRows(rows: [
                        (MonthMath.monthYear(pym), "\(MonthMath.fmt(b.per, 2)) h\(b.set.map { "  set to ⌀ \(MonthMath.fmt($0))°" } ?? "")", nil),
                        (MonthMath.monthYear(ym), "\(MonthMath.fmt(a.per, 2)) h\(a.set.map { "  set to ⌀ \(MonthMath.fmt($0))°" } ?? "")", nil),
                    ])
                    Text("Hours of heating for each degree a day averaged below 18°C. \(abs(ch) < 5 ? "About the same as a year before." : "About \(abs(ch))% \(ch > 0 ? "more" : "less") heating for the same cold\(why).")")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ColdView: View {
    let db: SolarDB

    struct Bin { var n = 0; var grid = 0.0, aux = 0.0, heat = 0.0 }

    var body: some View {
        let cd = db.climateData(nil), days = cd.days, auxKw = cd.auxKw
        var bins: [Int: Bin] = [:]
        for r in days {
            guard let o = r.out, let g = r.grid else { continue }
            let b = iInt(floor(o / 5) * 5); var x = bins[b] ?? Bin()
            x.n += 1; x.grid += g; x.aux += min(g, r.aux * auxKw); x.heat += r.heat; bins[b] = x
        }
        let bk = bins.keys.sorted().filter { bins[$0]!.n >= 3 && $0 <= 25 }
        let avg = { (b: Int, k: KeyPath<Bin, Double>) in bins[b]![keyPath: k] / Double(bins[b]!.n) }
        let auxFrom = bk.reversed().first { avg($0, \.aux) > 3 * auxKw }, flat = bk.reversed().first { avg($0, \.heat) >= 23 }
        let deg = { (b: Int) in "**\(String(b + 5).replacingOccurrences(of: "-", with: "−"))°C**" }
        let lead = auxFrom == nil ? "The heat pump handled every temperature on its own; backup heat barely ran."
            : flat != nil && flat! >= auxFrom! ? "Down to about \(deg(auxFrom!)) the heat pump copes on its own. Below that, it runs all day and backup heat makes up the rest."
            : "Down to about \(deg(auxFrom!)) the heat pump copes on its own. Below that, backup heat starts\(flat.map { ", and below \(deg($0)) the heat pump runs all day and backup heat does the rest" } ?? "")."
        let winter = days.filter { $0.grid != nil && ($0.out ?? 99) < 10 && ["12", "01", "02"].contains(String($0.d.dropFirst(5).prefix(2))) }
        var degree: Double? = nil
        if winter.count >= 20 {
            let xs = winter.map { 18 - ($0.out ?? 0) }, ys = winter.map { $0.grid ?? 0 }
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / xs.reduce(0) { $0 + pow($1 - mx, 2) }
            if slope > 0 { degree = slope * 30 * cd.rate }
        }
        let nonstop = days.filter { $0.heat >= 23.9 }.count
        let mild = days.filter { $0.grid != nil && $0.heat + $0.aux + $0.cool < 0.5 }.compactMap { $0.grid }.sorted()
        var rows: [(String, String, Color?)] = []
        if let degree { rows.append(("One degree cooler in winter", "about \(MonthMath.dollars((degree / 5).rounded() * 5)) a month", nil)) }
        rows.append(("Days the heat pump ran nonstop", MonthMath.fmt(Double(nonstop)), nil))
        if mild.count >= 5 { rows.append(("A mild day, no heating or cooling", "\(MonthMath.fmt(mild[mild.count / 2])) kWh", nil)) }
        let most = bk.map { avg($0, \.grid) }.max() ?? 1, step = MonthMath.niceStep(most), ymax = ceil(most / step) * step

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if bk.isEmpty {
                    Text("Not enough days with both thermostat and meter data yet.").font(.system(size: 15)).foregroundStyle(.secondary)
                } else {
                    richText(lead, size: 17)
                    HStack(spacing: 14) {
                        LegendDot(color: Palette.grid, text: "Grid")
                        LegendDot(color: Palette.aux, text: "Of that, backup heat")
                        Spacer()
                        Text("⌀ kWh a day").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 18)
                    Canvas { ctx, size in
                        let H = size.height, top: CGFloat = 18, bot: CGFloat = 40, pw = size.width - 40, bw = pw / CGFloat(bk.count)
                        let Y = { (v: Double) in top + (H - top - bot) * CGFloat(1 - v / ymax) }
                        var v = step
                        while v <= ymax + 1e-9 {
                            var g = Path(); g.move(to: CGPoint(x: 0, y: Y(v))); g.addLine(to: CGPoint(x: pw, y: Y(v)))
                            ctx.stroke(g, with: .color(Palette.rule), lineWidth: 1)
                            ctx.draw(Text(MonthMath.fmt(v)).font(.system(size: 11)).foregroundStyle(.secondary), at: CGPoint(x: pw + 6, y: Y(v)), anchor: .leading)
                            v += step
                        }
                        for (i, b) in bk.enumerated() {
                            let gr = avg(b, \.grid), ax = avg(b, \.aux), x = CGFloat(i) * bw + 3, w = max(2, bw - 6), cx = x + w / 2
                            ctx.fill(Path(roundedRect: CGRect(x: x, y: Y(gr - ax), width: w, height: Y(0) - Y(gr - ax)), cornerRadius: 2), with: .color(Palette.grid))
                            if ax > 0.5 { ctx.fill(Path(roundedRect: CGRect(x: x, y: Y(gr), width: w, height: Y(gr - ax) - Y(gr)), cornerRadius: 2), with: .color(Palette.aux)) }
                            ctx.draw(Text(MonthMath.fmt(gr)).font(.system(size: 11, weight: .semibold)), at: CGPoint(x: cx, y: Y(gr) - 8), anchor: .center)
                            ctx.draw(Text("\(b)°".replacingOccurrences(of: "-", with: "−")).font(.system(size: 11)), at: CGPoint(x: cx, y: H - 24), anchor: .center)
                            ctx.draw(Text("\(bins[b]!.n) d").font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: cx, y: H - 8), anchor: .center)
                        }
                        var axis = Path(); axis.move(to: CGPoint(x: 0, y: Y(0))); axis.addLine(to: CGPoint(x: pw, y: Y(0)))
                        ctx.stroke(axis, with: .color(Palette.rule), lineWidth: 1)
                    }
                    .frame(height: 230).padding(.top, 10)
                    Text("An average day at each outdoor temperature over the last year. Backup heat's share is estimated at \(MonthMath.fmt(auxKw, 1)) kW.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 6)
                    InfoRows(rows: rows).padding(.top, 22)
                }
            }
            .padding(20)
        }
        .navigationTitle("How the house handles cold")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
