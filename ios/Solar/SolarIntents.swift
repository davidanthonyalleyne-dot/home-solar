import AppIntents
import SwiftUI

// Siri, Shortcuts and Spotlight. Each answer leads with the number and shows a small card. They
// read the same encrypted data the app does, with the passphrase from the keychain, so they work
// once Solar has been unlocked on this iPhone.

private func freshSnapshot() async -> Snapshot? {
    if let s = await Snapshot.build() { s.cache(); return s }
    return Snapshot.cached()
}

private let locked: LocalizedStringResource = "Open Solar once to unlock it, then ask again."

struct SolarTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Solar today"
    static let description = IntentDescription("What the panels have made today, against what today's sunlight should give, and what they're making now.")
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let s = await freshSnapshot() else { return .result(dialog: IntentDialog(locked), view: EmptyView().eraseToAnyView()) }
        var line = "Your panels made \(SK.kwh(s.todayKwh)) kilowatt hours today"
        if let e = s.expectedKwh, e > 0.5 { line += ", \(Int((100 * s.todayKwh / e).rounded()))% of what today's sunlight should give" }
        line += s.nowKw >= 0.01 ? ". They're making \(String(format: "%.2f", s.nowKw)) kilowatts right now." : ". They've stopped for the day."
        return .result(dialog: IntentDialog(stringLiteral: line), view: TodaySnippet(s: s).eraseToAnyView())
    }
}

struct SolarMonthIntent: AppIntent {
    static let title: LocalizedStringResource = "Solar this month"
    static let description = IntentDescription("What the panels have made this month and what they've saved.")
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let s = await freshSnapshot(), let m = s.month else { return .result(dialog: IntentDialog(locked), view: EmptyView().eraseToAnyView()) }
        var line = "In \(m.name) the panels have made \(SK.kwh(m.kwh)) kilowatt hours"
        if let sv = m.saved { line += " and saved you about \(SK.dollars(sv))" }
        line += "."
        return .result(dialog: IntentDialog(stringLiteral: line), view: StatSnippet(big: SK.dollars(m.saved ?? 0), unit: "saved", sub: "\(SK.kwh(m.kwh)) kWh in \(m.name) so far").eraseToAnyView())
    }
}

struct SolarTomorrowIntent: AppIntent {
    static let title: LocalizedStringResource = "Solar tomorrow"
    static let description = IntentDescription("How much the panels should make tomorrow, from the forecast.")
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let s = await freshSnapshot(), let d = s.days.first else { return .result(dialog: IntentDialog(locked), view: EmptyView().eraseToAnyView()) }
        let sky = describe(d.code).lowercased()
        let line = d.kwh.map { "Tomorrow should be \(sky), with about \(SK.kwh($0)) kilowatt hours from the panels." } ?? "Tomorrow should be \(sky)."
        let temps = [d.hi.map { "H \(iInt($0.rounded()))°" }, d.lo.map { "L \(iInt($0.rounded()))°" }].compactMap { $0 }.joined(separator: "  ")
        return .result(dialog: IntentDialog(stringLiteral: line),
                       view: StatSnippet(big: d.kwh.map { SK.kwh($0) } ?? "–", unit: "kWh", sub: "Tomorrow, \(sky). \(temps)", symbol: SK.symbol(d.code)).eraseToAnyView())
    }
}

struct SolarStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Solar working?"
    static let description = IntentDescription("Whether the system and the connection to SolarEdge are working.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await Snapshot.build() != nil, let json = SolarCrypto.lastJSON, let st = SolarStatus.items(json) else { return .result(dialog: IntentDialog(locked)) }
        let line: String
        switch st.level {
        case "ok": line = "Yes. Everything is working."
        default: line = st.items.first { $0.level == st.level }.map { "\($0.title). \($0.note)" } ?? "Something needs a look. Open Solar for details."
        }
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

struct SolarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SolarTodayIntent(), phrases: ["How much did \(.applicationName) make today", "\(.applicationName) today", "How's \(.applicationName) doing"],
                    shortTitle: "Solar today", systemImageName: "sun.max")
        AppShortcut(intent: SolarMonthIntent(), phrases: ["What did \(.applicationName) save this month", "\(.applicationName) this month"],
                    shortTitle: "This month", systemImageName: "calendar")
        AppShortcut(intent: SolarTomorrowIntent(), phrases: ["What's tomorrow's \(.applicationName)", "\(.applicationName) tomorrow"],
                    shortTitle: "Tomorrow", systemImageName: "cloud.sun")
        AppShortcut(intent: SolarStatusIntent(), phrases: ["Is \(.applicationName) working"],
                    shortTitle: "Is it working?", systemImageName: "checkmark.circle")
    }
    static let shortcutTileColor: ShortcutTileColor = .orange
}

extension View { func eraseToAnyView() -> AnyView { AnyView(self) } }

struct TodaySnippet: View {
    let s: Snapshot
    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                (Text(SK.kwh(s.todayKwh)).font(.system(size: 40, weight: .bold)) + Text(" kWh").font(.system(size: 18, weight: .semibold)).foregroundColor(.secondary))
                    .monospacedDigit()
                Text(s.expectedKwh.map { "of \(SK.kwh($0)) expected" } ?? "today").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            MiniCurveApp(points: s.curve.compactMap { $0.count > 1 ? $0[1] : nil }).frame(width: 150, height: 48)
        }
        .padding(16)
    }
}

struct StatSnippet: View {
    let big: String, unit: String, sub: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                (Text(big).font(.system(size: 40, weight: .bold)) + Text(" \(unit)").font(.system(size: 18, weight: .semibold)).foregroundColor(.secondary)).monospacedDigit()
                Text(sub).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if let symbol { Image(systemName: symbol).font(.system(.largeTitle)).foregroundStyle(SK.sunColor) }
        }
        .padding(16)
    }
}

struct MiniCurveApp: View {
    let points: [Double]
    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1 else { return }
            let mx = max(points.max() ?? 1, 0.1)
            var p = Path()
            for (i, v) in points.enumerated() {
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(points.count - 1), y: size.height - size.height * 0.92 * CGFloat(v / mx))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(SK.sunColor), lineWidth: 2)
        }
    }
}
