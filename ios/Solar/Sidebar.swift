import SwiftUI

// iPad: the five sections in a sidebar, the system's status at its foot, and each screen in the
// detail area at a comfortable reading width.

struct SidebarRoot: View {
    let onLock: () -> Void
    @StateObject private var now = NowModel()
    @State private var tab: SolarTab? = .now
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $tab) {
                ForEach(SolarTab.allCases, id: \.self) { t in
                    Label(t.title, systemImage: t.symbol).tag(t)
                }
            }
            .navigationTitle("Solar")
            .safeAreaInset(edge: .bottom) { SidebarStatus(model: now) { now.settingsPath = ["solaredge"]; tab = .settings } }
        } detail: {
            Group {
                switch tab ?? .now {
                case .now:
                    NowScreen(model: now) { _ in now.settingsPath = ["solaredge"]; tab = .settings }
                case .month: MonthScreen(model: now)
                case .history: HistoryScreen(model: now) { ym in now.selectedMonth = ym; tab = .month }
                case .ask: AskScreen(model: now)
                case .settings: SettingsScreen(model: now, onLock: onLock)
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .tint(SK.sunColor)
    }
}

struct SidebarStatus: View {
    @ObservedObject var model: NowModel
    let open: () -> Void
    var body: some View {
        if let d = model.data {
            Button(action: open) {
                HStack(spacing: 8) {
                    Circle().fill(Fmt.statusColor(d.status.level)).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.status.label).font(.system(size: 13, weight: .medium))
                        if let u = d.updated { Text("Updated \(Fmt.ago(u))").font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
