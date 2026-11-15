import Foundation

// Commits a file to the home-solar repository with the upload token that arrives inside the
// encrypted data, the way web/app.js commitFile() does: through the Git data API, retrying on
// top of anyone else's push.

enum GitHub {
    static let repo = "davidanthonyalleyne-dot/home-solar"

    enum Failure: LocalizedError {
        case refused, status(Int)
        var errorDescription: String? {
            switch self {
            case .refused: return "GitHub refused the upload token."
            case .status(let s): return "GitHub said \(s)."
            }
        }
    }

    private static func call(_ path: String, _ method: String = "GET", _ body: [String: Any]? = nil, token: String) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/\(path)")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw [401, 403, 404].contains(code) ? Failure.refused : Failure.status(code) }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    static func commit(path: String, text: String, message: String, token: String) async throws {
        let blob = try await call("git/blobs", "POST", ["content": Data(text.utf8).base64EncodedString(), "encoding": "base64"], token: token)
        guard let blobSha = blob["sha"] as? String else { throw Failure.status(0) }
        for attempt in 0... {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(1500 * attempt)) }
            let head = try await call("git/ref/heads/main", token: token)
            guard let headSha = (head["object"] as? [String: Any])?["sha"] as? String else { throw Failure.status(0) }
            let parent = try await call("git/commits/\(headSha)", token: token)
            guard let baseTree = (parent["tree"] as? [String: Any])?["sha"] as? String else { throw Failure.status(0) }
            let tree = try await call("git/trees", "POST", ["base_tree": baseTree, "tree": [["path": path, "mode": "100644", "type": "blob", "sha": blobSha]]], token: token)
            let commit = try await call("git/commits", "POST", ["message": message, "tree": tree["sha"] ?? "", "parents": [headSha]], token: token)
            do { _ = try await call("git/refs/heads/main", "PATCH", ["sha": commit["sha"] ?? ""], token: token); return }
            catch { if attempt >= 5 { throw error } }
        }
    }

    /// Commits one encrypted file to data/inbox; the next build reads it.
    static func toInbox(_ box: [String: Any], kind: String, message: String, token: String) async throws {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let rand = String(UUID().uuidString.lowercased().prefix(4))
        let text = String(data: try JSONSerialization.data(withJSONObject: box), encoding: .utf8) ?? "{}"
        try await commit(path: "data/inbox/\(f.string(from: Date()))-\(rand)-\(kind).json", text: text, message: message, token: token)
    }

    /// GitHub often skips its scheduled runs. When the numbers are over 25 minutes old in the
    /// daytime, ask for a fresh build by touching data/ping.txt, at most every 15 minutes.
    static func nudgeIfLate(updated: Date?, token: String?) async {
        guard let updated, let token, Date().timeIntervalSince(updated) > 25 * 60 else { return }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = SolarConfig.tz
        let hr = cal.component(.hour, from: Date())
        guard hr >= 6, hr < 22 else { return }
        let last = UserDefaults.standard.double(forKey: "nudgeAt")
        guard Date().timeIntervalSince1970 - last > 15 * 60 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "nudgeAt")
        try? await commit(path: "data/ping.txt", text: ISO8601DateFormatter().string(from: Date()) + "\n", message: "Ask for fresh numbers (the hourly run is late)", token: token)
    }
}
