// What the widgets show, built on each refresh from the same encrypted data.json the app opens
// (unlocked with the passphrase you enter once in the app, kept in a keychain group the app and
// widgets share) plus Open-Meteo's forecast. The last data.json is kept, still encrypted, so
// the app and widgets open on it when the network is slow or gone.
// Expected solar uses the web app's method: forecast sunlight times what the panels made per unit
// of sunlight on similar days within a month of the date.

import Foundation

/// A whole number from a Double that may be NaN or infinite (a zero in the data it was divided by).
/// Int() traps on those and takes the app down; this gives 0 instead.
func iInt<T: BinaryFloatingPoint>(_ v: T) -> Int { v.isFinite ? Int(Swift.max(Swift.min(v, 1e12), -1e12)) : 0 }
import CryptoKit
import CommonCrypto
import Security
import SwiftUI

enum SolarConfig {
    static let site = URL(string: "https://davidanthonyalleyne-dot.github.io/home-solar/")!
    static var dataURL: URL { URL(string: "data.json?t=\(Int(Date().timeIntervalSince1970))", relativeTo: site)! }
    static let tz = TimeZone(identifier: "America/Toronto")!
}

// MARK: - The keychain the app and widgets share: the passphrase, and the key it makes

enum SharedVault {
    static let group = "M8GX2N7YR2.ca.davidalleyne.solar.shared"
    private static func base(_ name: String, group: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ca.davidalleyne.solar", kSecAttrAccount as String: name]
        if group { q[kSecAttrAccessGroup as String] = SharedVault.group }
        return q
    }
    static func set(_ name: String, _ data: Data) {
        for g in [true, false] {
            SecItemDelete(base(name, group: g) as CFDictionary)
            var add = base(name, group: g)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return }   // the shared group, or this app's own if that isn't allowed
        }
    }
    static func get(_ name: String) -> Data? {
        for g in [true, false] {
            var q = base(name, group: g); q[kSecReturnData as String] = true
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return d }
        }
        return nil
    }
    static func remove(_ name: String) { for g in [true, false] { SecItemDelete(base(name, group: g) as CFDictionary) } }

    static var passphrase: String? {
        get { get("passphrase").flatMap { String(data: $0, encoding: .utf8) } }
        set { if let v = newValue { set("passphrase", Data(v.utf8)) } else { remove("passphrase"); remove("key") } }
    }
}

enum KeyCache {
    // stored as salt length (1 byte) + salt + key
    static func load(salt: String) -> Data? {
        guard let d = SharedVault.get("key"), d.count > 33 else { return nil }
        let n = Int(d[0]); guard d.count == 1 + n + 32, String(data: d.subdata(in: 1..<(1 + n)), encoding: .utf8) == salt else { return nil }
        return d.subdata(in: (1 + n)..<d.count)
    }
    static func save(_ key: Data, salt: String) {
        var blob = Data([UInt8(min(255, salt.utf8.count))]); blob.append(Data(salt.utf8.prefix(255))); blob.append(key)
        SharedVault.set("key", blob)
    }
}

/// The last data.json, exactly as downloaded (encrypted), in this app's or widget's own storage.
enum BoxCache {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data-box.json")
    }
    static func save(_ d: Data) { try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    static func load() -> Data? { try? Data(contentsOf: url) }
}

struct Box: Decodable { let iter: Int; let salt: String; let iv: String; let ct: String }

enum SolarCrypto {
    static func key(passphrase: String, salt: Data, iterations: Int) -> Data? {
        let pw = Array(passphrase.precomposedStringWithCompatibilityMapping.utf8)
        guard !pw.isEmpty else { return nil }
        var out = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        let r = pw.withUnsafeBufferPointer { p in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), UnsafeRawPointer(p.baseAddress!).assumingMemoryBound(to: Int8.self), pw.count,
                                 saltBytes, saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, out.count)
        }
        return r == kCCSuccess ? Data(out) : nil
    }
    /// Encrypts bytes the way web/lock.js seal() does, so the build can read them.
    static func seal(_ bytes: Data) throws -> [String: Any] {
        guard let box = lastBox, let key = lastKey else { throw CocoaError(.userCancelled) }
        let sealed = try AES.GCM.seal(bytes, using: SymmetricKey(data: key))
        return ["v": 1, "kdf": "PBKDF2-SHA256", "iter": box.iter, "salt": box.salt,
                "iv": Data(sealed.nonce).base64EncodedString(), "ct": (sealed.ciphertext + sealed.tag).base64EncodedString()]
    }
    static func open(_ box: Box, key: Data) throws -> Data {
        guard let iv = Data(base64Encoded: box.iv), let ct = Data(base64Encoded: box.ct), ct.count > 16 else { throw CocoaError(.coderInvalidValue) }
        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ct.dropLast(16), tag: ct.suffix(16))
        return try AES.GCM.open(sealed, using: SymmetricKey(data: key))
    }
    /// Downloads and opens data.json. Nil when there's no passphrase in this build or it no longer fits.
    /// The last data.json opened, for the app's Now screen, which needs more of it than the widgets.
    nonisolated(unsafe) static var lastJSON: [String: Any]?
    /// The salt, rounds and key of the last data.json opened; the app seals uploads with them.
    nonisolated(unsafe) static var lastBox: Box?
    nonisolated(unsafe) static var lastKey: Data?
    static func latest() async -> [String: Any]? {
        var req = URLRequest(url: SolarConfig.dataURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200, let json = open(data) {
            BoxCache.save(data)
            return json
        }
        return cached()
    }
    /// The last data.json downloaded, opened from the copy kept on this device.
    static func cached() -> [String: Any]? { BoxCache.load().flatMap { open($0) } }

    /// Opens a downloaded data.json with the passphrase from the keychain. Throws nothing: nil means no
    /// passphrase yet, or one that no longer fits.
    static func open(_ data: Data) -> [String: Any]? {
        if let plain = try? JSONSerialization.jsonObject(with: data) as? [String: Any], plain["solar"] != nil { lastJSON = plain; return plain }
        guard let box = try? JSONDecoder().decode(Box.self, from: data), let salt = Data(base64Encoded: box.salt) else { return nil }
        var key = KeyCache.load(salt: box.salt)
        if key == nil, let p = SharedVault.passphrase, let k = SolarCrypto.key(passphrase: p, salt: salt, iterations: box.iter) {
            key = k; KeyCache.save(k, salt: box.salt)
        }
        guard let key, let raw = try? SolarCrypto.open(box, key: key) else { return nil }
        lastBox = box; lastKey = key
        let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        if json != nil { lastJSON = json }
        return json
    }

    /// Checks a passphrase against the latest data.json and keeps it if it works.
    static func adopt(passphrase: String) async -> Bool {
        var req = URLRequest(url: SolarConfig.dataURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let data = (try? await URLSession.shared.data(for: req))?.0 ?? BoxCache.load()
        guard let data, let box = try? JSONDecoder().decode(Box.self, from: data), let salt = Data(base64Encoded: box.salt) else { return false }
        let key: Data? = await Task.detached { SolarCrypto.key(passphrase: passphrase, salt: salt, iterations: box.iter) }.value
        guard let key, (try? SolarCrypto.open(box, key: key)) != nil else { return false }
        SharedVault.passphrase = passphrase
        KeyCache.save(key, salt: box.salt)
        BoxCache.save(data)
        return true
    }
}

// MARK: - The snapshot the views draw

struct Snapshot: Codable {
    struct Month: Codable { var ym: String; var name: String; var kwh: Double; var saved: Double?; var days: [Double]? }
    struct Bill: Codable { var ym: String; var name: String; var grid: Double?; var saved: Double?; var without: Double? }
    struct Day: Codable { var d: String; var code: Int?; var hi: Double?; var lo: Double?; var kwh: Double? }
    struct Weather: Codable { var temp: Double?; var code: Int?; var isDay: Int? }

    var today: String
    var updated: String?
    var todayDate: String?
    var nowKw: Double
    var todayKwh: Double
    var expectedKwh: Double?
    var lat: Double?
    var lon: Double?
    var curve: [[Double]]
    var month: Month?
    var bill: Bill?
    var days: [Day]
    var weather: Weather?

    static let sample = Snapshot(today: SK.day(Date()), updated: nil, todayDate: SK.day(Date()), nowKw: 1.84, todayKwh: 9.6, expectedKwh: 11,
                                 lat: 43.64, lon: -79.43,
                                 curve: stride(from: 7.2, through: 13.4, by: 0.25).map { [$0, 3.2 * pow(sin(Double.pi * ($0 - 7.1) / 9.8), 1.5) * 0.9] },
                                 month: Month(ym: "", name: "November", kwh: 138, saved: 24, days: [6, 9, 4, 11, 8, 3, 7, 10, 12, 5, 9, 8, 11, 10]),
                                 bill: Bill(ym: "", name: "October", grid: 186, saved: 94, without: 280),
                                 days: [Day(d: "9999-01-01", code: 0, hi: 4, lo: -2, kwh: 15), Day(d: "9999-01-02", code: 2, hi: 6, lo: 1, kwh: 9),
                                        Day(d: "9999-01-03", code: 3, hi: 7, lo: 3, kwh: 4)],
                                 weather: Weather(temp: 6, code: 2, isDay: 1))

    // the last good snapshot, so a failed refresh still shows something
    static func cached() -> Snapshot? {
        guard let d = UserDefaults.standard.data(forKey: "snapshot") else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: d)
    }
    func cache() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "snapshot") } }

    /// Builds today's snapshot from data.json and the forecast.
    static func build(from json: [String: Any]? = nil) async -> Snapshot? {
        var data = json
        if data == nil { data = await SolarCrypto.latest() }
        guard let data, let s = data["solar"] as? [String: Any] else { return nil }
        let w = data["weather"] as? [String: Any] ?? [:]
        let wd = w["daily"] as? [String: [Any]] ?? [:]
        let daily = (s["daily"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        let num = { (x: Any?) in (x as? NSNumber)?.doubleValue }
        let lat = num(w["lat"]) ?? 43.64, lon = num(w["lon"]) ?? -79.43
        let day = SK.day(Date()), ym = String(day.prefix(7))
        let fresh = (s["todayDate"] as? String ?? day) == day

        // kWh per MJ/m² of sunlight, from days within a month of d (skipping outages and snow)
        func factor(_ d: String) -> Double? {
            guard let t = SK.dayNum(d) else { return num(w["factor"]) }
            var r: [Double] = []
            for (k, p) in daily {
                guard let row = wd[k], row.count > 4, let rad = num(row[4]), rad >= 2, p >= 0.5,
                      (num(row.count > 5 ? row[5] : nil) ?? 0) <= 0, ![71, 73, 75, 77, 85, 86].contains(iInt(num(row[2]) ?? 0)),
                      let kt = SK.dayNum(k), abs(kt - t) <= 30 else { continue }
                r.append(p / rad)
            }
            r.sort()
            return r.count >= 7 ? r[r.count / 2] : num(w["factor"])
        }
        func expected(_ d: String, radiation: Double?) -> Double? {
            guard let rad = radiation, let k = factor(d) else { return nil }
            return k * rad
        }

        // the next few days and the current weather, straight from Open-Meteo like the app
        var days: [Day] = []
        var current: Weather? = nil
        var todayRad = (wd[day].flatMap { $0.count > 4 ? num($0[4]) : nil })
        let q = "latitude=\(lat)&longitude=\(lon)&timezone=America%2FToronto&forecast_days=5&current=temperature_2m,weather_code,is_day"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min,shortwave_radiation_sum"
        if let url = URL(string: "https://api.open-meteo.com/v1/forecast?\(q)"),
           let (fd, _) = try? await URLSession.shared.data(from: url),
           let f = try? JSONSerialization.jsonObject(with: fd) as? [String: Any] {
            if let c = f["current"] as? [String: Any] {
                current = Weather(temp: num(c["temperature_2m"]), code: (c["weather_code"] as? NSNumber)?.intValue, isDay: (c["is_day"] as? NSNumber)?.intValue)
            }
            if let fdaily = f["daily"] as? [String: Any], let times = fdaily["time"] as? [String] {
                let codes = fdaily["weather_code"] as? [Any] ?? [], hi = fdaily["temperature_2m_max"] as? [Any] ?? []
                let lo = fdaily["temperature_2m_min"] as? [Any] ?? [], rad = fdaily["shortwave_radiation_sum"] as? [Any] ?? []
                for (i, t) in times.enumerated() {
                    let r = i < rad.count ? num(rad[i]) : nil
                    if t == day { todayRad = r ?? todayRad; continue }
                    guard t > day else { continue }
                    days.append(Day(d: t, code: i < codes.count ? (codes[i] as? NSNumber)?.intValue : nil,
                                    hi: i < hi.count ? num(hi[i]) : nil, lo: i < lo.count ? num(lo[i]) : nil, kwh: expected(t, radiation: r)))
                }
            }
        }
        if days.isEmpty, let tm = w["tomorrow"] as? String ?? Optional(SK.day(Date().addingTimeInterval(86400))), let row = wd[tm], row.count > 4 {
            days = [Day(d: tm, code: (row[2] as? NSNumber)?.intValue, hi: num(row[0]), lo: num(row[1]), kwh: expected(tm, radiation: num(row[4])))]
        }
        if current == nil, let c = w["current"] as? [String: Any] {
            current = Weather(temp: num(c["temp"]), code: (c["code"] as? NSNumber)?.intValue, isDay: (c["isDay"] as? NSNumber)?.intValue)
        }

        let curve: [[Double]] = fresh ? (s["todayCurve"] as? [[Any]] ?? []).compactMap { p in
            guard p.count >= 2, let t = p[0] as? String else { return nil }
            let hm = t.split(separator: ":").compactMap { Double($0) }
            return hm.count == 2 ? [hm[0] + hm[1] / 60, num(p[1]) ?? 0] : nil
        } : []

        let months = (data["money"] as? [String: Any])?["months"] as? [String: [String: Any]] ?? [:]
        let full = months.keys.filter { $0 < ym && (num(months[$0]?["without"]) ?? 0) > 0 }.max()
        let n = Int(day.suffix(2)) ?? 1
        let monthDays = (1...n).map { daily[String(format: "%@-%02d", ym, $0)] ?? 0 }

        return Snapshot(today: day, updated: s["updated"] as? String, todayDate: s["todayDate"] as? String,
                        nowKw: fresh ? num(s["nowKw"]) ?? 0 : 0, todayKwh: fresh ? num(s["today"]) ?? 0 : 0,
                        expectedKwh: expected(day, radiation: todayRad), lat: lat, lon: lon, curve: curve,
                        month: Month(ym: ym, name: SK.monthName(ym), kwh: num(s["month"]) ?? 0, saved: num(months[ym]?["saved"]), days: monthDays),
                        bill: full.map { Bill(ym: $0, name: SK.monthName($0), grid: num(months[$0]?["grid"]), saved: num(months[$0]?["saved"]), without: num(months[$0]?["without"])) },
                        days: Array(days.prefix(3)), weather: current)
    }
}

// MARK: - Dates, sun and formatting

enum SK {
    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = SolarConfig.tz; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    // Making a DateFormatter is slow (a Month screen was making tens of thousands), so each
    // format is made once and reused. DateFormatter is safe to share across threads.
    private static let formatLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    static func formatter(_ format: String, utc: Bool = false) -> DateFormatter {
        formatLock.lock(); defer { formatLock.unlock() }
        let key = format + (utc ? "|utc" : "")
        if let f = formatters[key] { return f }
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = utc ? TimeZone(identifier: "UTC") : SolarConfig.tz; f.dateFormat = format
        formatters[key] = f
        return f
    }
    static func date(_ s: String) -> Date? { formatter("yyyy-MM-dd").date(from: s) }
    /// "yyyy-MM-dd" as a count of days, by arithmetic (no calendar), for comparing dates quickly
    static func dayNum(_ s: String) -> Int? {
        let u = Array(s.utf8)
        guard u.count >= 10 else { return nil }
        func n(_ a: Int, _ b: Int) -> Int? { var v = 0; for i in a..<b { let c = Int(u[i]) - 48; guard c >= 0, c <= 9 else { return nil }; v = v * 10 + c }; return v }
        guard var y = n(0, 4), let m = n(5, 7), let d = n(8, 10), (1...12).contains(m) else { return nil }
        y -= m <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400, yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        return era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy
    }
    static func monthName(_ ym: String) -> String {
        guard let d = date(ym + "-15") else { return "" }
        let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "MMMM"
        return f.string(from: d)
    }
    static func hours(_ d: Date) -> Double {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = SolarConfig.tz
        let c = cal.dateComponents([.hour, .minute], from: d)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }
    static func iso(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        for o: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            f.formatOptions = o
            if let d = f.date(from: s) { return d }
        }
        // the build writes some times to the minute, like 2026-11-06T10:51-05:00
        let g = DateFormatter(); g.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm"] {
            g.dateFormat = fmt
            if fmt.hasSuffix("mm") { g.timeZone = SolarConfig.tz }
            if let d = g.date(from: s) { return d }
        }
        return nil
    }
    /// Sunrise and sunset, the same formula the web app uses.
    static func sun(_ day: String, lat: Double = 43.64, lon: Double = -79.43) -> (rise: Date, set: Date) {
        let p = day.split(separator: "-").compactMap { Int($0) }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = p.count == 3 ? (cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)) ?? Date()) : Date()
        let rad = Double.pi / 180
        let jd = noon.timeIntervalSince1970 / 86400 + 2440587.5
        let n = (jd - 2451545 + 0.0008).rounded(), js = n - lon / 360
        let mm = (357.5291 + 0.98560028 * js).truncatingRemainder(dividingBy: 360)
        let c = 1.9148 * sin(mm * rad) + 0.02 * sin(2 * mm * rad) + 0.0003 * sin(3 * mm * rad)
        let l = (mm + c + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let jt = 2451545 + js + 0.0053 * sin(mm * rad) - 0.0069 * sin(2 * l * rad)
        let dec = asin(sin(l * rad) * sin(23.4397 * rad))
        let cosw = (sin(-0.833 * rad) - sin(lat * rad) * sin(dec)) / (cos(lat * rad) * cos(dec))
        let w = acos(max(-1, min(1, cosw))) / rad
        let t = { (j: Double) in Date(timeIntervalSince1970: (j - 2440587.5) * 86400) }
        return (t(jt - w / 360), t(jt + w / 360))
    }
    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "h:mm"
        return f.string(from: d)
    }
    static func kw(_ v: Double) -> String { String(format: "%.2f", v) }
    static func kwh(_ v: Double) -> String { abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v) }
    static func dollars(_ v: Double) -> String { "$" + String(format: "%.0f", v.rounded()) }
    static func weekday(_ d: String) -> String {
        guard let date = date(d) else { return "" }
        let f = DateFormatter(); f.timeZone = SolarConfig.tz; f.dateFormat = "EEE"
        return f.string(from: date)
    }
    /// SF Symbol for an Open-Meteo weather code, matching the web app's icon choices.
    static func symbol(_ code: Int?, day: Bool = true) -> String {
        switch code ?? 3 {
        case 0, 1: return day ? "sun.max.fill" : "moon.stars"
        case 2: return day ? "cloud.sun" : "cloud"
        case 45, 48: return "cloud.fog"
        case 51, 53, 55, 56, 57: return "cloud.drizzle"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow"
        case 95, 96, 99: return "cloud.bolt"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain"
        default: return "cloud"
        }
    }
    static let sunColor = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.624, blue: 0.039, alpha: 1) : UIColor(red: 0.91, green: 0.514, blue: 0.047, alpha: 1) })
    static let washColor = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.239, green: 0.165, blue: 0.059, alpha: 1) : UIColor(red: 0.984, green: 0.89, blue: 0.769, alpha: 1) })
}

struct WeatherGlyph: View {
    let code: Int?
    var day = true
    var size: CGFloat = 14
    var body: some View {
        let name = SK.symbol(code, day: day)
        Image(systemName: name)
            .font(.system(size: size))
            .symbolRenderingMode(name == "sun.max.fill" ? .monochrome : .hierarchical)
            .foregroundStyle(name == "sun.max.fill" ? SK.sunColor : .secondary)
    }
}
