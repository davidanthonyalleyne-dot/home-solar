import SwiftUI
import Speech
import AVFoundation
import WebKit

// Phase five: Ask Sunny in SwiftUI. Same prompt, same data summary and live weather as
// web/app.js (ASK_SYSTEM, askContext, askWeather), the same little charts, and saved
// conversations on this phone. Voice is the iPhone's own: speech recognition on the phone
// for the question, and the Nathan voice (or the best English voice there is) for the answer.

// MARK: - The screen

struct AskScreen: View {
    @ObservedObject var model: NowModel
    @StateObject private var ask = AskModel()
    @State private var showPast = false
    @FocusState private var typing: Bool

    var body: some View {
        let json = model.json
        let hasKey = (json?["askKey"] as? String)?.isEmpty == false || AskModel.appleReady
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("About your home's energy").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                Text("Ask Sunny").font(.system(size: 34, weight: .bold)).tracking(-0.5)
                            }
                            Spacer()
                            if !ask.chats.isEmpty { Button("Past") { showPast = true }.font(.system(size: 17)) }
                            if !ask.msgs.isEmpty { Button("New") { ask.newChat() }.font(.system(size: 17)).padding(.leading, 12) }
                        }
                        .tint(SK.sunColor)
                        if json == nil {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                        } else if !hasKey {
                            Text("Sunny answers with Apple Intelligence on iPhones that have it. \(AskModel.appleNote) Otherwise it needs a Claude API key: create one in the Anthropic Console and add it to the repository as a GitHub secret named ANTHROPIC_API_KEY. It's kept inside the encrypted data, so only your unlocked app can use it.")
                                .font(.system(size: 17)).padding(.top, 20)
                        } else if ask.msgs.isEmpty && !ask.listening {
                            Start(ask: ask, db: model.db ?? SolarDB(json!)) { q in Task { await ask.send(q, json: json) } }
                        } else {
                            Conversation(ask: ask) { Task { if let last = ask.msgs.last(where: { $0.role == "user" }) { ask.msgs.removeLast(); await ask.send(last.text, json: json) } } }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: ask.msgs.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: ask.busy) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            if hasKey {
                AskBar(ask: ask, typing: $typing, engine: AskModel.engineName(hasKey: (json?["askKey"] as? String)?.isEmpty == false)) { Task { await ask.send(ask.draft, json: json) } } listen: { ask.listen(json: json) }
            }
        }
        .task { await model.refresh() }
        .sheet(isPresented: $showPast) { PastChats(ask: ask) }
    }
}

struct Start: View {
    @ObservedObject var ask: AskModel
    let db: SolarDB
    let send: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sunny is Solar's assistant. Ask about what the panels make, what you pay, and why. Sunny answers from the app's own data: every day of production, your meter readings and your bills.")
                .font(.system(size: 17)).padding(.top, 18)
            Text("Try asking").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.top, 24)
            ForEach(AskData.suggestions(db), id: \.self) { q in
                Button { send(q) } label: {
                    HStack { Text(q).multilineTextAlignment(.leading); Spacer(); Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.faint) }
                        .font(.system(size: 17)).padding(.vertical, 13).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(Palette.rule).frame(height: 1)
            }
            if !ask.chats.isEmpty {
                Text("Recent").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.top, 24)
                ForEach(ask.chats.prefix(3)) { c in ChatRow(ask: ask, chat: c) }
            }
        }
    }
}

struct Conversation: View {
    @ObservedObject var ask: AskModel
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(ask.msgs.enumerated()), id: \.offset) { i, m in
                if m.role == "user" {
                    Text(m.text).font(.system(size: 16)).padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Palette.well, in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 4, topTrailingRadius: 18))
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 50)
                } else if m.error == true {
                    Text(m.text).font(.system(size: 15)).foregroundStyle(Palette.bad)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        AnswerView(text: m.text)
                        if m.spoken == true && i == ask.msgs.count - 1 {
                            Button { ask.speaking ? ask.voice.stopSpeaking() : ask.voice.speak(m.text) } label: {
                                Label(ask.speaking ? "Reading aloud" : "Read again", systemImage: ask.speaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .tint(SK.sunColor)
                        }
                    }
                }
            }
            if ask.listening {
                Text(ask.heard.isEmpty ? "Listening…" : ask.heard).font(.system(size: 16)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(SK.sunColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 50)
            } else if ask.busy {
                HStack(spacing: 6) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Palette.faint).frame(width: 8, height: 8) } }
                    .padding(.vertical, 8).accessibilityLabel("Sunny is thinking")
            } else if let last = ask.msgs.last, last.role == "user" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No answer came back. Try asking again.").font(.system(size: 15)).foregroundStyle(Palette.bad)
                    Button("Ask again", action: retry).tint(SK.sunColor)
                }
            }
        }
        .padding(.top, 18)
    }
}

struct AskBar: View {
    @ObservedObject var ask: AskModel
    var typing: FocusState<Bool>.Binding
    var engine = "Claude"
    let send: () -> Void
    let listen: () -> Void
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                TextField(ask.msgs.isEmpty ? "Ask Sunny about your energy" : "Ask Sunny a follow-up", text: $ask.draft)
                    .focused(typing).submitLabel(.send).onSubmit(send)
                    .disabled(ask.listening)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(Palette.well, in: Capsule())
                Button(action: listen) {
                    Group {
                        if ask.listening { RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 14, height: 14) }
                        else { Image(systemName: "mic").font(.system(size: 18, weight: .medium)).foregroundStyle(.primary) }
                    }
                    .frame(width: 44, height: 44)
                    .background(ask.listening ? SK.sunColor : Palette.well, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ask.listening ? "Stop and ask" : "Ask out loud")
            }
            Text(ask.note ?? (ask.listening ? "Listening. Pause or tap to send." : "Sunny answers from your app's data, using \(engine)"))
                .font(.system(size: 12)).foregroundStyle(ask.note != nil ? Palette.bad : Color.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        .background(.bar)
    }
}

struct ChatRow: View {
    @ObservedObject var ask: AskModel
    let chat: Chat
    var onOpen: (() -> Void)? = nil
    var body: some View {
        let q = chat.msgs.first { $0.role == "user" }?.text ?? "Conversation"
        let n = chat.msgs.filter { $0.role == "user" }.count
        HStack {
            Button { ask.open(chat); onOpen?() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.count > 70 ? String(q.prefix(68)) + "…" : q).font(.system(size: 16)).lineLimit(2).multilineTextAlignment(.leading)
                    Text("\(AskData.when(chat.updated))\(n > 1 ? " · \(n) questions" : "")").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { ask.delete(chat) } label: { Image(systemName: "trash").foregroundStyle(.secondary).frame(width: 44, height: 44) }
                .buttonStyle(.plain).accessibilityLabel("Delete \(q)")
        }
        .padding(.vertical, 4)
    }
}

struct PastChats: View {
    @ObservedObject var ask: AskModel
    @Environment(\.dismiss) private var dismiss
    @State private var armed = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ask.chats) { c in ChatRow(ask: ask, chat: c) { dismiss() } }
                } footer: {
                    Text("Kept on this phone only, up to 60. Claude also sees your last few questions, so you can pick up where you left off.")
                }
                if !ask.chats.isEmpty {
                    Section { Button(armed ? "Tap again to delete all" : "Delete all conversations", role: .destructive) { if armed { ask.deleteAll(); dismiss() } else { armed = true } } }
                }
            }
            .navigationTitle("Conversations").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Answers and their charts

struct AnswerView: View {
    let text: String
    var body: some View {
        let parts = AnswerView.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parts.blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .text(let t): richText(t, size: 17).fixedSize(horizontal: false, vertical: true)
                case .chart(let c): AskChartView(c: c)
                }
            }
            if let s = parts.source { Text(s).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }

    enum Block { case text(String), chart([String: Any]) }
    static func parse(_ raw: String) -> (blocks: [Block], source: String?) {
        var t = raw
        if let r = t.range(of: "```chart(?![\\s\\S]*?```)[\\s\\S]*$", options: .regularExpression) { t.removeSubrange(r) }   // a chart cut off mid-way
        var blocks: [Block] = []
        var lines = t.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        var source: String? = nil
        if let last = lines.last?.trimmingCharacters(in: .whitespaces), last.lowercased().hasPrefix("from ") { source = last; lines.removeLast() }
        let body = lines.joined(separator: "\n")
        let pieces = body.components(separatedBy: "```")
        for (i, p) in pieces.enumerated() {
            if i % 2 == 1 {
                let j = p.hasPrefix("chart") ? String(p.dropFirst(5)) : p
                if let d = j.data(using: .utf8), let c = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { blocks.append(.chart(c)) }
            } else {
                for para in p.components(separatedBy: "\n\n") {
                    let s = para.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { blocks.append(.text(s)) }
                }
            }
        }
        return (blocks, source)
    }
}

struct AskChartView: View {
    let c: [String: Any]

    static func color(_ name: String, _ i: Int) -> Color {
        let n = name.lowercased()
        if n.contains("backup") || n.contains("aux") { return Palette.aux }
        if n.contains("heat") { return Palette.heat }
        if n.contains("cool") || n.range(of: "\\bac\\b", options: .regularExpression) != nil { return Palette.cool }
        if ["solar", "sun", "panel", "generat", "saved", "credit"].contains(where: n.contains) { return SK.sunColor }
        if ["grid", "bill", "cost", "paid", "used", "use"].contains(where: n.contains) { return Palette.grid }
        if n.contains("indoor") || n.contains("inside") { return SK.sunColor }
        if n.contains("outdoor") || n.contains("outside") || n.contains("temp") { return Palette.cool }
        return i > 0 ? SK.sunColor : Palette.grid
    }

    var body: some View {
        let type = ["bars", "columns", "line", "split", "area"].contains(c["type"] as? String ?? "") ? c["type"] as! String : "bars"
        let ser = ((c["series"] as? [Any]) ?? []).prefix(2).map { "\($0)" }
        var cols = ser.enumerated().map { AskChartView.color($1, $0) }
        if cols.count > 1 && cols[0] == cols[1] { cols[1] = cols[0] == SK.sunColor ? Palette.grid : SK.sunColor }
        if cols.isEmpty { cols = [Palette.grid] }
        let unit = String(("\(c["unit"] ?? "")").prefix(4))
        let rows: [(String, Double, Double?)] = ((c["rows"] as? [[Any]]) ?? []).filter { $0.count > 1 }.map {
            (String("\($0[0])".prefix(12)), ($0[1] as? NSNumber)?.doubleValue ?? 0, $0.count > 2 ? ($0[2] as? NSNumber)?.doubleValue : nil)
        }
        let fmtV = { (v: Double) -> String in
            unit == "$" ? MonthMath.dollars(v) : MonthMath.fmt(v, abs(v) < 10 && v.truncatingRemainder(dividingBy: 1) != 0 ? 1 : 0) + (unit == "%" ? "%" : unit == "°C" ? "°" : unit.isEmpty ? "" : " " + unit)
        }
        return VStack(alignment: .leading, spacing: 8) {
            if !rows.isEmpty {
                if type == "split" {
                    let rs = Array(rows.prefix(4)), tot = max(0.0001, rs.reduce(0) { $0 + max(0, $1.1) })
                    GeometryReader { g in
                        HStack(spacing: 2) {
                            ForEach(Array(rs.enumerated()), id: \.offset) { i, r in
                                Rectangle().fill(AskChartView.color(r.0, i)).frame(width: max(0, (g.size.width - CGFloat(rs.count - 1) * 2) * max(0, r.1) / tot))
                            }
                        }
                    }
                    .frame(height: 12).clipShape(Capsule())
                    FlowRow(items: rs.enumerated().map { i, r in (AskChartView.color(r.0, i), "\(fmtV(r.1)) \(r.0)", "\(iInt((100 * max(0, r.1) / tot).rounded()))%") })
                } else if type == "bars" {
                    let rs = Array(rows.prefix(8)), stacked = ser.count > 1
                    let mx = max(1e-9, rs.map { max(0, $0.1) + (stacked ? max(0, $0.2 ?? 0) : 0) }.max() ?? 1)
                    ForEach(Array(rs.enumerated()), id: \.offset) { _, r in
                        HStack(spacing: 8) {
                            Text(r.0).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading).lineLimit(1)
                            GeometryReader { g in
                                HStack(spacing: 0) {
                                    Rectangle().fill(cols[0]).frame(width: g.size.width * max(0, r.1) / mx)
                                    if stacked { Rectangle().fill(cols[min(1, cols.count - 1)]).frame(width: g.size.width * max(0, r.2 ?? 0) / mx) }
                                    Spacer(minLength: 0)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            .frame(height: 14)
                            Text(fmtV(stacked ? max(0, r.1) + max(0, r.2 ?? 0) : r.1)).font(.system(size: 13)).monospacedDigit().frame(width: 64, alignment: .trailing)
                        }
                    }
                    if ser.count > 1 { FlowRow(items: ser.enumerated().map { (cols[min($0, cols.count - 1)], $1, "") }) }
                } else if type == "area" {
                    AreaPlot(rows: Array(rows.prefix(31)), two: ser.count > 1, names: ser, cols: cols, fmtV: fmtV).frame(height: 158)
                    if ser.count > 1 { FlowRow(items: ser.enumerated().map { (cols[min($0, cols.count - 1)], $1, "") }) }
                } else {
                    SmallPlot(type: type, rows: Array(rows.prefix(31)), two: ser.count > 1, cols: cols, unit: unit, fmtV: fmtV).frame(height: 120)
                    if ser.count > 1 { FlowRow(items: ser.enumerated().map { (cols[min($0, cols.count - 1)], $1, "") }) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement()
        .accessibilityLabel("\(ser.joined(separator: " and ")): " + rows.map { "\($0.0) \(fmtV($0.1))\($0.2.map { ", " + fmtV($0) } ?? "")" }.joined(separator: "; "))
    }
}

struct FlowRow: View {
    let items: [(Color, String, String)]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(it.0).frame(width: 10, height: 10)
                    Text(it.1).font(.system(size: 12))
                    if !it.2.isEmpty { Text(it.2).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct SmallPlot: View {
    let type: String
    let rows: [(String, Double, Double?)]
    let two: Bool
    let cols: [Color]
    let unit: String
    let fmtV: (Double) -> String
    var body: some View {
        Canvas { ctx, size in
            let W = size.width, H = size.height, top: CGFloat = 16, bot: CGFloat = 20, n = rows.count
            let vals = rows.flatMap { [Optional($0.1), two ? $0.2 : nil] }.compactMap { $0 }
            var lo = min(0, vals.min() ?? 0), hi = vals.max() ?? 1
            if hi == lo { hi = lo + 1 }
            if type == "line", let mn = vals.min(), mn > 0, unit != "$", unit != "kWh" { lo = floor(mn - (hi - mn) * 0.15) }
            let Y = { (v: Double) in top + (H - top - bot) * CGFloat(1 - (v - lo) / (hi - lo)) }
            var axis = Path(); axis.move(to: CGPoint(x: 0, y: Y(lo))); axis.addLine(to: CGPoint(x: W, y: Y(lo)))
            ctx.stroke(axis, with: .color(Palette.rule), lineWidth: 1)
            let step = max(1, iInt(ceil(Double(n) / 7)))
            let label = { (i: Int) -> Bool in (i % step == 0 && n - 1 - i >= step) || i == n - 1 }
            if type == "columns" {
                let bw = W / CGFloat(n), w = max(2, min(28, bw * (two ? 0.4 : 0.7)))
                for (i, r) in rows.enumerated() {
                    for (j, v) in [Optional(r.1), two ? r.2 : nil].enumerated() {
                        guard let v else { continue }
                        let x = CGFloat(i) * bw + bw / 2 + (two ? (j == 1 ? 1 : -w - 1) : -w / 2), y0 = Y(max(0, lo)), y1 = Y(v)
                        ctx.fill(Path(roundedRect: CGRect(x: x, y: min(y0, y1), width: w, height: max(1.5, abs(y0 - y1))), cornerRadius: 2), with: .color(cols[min(j, cols.count - 1)]))
                        if n <= 8 && !two { ctx.draw(Text(fmtV(v)).font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: x + w / 2, y: min(y0, y1) - 7), anchor: .center) }
                    }
                    if label(i) { ctx.draw(Text(r.0).font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: CGFloat(i) * bw + bw / 2, y: H - 6), anchor: .center) }
                }
            } else {
                let X = { (i: Int) -> CGFloat in n > 1 ? 6 + (W - 12) * CGFloat(i) / CGFloat(n - 1) : W / 2 }
                for j in 0..<(two ? 2 : 1) {
                    let pts = rows.enumerated().compactMap { i, r -> CGPoint? in
                        guard let v = j == 0 ? Optional(r.1) : r.2 else { return nil }; return CGPoint(x: X(i), y: Y(v))
                    }
                    guard let last = pts.last else { continue }
                    var p = Path(); p.addLines(pts)
                    ctx.stroke(p, with: .color(cols[min(j, cols.count - 1)]), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)), with: .color(cols[min(j, cols.count - 1)]))
                    if !two, let v = rows.last?.1 { ctx.draw(Text(fmtV(v)).font(.system(size: 10, weight: .semibold)), at: CGPoint(x: last.x, y: last.y - 10), anchor: .trailing) }
                }
                for (i, r) in rows.enumerated() where label(i) {
                    ctx.draw(Text(r.0).font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: X(i), y: H - 6), anchor: i == 0 ? .leading : i == n - 1 ? .trailing : .center)
                }
                ctx.draw(Text(fmtV(hi)).font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: W, y: top - 6), anchor: .trailing)
            }
        }
    }
}


/// Sunny's area chart: a soft filled curve that draws itself in, with an optional dashed
/// second series. Drag across it to read each point; a light tick plays at each new point.
struct AreaPlot: View {
    let rows: [(String, Double, Double?)]
    let two: Bool
    let names: [String]
    let cols: [Color]
    let fmtV: (Double) -> String
    @State private var drawn: CGFloat = 0
    @State private var sel: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let top: CGFloat = 30, bot: CGFloat = 22

    var body: some View {
        GeometryReader { g in
            let W = g.size.width, H = g.size.height, n = rows.count
            let a = rows.map { $0.1 }, b = two && rows.allSatisfy({ $0.2 != nil }) ? rows.map { $0.2! } : []
            let all = a + b
            let hi = max(5, ceil((all.max() ?? 1) / 5) * 5), lo = max(0, floor((all.min() ?? 0) * 0.6 / 5) * 5)
            let X = { (i: Int) -> CGFloat in n > 1 ? 4 + (W - 8) * CGFloat(i) / CGFloat(n - 1) : W / 2 }
            let Y = { (v: Double) -> CGFloat in top + (H - top - bot) * CGFloat(1 - (v - lo) / max(1e-9, hi - lo)) }
            let curve = { (vs: [Double]) -> Path in
                var p = Path()
                for (i, v) in vs.enumerated() {
                    let pt = CGPoint(x: X(i), y: Y(v))
                    if i == 0 { p.move(to: pt) } else {
                        let prev = CGPoint(x: X(i - 1), y: Y(vs[i - 1])), m = (pt.x - prev.x) / 2
                        p.addCurve(to: pt, control1: CGPoint(x: prev.x + m, y: prev.y), control2: CGPoint(x: pt.x - m, y: pt.y))
                    }
                }
                return p
            }
            let line = curve(a)
            let fill: Path = {
                var f = line
                f.addLine(to: CGPoint(x: X(n - 1), y: Y(lo))); f.addLine(to: CGPoint(x: X(0), y: Y(lo))); f.closeSubpath()
                return f
            }()
            ZStack(alignment: .topLeading) {
                Path { p in p.move(to: CGPoint(x: 0, y: Y(hi))); p.addLine(to: CGPoint(x: W, y: Y(hi))) }
                    .stroke(Palette.rule, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                Text(fmtV(hi)).font(.system(size: 10)).foregroundStyle(.secondary).position(x: 22, y: Y(hi) - 8)
                Path { p in p.move(to: CGPoint(x: 0, y: Y(lo))); p.addLine(to: CGPoint(x: W, y: Y(lo))) }
                    .stroke(Palette.rule, lineWidth: 1)
                fill.fill(LinearGradient(colors: [cols[0].opacity(0.38), cols[0].opacity(0)], startPoint: .top, endPoint: .bottom))
                    .opacity(drawn > 0.6 ? 1 : 0)
                if !b.isEmpty {
                    curve(b).stroke(cols[min(1, cols.count - 1)], style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }
                line.trim(from: 0, to: drawn).stroke(cols[0], style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                ForEach(labelIdx(n), id: \.self) { i in
                    Text(rows[i].0).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: min(max(X(i), 14), W - 14), y: H - 6)
                }
                if let i = sel {
                    Path { p in p.move(to: CGPoint(x: X(i), y: top - 6)); p.addLine(to: CGPoint(x: X(i), y: Y(lo))) }
                        .stroke(.secondary, lineWidth: 1)
                    if !b.isEmpty {
                        Circle().fill(Palette.well).overlay(Circle().stroke(cols[min(1, cols.count - 1)], lineWidth: 2))
                            .frame(width: 8, height: 8).position(x: X(i), y: Y(b[i]))
                    }
                    Circle().fill(cols[0]).overlay(Circle().stroke(Palette.well, lineWidth: 2.5))
                        .frame(width: 11, height: 11).position(x: X(i), y: Y(a[i]))
                    pill(i).fixedSize()
                        .background(GeometryReader { pg in
                            Color.clear.preference(key: PillW.self, value: pg.size.width)
                        })
                        .modifier(PillPlace(x: X(i), width: W))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard n > 0 else { return }
                    let i = (0..<n).min(by: { abs(X($0) - v.location.x) < abs(X($1) - v.location.x) }) ?? 0
                    if i != sel { sel = i; UISelectionFeedbackGenerator().selectionChanged() }
                }
                .onEnded { _ in withAnimation(.easeOut(duration: 0.15)) { sel = nil } })
            .animation(.easeOut(duration: 0.12), value: sel)
        }
        .onAppear {
            if reduceMotion { drawn = 1 } else { withAnimation(.timingCurve(0.85, 0, 0.15, 1, duration: 1.1)) { drawn = 1 } }
        }
    }

    private func labelIdx(_ n: Int) -> [Int] {
        guard n > 0 else { return [] }
        let step = max(1, Int(ceil(Double(n) / 6)))
        return (0..<n).filter { ($0 % step == 0 && Double(n - 1 - $0) >= Double(step) / 2) || $0 == n - 1 }
    }

    private func pill(_ i: Int) -> some View {
        HStack(spacing: 4) {
            Text(rows[i].0).fontWeight(.semibold)
            Text(fmtV(rows[i].1)).fontWeight(.semibold).foregroundStyle(cols[0]).monospacedDigit()
            if two, let v = rows[i].2 { Text("· \(names.count > 1 ? names[1] : "") \(fmtV(v))").foregroundStyle(.secondary).monospacedDigit() }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PillW: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PillPlace: ViewModifier {
    let x: CGFloat, width: CGFloat
    @State private var w: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .onPreferenceChange(PillW.self) { w = $0 }
            .offset(x: min(max(0, x - w / 2), max(0, width - w)), y: 2)
    }
}
