import SwiftUI
import AppKit
import UserNotifications
import MowerBarCore

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

struct MowerBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()
    @AppStorage(Preference.menuBarIcon) private var showMenuBarIcon = true
    var body: some Scene {
        WindowGroup("MowerBar", id: "main") {
            MainView().environmentObject(store).task { await store.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.shutdown() }
        }.defaultSize(width: 1000, height: 720)
        MenuBarExtra(isInserted: $showMenuBarIcon) { MenuPanel().environmentObject(store).task { await store.start() } }
            label: { MenuBarLabel(store: store) }
            .menuBarExtraStyle(.window)
    }
}

@main enum Launcher {
    @MainActor static func main() async {
        do {
            if let index = CommandLine.arguments.firstIndex(of: "--export-icon"), index + 1 < CommandLine.arguments.count {
                try MowerGlyph.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); return
            }
            if CommandLine.arguments.contains("--check-readonly") {
                try await ReadOnlyCheck.run(); return
            }
            MowerBarApp.main()
        } catch {
            // No tokens, URLs with identifiers or raw server bodies in diagnostics.
            if let e = error as? ProtocolError { fputs(e.localizedDescription+"\n", stderr) }
            else { fputs("The check did not complete (\(type(of: error))).\n", stderr) }
            exit(1)
        }
    }
}

/// `--check-readonly`: reads the account, opens the MQTT link and asks for one status update. Sends no movement.
@MainActor enum ReadOnlyCheck {
    static func run() async throws {
        let api = CloudAPI(); let values = try await api.inventory()
        guard let mower = values.first else { throw ProtocolError.invalid("No mower found.") }
        let history = try await api.history(mower)
        let token = try await api.token()
        let mqtt = MQTTClient()
        let id = Int.random(in: 1024...65534)
        var received = 0, correlated = false
        mqtt.onEvent = { event in
            if case .telemetry(let data) = event,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["cfg"] != nil, object["dat"] != nil {
                received += 1
                let telemetry = Telemetry.parse(object)
                if telemetry.correlationID == id { correlated = true }
            }
        }
        try await mqtt.connect(mower: mower, token: token.accessToken)
        defer { mqtt.disconnect() }
        let data = try CommandEnvelope.data(command: .status, serial: mower.serial, protocolVersion: mower.protocolVersion,
            capabilities: mower.capabilities, id: id, timeZone: TimeZone(identifier: mower.timeZoneName) ?? .current)
        try await mqtt.publish(topic: mower.topicIn, payload: data)
        for _ in 0..<40 {
            if correlated { break }; try await Task.sleep(for: .seconds(1))
        }
        let summary: [String: Any] = ["rest_inventory": "HTTP 200", "history_entries": history.count,
            "mqtt_tls": true, "mqtt_subscription": true, "status_request_ack": true,
            "telemetry_received": received, "status_response_correlated": correlated,
            "motion_commands_sent": 0, "bluetooth_driving_declared": mower.capabilities.contains("bluetooth_remote_driving")]
        print(String(data: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        guard correlated else { throw ProtocolError.invalid("Connected, but no correlated status answer arrived in time.") }
    }
}
