import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Sunny on Apple's own model, running on this iPhone (Apple Intelligence). Nothing leaves the
// phone. The on-device model only has room for a short brief, so instead of the whole data
// summary Claude gets, it gets today and this month up front and looks up anything else with
// tools: a day, a month, a year, and the forecast.

enum SunnyEngine: String, CaseIterable, Identifiable {
    case apple, claude
    var id: String { rawValue }
    var title: String { self == .apple ? "Apple Intelligence" : "Claude" }

    static var chosen: SunnyEngine {
        get { SunnyEngine(rawValue: UserDefaults.standard.string(forKey: "sunnyEngine") ?? "") ?? .apple }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sunnyEngine") }
    }

    /// Whether Apple's model can answer on this device right now, and if not, why not
    static var appleStatus: (ok: Bool, note: String) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return (true, "Ready on this iPhone")
            case .unavailable(.deviceNotEligible): return (false, "This iPhone can't run Apple Intelligence")
            case .unavailable(.appleIntelligenceNotEnabled): return (false, "Turn on Apple Intelligence in Settings")
            case .unavailable(.modelNotReady): return (false, "Apple's model is still downloading")
            default: return (false, "Not available right now")
            }
        }
        #endif
        return (false, "Needs iOS 26 or later")
    }
}

// SolarDB is all lets, read only, so the tools can hold it
extension SolarDB: @unchecked Sendable {}

struct AppleSunnyError: Error { let message: String; let tryClaude: Bool }

enum AppleSunny {
    static let instructions = """
    You are Sunny, the assistant inside Solar, a private app for one home in Toronto with rooftop solar panels.
    Answer the owner's question from the facts below and from your tools. Never make up a figure.
    Lead with the answer, with the key figure in bold using **double asterisks**. Write two or three short, plain sentences.
    No headings, no lists, no em dashes. Energy in kWh, money in dollars, temperatures in °C.
    If you use the forecast, say it's a forecast. If the facts and tools can't answer, say what's missing.
    Never write your own name or sign the answer.
    End with a final line, on its own, that begins "From " and names the data used, like "From your October bill".
    """

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    static func answer(_ q: String, history: [ChatMsg], db: SolarDB, json: [String: Any], weather: String?) async throws -> String {
        guard SunnyEngine.appleStatus.ok else { throw AppleSunnyError(message: SunnyEngine.appleStatus.note + ".", tryClaude: true) }
        let session = LanguageModelSession(
            tools: [DayTool(db: db), MonthTool(db: db), YearTool(db: db), ForecastTool(weather: weather)],
            instructions: instructions + "\n\n" + brief(db: db, json: json))
        // the last couple of exchanges, so follow-ups like "and last year?" make sense
        let recent = history.dropLast().suffix(4).map { "\($0.role == "user" ? "Question" : "Answer"): \(plain($0.text).prefix(300))" }.joined(separator: "\n")
        let prompt = recent.isEmpty ? q : "Earlier in this conversation:\n\(recent)\n\nQuestion: \(q)"
        do {
            let r = try await session.respond(to: prompt)
            let text = tidy(r.content)
            guard !text.isEmpty else { throw AppleSunnyError(message: "Apple's model sent back nothing.", tryClaude: true) }
            return text
        } catch let e as LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: throw AppleSunnyError(message: "That question needs more data than Apple's model can hold.", tryClaude: true)
            case .guardrailViolation, .refusal: throw AppleSunnyError(message: "Apple's model wouldn't answer that one.", tryClaude: true)
            default: throw AppleSunnyError(message: "Apple's model couldn't answer: \(e.localizedDescription)", tryClaude: true)
            }
        }
    }
    #endif

    /// Today, this month and last month, short enough for the on-device model
    static func brief(db: SolarDB, json: [String: Any]) -> String {
        let s = json["solar"] as? [String: Any] ?? [:]
        let n = { (x: Any?) in (x as? NSNumber)?.doubleValue }
        let today = SK.day(Date()), ym = String(today.prefix(7))
        var lines = ["Today is \(MonthMath.date(today, "EEEE, MMMM d, yyyy")).",
                     "Months with data run from \(db.months.first ?? "?") to \(db.months.last ?? "?") (YYYY-MM)."]
        if let kw = n(s["nowKw"]) { lines.append("Panels right now: \(String(format: "%.2f", kw)) kW.") }
        if let t = n(s["today"]) { lines.append("Made so far today: \(String(format: "%.1f", t)) kWh.") }
        lines.append(AppleSunny.month(db, ym, label: "This month so far"))
        let last = String(SK.day(Calendar.current.date(byAdding: .month, value: -1, to: Date())!).prefix(7))
        lines.append(AppleSunny.month(db, last, label: "Last month"))
        return "Facts:\n" + lines.joined(separator: "\n")
    }

    static func month(_ db: SolarDB, _ ym: String, label: String) -> String {
        let days = db.monthDays(ym)
        guard !days.isEmpty || db.money[ym] != nil else { return "\(label) (\(ym)): no data." }
        let t = db.totals(days)
        let src = db.isEstimate(ym) ? "estimated from the meter" : "from the bill"
        var s = "\(label) (\(ym)): paid \(AppleSunny.money(db.num(ym, "grid"))) (\(src)), saved by solar \(AppleSunny.money(db.num(ym, "saved"))), without solar \(AppleSunny.money(db.num(ym, "without"))); "
        s += "solar made \(String(format: "%.0f", t.prod)) kWh, bought \(String(format: "%.0f", t.imp)) kWh, sent back \(String(format: "%.0f", t.exp)) kWh."
        if let best = days.max(by: { ($0.prod ?? 0) < ($1.prod ?? 0) }), let p = best.prod, p > 0 { s += " Best solar day \(best.d) with \(String(format: "%.1f", p)) kWh." }
        return s
    }

    /// Apple's model sometimes signs off as "Sunny" or puts the source on the same line; keep the
    /// answer clean and the source on its own last line starting "From", the way the screen shows it
    static func tidy(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "^(\\*\\*)?Sunny(\\*\\*)?\\s*[:,\\-–]\\s*", with: "", options: [.regularExpression, .caseInsensitive])
        var lines = t.components(separatedBy: "\n")
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if var last = lines.last {
            last = last.replacingOccurrences(of: "^[\\s—–\\-]*(Sunny\\s*[:,\\-–]?\\s*)?", with: "", options: [.regularExpression, .caseInsensitive])
            if last.lowercased().hasPrefix("from ") {
                lines[lines.count - 1] = "From " + last.dropFirst(5)
            } else if let r = last.range(of: "\\s*(?:(?:—|–|-)\\s*|\\bSunny\\s+)(?:Sunny\\s+)?from (your|the) ", options: [.regularExpression, .caseInsensitive]), r.lowerBound > last.startIndex {
                // source tacked onto the last sentence: move it to its own line
                let src = last[r].trimmingCharacters(in: CharacterSet(charactersIn: " —–-")).replacingOccurrences(of: "^Sunny\\s+", with: "", options: [.regularExpression, .caseInsensitive])
                lines[lines.count - 1] = String(last[..<r.lowerBound])
                lines.append("From " + src.dropFirst(5) + last[r.upperBound...])
            } else { lines[lines.count - 1] = last }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plain(_ t: String) -> String {
        t.replacingOccurrences(of: "```[\\s\\S]*?```", with: "", options: .regularExpression).replacingOccurrences(of: "**", with: "")
    }
    static func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "no data" }
    static func money(_ v: Double?) -> String { v.map { String(format: "$%.2f", $0) } ?? "no bill or estimate" }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
struct DayTool: Tool {
    let db: SolarDB
    let name = "dayFigures"
    let description = "Energy and weather for one day: solar made, bought from the grid, sent to the grid, used at home, high and low temperature."
    @Generable struct Arguments {
        @Guide(description: "The day, written YYYY-MM-DD") var date: String
    }
    func call(arguments: Arguments) async throws -> String {
        let d = arguments.date.trimmingCharacters(in: .whitespaces)
        guard d.count == 10 else { return "Write the day as YYYY-MM-DD." }
        guard let r = db.monthDays(String(d.prefix(7))).first(where: { $0.d == d }) else { return "No data for \(d)." }
        var s = "\(d): solar made \(AppleSunny.f1(r.prod)) kWh, bought from the grid \(AppleSunny.f1(r.imp)) kWh, sent to the grid \(AppleSunny.f1(r.exp)) kWh, used at home in total \(AppleSunny.f1(r.home)) kWh."
        if let hi = db.w(d, 0), let lo = db.w(d, 1) { s += " High \(Int(hi.rounded()))°C, low \(Int(lo.rounded()))°C, \(describe(db.w(d, 2).map { iInt($0) }).lowercased())." }
        return s
    }
}

@available(iOS 26.0, *)
struct MonthTool: Tool {
    let db: SolarDB
    let name = "monthFigures"
    let description = "Totals for one month: paid to Toronto Hydro, saved by solar, what it would have cost without solar, solar made, bought and sent back, and the best solar day."
    @Generable struct Arguments {
        @Guide(description: "The month, written YYYY-MM") var month: String
    }
    func call(arguments: Arguments) async throws -> String {
        AppleSunny.month(db, String(arguments.month.trimmingCharacters(in: .whitespaces).prefix(7)), label: arguments.month)
    }
}

@available(iOS 26.0, *)
struct YearTool: Tool {
    let db: SolarDB
    let name = "yearFigures"
    let description = "Totals for one calendar year: solar made, paid to Toronto Hydro and saved by solar."
    @Generable struct Arguments {
        @Guide(description: "The year, written YYYY") var year: String
    }
    func call(arguments: Arguments) async throws -> String {
        let y = String(arguments.year.trimmingCharacters(in: .whitespaces).prefix(4))
        guard let t = db.yearTotals()[y] else { return "\(y): no data." }
        var s = "\(y): solar made \(t.prod.map { String(format: "%.0f", $0) } ?? "no data") kWh"
        s += t.gridN > 0 ? ", paid Toronto Hydro \(AppleSunny.money(t.grid)) over \(t.gridN) months, saved by solar \(AppleSunny.money(t.saved))." : "; no bills that year."
        return s
    }
}

@available(iOS 26.0, *)
struct ForecastTool: Tool {
    let weather: String?
    let name = "forecast"
    let description = "The live weather now and the forecast for the coming days, with expected solar per day."
    @Generable struct Arguments {
        @Guide(description: "What the forecast is needed for") var topic: String
    }
    func call(arguments: Arguments) async throws -> String {
        guard let w = weather else { return "The weather service didn't answer just now." }
        return String(w.prefix(1800))
    }
}
#endif
