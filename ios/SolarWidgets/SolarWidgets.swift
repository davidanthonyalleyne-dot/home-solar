// Solar's widgets: Home Screen (small, medium, large, extra large on iPad), Lock Screen (circular,
// rectangular, inline) and StandBy, which uses the small one. Each refresh opens the latest
// data.json and the forecast (WidgetData.swift); iOS decides how often that actually happens.

import WidgetKit
import SwiftUI

@main
struct SolarWidgetBundle: WidgetBundle {
    var body: some Widget { SolarWidget() }
}

struct SolarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Solar", provider: Provider()) { entry in
            SolarWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        }
        .configurationDisplayName("Solar")
        .description("What the panels are making now, today against what's expected, and the days ahead.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snap: Snapshot?
    var locked: Bool { snap == nil }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        if context.isPreview { return completion(Entry(date: Date(), snap: Snapshot.cached() ?? .sample)) }
        Task { completion(Entry(date: Date(), snap: await Snapshot.build() ?? Snapshot.cached())) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            var snap = await Snapshot.build()
            if let snap { snap.cache() } else { snap = Snapshot.cached() }
            let now = Date()
            var entries = [Entry(date: now, snap: snap)]
            // switch to the evening layout at dusk even if no refresh comes
            let sun = SK.sun(SK.day(now), lat: snap?.lat ?? 43.64, lon: snap?.lon ?? -79.43)
            let dusk = sun.set.addingTimeInterval(1800)
            if dusk > now, dusk < now.addingTimeInterval(3600) { entries.append(Entry(date: dusk, snap: snap)) }
            // SolarEdge numbers change about every 15 minutes in daylight; overnight there's nothing new
            let daylight = now > sun.rise.addingTimeInterval(-1800) && now < dusk
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(daylight ? 15 * 60 : 60 * 60))))
        }
    }
}

// MARK: - What an entry means right now

struct Reading {
    let s: Snapshot
    let date: Date
    var today: String { SK.day(date) }
    var sun: (rise: Date, set: Date) { SK.sun(today, lat: s.lat ?? 43.64, lon: s.lon ?? -79.43) }
    var fresh: Bool { (s.todayDate ?? s.today) == today }
    var isDay: Bool { date > sun.rise && date < sun.set.addingTimeInterval(1800) }
    var nowKw: Double { fresh && isDay ? s.nowKw : 0 }
    var todayKwh: Double { fresh ? s.todayKwh : 0 }
    var expected: Double? { s.today == today ? s.expectedKwh : nil }
    var progress: Double { guard let e = expected, e > 0 else { return 0 }; return min(1, todayKwh / e) }
    var tomorrow: Snapshot.Day? { s.days.first { $0.d > today } ?? s.days.first }
    var nextRise: Date { date < sun.rise ? sun.rise : SK.sun(tomorrowDay, lat: s.lat ?? 43.64, lon: s.lon ?? -79.43).rise }
    var tomorrowDay: String { SK.day(date.addingTimeInterval(86400)) }
    var updated: Date? { SK.iso(s.updated) }
    var curve: [[Double]] { fresh ? s.curve : [] }
}

// MARK: - Views

struct SolarWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry

    var body: some View {
        if let s = entry.snap {
            let r = Reading(s: s, date: entry.date)
            switch family {
            case .systemSmall: SmallView(r: r)
            case .systemMedium: MediumView(r: r)
            case .systemLarge: LargeView(r: r)
            case .systemExtraLarge: ExtraLargeView(r: r)
            case .accessoryCircular: CircularView(r: r)
            case .accessoryRectangular: RectangularView(r: r)
            case .accessoryInline: InlineView(r: r)
            default: SmallView(r: r)
            }
        } else {
            LockedView(family: family)
        }
    }
}

struct LockedView: View {
    let family: WidgetFamily
    var body: some View {
        switch family {
        case .accessoryInline: Label("Solar is loading", systemImage: "sun.max")
        case .accessoryCircular: Image(systemName: "sun.max").font(.title2)
        case .accessoryRectangular: Label("Solar is loading", systemImage: "sun.max").font(.headline)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Header()
                Spacer()
                Text("Your numbers will show here once Solar can reach them.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct Header: View {
    var right: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(SK.sunColor).frame(width: 9, height: 9)
            Text("Solar").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let right { Text(right).font(.caption2.weight(.medium)).foregroundStyle(.secondary) }
        }
    }
}

struct BigNumber: View {
    let value: String
    let unit: String
    var size: CGFloat = 34
    var color: Color = SK.sunColor
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.system(size: size, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            Text(unit).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.secondary)
        }
        .minimumScaleFactor(0.6).lineLimit(1)
    }
}

struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(SK.sunColor).frame(width: max(height, g.size.width * value))
            }
        }
        .frame(height: height)
    }
}

/// Today's production against the expected curve, sunrise to sunset.
struct CurveView: View {
    let r: Reading
    var labels = true
    var lineWidth: CGFloat = 2.5
    var tint: Color = SK.sunColor
    var fill: Color = SK.washColor

    var body: some View {
        let sun = r.sun
        let rise = SK.hours(sun.rise), set = SK.hours(sun.set)
        let x0 = rise - 0.6, x1 = set + 0.6
        let pts = r.curve.filter { $0.count == 2 && $0[0] >= rise - 0.75 && $0[0] <= set + 0.75 }
        let expPeak = (r.expected ?? 0) * Double.pi / (2 * max(1, set - rise))
        let ymax = max(1, expPeak, pts.map { $0[1] }.max() ?? 0) * 1.12
        VStack(spacing: 2) {
            Canvas { ctx, size in
                let X = { (h: Double) in CGFloat((h - x0) / (x1 - x0)) * size.width }
                let Y = { (v: Double) in size.height - CGFloat(v / ymax) * (size.height - 2) }
                var base = Path(); base.move(to: CGPoint(x: 0, y: size.height)); base.addLine(to: CGPoint(x: size.width, y: size.height))
                ctx.stroke(base, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                if expPeak > 0 {
                    var e = Path()
                    for i in 0...48 {
                        let h = rise + (set - rise) * Double(i) / 48
                        let p = CGPoint(x: X(h), y: Y(expPeak * sin(Double.pi * Double(i) / 48)))
                        i == 0 ? e.move(to: p) : e.addLine(to: p)
                    }
                    ctx.stroke(e, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                }
                if pts.count > 1, pts.contains(where: { $0[1] > 0 }) {
                    var line = Path(), area = Path()
                    area.move(to: CGPoint(x: X(pts[0][0]), y: size.height))
                    for (i, p) in pts.enumerated() {
                        let c = CGPoint(x: X(p[0]), y: Y(p[1]))
                        i == 0 ? line.move(to: c) : line.addLine(to: c)
                        area.addLine(to: c)
                    }
                    area.addLine(to: CGPoint(x: X(pts.last![0]), y: size.height)); area.closeSubpath()
                    ctx.fill(area, with: .color(fill))
                    ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
                    if r.isDay, let last = pts.last, last[1] > 0 {
                        let c = CGPoint(x: X(last[0]), y: Y(last[1]))
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - lineWidth * 1.6, y: c.y - lineWidth * 1.6, width: lineWidth * 3.2, height: lineWidth * 3.2)), with: .color(tint))
                    }
                }
            }
            if labels {
                HStack {
                    Text(SK.clock(sun.rise)); Spacer(); Text("Noon"); Spacer(); Text(SK.clock(sun.set))
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

struct WeatherGlyph: View {
    let code: Int?
    var day = true
    var size: CGFloat = 14
    var body: some View {
        let name = SK.symbol(code, day: day)
        Image(systemName: name)
            .font(.system(size: size))
            .symbolRenderingMode(name == "sun.max.fill" ? .monochrome : .hierarchical)
            .foregroundStyle(name == "sun.max.fill" ? SK.sunColor : .secondary)
    }
}

struct SmallView: View {
    let r: Reading
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if r.isDay {
                Header()
                Spacer(minLength: 0)
                Text("Generating now").font(.caption).foregroundStyle(.secondary)
                BigNumber(value: SK.kw(r.nowKw), unit: "kW", color: r.nowKw > 0 ? SK.sunColor : .secondary)
                Text(r.expected.map { "\(SK.kwh(r.todayKwh)) of \(SK.kwh($0)) kWh today" } ?? "\(SK.kwh(r.todayKwh)) kWh today")
                    .font(.caption).lineLimit(1).minimumScaleFactor(0.8).padding(.vertical, 5)
                ProgressBar(value: r.progress)
            } else {
                Header(right: "Night")
                Spacer(minLength: 0)
                Text("Today").font(.caption).foregroundStyle(.secondary)
                BigNumber(value: SK.kwh(r.todayKwh), unit: "kWh", color: .primary)
                HStack(alignment: .top, spacing: 5) {
                    WeatherGlyph(code: r.tomorrow?.code, size: 12)
                    Text(tomorrowLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.top, 4)
            }
        }
    }
    var tomorrowLine: String {
        let k = r.tomorrow?.kwh.map { "Tomorrow \(SK.kwh($0)) kWh, " } ?? "Tomorrow, "
        return k + "sunrise \(SK.clock(r.nextRise))"
    }
}

struct MediumView: View {
    let r: Reading
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Header()
                Spacer(minLength: 0)
                Text(r.isDay ? "Now" : "Today").font(.caption).foregroundStyle(.secondary)
                if r.isDay {
                    BigNumber(value: SK.kw(r.nowKw), unit: "kW", size: 32, color: r.nowKw > 0 ? SK.sunColor : .secondary)
                    Text("\(SK.kwh(r.todayKwh)) kWh today").font(.caption).padding(.top, 3)
                } else {
                    BigNumber(value: SK.kwh(r.todayKwh), unit: "kWh", size: 32, color: .primary)
                    Text("Sunrise \(SK.clock(r.nextRise))").font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                }
            }
            .frame(width: 124, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Spacer()
                    if let w = r.s.weather {
                        WeatherGlyph(code: w.code, day: (w.isDay ?? 1) == 1, size: 13)
                        if let t = w.temp { Text("\(Int(t.rounded()))°").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                CurveView(r: r)
                if let t = r.tomorrow {
                    Text("Tomorrow \(t.kwh.map { SK.kwh($0) + " kWh" } ?? "")").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct Totals: View {
    let r: Reading
    var size: CGFloat = 19
    var body: some View {
        HStack(spacing: 0) {
            cell("Today", SK.kwh(r.todayKwh), "kWh")
            Divider().padding(.horizontal, 8)
            cell(r.s.month?.name ?? "Month", SK.kwh(r.s.month?.kwh ?? 0), "kWh")
            Divider().padding(.horizontal, 8)
            cell("Saved", r.s.month?.saved.map { SK.dollars($0) } ?? "–", "this month")
        }
        .frame(height: 38)
    }
    func cell(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: size, weight: .semibold)).monospacedDigit()
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DaysRow: View {
    let r: Reading
    var showUnit = true
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(r.s.days.filter { $0.d > r.today }.prefix(3).enumerated()), id: \.offset) { _, d in
                HStack(spacing: 5) {
                    Text(SK.weekday(d.d)).font(.system(size: 12)).foregroundStyle(.secondary)
                    WeatherGlyph(code: d.code, size: 15)
                    Spacer(minLength: 0)
                    if let k = d.kwh {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(k < 10 ? String(format: "%.1f", k) : String(format: "%.0f", k)).font(.system(size: 14, weight: .semibold))
                            if showUnit { Text("kWh").font(.system(size: 9)).foregroundStyle(.secondary) }
                        }
                        .lineLimit(1)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            }
        }
    }
}

struct LiveHeader: View {
    let r: Reading
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(right: r.updated.map { "Updated \(SK.clock($0))" })
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.isDay ? "Generating now" : "Today").font(.caption).foregroundStyle(.secondary)
                    if r.isDay { BigNumber(value: SK.kw(r.nowKw), unit: "kW", size: 38, color: r.nowKw > 0 ? SK.sunColor : .secondary) }
                    else { BigNumber(value: SK.kwh(r.todayKwh), unit: "kWh", size: 38, color: .primary) }
                }
                Spacer()
                if let w = r.s.weather {
                    HStack(spacing: 4) {
                        WeatherGlyph(code: w.code, day: (w.isDay ?? 1) == 1, size: 15)
                        if let t = w.temp { Text("\(Int(t.rounded()))°").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }
}

struct LargeView: View {
    let r: Reading
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiveHeader(r: r)
            CurveView(r: r).frame(maxHeight: .infinity)
            Totals(r: r)
            DaysRow(r: r)
        }
    }
}

struct ExtraLargeView: View {
    let r: Reading
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                LiveHeader(r: r)
                CurveView(r: r).frame(maxHeight: .infinity)
                Totals(r: r, size: 17)
            }
            .frame(maxWidth: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let b = r.s.bill {
                    Text(b.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 22) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Paid to the grid").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(b.grid.map { SK.dollars($0) } ?? "–").font(.system(size: 28, weight: .semibold))
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Saved by solar").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(b.saved.map { SK.dollars($0) } ?? "–").font(.system(size: 28, weight: .semibold)).foregroundStyle(SK.sunColor)
                        }
                    }
                    if let w = b.without { Text("Without solar, \(SK.dollars(w))").font(.caption).foregroundStyle(.secondary) }
                }
                MonthBars(r: r).frame(maxHeight: .infinity)
                Text("Expected, kWh").font(.system(size: 11)).foregroundStyle(.secondary)
                DaysRow(r: r, showUnit: false)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// This month's solar, one bar a day.
struct MonthBars: View {
    let r: Reading
    var body: some View {
        let days = r.s.month?.days ?? []
        VStack(alignment: .leading, spacing: 4) {
            Text("\(r.s.month?.name ?? "This month") so far, \(SK.kwh(r.s.month?.kwh ?? 0)) kWh").font(.system(size: 11)).foregroundStyle(.secondary)
            Canvas { ctx, size in
                let n = max(28, days.count), mx = max(1, days.max() ?? 1), bw = size.width / CGFloat(n)
                for (i, v) in days.enumerated() {
                    let h = max(2, CGFloat(v / mx) * size.height)
                    let rect = CGRect(x: CGFloat(i) * bw + 1, y: size.height - h, width: max(2, bw - 2), height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(i == days.count - 1 ? SK.sunColor : SK.sunColor.opacity(0.55)))
                }
            }
        }
    }
}

struct CircularView: View {
    let r: Reading
    var body: some View {
        if r.isDay || r.todayKwh > 0 {
            Gauge(value: r.progress) {
                Image(systemName: "sun.max.fill")
            } currentValueLabel: {
                VStack(spacing: -1) {
                    Text(SK.kwh(r.todayKwh)).font(.system(size: 16, weight: .bold)).minimumScaleFactor(0.6)
                    Text("kWh").font(.system(size: 8, weight: .semibold))
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -1) {
                    Text(SK.clock(r.nextRise)).font(.system(size: 15, weight: .bold)).minimumScaleFactor(0.6)
                    Text("sunrise").font(.system(size: 8, weight: .semibold))
                }
            }
        }
    }
}

struct RectangularView: View {
    let r: Reading
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(r.isDay ? "\(SK.kw(r.nowKw)) kW now" : "Sunrise \(SK.clock(r.nextRise))", systemImage: "sun.max.fill")
                .font(.headline).widgetAccentable()
            Text(r.expected.map { "\(SK.kwh(r.todayKwh)) of \(SK.kwh($0)) kWh today" } ?? "\(SK.kwh(r.todayKwh)) kWh today")
                .font(.caption)
            CurveView(r: r, labels: false, lineWidth: 1.6, tint: .primary, fill: .primary.opacity(0.2)).frame(height: 16)
        }
    }
}

struct InlineView: View {
    let r: Reading
    var body: some View {
        Label(r.isDay ? "\(String(format: "%.1f", r.nowKw)) kW · \(SK.kwh(r.todayKwh)) kWh today" : "\(SK.kwh(r.todayKwh)) kWh today",
              systemImage: "sun.max.fill")
    }
}
