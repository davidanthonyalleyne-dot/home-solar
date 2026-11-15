import SwiftUI
import UniformTypeIdentifiers

// Phase five: Settings in SwiftUI, the way iOS Settings looks. Ported from web/app.js
// (settingsScreen, settingsPage, solarStatusCard, systemStatus, solarRows, inverterRows,
// systemSection, heatingPage, uploadLog, sendFile).

// MARK: - System status, as the status dot works it out

struct StatusItem { var level: String; var title: String; var note: String }

enum SolarStatus {
    static func items(_ json: [String: Any]) -> (level: String, items: [StatusItem], connect: Bool)? {
        guard let s = json["solar"] as? [String: Any] else { return nil }
        let n = { (x: Any?) in (x as? NSNumber)?.doubleValue }
        var items: [StatusItem] = []
        let when = { (iso: Any?) -> String in SK.iso(iso as? String).map { Fmt.timeOf($0) } ?? "" }
        for x in (s["alerts"] as? [[String: Any]] ?? []) {
            var parts: [String] = []
            if let c = x["component"] as? String { parts.append(c) }
            if let i = n(x["impact"]) { parts.append("impact \(iInt(i)) of 9") }
            if let f = x["first"] { parts.append("since \(when(f))") }
            items.append(StatusItem(level: "bad", title: x["type"] as? String ?? "SolarEdge alert",
                                    note: parts.joined(separator: " · ") + ". SolarEdge also opened an issue in your GitHub repo, which emails you."))
        }
        let metrics = (s["inverter"] as? [String: Any])?["metrics"] as? [String: [String: Any]] ?? [:]
        let modeName = metrics.keys.first { $0.range(of: "mode|status|state", options: [.regularExpression, .caseInsensitive]) != nil }
        let mode = modeName.map { "\(metrics[$0]?["latest"] ?? "")".uppercased() } ?? ""
        let day = SK.day(Date()), sun = SK.sun(day), now = Date()
        let daylight = now > sun.rise && now < sun.set
        if daylight, mode.range(of: "FAULT|ERROR|SHUTDOWN|LOCKED", options: .regularExpression) != nil {
            items.append(StatusItem(level: "bad", title: "Inverter fault", note: "The inverter reports \(mode.lowercased().replacingOccurrences(of: "_", with: " ")). Check its light and the SolarEdge app."))
        }
        let updated = SK.iso(s["updated"] as? String)
        let age = updated.map { now.timeIntervalSince($0) } ?? 0
        let needsConnect = s["needsConnect"] as? Bool ?? false, trouble = s["authTroubleSince"] as? String
        let fresh = s["todayDate"] as? String == day && !needsConnect && trouble == nil && age < 75 * 60
        if !needsConnect, trouble == nil, age > 90 * 60, age < 36 * 3600 {
            items.append(StatusItem(level: "warn", title: "Numbers are \(Fmt.ago(updated!).replacingOccurrences(of: " ago", with: "")) old",
                                    note: "GitHub hasn't run the update since \(when(s["updated"])), so today's figures stop there. Solar has asked it to run now; fresh numbers usually follow within a few minutes. Your panels are probably fine."))
        }
        let wd = ((json["weather"] as? [String: Any])?["daily"] as? [String: [Any]])?[day]
        let snowy = wd.map { (n($0.count > 5 ? $0[5] : nil) ?? 0) > 0 || [71, 73, 75, 77, 85, 86].contains((($0.count > 2 ? $0[2] : nil) as? NSNumber)?.intValue ?? -1) } ?? false
        if fresh, daylight, now.timeIntervalSince(sun.rise) > 3 * 3600, (n(s["today"]) ?? 0) < 0.05, !snowy {
            items.append(StatusItem(level: "bad", title: "No production today", note: "Nothing since sunrise at \(Fmt.clock(sun.rise)). Check the inverter's light and the SolarEdge app."))
        }
        var connect = false
        let hasUrl = json["connectUrl"] as? String != nil
        if needsConnect {
            connect = hasUrl
            items.append(StatusItem(level: "warn", title: "SolarEdge needs you to sign in again", note: "The app can't get new numbers until you do. Showing the last ones, from \(when(s["updated"]))."))
        } else if let t = trouble {
            connect = hasUrl
            items.append(StatusItem(level: "warn", title: "No live data from SolarEdge", note: "SolarEdge has refused to renew the app's access since \(when(t)), so the numbers are from \(when(s["updated"])). Your panels are fine. Signing in again usually fixes it."))
        }
        if items.isEmpty {
            items.append(s["alertsChecked"] != nil ? StatusItem(level: "ok", title: "System normal", note: "")
                         : StatusItem(level: "unknown", title: "Alerts not checked yet", note: ""))
        }
        let level = items.contains { $0.level == "bad" } ? "bad" : items.contains { $0.level == "warn" } ? "warn" : items[0].level
        return (level, items, connect)
    }
}

enum Fmt {
    static func clock(_ d: Date) -> String { let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "h:mm a"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f.string(from: d) }
    static func timeOf(_ d: Date) -> String { let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "MMM d 'at' h:mm a"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f.string(from: d) }
    static func ago(_ t: Date) -> String {
        let m = Int(Date().timeIntervalSince(t) / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m) min ago" }
        if m < 24 * 60 { return "\(iInt((Double(m) / 60).rounded())) hr ago" }
        let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "MMMM d, h:mm a"; f.amSymbol = "am"; f.pmSymbol = "pm"
        return f.string(from: t)
    }
    static func span(_ a: String, _ z: String) -> String { "\(MonthMath.shortDay(a)), \(a.prefix(4)) to \(MonthMath.shortDay(z)), \(z.prefix(4))" }
    static func statusColor(_ level: String) -> Color {
        switch level {
        case "bad": return Palette.bad
        case "warn": return Palette.dyn(0xE5B800, 0xFFD60A)
        case "unknown": return Palette.faint
        default: return Palette.dyn(0x2E9E5B, 0x30D158)
        }
    }
}

// MARK: - Settings

struct SettingsScreen: View {
    @ObservedObject var model: NowModel
    let onLock: () -> Void
    @State private var importing = false
    @State private var upStatus: String? = nil
    @State private var upBad = false
    @AppStorage("landscape") private var landscape = true

    var body: some View {
        NavigationStack(path: $model.settingsPath) {
            Group {
                if let j = model.json { root(j) } else { ProgressView() }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: String.self) { k in
                if let j = model.json { SettingsPage(key: k, json: j, onLock: onLock) }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .commaSeparatedText, .zip,
                                                                      UTType(filenameExtension: "xlsx") ?? .data], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { Task { await upload(urls) } }
        }
        .task { await model.refresh() }
    }

    @ViewBuilder func root(_ j: [String: Any]) -> some View {
        let s = j["solar"] as? [String: Any]
        let ok = (s?["connected"] as? Bool ?? false) && !(s?["needsConnect"] as? Bool ?? false) && s?["authTroubleSince"] == nil
        let bills = (j["bills"] as? [[String: Any]] ?? []).filter { ($0["preSolar"] as? Bool) != true }
        let t = j["thermostat"] as? [String: Any]
        let y = j["system"] as? [String: Any] ?? [:]
        let panels = y["panels"] as? [String: Any], inv = y["inverter"] as? [String: Any]
        let st = SolarStatus.items(j)
        List {
            Section("Data sources") {
                NavigationLink(value: "solaredge") {
                    SetRow(icon: "sun.max", title: "SolarEdge") {
                        HStack(spacing: 6) {
                            if s != nil { Circle().fill(Fmt.statusColor(ok ? (st?.level ?? "ok") : "bad")).frame(width: 8, height: 8) }
                            Text(ok ? "Connected" : s?["authTroubleSince"] != nil ? "No data" : (s?["needsConnect"] as? Bool ?? false) ? "Sign in again" : "Not connected")
                        }
                    }
                }
                NavigationLink(value: "hydro") { SetRow(icon: "bolt", title: "Toronto Hydro") { Text(bills.isEmpty ? "No bills" : "\(bills.count) bills") } }
                NavigationLink(value: "thermostat") {
                    SetRow(icon: "thermometer.medium", title: "ecobee thermostat") { Text((t?["to"] as? String).map { "to \(MonthMath.shortDay($0))" } ?? "Not added") }
                }
            }
            if j["uploadToken"] as? String != nil {
                Section {
                    Button { importing = true } label: { SetRow(icon: "plus", title: "Add a bill or data file") { EmptyView() } }
                        .tint(.primary)
                } footer: {
                    Text(upStatus ?? "A Toronto Hydro bill PDF, a MyTorontoHydro spreadsheet or your ecobee thermostat's history, or a zip of any of them. Encrypted before it leaves your phone.")
                        .foregroundStyle(upBad ? Palette.bad : Color.secondary)
                }
            }
            Section("Your home") {
                if let panels, let inv {
                    NavigationLink(value: "system") {
                        SetRow(icon: "square.grid.3x2", title: "Solar system") {
                            Text("\((panels["count"] as? NSNumber)?.intValue ?? 0) panels · \(MonthMath.fmt((inv["dcKw"] as? NSNumber)?.doubleValue, 1)) kW")
                        }
                    }
                }
                if y["heating"] != nil { NavigationLink(value: "heating") { SetRow(icon: "house", title: "Heating and cooling") { Text("Heat pump") } } }
            }
            Section {
                Toggle(isOn: $landscape) { SetRow(icon: "rectangle.landscape.rotate", title: "Landscape layout") { EmptyView() } }
                    .tint(SK.sunColor)
            } header: { Text("Display") } footer: { Text("On an iPhone turned sideways, Now and Month split into two columns. Off keeps the upright layout.") }
            Section("App") {
                NavigationLink(value: "alerts") { SetRow(icon: "bell", title: "Alerts") { Text("Home Screen app") } }
                NavigationLink(value: "ask") { SetRow(icon: "bubble.left", title: "Sunny") { Text(j["askKey"] != nil ? "Claude" : "Not set up") } }
                NavigationLink(value: "security") { SetRow(icon: "lock", title: "Security") { Text("Face ID") } }
            }
            Section {
            } footer: {
                VStack(spacing: 4) {
                    Text("Solar \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")) · Built \(SK.iso(j["generated"] as? String).map { Fmt.timeOf($0) } ?? "")")
                    Text("Weather data by Open-Meteo.com. Sunrise and sunset are calculated for Parkdale.")
                }
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
            }
        }
        .refreshable { await model.refresh(force: true) }
    }

    // a bill, a meter export, ecobee history or a zip: encrypted here, committed to data/inbox
    func upload(_ urls: [URL]) async {
        guard let token = model.json?["uploadToken"] as? String else { return }
        var sent = 0
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { upStatus = "Couldn't read \(url.lastPathComponent)."; upBad = true; continue }
            let ext = url.pathExtension.lowercased()
            var kind: String? = ext == "pdf" ? "bill" : ["xlsx", "csv"].contains(ext) ? "meter" : ext == "zip" ? "zip" : nil
            if ext == "csv", let head = String(data: data.prefix(64), encoding: .utf8), head.replacingOccurrences(of: "\u{FEFF}", with: "").hasPrefix("#,Thermostat") { kind = "ecobee" }
            guard let kind else { upStatus = "\(url.lastPathComponent) isn't a bill, spreadsheet or zip."; upBad = true; continue }
            guard data.count <= (kind == "zip" ? 40 : 20) * 1024 * 1024 else { upStatus = "\(url.lastPathComponent) is too big."; upBad = true; continue }
            do {
                upStatus = "Encrypting…"; upBad = false
                var box = try SolarCrypto.seal(data)
                box["kind"] = kind; box["ext"] = ext
                upStatus = "Sending…"
                let what = kind == "bill" ? "bill" : kind == "ecobee" ? "thermostat file" : kind == "zip" ? "zip of files" : "meter file"
                try await GitHub.toInbox(box, kind: kind, message: "Add a \(what) from the app", token: token)
                sent += 1
                upStatus = kind == "zip" ? "Sent. Everything in the zip will be in the app in a few minutes."
                    : kind == "bill" ? "Sent. The bill will be in the app in a few minutes."
                    : kind == "ecobee" ? "Sent. The heating history will be in the app in a few minutes."
                    : "Sent. The new readings will be in the app in a few minutes."
            } catch {
                upStatus = (error as? LocalizedError)?.errorDescription ?? "That didn't work. Pull down to refresh, then try again."; upBad = true
            }
        }
        if sent > 1, !upBad { upStatus = "Sent \(sent) files. They'll be in the app in a few minutes." }
    }
}

struct SetRow<V: View>: View {
    let icon: String, title: String
    @ViewBuilder let value: () -> V
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                .frame(width: 29, height: 29).background(SK.sunColor, in: RoundedRectangle(cornerRadius: 7))
            Text(title)
            Spacer()
            value().foregroundStyle(.secondary)
        }
    }
}

// MARK: - The pages

struct SettingsPage: View {
    let key: String
    let json: [String: Any]
    let onLock: () -> Void
    @State private var armed = false

    static let titles = ["solaredge": "SolarEdge", "hydro": "Toronto Hydro", "thermostat": "ecobee thermostat", "system": "Solar system",
                         "heating": "Heating and cooling", "alerts": "Alerts", "ask": "Sunny", "security": "Security"]

    var body: some View {
        List { content }
            .navigationTitle(SettingsPage.titles[key] ?? "")
            .navigationBarTitleDisplayMode(.large)
    }

    private func row(_ k: String, _ v: String, _ c: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(k); Spacer(minLength: 12); Text(v).foregroundStyle(c ?? Color.secondary).multilineTextAlignment(.trailing).monospacedDigit() }
    }
    private var n: (Any?) -> Double? { { ($0 as? NSNumber)?.doubleValue } }

    @ViewBuilder var content: some View {
        let s = json["solar"] as? [String: Any] ?? [:]
        let y = json["system"] as? [String: Any] ?? [:]
        let pv = y["private"] as? [String: Any] ?? [:]
        switch key {
        case "solaredge": solarEdge(s)
        case "hydro":
            let h = (json["hydro"] as? [String: Any] ?? [:]).keys.sorted()
            let bills = (json["bills"] as? [[String: Any]] ?? []).filter { ($0["preSolar"] as? Bool) != true }
            Section {
                row("Meter data", h.isEmpty ? "None yet" : Fmt.span(h.first!, h.last!))
                row("Bills", bills.isEmpty ? "None yet" : "\(bills.count) · \(MonthMath.date(String((bills.first?["to"] as? String ?? "").prefix(7)) + "-01", "MMM yyyy")) to \(MonthMath.date(String((bills.last?["to"] as? String ?? "").prefix(7)) + "-01", "MMM yyyy"))")
            } footer: { Text("Meter readings come from the spreadsheets you download from MyTorontoHydro. Add them, and bill PDFs, from Settings.") }
            let ups = Array((json["uploads"] as? [[String: Any]] ?? []).suffix(4).reversed())
            if !ups.isEmpty {
                Section("Files added lately") {
                    ForEach(Array(ups.enumerated()), id: \.offset) { _, x in
                        let kind = x["kind"] as? String, to = x["to"] as? String, from = x["from"] as? String
                        let what = kind == "bill" ? (to.map { "\(MonthMath.monthYear(String($0.prefix(7)))) bill" } ?? "A bill") : kind == "meter" ? "Meter file"
                            : kind == "thermostat" ? "Thermostat\(from.map { ", " + MonthMath.date(String($0.prefix(7)) + "-01", "MMM yyyy") } ?? "")" : (x["file"] as? String ?? "A file")
                        let res = x["result"] as? String
                        row(what, res == "added" ? "added" : res == "duplicate" ? "already in the app" : "not added\((x["note"] as? String).map { ": \($0)" } ?? "")",
                            res == "refused" ? Palette.bad : nil)
                    }
                }
            }
        case "thermostat":
            let t = json["thermostat"] as? [String: Any]
            Section {
                row("History", (t?["from"] as? String).flatMap { f in (t?["to"] as? String).map { Fmt.span(f, $0) } } ?? "None yet")
                if let d = t?["daily"] as? [String: Any] { row("Days", MonthMath.fmt(Double(d.count))) }
            } footer: { Text("From ecobee.com, open Home IQ or your thermostat's Download data and save a month as CSV, then add it from Settings. The heating section in Month uses it.") }
        case "system":
            let p = y["panels"] as? [String: Any] ?? [:], inv = y["inverter"] as? [String: Any] ?? [:]
            let opt = y["optimizers"] as? [String: Any], sh = y["shutdown"] as? [String: Any], meter = y["meter"] as? [String: Any]
            let strings = (p["strings"] as? [Int]) ?? []
            Section {
                if let c = p["count"] { row("Panels", "\(c) × \(p["model"] ?? ""), \(p["watts"] ?? "") W") }
                if strings.count > 1 { row("Wiring", "\(strings.count) strings, \(strings.dropLast().map(String.init).joined(separator: ", ")) and \(strings.last!) panels") }
                if let dc = n(inv["dcKw"]) { row("Size", "\(MonthMath.fmt(dc, 2)) kW of panels, \(MonthMath.fmt(n(inv["acKw"]))) kW inverter") }
                if let o = opt { row("Optimizers", "\(o["count"] ?? "") × \(o["model"] ?? ""), one per panel") }
                row("Inverter", inv["model"] as? String ?? "–")
                if let x = pv["inverterSerial"] as? String { row("Inverter serial", x) }
                if let x = sh?["model"] as? String { row("Shutdown", x) }
                if let x = pv["switchSerial"] as? String { row("Switch serial", x) }
                if let m = meter?["model"] as? String { row("Meter", m + ((pv["meter"] as? String).map { " · \($0)" } ?? "")) }
                if let x = y["installer"] as? String { row("Installed by", x) }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("In an emergency, turn \(sh?["where"] as? String ?? "the rapid shutdown switch") to Off. That shuts the panels down to a safe voltage.")
                    if let dc = n(inv["dcKw"]), let ac = n(inv["acKw"]), dc > ac {
                        Text("The panels can make \(MonthMath.fmt(dc, 1)) kW but the inverter tops out at \(MonthMath.fmt(ac)) kW, so on the brightest days output levels off at about \(MonthMath.fmt(ac)) kW. That's by design, not a fault.")
                    }
                }
            }
        case "heating": heating(y, pv)
        case "alerts":
            Section {
                Text("Alerts reach this iPhone through the Home Screen version of Solar for now: no output on a sunny day, an inverter fault, SolarEdge going quiet, files you add, the monthly summary and heavy winter days.")
                Text("To turn them on, open Solar in Safari, tap Share, then Add to Home Screen, and open Settings, Alerts there.").foregroundStyle(.secondary)
            }
        case "ask":
            let count = ChatStore.load().count
            Section {
                row("Powered by", json["askKey"] != nil ? "Claude Haiku" : "Not set up")
                row("Saved conversations", count > 0 ? "\(count) on this phone" : "None")
                row("Voice", "Recognized on this iPhone, read aloud by \(Voice.bestVoice()?.name ?? "the system voice")")
            } footer: {
                Text(json["askKey"] != nil ? "Each question to Sunny sends Claude a summary of the app's data and the forecast. Conversations stay on this phone. For the best voice, download Nathan in Settings, Accessibility, Spoken Content, Voices."
                     : "Add an ANTHROPIC_API_KEY secret in GitHub to turn Sunny on.")
            }
            if count > 0 {
                Section { Button(armed ? "Tap again to delete all" : "Delete all conversations", role: .destructive) { if armed { ChatStore.save([]); armed = false } else { armed = true } } }
            }
        case "security":
            Section {
                row("Data", "Encrypted")
                row("Unlock", "Sign in with Apple and Face ID")
                row("Passphrase", SharedVault.passphrase != nil ? "In this iPhone's keychain" : "Not entered")
            } footer: { Text("Everything Solar publishes is encrypted with your passphrase. This iPhone keeps it in its keychain, shared only with Solar's widgets, so the app opens with Face ID.") }
            Section { Button("Lock Solar now", action: onLock) }
            Section {
                Button(armed ? "Tap again to forget it" : "Forget the passphrase on this iPhone", role: .destructive) {
                    if armed { SharedVault.passphrase = nil; armed = false; onLock() } else { armed = true }
                }
            } footer: { Text("Solar will ask for it again the next time it opens. The widgets stay empty until then.") }
        default: EmptyView()
        }
    }

    @ViewBuilder func solarEdge(_ s: [String: Any]) -> some View {
        if let st = SolarStatus.items(json) {
            let linkOk = !(s["needsConnect"] as? Bool ?? false) && s["authTroubleSince"] == nil && (s["connected"] as? Bool) != false
            let head = st.level == "bad" ? st.items.first { $0.level == "bad" }!.title : st.level == "warn" ? st.items.first { $0.level == "warn" }!.title
                : linkOk ? "Connected" : "Not connected"
            let sub = st.level == "ok" ? "Everything is working" : st.level == "unknown" ? "Waiting for the first check" : linkOk ? "Connected, but something needs a look" : "Not getting new numbers"
            let issues = st.items.filter { $0.level == "bad" || $0.level == "warn" }
            let lead = issues.first { $0.title == head }, rest = issues.filter { $0.title != head }
            let sun = SK.sun(SK.day(Date())), now = Date()
            Section {
                HStack(spacing: 14) {
                    Image(systemName: st.level == "ok" ? "checkmark" : st.level == "unknown" ? "clock" : "exclamationmark")
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(Fmt.statusColor(st.level), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(head).font(.system(size: 20, weight: .semibold))
                        Text(sub).font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                if let lead, !lead.note.isEmpty { Text(lead.note).font(.system(size: 15)).foregroundStyle(.secondary) }
                ForEach(Array(rest.enumerated()), id: \.offset) { _, x in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(Fmt.statusColor(x.level)).frame(width: 8, height: 8).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) { Text(x.title).fontWeight(.semibold); if !x.note.isEmpty { Text(x.note).font(.system(size: 15)).foregroundStyle(.secondary) } }
                    }
                }
                if st.connect, let u = json["connectUrl"] as? String, let url = URL(string: u) {
                    Link("Connect SolarEdge", destination: url).fontWeight(.semibold).tint(SK.sunColor)
                    Button("Copy the sign-in link instead") { UIPasteboard.general.string = u }.tint(SK.sunColor)
                }
                if let u = SK.iso(s["updated"] as? String) { row("Latest numbers", Fmt.ago(u)) }
                if linkOk, let e = n(s["liveEvery"]) {
                    row("Checks SolarEdge", now > sun.rise && now < sun.set ? "About every \(MonthMath.fmt(e)) min until sunset" : "Every \(MonthMath.fmt(e)) min from sunrise at \(Fmt.clock(sun.rise))")
                }
                if let g = SK.iso(json["generated"] as? String) { row("App last updated", Fmt.ago(g)) }
                if let c = SK.iso(s["alertsChecked"] as? String) {
                    row("System alerts", st.items.contains { $0.level == "bad" && $0.title.localizedCaseInsensitiveContains("alert") } ? "Open" : "None, checked \(Fmt.ago(c))")
                }
            }
        }
        let eq = s["equipment"] as? [String: Any]
        Section {
            if let pk = n(s["peakKw"]) { row("System size", "\(MonthMath.fmt(pk, 2)) kW") }
            if let i = s["installed"] as? String { row("Installed", MonthMath.date(i, "MMMM d, yyyy")) }
            ForEach(Array((eq?["inverters"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, i in
                row("Inverter", i["model"] as? String ?? i["name"] as? String ?? "–")
                if let f = i["firmware"] as? String { row("Firmware", f) }
                if let c = i["communication"] as? String {
                    row("Connection", ["WIFI": "Wi-Fi", "ETHERNET": "Ethernet", "LAN": "Ethernet", "CELLULAR": "Cellular"][c.uppercased()] ?? c.capitalized)
                }
            }
            if let eq {
                let wired = (eq["inverters"] as? [[String: Any]] ?? []).reduce(0) { $0 + ((($1["optimizers"] as? NSNumber)?.intValue) ?? 0) }
                let models = Array(Set((eq["optimizerModels"] as? [String] ?? []).map { String($0.split(separator: "-").first ?? "") })).sorted()
                let count = wired > 0 ? wired : (eq["optimizers"] as? NSNumber)?.intValue
                if let count { row("Optimizers", "\(count)\(models.isEmpty ? "" : " · " + models.joined(separator: ", "))") }
            }
        } footer: {
            if s["error"] != nil && !(s["error"] is NSNull) { Text("The last refresh failed, so these are the previous numbers.") }
        }
        inverterReadings(s)
    }

    @ViewBuilder func inverterReadings(_ s: [String: Any]) -> some View {
        let inv = s["inverter"] as? [String: Any]
        let m = inv?["metrics"] as? [String: [String: Any]] ?? [:]
        let live = m.keys.filter { k in !((m[k]?["max"] as? NSNumber)?.doubleValue == 0 && (m[k]?["min"] as? NSNumber)?.doubleValue == 0) }.sorted()
        if !live.isEmpty {
            let pick = { (re: String) in live.first { $0.range(of: re, options: [.regularExpression, .caseInsensitive]) != nil } }
            let order = [pick("^power$|^ac.*power|activepower"), pick("mode|status|state"), pick("temp"), pick("^voltage$|^ac.*volt"), pick("^current$|^ac.*curr"),
                         pick("freq"), pick("dc.*power"), pick("dc.*volt"), pick("^energy$")].compactMap { $0 }
            var seen = Set<String>()
            let shown = (order + live).filter { seen.insert($0).inserted }.prefix(8)
            let labels = ["power": "Output", "energy": "Energy in the last hour", "voltage": "Grid voltage", "current": "Current", "frequency": "Grid frequency", "temperature": "Temperature"]
            let units = ["C": "°C", "CELSIUS": "°C", "W": " W", "WATT": " W", "V": " V", "VOLT": " V", "HZ": " Hz", "HERTZ": " Hz", "A": " A", "AMPERE": " A", "WH": " Wh", "KWH": " kWh"]
            let modes = ["MPPT": "Producing", "SLEEPING": "Sleeping", "NIGHT": "Night", "NIGHT_MODE": "Night", "THROTTLED": "Limited", "FAULT": "Fault", "STARTING": "Starting up",
                         "OFF": "Off", "SHUTTING_DOWN": "Shutting down", "STANDBY": "Standby", "LOCKED": "Locked"]
            Section {
                ForEach(Array(shown), id: \.self) { k in
                    let x = m[k] ?? [:]
                    let u = "\(x["unit"] ?? "")".uppercased()
                    let unit = units[u] ?? ((x["unit"] as? String).map { " " + $0.lowercased() } ?? "")
                    let v: String = (x["latest"] as? NSNumber).map { MonthMath.fmt($0.doubleValue, abs($0.doubleValue) < 100 ? 1 : 0) + unit }
                        ?? modes["\(x["latest"] ?? "")".uppercased()] ?? "\(x["latest"] ?? "–")".replacingOccurrences(of: "_", with: " ").lowercased().capitalized
                    let pretty = k.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
                    row(labels[k] ?? pretty, v)
                }
            } header: { Text("Inverter readings") } footer: {
                Text("Hourly from SolarEdge\(SK.iso(inv?["at"] as? String).map { ", last at \(Fmt.timeOf($0))" } ?? "").")
            }
        }
    }

    @ViewBuilder func heating(_ y: [String: Any], _ pv: [String: Any]) -> some View {
        if let h = y["heating"] as? [String: Any] {
            let ah = h["airHandler"] as? [String: Any] ?? [:], bk = h["backupHeat"] as? [String: Any] ?? [:], ou = h["outdoorUnit"] as? [String: Any] ?? [:]
            let short = { (x: Any?) in ("\(x ?? "")").replacingOccurrences(of: "^Bosch\\s+", with: "", options: .regularExpression) }
            Section("Heat pump") {
                row("Make", "Bosch")
                if let s = h["size"] as? String { row("Size", s) }
                if h["thermostat"] != nil { row("Thermostat", "ecobee") }
                if let r = ah["refrigerant"] as? String { row("Refrigerant", r) }
            }
            Section {
                row("Make", "Bosch")
                row("Model", ou["model"] != nil ? short(ou["model"]) : "Not added yet")
                if let p = ou["part"] as? String { row("Part number", p) }
                if let s = pv["outdoorUnitSerial"] as? String { row("Serial", s) }
                if let c = ou["compressor"] as? String { row("Compressor", c.replacingOccurrences(of: " rotary, ", with: ", ").replacingOccurrences(of: " to ", with: "–").replacingOccurrences(of: " capacity", with: "")) }
                let rated = [(ou["seer2"] as? String).map { "SEER2 \($0.replacingOccurrences(of: " to ", with: "–"))" }, (ou["hspf2"] as? String).map { "HSPF2 \($0.replacingOccurrences(of: " to ", with: "–"))" }].compactMap { $0 }
                if !rated.isEmpty { row("Rated", rated.joined(separator: " · ")) }
            } header: { Text("Outdoor unit") } footer: { if let c = ou["heatingCapacity"] as? String { Text(c) } }
            Section("Air handler") {
                row("Make", "Bosch")
                if ah["model"] != nil { row("Model", short(ah["model"])) }
                if let p = ah["part"] as? String { row("Part number", p) }
                if let s = pv["airHandlerSerial"] as? String { row("Serial", s) }
                if let p = ah["power"] as? String { row("Blower", p.replacingOccurrences(of: "^.*?,\\s*", with: "", options: .regularExpression).replacingOccurrences(of: " blower", with: "")) }
            }
            Section {
                row("Make", "Bosch")
                row("Kind", "Electric")
                if let kw = n(bk["kw"]) { row("Size", "\((bk["estimated"] as? Bool) == true ? "About " : "")\(MonthMath.fmt(kw, 1)) kW") }
            } header: { Text("Backup heat") } footer: { if let note = bk["note"] as? String { Text(note) } }
        } else {
            Text("No heating details yet.").foregroundStyle(.secondary)
        }
    }
}
