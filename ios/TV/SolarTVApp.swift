import SwiftUI

// Solar on Apple TV: the same encrypted data.json as the iPhone app, read from the couch.
// The passphrase is typed once (the iPhone keyboard prompt works for this) and kept in the
// keychain, shared with the Top Shelf. Five tabs across the top, as tvOS does it.

@main
struct SolarTVApp: App {
    @StateObject private var model = TVPreview.on ? TVPreview.model() : NowModel()
    @State private var hasKey = TVPreview.on || SharedVault.passphrase != nil

    var body: some Scene {
        WindowGroup {
            Group {
                if hasKey { TVRoot(model: model, start: TVPreview.startTab, ambientNow: TVPreview.args.contains("-ambient")) { hasKey = false } }
                else { TVPassphrase { hasKey = true } }
            }
            .preferredColorScheme(.dark)
        }
    }
}

/// Screenshots in the simulator with the bundled sample numbers (Debug builds only).
enum TVPreview {
    static let args = ProcessInfo.processInfo.arguments
    static var on: Bool {
        #if DEBUG
        return args.contains("-previewTV")
        #else
        return false
        #endif
    }
    static var startTab: SolarTab {
        args.contains("-month") ? .month : args.contains("-history") ? .history : args.contains("-ask") ? .ask : args.contains("-settings") ? .settings : .now
    }
    @MainActor static func model() -> NowModel {
        let m = NowModel(cached: false)
        let s = Snapshot.sample
        m.data = NowData(day: SK.day(Date()), nowKw: s.nowKw, todayKwh: s.todayKwh, fresh: true, offline: false, updated: Date().addingTimeInterval(-300),
                         peakKw: 7.74, acKw: 6, month: 138.2, year: 3452, lifetime: 14828, since: "2023", curve: s.curve, expected: 11,
                         lat: 43.64, lon: -79.43, weather: s.weather, tomorrow: (0, 4, -2), status: ("ok", "System normal"))
        m.preview = true
        if let u = Bundle.main.url(forResource: "sample-data", withExtension: "json"), let d = try? Data(contentsOf: u) {
            m.json = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        return m
    }
}

struct TVPassphrase: View {
    let done: () -> Void
    @State private var text = ""
    @State private var busy = false
    @State private var bad = false
    var body: some View {
        VStack(spacing: 36) {
            Circle().fill(SK.sunColor).frame(width: 120, height: 120).shadow(color: SK.sunColor.opacity(0.6), radius: 40)
            Text("Solar").font(.system(size: 76, weight: .bold))
            Text("Enter your passphrase once. Apple TV keeps it in its keychain.").font(.system(size: 29)).foregroundStyle(.secondary)
            SecureField("Passphrase", text: $text).frame(width: 760).onSubmit(go)
            Button(busy ? "Checking…" : "Continue", action: go).disabled(text.isEmpty || busy)
            if bad { Text("That passphrase doesn't open the data. Try again.").font(.system(size: 26)).foregroundStyle(.red) }
        }
        .padding(80)
    }
    func go() {
        busy = true; bad = false
        Task { let ok = await SolarCrypto.adopt(passphrase: text); busy = false; if ok { done() } else { bad = true } }
    }
}

struct TVRoot: View {
    @ObservedObject var model: NowModel
    let onForget: () -> Void
    @State private var tab: SolarTab
    @State private var lastTouch = Date()
    @State private var ambient: Bool

    init(model: NowModel, start: SolarTab = .now, ambientNow: Bool = false, onForget: @escaping () -> Void) {
        self.model = model; self.onForget = onForget
        _tab = State(initialValue: start); _ambient = State(initialValue: ambientNow)
    }
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $tab) {
                TVNow(model: model) { tab = $0 }.tabItem { Text("Now") }.tag(SolarTab.now)
                TVMonth(model: model).tabItem { Text("Month") }.tag(SolarTab.month)
                TVHistory(model: model) { ym in model.selectedMonth = ym; tab = .month }.tabItem { Text("History") }.tag(SolarTab.history)
                TVAsk(model: model).tabItem { Text("Ask") }.tag(SolarTab.ask)
                TVSettings(model: model, onForget: onForget).tabItem { Text("Settings") }.tag(SolarTab.settings)
            }
            if let d = model.data {
                HStack(spacing: 12) {
                    Circle().fill(Fmt.statusColor(d.status.level)).frame(width: 16, height: 16)
                    Text(Date(), style: .time).font(.system(size: 29, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.top, 52).padding(.trailing, 90)
                .allowsHitTesting(false)
            }
            if ambient, let d = model.data {
                TVAmbient(d: d).transition(.opacity).ignoresSafeArea()
            }
        }
        .task { await model.refresh() }
        .onChange(of: tab) { _, _ in touched() }
        .onMoveCommand { _ in touched() }
        .onPlayPauseCommand { touched() }
        .onExitCommand(perform: ambient ? { touched() } : nil)
        .onReceive(tick) { _ in
            Task { await model.refresh() }
            if !ambient, Date().timeIntervalSince(lastTouch) > 600 { withAnimation(.easeInOut(duration: 1.2)) { ambient = true } }
        }
    }
    func touched() {
        lastTouch = Date()
        if ambient { withAnimation(.easeInOut(duration: 0.6)) { ambient = false } }
    }
}
