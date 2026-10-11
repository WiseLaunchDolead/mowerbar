import SwiftUI
import AppKit
import MowerBarCore

enum Page: String, CaseIterable, Identifiable {
    case dashboard, history, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return String(localized: "My mower")
        case .history: return String(localized: "Activity log")
        case .settings: return String(localized: "Settings")
        }
    }
    var icon: String { switch self { case .dashboard: return "leaf"; case .history: return "clock.arrow.circlepath"; case .settings: return "gearshape" } }
}

struct DayGroup: Identifiable {
    let day: Date, items: [Activity]
    var id: Date { day }
}

struct MainView: View {
    @EnvironmentObject var store: AppStore
    @State private var page: Page? = .dashboard
    @State private var confirmation: MowerCommand?
    @State private var resumeConfirmation: MowerCommand?
    @State private var settingConfirmation: MowerSetting?
    @State private var torqueDraft: Int?
    @AppStorage(Preference.menuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Preference.experimentalResume) private var experimentalResume = false
    var body: some View {
        NavigationSplitView {
            // Standard sidebar only: a custom header collides with the window buttons.
            List(Page.allCases, selection: $page) { p in
                Label { Text(p.title) } icon: {
                    (p == .dashboard ? Image(nsImage: MowerGlyph.sidebar) : Image(systemName: p.icon)).frame(width: 24)
                }.tag(p)
            }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .bottom) { sidebarFooter }
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let failure = store.failure { banner(failure, icon: "exclamationmark.triangle.fill", color: .orange) { store.failure = nil } }
                if let message = store.message, store.pendingCommand == nil, store.pendingSetting == nil {
                    banner(message, icon: "info.circle", color: .accentColor) { store.message = nil }
                }
                if !store.sessionAvailable {
                    ContentUnavailableView { Label("Welcome to MowerBar", systemImage: "leaf.circle") }
                        description: { Text("Connect your Worx account to follow your Landroid, its activity and its commands from your Mac. Wired models can be controlled; Vision models are read-only.") }
                        actions: { Button("Connect my Worx account") { store.showLogin = true }.buttonStyle(.borderedProminent) }
                } else {
                    switch page ?? .dashboard {
                    case .dashboard: dashboard
                    case .history: history
                    case .settings: settings
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle(page?.title ?? "MowerBar")
                .navigationSubtitle(page == .history && !store.activities.isEmpty ? String(localized: "\(store.activities.count) events") : "")
                .toolbar {
                    if store.mowers.count > 1 {
                        Picker("Mower", selection: Binding(get: { store.selectedID }, set: { id in Task { await store.select(id) } })) {
                            ForEach(store.mowers) { Text($0.name).tag($0.id) }
                        }.disabled(store.pendingCommand != nil || store.pendingSetting != nil || store.busy)
                    }
                    Button { Task { if page == .history { await store.loadHistory() } else { await store.refresh() } } }
                        label: { if store.busy { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") } }
                        .disabled(store.busy || !store.sessionAvailable || store.pendingCommand != nil)
                        .help("Refresh the mower’s state").keyboardShortcut("r", modifiers: .command)
                }
        }
        .frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: $store.showLogin) { AuthenticationView().environmentObject(store) }
        .confirmationDialog(confirmation?.label ?? "", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            if let command = confirmation {
                Button(command.label) { confirmation = nil; Task { await store.send(command) } }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation == .start ? "The mower will start or resume mowing. Make sure its area is clear." : confirmation == .pause ? "The mower will pause mowing." : "The mower will drive back to its base. Make sure it can move.")
        }
        .confirmationDialog("Try to resume after the error?", isPresented: Binding(get: { resumeConfirmation != nil }, set: { if !$0 { resumeConfirmation = nil } }), titleVisibility: .visible) {
            if let command = resumeConfirmation {
                Button(command.label) { resumeConfirmation = nil; Task { await store.attemptResume(command) } }
            }
            Button("Cancel", role: .cancel) { resumeConfirmation = nil }
        } message: {
            Text("Experimental, not offered by Worx for wired mowers. The mower may move or start its blades: only try with someone next to it and the area clear. The result is written to the technical log.")
        }
        .confirmationDialog("Apply this setting?", isPresented: Binding(get: { settingConfirmation != nil }, set: { if !$0 { settingConfirmation = nil } }), titleVisibility: .visible) {
            if let setting = settingConfirmation {
                Button("Apply") { settingConfirmation = nil; torqueDraft = nil; Task { await store.apply(setting) } }
            }
            Button("Cancel", role: .cancel) { settingConfirmation = nil }
        } message: {
            if let setting = settingConfirmation { Text("\(store.describe(setting).capitalizedFirst). The mower will not move.") }
        }
        // Coming back to the window asks the robot for a fresh state, so commands are usable right away.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshIfStale() }
        }
    }

    // MARK: Chrome

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.sessionAvailable && !store.notificationsEnabled {
                Button { Task { await store.enableNotifications() } } label: { Label("Turn on alerts", systemImage: "bell.badge") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            HStack(spacing: 6) {
                Circle().fill(store.live ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(store.live ? String(localized: "Connected to the Worx cloud") : store.connectionLabel).lineLimit(1)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func banner(_ text: String, icon: String, color: Color, close: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: close) { Image(systemName: "xmark").font(.caption.bold()) }.buttonStyle(.borderless).help("Dismiss")
        }.padding(.horizontal, 16).padding(.vertical, 10).background(color.opacity(0.1))
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.07), lineWidth: 1))
    }
    private func pill(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) { Circle().fill(color).frame(width: 7, height: 7); Text(text) }
            .font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5).background(color.opacity(0.12), in: Capsule())
    }

    // MARK: Dashboard

    private var dashboard: some View {
        ScrollView {
            if let mower = store.mower {
                VStack(spacing: 16) {
                    statusCard(mower)
                    commandsCard(mower)
                    recentActivity
                }.padding(24).frame(maxWidth: 880).frame(maxWidth: .infinity)
            } else if store.busy { ProgressView("Looking for your mower…").padding(50) }
            else { ContentUnavailableView("No mower found", systemImage: "leaf", description: Text("Refresh or reconnect your Worx account.")) }
        }
    }
    private func statusCard(_ mower: Mower) -> some View {
        let t = mower.telemetry
        let fresh = t.isFresh(now: store.clock)
        return card {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mower.name).font(.title2.bold())
                    Text("\(mower.model) · firmware \(mower.firmware)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                pill(mower.online ? String(localized: "Online") : String(localized: "Offline"), color: mower.online ? .green : .secondary)
            }
            Divider()
            HStack(alignment: .center, spacing: 20) {
                StateBadge(telemetry: t, size: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text(t.stateLabel).font(.title.bold())
                    if let error = t.errorLabel { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    else { Label("No error", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Spacer()
                batteryRing(t)
            }
            HStack(spacing: 6) {
                Image(systemName: "clock")
                if let date = t.date { Text("Updated \(date.formatted(.relative(presentation: .named)))") } else { Text("No state received yet") }
                if !fresh { Text("· needs a refresh").foregroundStyle(.orange) }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private func batteryRing(_ t: Telemetry) -> some View {
        let level = t.battery ?? 0
        let color: Color = level <= 20 ? .red : level <= 40 ? .orange : .green
        return VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 7)
                Circle().trim(from: 0, to: Double(level) / 100).stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(t.battery.map(String.init) ?? "—").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(verbatim: "%").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(width: 84, height: 84)
            Label("Battery", systemImage: t.charging ? "bolt.fill" : "battery.75percent").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func commandsCard(_ mower: Mower) -> some View {
        // The action that makes sense now is highlighted; the others stay secondary.
        let primary: MowerCommand? = store.canStart ? .start : store.canPause ? .pause : nil
        return card {
            Text("Commands").font(.headline)
            HStack(spacing: 10) {
                commandButton(.start, icon: "play.fill", enabled: store.canStart, primary: primary == .start)
                commandButton(.pause, icon: "pause.fill", enabled: store.canPause, primary: primary == .pause)
                commandButton(.safeHome, icon: "house.fill", enabled: store.canHome, primary: false)
            }.controlSize(.large)
            ControlHintView(hint: ControlHint(store: store, mower: mower))
            if experimentalResume && store.canResume { resumeBlock(mower) }
        }
    }
    @ViewBuilder private func commandButton(_ command: MowerCommand, icon: String, enabled: Bool, primary: Bool) -> some View {
        let button = Button { confirmation = command } label: { Label(command.label, systemImage: icon).frame(maxWidth: .infinity) }.disabled(!enabled)
        if primary { button.buttonStyle(.borderedProminent).tint(command == .start ? .green : .accentColor) }
        else { button.buttonStyle(.bordered) }
    }
    private func resumeBlock(_ mower: Mower) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Experimental resume", systemImage: "flask").font(.subheadline.bold()).foregroundStyle(.orange)
            Text("Resends a command with the current error, like the official app does for errors it considers resumable. Only with someone next to the mower.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if mower.capabilities.contains("safe_go_home") {
                    Button { resumeConfirmation = .safeHome } label: { Label("Try: return to base", systemImage: "house") }
                }
                Button { resumeConfirmation = .start } label: { Label("Try: start mowing", systemImage: "play") }
            }.buttonStyle(.bordered)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
    private var recentActivity: some View {
        card {
            HStack {
                Text("Recent activity").font(.headline)
                Spacer()
                Button("See all") { page = .history }.buttonStyle(.link).disabled(store.activities.isEmpty)
            }
            if store.activities.isEmpty { Text("No events loaded yet.").font(.callout).foregroundStyle(.secondary) }
            else {
                VStack(spacing: 10) { ForEach(Array(sortedActivities.prefix(4))) { activityRow($0) } }
            }
        }
    }

    // MARK: Shared pieces

    private var sortedActivities: [Activity] { store.activities.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) } }
    private func activityRow(_ item: Activity) -> some View {
        let t = item.telemetry
        return HStack(spacing: 12) {
            StateBadge(telemetry: t, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.errorLabel ?? t.stateLabel).fontWeight(.medium)
                if let date = item.date { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let battery = t.battery {
                Label("\(battery) %", systemImage: t.charging ? "bolt.fill" : "battery.50percent")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    // MARK: History

    private var historyDays: [DayGroup] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: sortedActivities) { calendar.startOfDay(for: $0.date ?? .distantPast) }
        return groups.keys.sorted(by: >).map { DayGroup(day: $0, items: groups[$0] ?? []) }
    }
    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if day == calendar.startOfDay(for: .distantPast) { return String(localized: "Unknown date") }
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
    private var history: some View {
        Group {
            if store.activities.isEmpty {
                ContentUnavailableView("No events loaded", systemImage: "clock", description: Text("Refresh to read the mower’s log."))
            } else {
                List {
                    ForEach(historyDays) { group in
                        Section { ForEach(group.items) { activityRow($0).padding(.vertical, 4) } }
                            header: { Text(dayTitle(group.day)) }
                    }
                }.listStyle(.inset)
            }
        }.task { await store.loadHistory() }
    }

    // MARK: Settings

    private var settings: some View {
        Form {
            if let mower = store.mower {
                Section("Mower") {
                    LabeledContent("Name", value: mower.name)
                    LabeledContent("Model", value: mower.model)
                    LabeledContent("Firmware", value: mower.firmware)
                    LabeledContent("Return to base with blades stopped", value: mower.capabilities.contains("safe_go_home") ? String(localized: "Available") : String(localized: "Not available"))
                    LabeledContent("Forward/reverse driving", value: mower.capabilities.contains("bluetooth_remote_driving") ? String(localized: "Bluetooth only, nearby") : String(localized: "Not available on this model"))
                }
                if mower.protocolVersion == 0 { boundarySettings(mower) }
            }
            Section {
                LabeledContent("macOS permission") {
                    Text(store.notificationsEnabled ? "On" : "Off").foregroundStyle(store.notificationsEnabled ? .green : .secondary)
                }
                if store.notificationsEnabled { Button("Send a test notification") { store.testNotification() } }
                else { Button("Turn on notifications") { Task { await store.enableNotifications() } } }
            } header: { Text("Notifications") } footer: {
                Text("Errors, low battery and activity changes. MowerBar must stay open and the Mac awake; you can close the window, MowerBar stays in the menu bar.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show the icon in the menu bar", isOn: $showMenuBarIcon)
            } header: { Text("Menu bar") } footer: {
                Text("The menu bar panel shows the mower’s state and commands, even with the window closed. Quitting MowerBar also removes the icon.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Offer a resume attempt after an error", isOn: $experimentalResume)
            } header: { Text("Experimental") } footer: {
                Text("For wired mowers, Worx asks you to press Start on the mower after errors such as “outside the mowing area”. This option resends start or return to base with the current error, the format the official app uses for errors it considers resumable. Not validated by Worx: the mower may move or start its blades, so only try with someone next to it and the area clear.")
                    .foregroundStyle(.secondary)
            }
            Section("Worx account") {
                LabeledContent("Session", value: store.sessionAvailable ? String(localized: "Connected · macOS Keychain") : String(localized: "Not connected"))
                HStack {
                    Button("Reconnect the account") { store.showLogin = true }
                    Spacer()
                    Button("Sign out", role: .destructive) { store.signOut() }.disabled(store.pendingCommand != nil || store.pendingSetting != nil)
                }
            }
            Section {
                LabeledContent("Worx cloud", value: store.connectionLabel)
                DisclosureGroup("Technical log") {
                    ForEach(Array(store.events.prefix(12).enumerated()), id: \.offset) { _, event in Text(event).font(.caption).textSelection(.enabled) }
                }
            } header: { Text("Connection") } footer: {
                Text("MowerBar \(AppInfo.version) · unofficial app, not affiliated with Worx or Positec. Commands go through the Worx cloud.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).task { await store.updateNotificationStatus() }
    }
    @ViewBuilder private func boundarySettings(_ mower: Mower) -> some View {
        let config = mower.config
        let enabled = store.canChangeSettings
        Section {
            if let torque = config.torque {
                let draft = torqueDraft ?? torque
                HStack {
                    Stepper(value: Binding(get: { draft }, set: { torqueDraft = $0 }), in: MowerSetting.torqueRange, step: 10) {
                        LabeledContent("Wheel torque", value: draft > 0 ? "+\(draft) %" : "\(draft) %")
                    }
                    Button("Apply") { settingConfirmation = .torque(draft) }.disabled(!enabled || draft == torque)
                }
            }
            if let rain = config.rainDelay {
                Picker("Delay after rain", selection: Binding(get: { rain }, set: { if $0 != rain { settingConfirmation = .rainDelay($0) } })) {
                    ForEach(Array(Set([0, 30, 60, 120, 180, 240, 360, 480, 720, rain])).sorted(), id: \.self) { minutes in
                        Text(minutes == 0 ? String(localized: "None") : Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))).tag(minutes)
                    }
                }.disabled(!enabled)
            }
            ForEach(config.slots, id: \.self) { slot in
                Toggle(isOn: Binding(get: { slot.edgeCut }, set: { settingConfirmation = .edgeCut(day: slot.day, second: slot.second, enabled: $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Calendar.current.weekdaySymbols[slot.day % 7].capitalizedFirst)
                        Text("\(slot.start) · \(Duration.seconds(slot.minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) · edge cut")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(!enabled)
            }
            if !enabled, let mower = store.mower { ControlHintView(hint: ControlHint(store: store, mower: mower), compact: true) }
            if let setting = store.pendingSetting {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Waiting for the mower to confirm: \(store.describe(setting))") }
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Fewer boundary exits") } footer: {
            Text("More wheel torque helps on slopes and wet grass, at the cost of more wear on the lawn: change it in steps of 10 and compare the activity log over a week or two. Turning off edge cutting on some slots shows whether exits happen during it. None of these settings moves the mower.")
                .foregroundStyle(.secondary)
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}
