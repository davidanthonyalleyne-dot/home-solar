import ActivityKit
import WidgetKit
import SwiftUI

// The Live Activity: on the Lock Screen, the live number, today against what's expected and the
// sun's place on today's arc; in the Dynamic Island, the live kW, opening to today's curve.

struct SolarLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SolarActivityAttributes.self) { ctx in
            LockActivityView(s: ctx.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text("Solar").font(.subheadline.weight(.semibold)) } icon: { SunDot(size: 18) }
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(SK.kw(s.nowKw)) kW").font(.subheadline.weight(.semibold)).foregroundStyle(SK.sunColor).monospacedDigit()
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(SK.kwh(s.todayKwh)) kWh").font(.title2.weight(.bold)).monospacedDigit()
                            Text(s.expectedKwh.map { "today, of \(SK.kwh($0)) expected" } ?? "today")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        MiniCurve(points: s.curve, fraction: s.dayFraction).frame(width: 150, height: 44)
                    }
                    .padding(.horizontal, 4).padding(.bottom, 4)
                }
            } compactLeading: {
                SunDot(size: 16)
            } compactTrailing: {
                Text("\(String(format: "%.1f", s.nowKw)) kW").font(.caption.weight(.semibold)).foregroundStyle(SK.sunColor).monospacedDigit()
            } minimal: {
                SunDot(size: 16)
            }
            .keylineTint(SK.sunColor)
        }
    }
}

struct SunDot: View {
    let size: CGFloat
    var body: some View { Circle().fill(SK.sunColor).frame(width: size * 0.55, height: size * 0.55).frame(width: size, height: size) }
}

struct LockActivityView: View {
    let s: SolarActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SunDot(size: 20)
                Text("Solar").font(.subheadline.weight(.semibold))
                Spacer()
                Text("sunset \(SK.clockAmPm(s.set))").font(.footnote).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(SK.kw(s.nowKw)).font(.system(size: 34, weight: .bold)).monospacedDigit()
                + Text(" kW now").font(.system(size: 17, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(SK.kwh(s.todayKwh)) kWh").font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    if let e = s.expectedKwh { Text("of \(SK.kwh(e)) expected").font(.caption).foregroundStyle(.secondary) }
                }
            }
            SunArc(fraction: s.dayFraction).frame(height: 40)
            HStack {
                Text(SK.clockAmPm(s.rise)); Spacer(); Text(SK.clockAmPm(s.set))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }
}

/// Today's arc from sunrise to sunset with the sun where it is now
struct SunArc: View {
    let fraction: Double
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, top: CGFloat = 6
            var arc = Path()
            arc.move(to: CGPoint(x: 0, y: h))
            arc.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w / 2, y: top - (h - top)))
            ctx.stroke(arc, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
            var base = Path(); base.move(to: CGPoint(x: 0, y: h)); base.addLine(to: CGPoint(x: w, y: h))
            ctx.stroke(base, with: .color(.white.opacity(0.3)), lineWidth: 1)
            let t = fraction, cy = top - (h - top)
            let x = 2 * (1 - t) * t * (w / 2) + t * t * w
            let y = (1 - t) * (1 - t) * h + 2 * (1 - t) * t * cy + t * t * h
            ctx.fill(Path(ellipseIn: CGRect(x: x - 7, y: y - 7, width: 14, height: 14)), with: .color(SK.sunColor))
        }
    }
}

/// Today's output so far, drawn across the share of the day that has passed
struct MiniCurve: View {
    let points: [Double]
    let fraction: Double
    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1 else { return }
            let mx = max(points.max() ?? 1, 0.1), w = size.width * max(0.15, fraction), h = size.height
            var p = Path()
            for (i, v) in points.enumerated() {
                let pt = CGPoint(x: w * CGFloat(i) / CGFloat(points.count - 1), y: h - h * 0.92 * CGFloat(v / mx))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(SK.sunColor), lineWidth: 2)
        }
    }
}
