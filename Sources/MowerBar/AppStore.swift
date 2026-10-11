import AppKit
import Combine
import Foundation
import UserNotifications
import MowerBarCore

enum Preference {
    static let menuBarIcon = "showMenuBarIcon"
    static let experimentalResume = "experimentalResume"
}

@MainActor final class AppStore: ObservableObject {
    @Published var mowers: [Mower] = []
    @Published var selectedID = ""
    @Published var activities: [Activity] = []
    @Published var busy = false
    @Published var live = false
    @Published var connectionLabel = String(localized: "Connecting…")
    @Published var message: String?
    @Published var failure: String?
    @Published var pendingCommand: MowerCommand?
    @Published var pendingSetting: MowerSetting?
    @Published var notificationsEnabled = false
    @Published var showLogin = false
    @Published var sessionAvailable = false
    @Published var events: [String] = []
    @Published var clock = Date()
    let api = CloudAPI()
    let mqtt = MQTTClient()
    private var pollTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var commandTimeout: Task<Void, Never>?
    private var settingTimeout: Task<Void, Never>?
    private var activeToken = ""
    private var pendingID: Int?
    private var pendingSettingID: Int?
    private var lastStatusRequest = Date.distantPast
    private var lastAutoRefresh = Date.distantPast
    private var stopping = false
    private var reconnectAttempt = 0
    private var hasStarted = false

    var mower: Mower? { mowers.first { $0.id == selectedID } }
    private var availability: ControlAvailability? {
        guard let mower else { return nil }
        return ControlAvailability(connected: live, online: mower.online, protocolVersion: mower.protocolVersion,
            pending: pendingCommand != nil || pendingSetting != nil, telemetry: mower.telemetry, capabilities: mower.capabilities, now: clock)
    }
    var canControl: Bool { availability?.available == true }
    var canStart: Bool { availability?.start == true }
    var canPause: Bool { availability?.pause == true }
    var canHome: Bool { availability?.home == true }
    var canChangeSettings: Bool { availability?.settings == true }
    var experimentalResumeEnabled: Bool { UserDefaults.standard.bool(forKey: Preference.experimentalResume) }
    var canResume: Bool { experimentalResumeEnabled && availability?.resume == true }

    init() {
        mqtt.onEvent = { [weak self] event in self?.handle(event) }
    }
    func start() async {
        guard !hasStarted else { return }; hasStarted = true
        sessionAvailable = (try? SecureSession.load()) != nil
        await updateNotificationStatus()
        if sessionAvailable { await refresh() } else { connectionLabel = String(localized: "Account not connected") }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                guard let self, self.sessionAvailable else { continue }
                await self.refresh(requestStatus: false)
            }
        }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.clock = Date()
            }
        }
    }
    func refresh(requestStatus: Bool = true) async {
        guard !busy, !stopping else { return }
        busy = true; failure = nil
        defer { busy = false; clock = Date() }
        do {
            let old = mowers
            var values = try await api.inventory()
            for i in values.indices {
                guard let prior = old.first(where: { $0.id == values[i].id }) else { continue }
                if (prior.telemetry.date ?? .distantPast) > (values[i].telemetry.date ?? .distantPast) {
                    values[i].telemetry = prior.telemetry; values[i].config = prior.config
                } else {
                    values[i].config = prior.config.merged(with: values[i].config)
                }
            }
            mowers = values; sessionAvailable = true
            if !values.contains(where: { $0.id == selectedID }) { selectedID = values.first?.id ?? "" }
            guard let mower else { connectionLabel = String(localized: "No mower on this account"); return }
            let token = try await api.token()
            if !live || activeToken != token.accessToken {
                connectionLabel = String(localized: "Connecting to the mower…")
                try await mqtt.connect(mower: mower, token: token.accessToken)
                activeToken = token.accessToken
            }
            if requestStatus && mower.online { try await requestState() }
            if activities.isEmpty { activities = try await api.history(mower) }
            log(String(localized: "Cloud read completed"))
        } catch {
            failure = friendly(error)
            if !live { connectionLabel = String(localized: "Connection unavailable") }
            log(String(localized: "Read failed: \(friendly(error))"))
            if !live { scheduleReconnect() }
        }
    }
    /// Called when a window or the menu bar panel comes forward: asks for a fresh state at most once a minute.
    func refreshIfStale() async {
        guard sessionAvailable, pendingCommand == nil, !busy, let mower, !mower.telemetry.isFresh(),
              Date().timeIntervalSince(lastAutoRefresh) >= 60 else { return }
        lastAutoRefresh = Date()
        await refresh()
    }
    func select(_ id: String) async {
        guard id != selectedID, pendingCommand == nil, pendingSetting == nil else { return }
        selectedID = id; activities = []; mqtt.disconnect(); live = false; activeToken = ""
        await refresh()
    }
    func loadHistory() async {
        guard let mower else { return }
        do { activities = try await api.history(mower) } catch { failure = friendly(error) }
    }
    func requestState() async throws {
        guard let mower, live, Date().timeIntervalSince(lastStatusRequest) >= 30 else { return }
        lastStatusRequest = Date()
        let data = try envelope(.status, mower: mower, id: Int.random(in: 1024...65534))
        try await mqtt.publish(topic: mower.topicIn, payload: data)
    }

    // MARK: Commands

    func send(_ command: MowerCommand) async {
        guard command.isMotion, let mower, canControl else { return }
        guard command != .start || canStart, command != .pause || canPause, command != .safeHome || canHome else { return }
        await transmit(command, mower: mower, resume: nil)
    }
    /// Experimental: resends start or safe home with the current `ls`/`le`, the official app's resume format.
    /// The mower's answer one minute later is logged, to learn which errors this firmware accepts to leave.
    func attemptResume(_ command: MowerCommand) async {
        guard [.start, .safeHome].contains(command), let mower, canResume,
              let state = mower.telemetry.state, let error = mower.telemetry.error else { return }
        let errorLabel = mower.telemetry.errorLabel ?? "\(error)"
        log(String(localized: "Resume attempt: \(command.label) after “\(errorLabel)”"))
        await transmit(command, mower: mower, resume: (state, error))
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, let after = self.mowers.first(where: { $0.id == mower.id })?.telemetry else { return }
            self.log(String(localized: "Resume result after 60 s: \(after.errorLabel ?? after.stateLabel)"))
        }
    }
    private func transmit(_ command: MowerCommand, mower: Mower, resume: (state: Int, error: Int)?) async {
        let id = Int.random(in: 1024...65534)
        pendingID = id; pendingCommand = command; failure = nil; message = String(localized: "Sending the command…")
        do {
            let data = try CommandEnvelope.data(command: command, serial: mower.serial, protocolVersion: mower.protocolVersion,
                capabilities: mower.capabilities, id: id, timeZone: timeZone(mower), resume: resume)
            try await mqtt.publish(topic: mower.topicIn, payload: data)
            log(String(localized: "\(command.label): received by the cloud"))
            if pendingID == id {
                message = String(localized: "Command received by the cloud; waiting for the mower…")
                commandTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.pendingID == id else { return }
                    self.pendingID = nil; self.pendingCommand = nil
                    self.failure = String(localized: "The mower did not confirm. Check its state before sending another command.")
                    self.message = nil
                }
            }
        } catch {
            if pendingID == id { pendingID = nil; pendingCommand = nil; message = nil; failure = friendly(error) }
        }
    }

    // MARK: Settings

    /// Sends one configuration change (`cmd: 0`, never a movement) and waits for the mower to echo it.
    func apply(_ setting: MowerSetting) async {
        guard let mower, canChangeSettings else { return }
        let id = Int.random(in: 1024...65534)
        pendingSettingID = id; pendingSetting = setting; failure = nil; message = String(localized: "Sending the setting…")
        do {
            let data = try CommandEnvelope.setting(setting, config: mower.config, serial: mower.serial,
                protocolVersion: mower.protocolVersion, id: id, timeZone: timeZone(mower))
            try await mqtt.publish(topic: mower.topicIn, payload: data)
            log(String(localized: "Setting sent: \(describe(setting))"))
            settingTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.pendingSettingID == id else { return }
                self.pendingSettingID = nil; self.pendingSetting = nil; self.message = nil
                self.failure = String(localized: "The mower did not confirm the setting. Refresh to see its current value.")
            }
        } catch {
            if pendingSettingID == id { pendingSettingID = nil; pendingSetting = nil; message = nil; failure = friendly(error) }
        }
    }
    func describe(_ setting: MowerSetting) -> String {
        switch setting {
        case .torque(let value): return String(localized: "wheel torque \(value) %")
        case .rainDelay(let minutes): return String(localized: "rain delay \(minutes) min")
        case .edgeCut(let day, let second, let enabled):
            let name = Calendar.current.weekdaySymbols[day % 7] + (second ? " (2)" : "")
            return enabled ? String(localized: "edge cut on for \(name)") : String(localized: "edge cut off for \(name)")
        }
    }
    private func confirmed(_ setting: MowerSetting, by config: MowerConfig) -> Bool {
        switch setting {
        case .torque(let value): return config.torque == value
        case .rainDelay(let minutes): return config.rainDelay == minutes
        case .edgeCut(let day, let second, let enabled):
            return config.slots.contains { $0.day == day && $0.second == second && $0.edgeCut == enabled }
        }
    }

    private func envelope(_ command: MowerCommand, mower: Mower, id: Int) throws -> Data {
        try CommandEnvelope.data(command: command, serial: mower.serial, protocolVersion: mower.protocolVersion,
            capabilities: mower.capabilities, id: id, timeZone: timeZone(mower))
    }
    private func timeZone(_ mower: Mower) -> TimeZone { TimeZone(identifier: mower.timeZoneName) ?? .current }

    private func handle(_ event: MQTTClient.Event) {
        guard !stopping else { return }
        switch event {
        case .connected:
            live = true; reconnectAttempt = 0; connectionLabel = String(localized: "Live events"); log(String(localized: "Cloud link established"))
        case .disconnected(let reason):
            live = false; activeToken = ""; connectionLabel = String(localized: "Reconnecting…")
            if pendingCommand != nil || pendingSetting != nil {
                pendingID = nil; pendingCommand = nil; commandTimeout?.cancel()
                pendingSettingID = nil; pendingSetting = nil; settingTimeout?.cancel(); message = nil
                failure = String(localized: "Connection lost. The request will not be resent automatically.")
            }
            log(reason); scheduleReconnect()
        case .telemetry(let data):
            guard let index = mowers.firstIndex(where: { $0.id == selectedID }),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any], payload["dat"] != nil else { return }
            let previous = mowers[index].telemetry
            let cfg = payload["cfg"] as? [String: Any] ?? [:]
            var date: Date? = nil
            if let day = cfg["dt"] as? String, let time = cfg["tm"] as? String {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: mowers[index].timeZoneName) ?? .current
                f.dateFormat = "dd/MM/yyyy HH:mm:ss"; date = f.date(from: day+" "+time)
            }
            let next = Telemetry.parse(payload, fallbackDate: date ?? Date())
            mowers[index].telemetry = next; mowers[index].online = true; clock = Date()
            mowers[index].config = mowers[index].config.merged(with: MowerConfig.parse(cfg))
            if let id = pendingID, next.correlationID == id {
                commandTimeout?.cancel(); pendingID = nil; pendingCommand = nil
                message = String(localized: "Mower answered: \(next.errorLabel ?? next.stateLabel).")
                log(message!)
            }
            if let id = pendingSettingID, next.correlationID == id, let setting = pendingSetting {
                settingTimeout?.cancel(); pendingSettingID = nil; pendingSetting = nil
                if confirmed(setting, by: mowers[index].config) {
                    message = String(localized: "Setting applied: \(describe(setting)).")
                } else {
                    message = nil; failure = String(localized: "The mower answered but kept its previous value for \(describe(setting)).")
                }
                log(message ?? failure ?? "")
            }
            notifyChanges(previous: previous, next: next)
        }
    }
    private func scheduleReconnect() {
        guard !stopping, sessionAvailable, reconnectTask == nil else { return }
        reconnectAttempt += 1
        let delay = min(120, 5 * (1 << min(reconnectAttempt-1, 5)))
        reconnectTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }; self.reconnectTask = nil
            await self.refresh(requestStatus: false)
        }
    }

    // MARK: Notifications

    func enableNotifications() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await updateNotificationStatus()
            if !notificationsEnabled { message = String(localized: "Turn on MowerBar notifications in System Settings → Notifications.") }
        } catch { failure = String(localized: "Notification permission could not be requested.") }
    }
    func updateNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsEnabled = [.authorized, .provisional].contains(settings.authorizationStatus)
    }
    func testNotification() { notify(title: "MowerBar", body: String(localized: "Notifications are ready. This is a test; nothing was sent to the mower.")) }
    private func notifyChanges(previous: Telemetry, next: Telemetry) {
        // Baseline is never notified as a new event; the first live message may be old.
        guard previous.state != nil, previous.isFresh(), next.isFresh() else { return }
        let name = mower?.name ?? "MowerBar"
        if let text = next.errorLabel, next.error != previous.error { notify(title: String(localized: "\(name) needs attention"), body: text) }
        else if previous.errorLabel != nil && next.error == 0 { notify(title: name, body: String(localized: "The mower’s error has cleared.")) }
        if next.state != previous.state && [1, 7, 30, 32, 34].contains(next.state ?? -1) {
            notify(title: name, body: next.stateLabel)
        }
        if let old = previous.battery, let level = next.battery, old > 20 && level <= 20 && !next.charging {
            notify(title: name, body: String(localized: "Battery at \(level) %."))
        }
    }
    private func notify(title: String, body: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: Session

    func signOut() {
        stopping = true; mqtt.disconnect(); reconnectTask?.cancel(); reconnectTask = nil; commandTimeout?.cancel(); settingTimeout?.cancel()
        SecureSession.delete(); sessionAvailable = false; live = false; activeToken = ""; mowers = []; activities = []
        pendingID = nil; pendingCommand = nil; pendingSettingID = nil; pendingSetting = nil; message = nil; failure = nil
        connectionLabel = String(localized: "Account not connected"); stopping = false
    }
    func shutdown() {
        stopping = true; mqtt.disconnect(); pollTask?.cancel(); heartbeatTask?.cancel(); reconnectTask?.cancel(); commandTimeout?.cancel(); settingTimeout?.cancel()
    }
    private func log(_ text: String) {
        events.insert(Date().formatted(date: .omitted, time: .shortened)+" · "+text, at: 0)
        if events.count > 30 { events.removeLast(events.count-30) }
    }
    private func friendly(_ error: Error) -> String {
        if let e = error as? ProtocolError { return e.localizedDescription }
        if error is URLError { return String(localized: "The Worx cloud is unreachable right now. Check the Internet connection.") }
        return String(localized: "The operation did not complete. Try again in a moment.")
    }
}
