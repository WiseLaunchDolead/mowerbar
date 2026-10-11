import Foundation

public enum ProtocolError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let text): return text }
    }
}

public enum MowerCommand: Int, CaseIterable, Sendable {
    case status = 0, start = 1, pause = 2, safeHome = 9
    public var label: String {
        switch self {
        case .status: return String(localized: "Refresh state")
        case .start: return String(localized: "Start mowing")
        case .pause: return String(localized: "Pause")
        case .safeHome: return String(localized: "Return to base")
        }
    }
    public var isMotion: Bool { self != .status }
}

/// Configuration changes MowerBar can send. None of them moves the mower.
public enum MowerSetting: Equatable, Sendable {
    case torque(Int), rainDelay(Int), edgeCut(day: Int, second: Bool, enabled: Bool)
    public static let torqueRange = -50...50
    public static let rainDelayRange = 0...1440
}

public struct CommandEnvelope {
    /// `resume` copies the current `ls`/`le` into the command: the official app's format to resume after an error.
    public static func data(command: MowerCommand, serial: String, protocolVersion: Int,
                            capabilities: Set<String>, date: Date = Date(), id: Int,
                            timeZone: TimeZone = .current, resume: (state: Int, error: Int)? = nil) throws -> Data {
        if command == .safeHome && !capabilities.contains("safe_go_home") {
            throw ProtocolError.invalid(String(localized: "This mower does not offer returning with the blades stopped."))
        }
        var body = try envelope(command: command.rawValue, serial: serial, protocolVersion: protocolVersion, date: date, id: id, timeZone: timeZone)
        if let resume { body["ls"] = resume.state; body["le"] = resume.error }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Configuration writes always use `cmd: 0`. The official app sometimes attaches `cmd: 3` (go home) to
    /// schedule writes; MowerBar never does, so a setting can never move the mower.
    public static func setting(_ setting: MowerSetting, config: MowerConfig, serial: String, protocolVersion: Int,
                               date: Date = Date(), id: Int, timeZone: TimeZone = .current) throws -> Data {
        var body = try envelope(command: MowerCommand.status.rawValue, serial: serial, protocolVersion: protocolVersion, date: date, id: id, timeZone: timeZone)
        switch setting {
        case .torque(let value):
            guard MowerSetting.torqueRange.contains(value) else { throw ProtocolError.invalid(String(localized: "Wheel torque must be between -50 and +50.")) }
            body["tq"] = value
        case .rainDelay(let minutes):
            guard MowerSetting.rainDelayRange.contains(minutes) else { throw ProtocolError.invalid(String(localized: "Rain delay must be between 0 and 1440 minutes.")) }
            body["rd"] = minutes
        case .edgeCut(let day, let second, let enabled):
            guard let schedule = config.schedule else { throw ProtocolError.invalid(String(localized: "The mower’s schedule has not been received yet.")) }
            // Same fields as the official app for wired mowers: the one-time mow (`ots`) is never sent back.
            var sc = schedule.filter { ["d", "dd", "m", "p", "distm"].contains($0.key) }
            let key = second ? "dd" : "d"
            guard var days = sc[key] as? [[Any]], days.indices.contains(day), days[day].count >= 3,
                  (days[day][1] as? Int ?? 0) > 0 else { throw ProtocolError.invalid(String(localized: "This schedule slot does not exist.")) }
            days[day][2] = enabled ? 1 : 0
            sc[key] = days
            body["sc"] = sc
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func envelope(command: Int, serial: String, protocolVersion: Int, date: Date, id: Int, timeZone: TimeZone) throws -> [String: Any] {
        guard protocolVersion == 0 else { throw ProtocolError.invalid(String(localized: "Commands are not supported yet for this mower type.")) }
        guard !serial.isEmpty, (1024...65534).contains(id) else { throw ProtocolError.invalid(String(localized: "Invalid command identifier.")) }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = timeZone; day.dateFormat = "dd/MM/yyyy"
        let time = DateFormatter(); time.locale = day.locale; time.timeZone = timeZone; time.dateFormat = "HH:mm:ss"
        return ["cmd": command, "sn": serial, "dt": day.string(from: date), "tm": time.string(from: date), "id": id]
    }
}

public struct MQTTFrame: Equatable, Sendable {
    public let header: UInt8
    public let body: Data
    public var type: UInt8 { header >> 4 }
    public init(header: UInt8, body: Data) { self.header = header; self.body = body }
    public var encoded: Data {
        var result = Data([header]); var remaining = body.count
        repeat { var b = UInt8(remaining % 128); remaining /= 128; if remaining > 0 { b |= 128 }; result.append(b) } while remaining > 0
        result.append(body); return result
    }
}

public struct MQTTDecoder {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [MQTTFrame] {
        buffer.append(data)
        guard buffer.count <= 2_097_152 else { throw ProtocolError.invalid(String(localized: "Network message too large.")) }
        var frames = [MQTTFrame]()
        while buffer.count >= 2 {
            let bytes = [UInt8](buffer)
            var length = 0, multiplier = 1, offset = 1, complete = false
            for _ in 0..<4 {
                guard offset < bytes.count else { return frames }
                let b = bytes[offset]; offset += 1
                length += Int(b & 127) * multiplier
                if b & 128 == 0 { complete = true; break }
                multiplier *= 128
            }
            guard complete, length <= 1_048_576 else { throw ProtocolError.invalid(String(localized: "Invalid network frame.")) }
            guard bytes.count >= offset + length else { return frames }
            frames.append(MQTTFrame(header: bytes[0], body: Data(bytes[offset..<(offset+length)])))
            buffer = Data(bytes.dropFirst(offset+length))
        }
        return frames
    }
}

public enum MQTTWire {
    public static func u16(_ n: Int) -> Data { Data([UInt8((n >> 8) & 255), UInt8(n & 255)]) }
    public static func string(_ value: String) throws -> Data {
        let d = Data(value.utf8)
        guard d.count <= 65535 else { throw ProtocolError.invalid(String(localized: "Network field too long.")) }
        return u16(d.count) + d
    }
    public static func connect(clientID: String, username: String) throws -> Data {
        // MQTT 5, clean start, username only, keepalive 30s, no CONNECT properties.
        let body = try string("MQTT") + Data([5, 0x82, 0, 30, 0]) + string(clientID) + string(username)
        return MQTTFrame(header: 0x10, body: body).encoded
    }
    public static func subscribe(topic: String, id: Int) throws -> Data {
        try validTopic(topic)
        return MQTTFrame(header: 0x82, body: try u16(id) + Data([0]) + string(topic) + Data([1])).encoded
    }
    public static func publish(topic: String, payload: Data, id: Int) throws -> Data {
        try validTopic(topic)
        // QoS 1, retain false, DUP false. Commands are never replayed automatically.
        return MQTTFrame(header: 0x32, body: try string(topic) + u16(id) + Data([0]) + payload).encoded
    }
    public static func publication(_ frame: MQTTFrame) throws -> (topic: String, payload: Data, id: Int?) {
        let bytes = [UInt8](frame.body)
        guard frame.type == 3, bytes.count >= 2 else { throw ProtocolError.invalid(String(localized: "Invalid network publication.")) }
        let length = Int(bytes[0]) * 256 + Int(bytes[1])
        guard bytes.count >= 2+length, let topic = String(bytes: bytes[2..<(2+length)], encoding: .utf8) else { throw ProtocolError.invalid(String(localized: "Invalid network topic.")) }
        let qos = (frame.header >> 1) & 3
        guard qos <= 1 else { throw ProtocolError.invalid(String(localized: "Unsupported network quality of service.")) }
        var offset = 2+length; var id: Int?
        if qos == 1 {
            guard bytes.count >= offset+2 else { throw ProtocolError.invalid(String(localized: "Invalid network acknowledgement.")) }
            id = Int(bytes[offset])*256 + Int(bytes[offset+1]); offset += 2
        }
        var properties = 0, multiplier = 1, complete = false
        for _ in 0..<4 {
            guard offset < bytes.count else { throw ProtocolError.invalid(String(localized: "Truncated network properties.")) }
            let b = bytes[offset]; offset += 1; properties += Int(b & 127) * multiplier
            if b & 128 == 0 { complete = true; break }; multiplier *= 128
        }
        guard complete, offset+properties <= bytes.count else { throw ProtocolError.invalid(String(localized: "Invalid network properties.")) }
        return (topic, Data(bytes.dropFirst(offset+properties)), id)
    }
    private static func validTopic(_ topic: String) throws {
        guard !topic.isEmpty, !topic.contains("#"), !topic.contains("+"), !topic.contains("\0") else { throw ProtocolError.invalid(String(localized: "Invalid device topic.")) }
    }
    public static func username(accessToken: String) throws -> String {
        let parts = accessToken.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+").split(separator: ".").map(String.init)
        guard parts.count == 3 else { throw ProtocolError.invalid(String(localized: "Invalid Worx session.")) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let escaped = parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return "username?jwt=\(escaped[0]).\(escaped[1])&x-amz-customauthorizer-signature=\(escaped[2])"
    }
}
