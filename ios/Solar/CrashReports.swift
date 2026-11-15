import Foundation
import MetricKit

// When the app crashes, iOS hands it a crash report (MetricKit) the next time it opens. This keeps
// the parts that say where it failed (the exception, the signal and the call stack as binary
// offsets, which CI turns back into line numbers with the build's dSYMs) and commits them to
// data/diag next to the web app's reports. Never any energy figures, bills or personal data.

final class CrashReports: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReports()
    private static var pendingURL: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("crash-reports.json")
    }

    func start() {
        MXMetricManager.shared.add(self)
        keep(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { keep(payloads) }

    private func keep(_ payloads: [MXDiagnosticPayload]) {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var out = Self.pending()
        let seen = Set(out.compactMap { $0["id"] as? String })
        for p in payloads {
            for c in p.crashDiagnostics ?? [] {
                let id = "\(p.timeStampEnd.timeIntervalSince1970)-\(c.signal?.intValue ?? 0)"
                guard !seen.contains(id) else { continue }
                var r: [String: Any] = [
                    "id": id, "kind": "native crash", "t": ISO8601DateFormatter().string(from: p.timeStampEnd),
                    "v": c.applicationVersion.isEmpty ? v : c.applicationVersion, "build": b,
                    "ios": c.metaData.osVersion, "device": c.metaData.deviceType,
                    "signal": c.signal?.intValue ?? 0, "exceptionType": c.exceptionType?.intValue ?? 0, "exceptionCode": c.exceptionCode?.intValue ?? 0,
                    "reason": c.terminationReason ?? "",
                ]
                if #available(iOS 17.0, *), let e = c.exceptionReason { r["exception"] = "\(e.exceptionName): \(e.composedMessage)" }
                if let stack = try? JSONSerialization.jsonObject(with: c.callStackTree.jsonRepresentation()) { r["stack"] = stack }
                out.append(r)
            }
        }
        Self.save(out)
    }

    private static func pending() -> [[String: Any]] {
        guard let d = try? Data(contentsOf: pendingURL), let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return a
    }
    private static func save(_ a: [[String: Any]]) {
        if a.isEmpty { try? FileManager.default.removeItem(at: pendingURL); return }
        if let d = try? JSONSerialization.data(withJSONObject: a) { try? d.write(to: pendingURL, options: .atomic) }
    }

    /// Commits waiting reports with the upload token from the unlocked data, then forgets them.
    static func send(token: String?) async {
        let a = pending()
        guard let token, !a.isEmpty, let d = try? JSONSerialization.data(withJSONObject: a, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: d, encoding: .utf8) else { return }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let rand = String(UUID().uuidString.lowercased().prefix(4))
        do {
            try await GitHub.commit(path: "data/diag/\(f.string(from: Date()))-\(rand)-ios.json", text: text, message: "iPhone app crash report", token: token)
            save([])
        } catch {}
    }
}
