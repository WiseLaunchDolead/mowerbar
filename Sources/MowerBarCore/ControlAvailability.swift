import Foundation

public struct ControlAvailability {
    public let connected: Bool, online: Bool, protocolVersion: Int, pending: Bool
    public let telemetry: Telemetry, capabilities: Set<String>, now: Date
    public init(connected: Bool, online: Bool, protocolVersion: Int, pending: Bool,
                telemetry: Telemetry, capabilities: Set<String>, now: Date = Date()) {
        self.connected = connected; self.online = online; self.protocolVersion = protocolVersion; self.pending = pending
        self.telemetry = telemetry; self.capabilities = capabilities; self.now = now
    }
    public var available: Bool { connected && online && protocolVersion == 0 && !pending && telemetry.isFresh(now: now) }
    public var start: Bool { available && telemetry.error == 0 && [1, 34].contains(telemetry.state ?? -1) }
    public var pause: Bool { available && [2,3,4,5,6,7,8,9,10,12,30,31,32,33].contains(telemetry.state ?? -1) }
    public var home: Bool { available && telemetry.error == 0 && capabilities.contains("safe_go_home") && telemetry.state != 1 }
    /// Experimental: the mower reports an error and its state is fresh. Not offered by the official app for wired mowers.
    public var resume: Bool { available && (telemetry.error ?? 0) != 0 }
    /// Settings need the same live link and fresh state, so the change is checked against the current configuration.
    public var settings: Bool { available }
}
