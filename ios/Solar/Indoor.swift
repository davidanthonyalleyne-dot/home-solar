import Foundation
import HomeKit

// The inside temperature for Sunny, read live from the thermostat in Apple Home (the ecobee is a
// HomeKit thermostat). ecobee no longer gives out developer API keys, so Apple Home is the only live
// route. Read on this iPhone only when Sunny is asked something, never stored or sent anywhere
// except inside the question to Claude when Claude is the one answering.

@MainActor
final class Indoor: NSObject, HMHomeManagerDelegate {
    static let shared = Indoor()
    static var on: Bool {
        get { UserDefaults.standard.object(forKey: "indoorHome") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "indoorHome") }
    }

    private var mgr: HMHomeManager?
    private var loaded = false

    /// Starts Apple Home (the first time, iOS asks permission)
    func start() {
        guard mgr == nil else { return }
        mgr = HMHomeManager()
        mgr?.delegate = self
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.loaded = true }
    }

    var access: String {
        switch mgr?.authorizationStatus {
        case .some(let s) where s.contains(.authorized): return thermostat == nil && loaded ? "No thermostat in Apple Home" : "Allowed"
        case .some(let s) where s.contains(.determined): return "Not allowed. Turn on Home for Solar in Settings, Apps, Solar."
        default: return "Not asked yet"
        }
    }

    private var thermostat: HMService? {
        let all = (mgr?.homes ?? []).flatMap { $0.accessories }.flatMap { $0.services }
        return all.first { $0.serviceType == HMServiceTypeThermostat }
    }

    /// One line for Sunny, or nil when it's off or can't be read
    func reading() async -> String? {
        guard Indoor.on else { return nil }
        start()
        for _ in 0..<25 where !loaded { try? await Task.sleep(nanoseconds: 200_000_000) }
        guard let t = thermostat else {
            return loaded ? "Inside: no thermostat found in Apple Home." : "Inside: Apple Home didn't answer just now."
        }
        func value(_ type: String) async -> Double? {
            guard let c = t.characteristics.first(where: { $0.characteristicType == type }) else { return nil }
            try? await c.readValue()
            return (c.value as? NSNumber)?.doubleValue
        }
        let now = await value(HMCharacteristicTypeCurrentTemperature)
        let target = await value(HMCharacteristicTypeTargetTemperature)
        let doing = await value(HMCharacteristicTypeCurrentHeatingCooling)
        let mode = await value(HMCharacteristicTypeTargetHeatingCooling)
        let heatAt = await value(HMCharacteristicTypeHeatingThreshold)
        let coolAt = await value(HMCharacteristicTypeCoolingThreshold)
        let humidity = await value(HMCharacteristicTypeCurrentRelativeHumidity)
        guard let now else { return "Inside: the thermostat didn't answer just now." }
        let c = { (v: Double) in String(format: "%.1f°C", v) }
        var s = "Inside right now (thermostat in Apple Home, read just now): \(c(now))"
        switch mode.map({ Int($0) }) {
        case 0: s += ", system off"
        case 3: if let heatAt, let coolAt { s += ", auto between \(c(heatAt)) and \(c(coolAt))" } else { s += ", auto" }
        default: if let target { s += ", set to \(c(target))" }
        }
        switch doing.map({ Int($0) }) {
        case 1: s += ", heating now"
        case 2: s += ", cooling now"
        case 0: s += ", idle"
        default: break
        }
        if let humidity { s += ", humidity \(Int(humidity.rounded()))%" }
        return s + "."
    }
}
