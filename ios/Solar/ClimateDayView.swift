import SwiftUI

// A day with the thermostat, as four small charts down the sheet, each showing one thing:
// inside (actual against the set point), outside, when the heat was on, and what the panels made.
// The numbers and the notes come from the build, so the web app says exactly the same.

struct ClimateDayView: View {
    let c: ClimateDay
    let made: Double?

    private static let outside = Palette.dyn(0x4A7FB5, 0x6FA3D8)
    private static let outsideText = Palette.dyn(0x2F5E8F, 0x8DB8E6)
    private static let cool = Palette.dyn(0x5B8DEF, 0x7BA4F2)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            trio
            section("Inside the house", "The dashed line is what the thermostat was set to; the black line is the actual temperature inside.") { InsideChart(c: c) }
            if c.out.contains(where: { $0 != nil }) {
                let (lo, li) = extreme(c.out, <), (hi, hiI) = extreme(c.out, >)
                section("Outside", "Coldest at \(hourName(li)), warmest at \(hourName(hiI)).") {
                    OutsideChart(values: c.out, low: (lo, li), high: (hi, hiI), line: Self.outside, text: Self.outsideText)
                }
            }
            section("When the \(c.cooling ? "cooling" : "heat") was on",
                    "Each bar is one hour; a full bar means it ran the whole hour." + (c.auxMin > 0 ? " Red is the electric backup, which costs about three times as much to run." : "")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        legend(c.cooling ? Self.cool : Palette.heat, c.cooling ? "Cooling" : "Heat pump")
                        if c.auxMin > 0 { legend(Palette.aux, "Backup heat") }
                        if c.onPeak.contains(true) {
                            HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(Palette.grid).frame(width: 16, height: 6); Text("On-peak price") }
                        }
                    }
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    RuntimeChart(c: c, cool: Self.cool)
                }
            }
            if let s = c.solar, s.contains(where: { $0 > 0.05 }) {
                let on = s.indices.filter { s[$0] > 0.05 }
                let total = made ?? s.reduce(0, +)
                section("What the panels made", "\(MonthMath.fmt(total, 1)) kWh between \(hourName(on.first ?? 8)) and \(hourName((on.last ?? 16) + 1))"
                        + (c.fromSun.map { (c.kwh ?? 0) > 0.5 ? "; \(MonthMath.fmt($0, 1)) kWh of it went to \(c.cooling ? "cooling" : "heating")" : "" } ?? "") + ".") {
                    SolarHours(values: s)
                }
            }
            if !c.notes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What stood out").font(.system(size: 18, weight: .semibold))
                    ForEach(Array(c.notes.enumerated()), id: \.offset) { _, n in richText(n.text, size: 15).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Text("From the ecobee file\(c.solar != nil ? ", SolarEdge" : "") and Toronto Hydro's time-of-use prices. Energy is estimated from runtime (heat pump \(MonthMath.fmt(c.heatPumpKw, 1)) kW, backup heat \(MonthMath.fmt(c.backupKw, 1)) kW), before delivery and HST.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var trio: some View {
        HStack(alignment: .top, spacing: 0) {
            cell(c.cooling ? "Cooling used" : "Heating used", "\(MonthMath.fmt(c.kwh ?? 0)) kWh", c.cost.map { "about \(MonthMath.money($0))" } ?? "", Palette.dyn(0xB86F0E, 0xF5B25A))
            divider
            if c.auxMin > 0 {
                cell("Backup heat", "\(c.auxMin) min", "the costly kind", Palette.bad)
            } else {
                let m = c.cooling ? c.coolMin : c.hpMin
                cell(c.cooling ? "Cooling ran" : "Heat pump ran", "\(m / 60) h \(m % 60) min", "through the day", .primary)
            }
            divider
            if let s = c.solar {
                let total = made ?? s.reduce(0, +)
                let share = (c.fromSun != nil && (c.kwh ?? 0) > 0.5) ? "\(iInt((100 * (c.fromSun ?? 0) / (c.kwh ?? 1)).rounded()))% to \(c.cooling ? "cooling" : "heating")" : ""
                cell("Solar made", "\(MonthMath.fmt(total)) kWh", share, SK.sunColor)
            } else { Spacer().frame(maxWidth: .infinity) }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
    }
    private var divider: some View { Rectangle().fill(Palette.rule).frame(width: 1).padding(.horizontal, 10) }
    private func cell(_ l: String, _ v: String, _ s: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(color).minimumScaleFactor(0.7).lineLimit(1)
            Text(s).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12); Text(label) }
    }
    private func section<C: View>(_ title: String, _ caption: String, @ViewBuilder _ chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(caption).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            chart()
        }
    }
    private func extreme(_ a: [Double?], _ better: (Double, Double) -> Bool) -> (Double, Int) {
        var best = (0.0, -1)
        for (i, v) in a.enumerated() { if let v, best.1 < 0 || better(v, best.0) { best = (v, i) } }
        return (best.0, max(best.1, 0))
    }
}

func hourName(_ h: Int) -> String { h % 24 == 0 ? "midnight" : h == 12 ? "noon" : "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "am" : "pm")" }
private func signedDeg(_ v: Double) -> String { "\(iInt(v.rounded()))°".replacingOccurrences(of: "-", with: "−") }

/// Shared layout: 24 hours across, labels at 12 am, 6 am, noon, 6 pm, 12 am
private struct HourFrame {
    let w: CGFloat
    let left: CGFloat = 34
    var plot: CGFloat { w - left }
    func x(_ h: Double) -> CGFloat { left + CGFloat(h / 24) * plot }
}

private struct HourAxis: View {
    let f: HourFrame
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach([(0, "12 am"), (6, "6 am"), (12, "noon"), (18, "6 pm"), (24, "12 am")], id: \.0) { h, l in
                Text(l).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                    .position(x: min(max(f.x(Double(h)), f.left + 14), f.w - 16), y: 7)
            }
        }
        .frame(width: f.w, height: 14)
    }
}

private struct InsideChart: View {
    let c: ClimateDay
    var body: some View {
        GeometryReader { g in
            let f = HourFrame(w: g.size.width)
            let sp = c.cooling ? c.cset : c.set
            let vals = c.inside.compactMap { $0 } + sp.compactMap { $0 }
            let lo = floor((vals.min() ?? 18) - 0.5), hi = ceil((vals.max() ?? 22) + 0.5)
            let top: CGFloat = 26, h: CGFloat = 140
            let y = { (t: Double) -> CGFloat in top + CGFloat((hi - t) / max(hi - lo, 1)) * h }
            let step = hi - lo > 6 ? 2.0 : 1.0
            let ticks = stride(from: ceil(lo), through: hi, by: step).map { $0 }
            let peak = c.inside.indices.filter { c.inside[$0] != nil }.max { (c.inside[$0] ?? 0) < (c.inside[$1] ?? 0) }
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.self) { t in
                    Path { p in p.move(to: CGPoint(x: f.left, y: y(t))); p.addLine(to: CGPoint(x: f.w, y: y(t))) }.stroke(Palette.rule, lineWidth: 1)
                    Text("\(iInt(t))°").font(.system(size: 11)).foregroundStyle(.secondary).position(x: 12, y: y(t))
                }
                Path { p in
                    var pen = false
                    for i in 0..<24 {
                        guard let v = sp[i] else { pen = false; continue }
                        if pen { p.addLine(to: CGPoint(x: f.x(Double(i)), y: y(v))) } else { p.move(to: CGPoint(x: f.x(Double(i)), y: y(v))) }
                        p.addLine(to: CGPoint(x: f.x(Double(i + 1)), y: y(v))); pen = true
                    }
                }
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                Path { p in
                    var pen = false
                    for i in 0..<24 {
                        guard let v = c.inside[i] else { pen = false; continue }
                        let pt = CGPoint(x: f.x(Double(i) + 0.5), y: y(v))
                        if pen { p.addLine(to: pt) } else { p.move(to: pt) }; pen = true
                    }
                }
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                ForEach(setLabels(sp), id: \.1) { mid, v in
                    Text("set to \(MonthMath.fmt(v, v.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1))°").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize()
                        .position(x: min(max(f.x(mid), 70), f.w - 40), y: y(v) + 13)
                }
                if let pk = peak, let v = c.inside[pk] {
                    Circle().fill(Color.primary).frame(width: 9, height: 9).position(x: f.x(Double(pk) + 0.5), y: y(v))
                    Text("\(MonthMath.fmt(v, 1))° at \(hourName(pk))").font(.system(size: 12, weight: .semibold)).fixedSize()
                        .position(x: min(max(f.x(Double(pk) + 0.5), 70), f.w - 70), y: y(v) - 13)
                }
                HourAxis(f: f).offset(y: top + h + 10)
            }
        }
        .frame(height: 196)
        .accessibilityElement().accessibilityLabel("Inside temperature through the day")
    }
    /// each set point, labelled under the middle of its longest stretch, clear of the rising line
    private func setLabels(_ sp: [Double?]) -> [(Double, Double)] {
        var best: [Double: (Int, Int)] = [:], order: [Double] = []
        var i = 0
        while i < 24 {
            guard let v = sp[i] else { i += 1; continue }
            let r = (v * 2).rounded() / 2
            var j = i
            while j < 24, let w = sp[j], (w * 2).rounded() / 2 == r { j += 1 }
            if best[r] == nil { order.append(r) }
            if let b = best[r], b.1 - b.0 >= j - i {} else { best[r] = (i, j) }
            i = j
        }
        return order.prefix(3).compactMap { r in best[r].map { (Double($0.0 + $0.1) / 2, r) } }
    }
}

private struct OutsideChart: View {
    let values: [Double?]
    let low: (Double, Int), high: (Double, Int)
    let line: Color, text: Color
    var body: some View {
        GeometryReader { g in
            let f = HourFrame(w: g.size.width)
            let span = max(4, high.0 - low.0)
            let y = { (t: Double) -> CGFloat in 24 + CGFloat((high.0 + span * 0.1 - t) / (span * 1.2)) * 56 }
            ZStack(alignment: .topLeading) {
                Path { p in
                    var pen = false
                    for i in 0..<24 {
                        guard let v = values[i] else { pen = false; continue }
                        let pt = CGPoint(x: f.x(Double(i) + 0.5), y: y(v))
                        if pen { p.addLine(to: pt) } else { p.move(to: pt) }; pen = true
                    }
                }
                .stroke(line, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                Circle().fill(line).frame(width: 9, height: 9).position(x: f.x(Double(high.1) + 0.5), y: y(high.0))
                Text("\(signedDeg(high.0)) at \(hourName(high.1))").font(.system(size: 12, weight: .semibold)).foregroundStyle(text).fixedSize()
                    .position(x: min(max(f.x(Double(high.1) + 0.5), 50), f.w - 50), y: y(high.0) - 12)
                Circle().fill(line).frame(width: 9, height: 9).position(x: f.x(Double(low.1) + 0.5), y: y(low.0))
                Text("\(signedDeg(low.0)) at \(hourName(low.1))").font(.system(size: 12, weight: .semibold)).foregroundStyle(text).fixedSize()
                    .position(x: min(max(f.x(Double(low.1) + 0.5), 50), f.w - 50), y: y(low.0) + 16)
                HourAxis(f: f).offset(y: 108)
            }
        }
        .frame(height: 124)
        .accessibilityElement().accessibilityLabel("Outside temperature through the day, low \(signedDeg(low.0)), high \(signedDeg(high.0))")
    }
}

private struct RuntimeChart: View {
    let c: ClimateDay
    let cool: Color
    var body: some View {
        GeometryReader { g in
            let f = HourFrame(w: g.size.width)
            let base: CGFloat = 146, h: CGFloat = 110, bw = f.plot / 24 - 3
            let firstAux = c.aux.firstIndex { $0 > 0 }
            ZStack(alignment: .topLeading) {
                Text("all hour").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize().position(x: 20, y: base - h)
                Path { p in p.move(to: CGPoint(x: 44, y: base - h)); p.addLine(to: CGPoint(x: f.w, y: base - h)) }.stroke(Palette.rule, lineWidth: 1)
                Path { p in p.move(to: CGPoint(x: f.left, y: base)); p.addLine(to: CGPoint(x: f.w, y: base)) }.stroke(Palette.faint, lineWidth: 1)
                ForEach(0..<24, id: \.self) { i in
                    let run = c.cooling ? c.cool[i] : max(c.hp[i], c.aux[i])
                    let total = CGFloat(min(run, 60) / 60) * h
                    let bh = c.cooling ? 0 : CGFloat(min(c.aux[i], 60) / 60) * h
                    let hh = max(0, total - bh)
                    RoundedRectangle(cornerRadius: 2).fill(c.cooling ? cool : Palette.heat)
                        .frame(width: bw, height: hh).position(x: f.x(Double(i)) + 1.5 + bw / 2, y: base - hh / 2)
                    if bh > 0 {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.aux)
                            .frame(width: bw, height: bh).position(x: f.x(Double(i)) + 1.5 + bw / 2, y: base - hh - bh / 2)
                    }
                    if c.onPeak[i] {
                        Rectangle().fill(Palette.grid).frame(width: f.plot / 24, height: 6).position(x: f.x(Double(i) + 0.5), y: base + 9)
                    }
                }
                if let a = firstAux {
                    Text("Backup heat from \(hourName(a))").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.aux).fixedSize()
                        .position(x: min(f.x(Double(a)) + 90, f.w - 92), y: 12)
                }
                HourAxis(f: f).offset(y: base + 18)
            }
        }
        .frame(height: 180)
        .accessibilityElement().accessibilityLabel("Runtime for each hour of the day")
    }
}

private struct SolarHours: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let f = HourFrame(w: g.size.width)
            let mx = max(values.max() ?? 1, 0.1), base: CGFloat = 92, h: CGFloat = 62, bw = f.plot / 24 - 3
            let best = values.indices.max { values[$0] < values[$1] } ?? 12
            ZStack(alignment: .topLeading) {
                Path { p in p.move(to: CGPoint(x: f.left, y: base)); p.addLine(to: CGPoint(x: f.w, y: base)) }.stroke(Palette.faint, lineWidth: 1)
                ForEach(0..<24, id: \.self) { i in
                    if values[i] > 0 {
                        let bh = CGFloat(values[i] / mx) * h
                        RoundedRectangle(cornerRadius: 2).fill(SK.sunColor).frame(width: bw, height: bh).position(x: f.x(Double(i)) + 1.5 + bw / 2, y: base - bh / 2)
                    }
                }
                Text("\(MonthMath.fmt(values[best], 1)) kWh at \(hourName(best))").font(.system(size: 12, weight: .semibold)).foregroundStyle(SK.sunColor).fixedSize()
                    .position(x: min(max(f.x(Double(best) + 0.5), 60), f.w - 60), y: base - h - 10)
                HourAxis(f: f).offset(y: base + 6)
            }
        }
        .frame(height: 112)
        .accessibilityElement().accessibilityLabel("Solar production for each hour")
    }
}
