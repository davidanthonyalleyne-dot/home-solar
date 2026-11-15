import Foundation
import AppIntents
#if canImport(ActivityKit)
import ActivityKit
#endif

// Shared by the app and the widget extension: what the Live Activity carries, and the intent that
// opens Solar (the Control Center control and the Lock Screen button run it).

#if canImport(ActivityKit) && os(iOS)
struct SolarActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var nowKw: Double
        var todayKwh: Double
        var expectedKwh: Double?
        var curve: [Double]        // kW at even steps from sunrise to now, at most 48 points
        var rise: Date
        var set: Date
        var updated: Date
    }
}

extension SolarActivityAttributes.ContentState {
    init(_ s: Snapshot, rise: Date, set: Date) {
        nowKw = s.nowKw; todayKwh = s.todayKwh; expectedKwh = s.expectedKwh
        self.rise = rise; self.set = set; updated = SK.iso(s.updated) ?? Date()
        let pts = s.curve.compactMap { $0.count > 1 ? $0[1] : nil }
        let step = max(1, Int((Double(pts.count) / 48).rounded(.up)))
        curve = stride(from: 0, to: pts.count, by: step).map { pts[$0] }
    }
    /// How far the sun is through today, 0 at sunrise and 1 at sunset
    var dayFraction: Double { max(0, min(1, Date().timeIntervalSince(rise) / max(1, set.timeIntervalSince(rise)))) }
}
#endif

struct OpenSolarIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Solar"
    static let description = IntentDescription("Opens Solar on Now.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}
