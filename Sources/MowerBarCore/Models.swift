import Foundation

public struct Mower: Identifiable, Equatable, Sendable {
    public var id: String, name: String, serial: String, model: String, firmware: String, endpoint: String, topicIn: String, topicOut: String
    public var userID: Int, protocolVersion: Int
    public var timeZoneName: String
    public var online: Bool
    public var capabilities: Set<String>
    public var telemetry: Telemetry
    public var config: MowerConfig
    public static func parse(_ value: [String: Any], products: [[String: Any]]) throws -> Mower {
        guard let serial = value["serial_number"] as? String, let endpoint = value["mqtt_endpoint"] as? String,
              let topics = value["mqtt_topics"] as? [String: String], let input = topics["command_in"], let output = topics["command_out"],
              let userID = value["user_id"] as? Int else { throw ProtocolError.invalid(String(localized: "The mower’s connection details are incomplete.")) }
        guard endpoint.hasSuffix(".worxlandroid.com"), !endpoint.contains("/"), !endpoint.contains(":") else { throw ProtocolError.invalid(String(localized: "Unexpected cloud address for this mower.")) }
        let product = products.first { ($0["id"] as? Int) == (value["product_id"] as? Int) }
        let last = value["last_status"] as? [String: Any] ?? [:]
        let data = last["payload"] as? [String: Any] ?? [:]
        return Mower(id: value["uuid"] as? String ?? serial, name: value["name"] as? String ?? String(localized: "My mower"), serial: serial,
            model: product?["code"] as? String ?? "Landroid", firmware: value["firmware_version"] as? String ?? "—", endpoint: endpoint,
            topicIn: input, topicOut: output, userID: userID, protocolVersion: value["protocol"] as? Int ?? -1,
            timeZoneName: value["time_zone"] as? String ?? TimeZone.current.identifier,
            online: value["online"] as? Bool ?? false, capabilities: Set(value["capabilities"] as? [String] ?? []),
            telemetry: Telemetry.parse(data, fallbackDate: parseCloudDate(last["timestamp"] as? String)),
            config: MowerConfig.parse(data["cfg"] as? [String: Any] ?? [:]))
    }
}

public func parseCloudDate(_ text: String?) -> Date? {
    guard let text else { return nil }
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: text) { return date }
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: text) { return date }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.date(from: text)
}

public struct Telemetry: Equatable, Sendable {
    public var state: Int?
    public var error: Int?
    public var battery: Int?
    public var charging: Bool
    public var date: Date?
    public var correlationID: Int?
    public init(state: Int?, error: Int?, battery: Int?, charging: Bool, date: Date?, correlationID: Int?) {
        self.state = state; self.error = error; self.battery = battery
        self.charging = charging; self.date = date; self.correlationID = correlationID
    }
    public static func parse(_ payload: [String: Any], fallbackDate: Date? = nil) -> Telemetry {
        let dat = payload["dat"] as? [String: Any] ?? [:]; let cfg = payload["cfg"] as? [String: Any] ?? [:]
        let bt = dat["bt"] as? [String: Any] ?? [:]
        return Telemetry(state: dat["ls"] as? Int, error: dat["le"] as? Int, battery: bt["p"] as? Int,
            charging: (bt["c"] as? Int ?? 0) == 1, date: fallbackDate, correlationID: cfg["id"] as? Int)
    }
    public var stateLabel: String {
        switch state {
        case 0: return String(localized: "Needs attention")
        case 1: return charging ? String(localized: "Charging") : String(localized: "At the base")
        case 2: return String(localized: "Starting up")
        case 3: return String(localized: "Leaving the base")
        case 4: return String(localized: "Following the wire")
        case 5: return String(localized: "Searching for the base")
        case 6: return String(localized: "Searching for the wire")
        case 7: return String(localized: "Mowing")
        case 8: return String(localized: "Recovering after being lifted")
        case 9: return String(localized: "Trying to free itself")
        case 10: return String(localized: "Recovering the blades")
        case 11: return String(localized: "Self-test")
        case 12: return String(localized: "Manual driving")
        case 30: return String(localized: "Going home")
        case 31: return String(localized: "Learning zones")
        case 32: return String(localized: "Cutting edges")
        case 33: return String(localized: "Searching for a zone")
        case 34: return String(localized: "Paused")
        case nil: return String(localized: "No state received")
        default: return String(localized: "State \(state!)")
        }
    }
    public var errorLabel: String? {
        guard let error, error != 0 else { return nil }
        switch error {
        case 1: return String(localized: "Mower trapped")
        case 2: return String(localized: "Mower lifted")
        case 3: return String(localized: "Boundary wire missing")
        case 4: return String(localized: "Outside the mowing area")
        case 5: return String(localized: "Rain delay")
        case 6: return String(localized: "Cover open")
        case 7: return String(localized: "Close the cover to go home")
        case 8: return String(localized: "Blade motor fault")
        case 9: return String(localized: "Wheel motor fault")
        case 10: return String(localized: "Trapped for too long")
        case 11: return String(localized: "Mower upside down")
        case 12: return String(localized: "Battery low")
        case 14: return String(localized: "Charging error")
        case 15: return String(localized: "Not enough sensor data")
        case 122: return String(localized: "Stopped manually on the mower")
        default: return String(localized: "Mower error \(error)")
        }
    }
    public func isFresh(now: Date = Date()) -> Bool { date.map { now.timeIntervalSince($0) >= -30 && now.timeIntervalSince($0) < 300 } ?? false }
}

public struct Activity: Identifiable, Sendable {
    public var id: String, date: Date?, telemetry: Telemetry
    public static func parse(_ value: [String: Any], index: Int) -> Activity {
        let date = parseCloudDate(value["timestamp"] as? String)
        return Activity(id: value["_id"] as? String ?? String(index), date: date,
            telemetry: Telemetry.parse(value["payload"] as? [String: Any] ?? [:], fallbackDate: date))
    }
}

/// One mowing slot of the weekly schedule (`sc.d` / `sc.dd`): day 0 is Sunday, as sent by the mower.
public struct ScheduleSlot: Hashable, Sendable {
    public var day: Int, second: Bool, start: String, minutes: Int, edgeCut: Bool
    public init(day: Int, second: Bool, start: String, minutes: Int, edgeCut: Bool) {
        self.day = day; self.second = second; self.start = start; self.minutes = minutes; self.edgeCut = edgeCut
    }
    /// Minutes since midnight for "HH:mm", nil if invalid.
    public static func minutes(of time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
    public var startMinutes: Int { Self.minutes(of: start) ?? 0 }
    public var endMinutes: Int { startMinutes + minutes }
}

/// Settings read from `cfg`. Only the fields MowerBar can change are decoded.
public struct MowerConfig: Equatable, Sendable {
    public var torque: Int?
    public var rainDelay: Int?
    /// `sc` exactly as received, so that a write only changes the edge-cut flags.
    public var scheduleJSON: Data?
    public init(torque: Int? = nil, rainDelay: Int? = nil, scheduleJSON: Data? = nil) {
        self.torque = torque; self.rainDelay = rainDelay; self.scheduleJSON = scheduleJSON
    }
    public static func parse(_ cfg: [String: Any]) -> MowerConfig {
        let schedule = (cfg["sc"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        return MowerConfig(torque: cfg["tq"] as? Int, rainDelay: cfg["rd"] as? Int, scheduleJSON: schedule)
    }
    /// Keeps known values when a message only carries part of the configuration.
    public func merged(with newer: MowerConfig) -> MowerConfig {
        MowerConfig(torque: newer.torque ?? torque, rainDelay: newer.rainDelay ?? rainDelay, scheduleJSON: newer.scheduleJSON ?? scheduleJSON)
    }
    public var schedule: [String: Any]? {
        scheduleJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    /// Whether the mower uses a second daily slot list (`dd`).
    public var hasSecondSlots: Bool { schedule?["dd"] is [[Any]] }
    /// Where a new slot can go on `day`: the first free position, or nil when the day is full.
    public func freePosition(day: Int) -> Bool? {
        let used = Set(slots.filter { $0.day == day }.map(\.second))
        if !used.contains(false) { return false }
        if hasSecondSlots && !used.contains(true) { return true }
        return nil
    }
    /// True when `cfg` now holds what a sent setting asked for (used to confirm the mower's echo).
    public func reflects(_ sent: [String: Any]) -> Bool {
        if let tq = sent["tq"] as? Int, torque != tq { return false }
        if let rd = sent["rd"] as? Int, rainDelay != rd { return false }
        if let sc = sent["sc"] as? [String: Any] {
            guard let schedule else { return false }
            for key in ["d", "dd"] where sc[key] != nil {
                guard let a = sc[key] as? NSArray, let b = schedule[key] as? NSArray, a == b else { return false }
            }
        }
        return true
    }
    /// Active slots (duration above zero), first and second daily slots.
    public var slots: [ScheduleSlot] {
        guard let schedule else { return [] }
        var result = [ScheduleSlot]()
        for (key, second) in [("d", false), ("dd", true)] {
            for (day, entry) in ((schedule[key] as? [[Any]]) ?? []).enumerated() {
                guard entry.count >= 3, let start = entry[0] as? String, let minutes = entry[1] as? Int, minutes > 0 else { continue }
                result.append(ScheduleSlot(day: day, second: second, start: start, minutes: minutes, edgeCut: (entry[2] as? Int ?? 0) == 1))
            }
        }
        return result.sorted { ($0.day, $0.second ? 1 : 0) < ($1.day, $1.second ? 1 : 0) }
    }
}
