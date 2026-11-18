import SwiftUI
import AVFoundation
#if os(iOS)
import Speech
import WebKit
#endif

let askModelName = "claude-haiku-5-5"

let askSystem = """
You are Sunny, the assistant inside Solar, a private app for one home in Toronto with rooftop solar. Answer the owner's questions using only the data provided. Lead with the answer, with the key figure in bold using **double asterisks**. Write two to four short, plain sentences; no headings, no bullet lists, no em dashes. Money in dollars, energy in kWh, temperatures in °C. The data includes live weather and a seven day forecast with expected solar per day; when you use it, say it's a forecast. If live weather is missing, say you couldn't get it right now. If something is estimated or missing, say so in a few words. If the data can't answer the question, say what's missing. Show, don't just tell: almost every answer with numbers should include a small chart, placed right after the sentence it supports. Use up to two chart blocks, each written exactly like this:
```chart
{"type":"bars","unit":"kWh","series":["Grid","Solar"],"rows":[["Sep",1150,540],["Oct",1420,410]]}
```
Types: "bars" compares two to eight things (months, years, bills), stacked when there are two series; "columns" shows a run of days, hours or months in order (up to 31); "line" shows a trend over time (up to 31 points); "split" shows how one total divides up, with one row per part (for example where the power came from). Give "unit" as "kWh", "$", "°C", "h" or "%". Use one or two series with plain names (Solar, Grid, Heating, Backup heat, Cooling, Outdoor, Indoor, Cost, Saved), short row labels like "Oct", "Mon", "12th" or "2025", and numbers rounded sensibly. Only chart figures that are in the data. Skip the chart for yes or no answers that have no figures. End with a final line that begins "From " and names the data used, like "From your October bill and meter data".
"""

// MARK: - Conversations

struct ChatMsg: Codable, Equatable { var role: String; var text: String; var error: Bool? = nil; var spoken: Bool? = nil }
struct Chat: Codable, Identifiable { var id: String; var started: String; var updated: String; var msgs: [ChatMsg] }

enum ChatStore {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("askChats.json")
    }
    static func load() -> [Chat] { (try? JSONDecoder().decode([Chat].self, from: Data(contentsOf: url))) ?? [] }
    static func save(_ c: [Chat]) { try? JSONEncoder().encode(Array(c.prefix(60))).write(to: url, options: [.atomic, .completeFileProtection]) }

    /// One time: bring over the conversations the web version kept in its own storage.
    #if os(iOS)
    static func importFromWeb(done: @escaping () -> Void) {
        guard !UserDefaults.standard.bool(forKey: "askImported") else { return }
        let w = WKWebView(frame: .zero, configuration: { let c = WKWebViewConfiguration(); c.websiteDataStore = .default(); return c }())
        let helper = WebImport(web: w) { json in
            UserDefaults.standard.set(true, forKey: "askImported")
            guard let json, let d = json.data(using: .utf8), let old = try? JSONDecoder().decode([Chat].self, from: d), !old.isEmpty else { return }
            var mine = load()
            for c in old where !mine.contains(where: { $0.id == c.id }) { mine.append(c) }
            mine.sort { $0.updated > $1.updated }
            save(mine)
            done()
        }
        w.navigationDelegate = helper
        WebImport.keep.append(w)
        WebImport.helpers.append(helper)
        w.loadHTMLString("<html></html>", baseURL: solarURL)
    }
    #endif
}

#if os(iOS)
final class WebImport: NSObject, WKNavigationDelegate {
    static var keep: [WKWebView] = []
    static var helpers: [WebImport] = []
    let web: WKWebView
    let done: (String?) -> Void
    init(web: WKWebView, done: @escaping (String?) -> Void) { self.web = web; self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("localStorage.getItem('askChats')") { r, _ in
            self.done(r as? String)
            WebImport.keep.removeAll { $0 === webView }
            WebImport.helpers.removeAll { $0 === self }
        }
    }
}
#endif

// MARK: - The model

@MainActor
final class AskModel: ObservableObject {
    @Published var chats: [Chat] = ChatStore.load()
    @Published var msgs: [ChatMsg] = []
    @Published var busy = false
    @Published var draft = ""
    @Published var listening = false
    @Published var heard = ""
    @Published var speaking = false
    @Published var note: String? = nil
    var id: String? = nil
    let voice = Voice()

    init() {
        if let cur = UserDefaults.standard.string(forKey: "askCurrent"), let c = chats.first(where: { $0.id == cur }) { id = c.id; msgs = c.msgs }
        #if os(iOS)
        ChatStore.importFromWeb { [weak self] in Task { @MainActor in self?.chats = ChatStore.load() } }
        #endif
        voice.onSpeakingChange = { [weak self] s in Task { @MainActor in self?.speaking = s } }
    }

    func newChat() { msgs = []; id = nil; UserDefaults.standard.set("", forKey: "askCurrent"); voice.stopSpeaking() }
    func open(_ c: Chat) { newChat(); id = c.id; msgs = c.msgs; UserDefaults.standard.set(c.id, forKey: "askCurrent") }
    func delete(_ c: Chat) { chats.removeAll { $0.id == c.id }; ChatStore.save(chats); if id == c.id { newChat() } }
    func deleteAll() { chats = []; ChatStore.save([]); newChat() }

    private func persist() {
        let keep = msgs.filter { $0.error != true }
        guard !keep.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        if id == nil { id = String(now.filter(\.isNumber).prefix(14)) + String(UUID().uuidString.lowercased().prefix(4)); UserDefaults.standard.set(id, forKey: "askCurrent") }
        let prev = chats.first { $0.id == id }
        chats.removeAll { $0.id == id }
        chats.insert(Chat(id: id!, started: prev?.started ?? now, updated: now, msgs: Array(keep.suffix(40)).map { ChatMsg(role: $0.role, text: $0.text) }), at: 0)
        ChatStore.save(chats)
    }

    func send(_ q: String, json: [String: Any]?, spoken: Bool = false) async {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy, let json else { return }
        let key = json["askKey"] as? String
        guard key != nil || AskModel.appleReady else { return }
        msgs.append(ChatMsg(role: "user", text: q)); draft = ""; busy = true; note = nil
        persist()
        let bg = UIApplication.shared.beginBackgroundTask(withName: "Sunny")   // finish the answer if you switch away
        defer { UIApplication.shared.endBackgroundTask(bg) }
        do {
            let db = SolarDB(json)
            let wx = await AskData.weather(db)
            #if os(iOS) && canImport(FoundationModels)
            // Apple Intelligence first, on this iPhone; Claude only if Apple can't answer and a key is set
            if SunnyEngine.chosen == .apple || key == nil, #available(iOS 26.0, *), SunnyEngine.appleStatus.ok {
                do {
                    let text = try await AppleSunny.answer(q, history: msgs.filter { $0.error != true }, db: db, json: json, weather: wx)
                    msgs.append(ChatMsg(role: "assistant", text: text, spoken: spoken))
                    if spoken { voice.speak(text) }
                    busy = false; persist(); return
                } catch let e as AppleSunnyError {
                    guard key != nil, e.tryClaude else { throw AskError(e.message) }
                } catch {
                    guard key != nil else { throw AskError("Apple's model couldn't answer that. Try asking another way.") }
                }
            }
            #endif
            guard let key else { throw AskError("Sunny needs Apple Intelligence on this iPhone. \(AskModel.appleNote)") }
            var clean = msgs.filter { $0.error != true && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            clean = clean.enumerated().filter { i, m in !(m.role == "user" && i + 1 < clean.count && clean[i + 1].role == "user") }.map { $0.1 }
            while let f = clean.first, f.role != "user" { clean.removeFirst() }
            let history = clean.suffix(12).map { ["role": $0.role, "content": $0.text] }
            let body: [String: Any] = [
                "model": askModelName, "max_tokens": 1400,
                "system": [["type": "text", "text": askSystem],
                           ["type": "text", "text": "The app's data:\n" + AskData.context(db), "cache_control": ["type": "ephemeral"]],
                           ["type": "text", "text": "Live weather:\n" + (wx ?? "not available right now") + pastNote()]],
                "messages": history,
            ]
            var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 90)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "content-type")
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            guard (200..<300).contains(code) else {
                let raw = String(data: d, encoding: .utf8) ?? ""
                throw AskError(code == 401 ? "The Claude API key was refused. Check the ANTHROPIC_API_KEY secret."
                    : code == 400 && raw.localizedCaseInsensitiveContains("credit") ? "The Anthropic account is out of credit."
                    : ((j["error"] as? [String: Any])?["message"] as? String) ?? "Claude said \(code).")
            }
            let text = ((j["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AskError("Claude sent back an empty answer. Try asking again.") }
            msgs.append(ChatMsg(role: "assistant", text: text, spoken: spoken))
            if spoken { voice.speak(text) }
        } catch let e as AskError {
            msgs.append(ChatMsg(role: "assistant", text: e.message, error: true))
        } catch {
            msgs.append(ChatMsg(role: "assistant", text: "That didn't work. Check the connection and try again.", error: true))
        }
        busy = false
        persist()
    }

    /// Whether Apple's on-device model can answer here (never on Apple TV)
    static var appleReady: Bool {
        #if os(iOS)
        return SunnyEngine.appleStatus.ok
        #else
        return false
        #endif
    }
    static var appleNote: String {
        #if os(iOS)
        return SunnyEngine.appleStatus.note + "."
        #else
        return ""
        #endif
    }

    /// a short memory of earlier conversations, so "like I asked yesterday" makes sense
    private func pastNote() -> String {
        let c = chats.filter { $0.id != id }.prefix(6)
        guard !c.isEmpty else { return "" }
        return "\n\nEarlier conversations (most recent first):\n" + c.map { x in
            let q = x.msgs.first { $0.role == "user" }?.text ?? "Conversation"
            let a = (x.msgs.first { $0.role == "assistant" }?.text ?? "").replacingOccurrences(of: "```[\\s\\S]*?```", with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
            let first = String((a.components(separatedBy: ". ").first ?? "").prefix(220))
            return "- \(AskData.when(x.updated)): asked \"\(q.prefix(70))\"; answer began: \(first)"
        }.joined(separator: "\n")
    }

    // voice in
    func listen(json: [String: Any]?) {
        if listening { voice.finish(send: true); return }
        guard !busy else { return }
        voice.stopSpeaking()
        note = nil; heard = ""
        voice.listen(onText: { [weak self] t in Task { @MainActor in self?.heard = t } },
                     onDone: { [weak self] t, err in
            Task { @MainActor in
                guard let self else { return }
                self.listening = false
                if let err { self.note = err; return }
                guard let t, t.count > 1 else { self.note = "Didn't catch that. Tap the mic and try again."; return }
                await self.send(t, json: json, spoken: true)
            }
        })
        listening = true
    }
}

struct AskError: Error { let message: String; init(_ m: String) { message = m } }

// MARK: - Voice

#if os(iOS)
final class Voice: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var text = ""
    private var lastChange = Date(), started = Date()
    private var timer: Timer?
    private var onDone: ((String?, String?) -> Void)?
    var onSpeakingChange: ((Bool) -> Void)?

    override init() { super.init(); synth.delegate = self }

    func listen(onText: @escaping (String) -> Void, onDone: @escaping (String?, String?) -> Void) {
        self.onDone = onDone
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { onDone(nil, "Solar can't use speech recognition. Allow it in Settings, Solar."); return }
                AVAudioApplication.requestRecordPermission { ok in
                    DispatchQueue.main.async {
                        guard ok else { onDone(nil, "Solar can't use the microphone. Allow it in Settings, Solar."); return }
                        self.start(onText: onText)
                    }
                }
            }
        }
    }

    private func start(onText: @escaping (String) -> Void) {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-CA")) ?? SFSpeechRecognizer(), rec.isAvailable else { finishWith(nil, "Voice isn't available right now. Type the question instead."); return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
            try s.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { b, _ in req.append(b) }
            engine.prepare(); try engine.start()
            text = ""; started = Date(); lastChange = Date()
            task = rec.recognitionTask(with: req) { [weak self] r, e in
                guard let self else { return }
                if let r { let t = r.bestTranscription.formattedString; if t != self.text { self.text = t; self.lastChange = Date(); DispatchQueue.main.async { onText(t) } }
                    if r.isFinal { self.finish(send: true) } }
                if e != nil, self.task != nil { self.finish(send: true) }
            }
            // the end of the question: quiet for 1.4 s after speaking, 8 s of nothing, or 30 s in all
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self else { return }
                let quiet = Date().timeIntervalSince(self.lastChange), all = Date().timeIntervalSince(self.started)
                if (!self.text.isEmpty && quiet > 1.4) || (self.text.isEmpty && all > 8) || all > 30 { self.finish(send: true) }
            }
        } catch { finishWith(nil, "The microphone isn't available right now.") }
    }

    func finish(send: Bool) {
        guard request != nil else { return }
        timer?.invalidate(); timer = nil
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        finishWith(send ? text : nil, send && text.isEmpty ? "Didn't hear anything. Tap the mic and try again." : nil)
    }
    private func finishWith(_ t: String?, _ err: String?) {
        let d = onDone; onDone = nil
        DispatchQueue.main.async { d?(err == nil ? t : nil, err) }
    }

    // voice out: Nathan if he's on the phone (Settings, Accessibility, Spoken Content, Voices), otherwise the best English voice
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let vs = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            (v.name.localizedCaseInsensitiveContains("Nathan") ? 100 : 0) + (v.quality == .premium ? 30 : v.quality == .enhanced ? 20 : 0)
                + (["en-US", "en-CA"].contains(v.language) ? 2 : 0) - (v.voiceTraits.contains(.isNoveltyVoice) ? 50 : 0)
        }
        return vs.max { score($0) < score($1) }
    }
    func speak(_ text: String) {
        let plain = text.replacingOccurrences(of: "```chart[\\s\\S]*?```", with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("from ") }.joined(separator: " ")
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: plain)
        u.voice = Voice.bestVoice() ?? AVSpeechSynthesisVoice(language: "en-CA")
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
        onSpeakingChange?(true)
    }
    func stopSpeaking() { if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }; onSpeakingChange?(false) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { onSpeakingChange?(false) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { onSpeakingChange?(false) }
}
#else
final class Voice: NSObject, AVSpeechSynthesizerDelegate {
    // Apple TV: questions come in by typing or the remote's dictation; answers are read aloud
    private let synth = AVSpeechSynthesizer()
    var onSpeakingChange: ((Bool) -> Void)?
    override init() { super.init(); synth.delegate = self }
    func listen(onText: @escaping (String) -> Void, onDone: @escaping (String?, String?) -> Void) {
        DispatchQueue.main.async { onDone(nil, "Hold the microphone button on the remote and ask, or type the question.") }
    }
    func finish(send: Bool) {}
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let vs = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            (v.name.localizedCaseInsensitiveContains("Nathan") ? 100 : 0) + (v.quality == .premium ? 30 : v.quality == .enhanced ? 20 : 0)
                + (["en-US", "en-CA"].contains(v.language) ? 2 : 0)
        }
        return vs.max { score($0) < score($1) }
    }
    func speak(_ text: String) {
        let plain = text.replacingOccurrences(of: "```chart[\\s\\S]*?```", with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("from ") }.joined(separator: " ")
        let u = AVSpeechUtterance(string: plain)
        u.voice = Voice.bestVoice() ?? AVSpeechSynthesisVoice(language: "en-CA")
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
        onSpeakingChange?(true)
    }
    func stopSpeaking() { if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }; onSpeakingChange?(false) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { onSpeakingChange?(false) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { onSpeakingChange?(false) }
}

#endif

// MARK: - What Sunny is told

enum AskData {
    static func r2(_ x: Double?) -> Any { x.map { ($0 * 100).rounded() / 100 } ?? NSNull() }

    static func context(_ db: SolarDB) -> String {
        var months: [String: Any] = [:]
        for (ym, _) in db.money {
            let n = { (k: String) in r2(db.num(ym, k)) }
            months[ym] = ["paid": n("grid"), "paidFrom": db.money[ym]?["gridSource"] ?? NSNull(), "savedBySolar": n("saved"), "costWithoutSolar": n("without"),
                          "gridKwh": n("imp"), "sentBackKwh": n("exp"), "solarKwh": n("prod"), "solarUsedInHouseKwh": n("selfUsed"),
                          "monthComplete": db.money[ym]?["complete"] ?? NSNull()]
        }
        let bills: [[String: Any]] = db.bills.map { b in
            var o: [String: Any] = [:]
            if (b["preSolar"] as? Bool) == true { o["beforeSolar"] = true }
            for (k, src) in [("from", "from"), ("to", "to"), ("issued", "statement"), ("usedKwh", "used"), ("sentBackKwh", "generated"),
                             ("electricity", "electricity"), ("hst", "hst"), ("rebate", "rebate"), ("amountDue", "due")] { o[k] = b[src] ?? NSNull() }
            return o
        }
        var days: [[Any]] = []
        let today = SK.day(Date())
        for i in stride(from: 120, through: 0, by: -1) {
            guard let t = SK.date(today) else { break }
            let d = SK.day(t.addingTimeInterval(Double(-i) * 86400 + 43200))
            let h = db.hydro[d], p = db.daily[d], w = db.weather[d], th = db.thermostat[d]
            guard h != nil || p != nil || w != nil || th != nil else { continue }
            var row: [Any] = [d, r2(h?.first), r2(h.flatMap { $0.count > 1 ? $0[1] : nil }), r2(p), db.w(d, 0) ?? NSNull(), db.w(d, 1) ?? NSNull()]
            for k in [0, 1, 3, 4, 5, 7] { row.append(db.th(d, k) ?? NSNull()) }
            days.append(row)
        }
        let s = db.solarJSON, y = db.json["system"] as? [String: Any] ?? [:]
        let inv = y["inverter"] as? [String: Any], heat = y["heating"] as? [String: Any]
        var system: [String: Any] = ["panels": y["panels"] ?? NSNull(), "inverter": inv?["model"] ?? NSNull(), "inverterLimitKw": inv?["acKw"] ?? NSNull(),
                                     "installer": y["installer"] ?? NSNull(), "firstProduction": s["installed"] ?? NSNull()]
        if let heat {
            let bk = heat["backupHeat"] as? [String: Any]
            system["heating"] = ["kind": heat["kind"] ?? NSNull(), "size": heat["size"] ?? NSNull(),
                                 "airHandler": (heat["airHandler"] as? [String: Any])?["model"] ?? NSNull(),
                                 "outdoorUnit": (heat["outdoorUnit"] as? [String: Any])?["model"] ?? NSNull(),
                                 "outdoorUnitDetails": heat["outdoorUnit"] ?? NSNull(), "backupHeatKw": bk?["kw"] ?? NSNull(),
                                 "backupHeatKwEstimated": bk?["estimated"] ?? NSNull(), "thermostat": heat["thermostat"] ?? NSNull()]
        }
        let o: [String: Any] = [
            "today": today, "place": "Toronto, Ontario", "currency": "CAD", "system": system,
            "live": ["generatingNowKw": s["nowKw"] ?? NSNull(), "todaySoFarKwh": s["today"] ?? NSNull(), "updated": s["updated"] ?? NSNull(),
                     "solarThisMonthKwh": s["month"] ?? NSNull(), "solarThisYearKwh": s["year"] ?? NSNull(), "solarLifetimeKwh": s["lifetime"] ?? NSNull()],
            "notes": "Net metered on Toronto Hydro time-of-use. paid is what the household paid for electricity that month (from the bill when paidFrom is 'bill', otherwise estimated from meter readings). savedBySolar is costWithoutSolar minus paid. Meter data arrives in batches, so recent days may be missing. Bills marked beforeSolar are from before the panels were switched on, useful for before and after comparisons. The heating columns come from the ecobee thermostat (a heat pump with electric backup heat) for days where its history was added.",
            "months": months, "bills": bills,
            "dailyColumns": ["date", "gridKwh", "sentBackKwh", "solarKwh", "highC", "lowC", "heatPumpHours", "backupHeatHours", "fanHours", "heatSetC", "indoorC", "indoorHumidityPct"],
            "daily": days,
        ]
        return String(data: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}"
    }

    private static var wxCache: (String, Date)? = nil
    static func weather(_ db: SolarDB) async -> String? {
        if let c = wxCache, Date().timeIntervalSince(c.1) < 600 { return c.0 }
        let q = "latitude=\(db.lat)&longitude=\(db.lon)&timezone=America%2FToronto&forecast_days=7"
            + "&current=temperature_2m,apparent_temperature,weather_code,is_day,cloud_cover,wind_speed_10m,precipitation,snowfall"
            + "&hourly=temperature_2m,weather_code,cloud_cover,shortwave_radiation,precipitation_probability"
            + "&daily=temperature_2m_max,temperature_2m_min,weather_code,sunshine_duration,shortwave_radiation_sum,precipitation_probability_max,precipitation_sum,snowfall_sum,sunrise,sunset"
        var r = URLRequest(url: URL(string: "https://api.open-meteo.com/v1/forecast?\(q)")!); r.timeoutInterval = 6
        guard let (d, _) = try? await URLSession.shared.data(for: r), let b = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let c = b["current"] as? [String: Any], let h = b["hourly"] as? [String: [Any]], let dy = b["daily"] as? [String: [Any]] else { return nil }
        let n = { (x: Any?) in (x as? NSNumber)?.doubleValue }
        let r1 = { (x: Any?) -> Any in n(x).map { ($0 * 10).rounded() / 10 } ?? NSNull() }
        let words = { (x: Any?, day: Bool) -> String in
            let k = describe((x as? NSNumber)?.intValue).lowercased()
            return k == "mostly clear" ? "clear" : k
        }
        let k = db.factorAround(SK.day(Date()))
        let times = h["time"] as? [String] ?? []
        let ct = String((c["time"] as? String ?? "").prefix(13))
        let nowIdx = max(0, times.firstIndex { $0 >= ct } ?? 0)
        // one value from an hourly or daily column, or null
        func hv(_ col: String, _ j: Int) -> Any { if let a = h[col], j < a.count { return a[j] }; return NSNull() }
        func dv(_ col: String, _ i: Int) -> Any { if let a = dy[col], i < a.count { return a[i] }; return NSNull() }
        var hrs: [[Any]] = []
        for j in nowIdx..<min(times.count, nowIdx + 24) {
            var row: [Any] = [String(times[j].dropFirst(11).prefix(5))]
            row.append(words(hv("weather_code", j), true))
            row.append(r1(hv("temperature_2m", j)))
            row.append(hv("cloud_cover", j))
            let sw: Int = n(hv("shortwave_radiation", j)).map { iInt($0.rounded()) } ?? 0
            row.append(sw)
            row.append(hv("precipitation_probability", j))
            hrs.append(row)
        }
        let dts = dy["time"] as? [String] ?? []
        var drows: [[Any]] = []
        for i in dts.indices {
            let rad: Double? = n(dv("shortwave_radiation_sum", i))
            let sunH: Double? = n(dv("sunshine_duration", i)).map { $0 / 3600 }
            var row: [Any] = [dts[i]]
            row.append(words(dv("weather_code", i), true))
            row.append(dv("temperature_2m_max", i))
            row.append(dv("temperature_2m_min", i))
            row.append(r1(sunH))
            row.append(dv("precipitation_probability_max", i))
            row.append(dv("precipitation_sum", i))
            row.append(dv("snowfall_sum", i))
            if let k, let rad { row.append(r1(k * rad)) } else { row.append(NSNull()) }
            row.append(String((dv("sunrise", i) as? String ?? "").dropFirst(11)))
            row.append(String((dv("sunset", i) as? String ?? "").dropFirst(11)))
            drows.append(row)
        }
        let o: [String: Any] = [
            "source": "Open-Meteo forecast for the house, fetched just now",
            "now": ["at": c["time"] ?? NSNull(), "conditions": words(c["weather_code"], (c["is_day"] as? NSNumber)?.intValue == 1), "tempC": c["temperature_2m"] ?? NSNull(),
                    "feelsLikeC": c["apparent_temperature"] ?? NSNull(), "cloudPct": c["cloud_cover"] ?? NSNull(), "windKmh": c["wind_speed_10m"] ?? NSNull(),
                    "precipMm": c["precipitation"] ?? NSNull(), "snowCm": c["snowfall"] ?? NSNull()],
            "next24h": ["columns": ["hour", "conditions", "tempC", "cloudPct", "sunlightWm2", "chanceOfPrecipPct"], "rows": hrs],
            "days": ["columns": ["date", "conditions", "highC", "lowC", "sunshineHours", "chanceOfPrecipPct", "rainMm", "snowCm", "expectedSolarKwh", "sunrise", "sunset"], "rows": drows],
            "expectedSolarNote": "expectedSolarKwh is an estimate from forecast sunlight and what the panels made on recent days with similar light. Snow on the panels would lower it.",
        ]
        guard let s = String(data: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), encoding: .utf8) else { return nil }
        wxCache = (s, Date())
        return s
    }

    static func when(_ iso: String) -> String {
        guard let d = SK.iso(iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let day = SK.day(d), today = SK.day(Date()), yest = SK.day(Date().addingTimeInterval(-86400))
        let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.amSymbol = "am"; f.pmSymbol = "pm"; f.dateFormat = "h:mm a"
        if day == today { return "Today, \(f.string(from: d))" }
        if day == yest { return "Yesterday, \(f.string(from: d))" }
        f.dateFormat = day.prefix(4) == today.prefix(4) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: d)
    }

    static func suggestions(_ db: SolarDB) -> [String] {
        let all = db.money.keys.filter { (db.money[$0]?["complete"] as? Bool) != false }.sorted()
        var out: [String] = []
        if all.count >= 2 {
            let a = all[all.count - 2], b = all[all.count - 1]
            if let ga = db.num(a, "grid"), let gb = db.num(b, "grid") {
                out.append("Why was \(MonthMath.monthName(b)) \(gb > ga ? "more" : "less") expensive than \(MonthMath.monthName(a))?")
            }
        }
        out.append("How much has solar saved this year?")
        out.append("Is this \(MonthMath.monthName(String(SK.day(Date()).prefix(7)))) colder than last year?")
        out.append("Will tomorrow be a good day for solar?")
        return out
    }
}

