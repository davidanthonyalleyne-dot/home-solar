import ActivityKit
import Foundation

// Starts the Live Activity when you open Solar while the sun is up, keeps it current from the app
// and from background refreshes, and ends it at sunset. iOS lets an app start a Live Activity only
// while it's open, and keeps one going for up to eight hours.

enum SolarActivity {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "liveActivity") }
    }

    static func update(_ snap: Snapshot, canStart: Bool = false) async {
        let (rise, set) = SK.sun(SK.day(Date()), lat: snap.lat ?? 43.64, lon: snap.lon ?? -79.43)
        let now = Date(), up = now > rise && now < set
        let state = SolarActivityAttributes.ContentState(snap, rise: rise, set: set)
        let running = Activity<SolarActivityAttributes>.activities
        guard enabled, up, ActivityAuthorizationInfo().areActivitiesEnabled else {
            for a in running { await a.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate) }
            return
        }
        let content = ActivityContent(state: state, staleDate: min(set, now.addingTimeInterval(45 * 60)))
        if let a = running.first {
            await a.update(content)
            for extra in running.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        } else if canStart {
            _ = try? Activity.request(attributes: SolarActivityAttributes(), content: content, pushType: nil)
        }
    }

    static func endAll() async {
        for a in Activity<SolarActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
