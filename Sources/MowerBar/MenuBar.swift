import SwiftUI
import AppKit
import MowerBarCore

extension Telemetry {
    var symbol: String {
        if errorLabel != nil || state == 0 { return "exclamationmark.triangle.fill" }
        switch state {
        case 1: return charging ? "bolt.fill" : "house.fill"
        case 7, 32: return "leaf.fill"
        case 34: return "pause.fill"
        case 3, 4, 5, 6, 30, 33: return "location.north.fill"
        case nil: return "questionmark"
        default: return "gearshape.fill"
        }
    }
    var tint: Color {
        if errorLabel != nil || state == 0 { return .orange }
        switch state {
        case 7, 32: return .green
        case 1: return .blue
        case 34: return .yellow
        case nil: return .secondary
        default: return .teal
        }
    }
}

struct StateBadge: View {
    let telemetry: Telemetry, size: CGFloat
    var body: some View {
        Image(systemName: telemetry.symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(telemetry.tint)
            .frame(width: size, height: size).background(telemetry.tint.opacity(0.15), in: Circle())
    }
}

/// Why commands are (un)available right now, shared by the window and the menu bar panel.
enum ControlHint {
    case pending(MowerCommand), cloudOffline, robotOffline, unsupported, stale, error(String), ready
    @MainActor init(store: AppStore, mower: Mower) {
        let t = mower.telemetry
        if let command = store.pendingCommand { self = .pending(command) }
        else if !store.live { self = .cloudOffline }
        else if !mower.online { self = .robotOffline }
        else if mower.protocolVersion != 0 { self = .unsupported }
        else if !t.isFresh(now: store.clock) { self = .stale }
        else if let error = t.errorLabel { self = .error(error) }
        else { self = .ready }
    }
    var text: String {
        switch self {
        case .pending(let command): return String(localized: "\(command.label): waiting for the mower’s answer…")
        case .cloudOffline: return String(localized: "Reconnecting to the cloud. Commands come back as soon as the link is restored.")
        case .robotOffline: return String(localized: "The mower is offline: check its Wi-Fi and its base.")
        case .unsupported: return String(localized: "Commands are not supported yet for this model.")
        case .stale: return String(localized: "The state is more than 5 minutes old. Refresh it to unlock commands.")
        case .error(let error): return String(localized: "\(error): fix it on the mower before mowing again.")
        case .ready: return String(localized: "Every command asks for confirmation before it is sent.")
        }
    }
    var icon: String {
        switch self {
        case .pending: return "hourglass"
        case .cloudOffline: return "icloud.slash"
        case .robotOffline: return "wifi.slash"
        case .unsupported: return "nosign"
        case .stale: return "clock.arrow.circlepath"
        case .error: return "exclamationmark.triangle"
        case .ready: return "hand.raised"
        }
    }
    var isWarning: Bool { switch self { case .stale, .error: return true; default: return false } }
}

struct ControlHintView: View {
    @EnvironmentObject var store: AppStore
    let hint: ControlHint
    var compact = false
    var body: some View {
        switch hint {
        case .pending:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(hint.text) }.font(compact ? .caption : .callout).foregroundStyle(.secondary)
        case .stale:
            if compact {
                VStack(alignment: .leading, spacing: 6) { label; refreshButton }
            } else {
                HStack { label; Spacer(minLength: 12); refreshButton }
            }
        default: label
        }
    }
    private var label: some View {
        Label(hint.text, systemImage: hint.icon).font(compact ? .caption : .callout)
            .foregroundStyle(hint.isWarning ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var refreshButton: some View {
        Button("Refresh state") { Task { await store.refresh() } }.disabled(store.busy).controlSize(compact ? .small : .regular)
    }
}

/// Menu bar icon: the mower gets a warning badge when the robot reports an error.
struct MenuBarLabel: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Image(nsImage: store.mower?.telemetry.errorLabel != nil ? MowerGlyph.menuBarAlert : MowerGlyph.menuBar)
    }
}

struct MenuPanel: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Preference.menuBarIcon) private var showIcon = true
    @State private var armed: MowerCommand?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let mower = store.mower { robot(mower) }
            else if !store.sessionAvailable {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Worx account not connected", systemImage: "person.crop.circle.badge.exclamationmark").foregroundStyle(.secondary)
                    // The sign-in sheet lives on the main window, which may be closed: open it first.
                    Button { openMain(); store.showLogin = true } label: { Text("Connect my Worx account").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            else if store.busy { ProgressView("Looking for your mower…").controlSize(.small) }
            else { Label("No mower found", systemImage: "leaf").foregroundStyle(.secondary) }
            Divider()
            footer
        }
        .padding(14).frame(width: 300)
        .onAppear { Task { await store.refreshIfStale() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in Task { await store.refreshIfStale() } }
        .onChange(of: store.pendingCommand) { _, _ in armed = nil }
    }
    private func robot(_ mower: Mower) -> some View {
        let t = mower.telemetry
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StateBadge(telemetry: t, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mower.name).font(.headline).lineLimit(1)
                    Text(t.errorLabel ?? t.stateLabel).font(.callout).foregroundStyle(t.errorLabel != nil ? Color.orange : Color.secondary)
                }
                Spacer()
                if let battery = t.battery {
                    Label("\(battery) %", systemImage: t.charging ? "bolt.fill" : "battery.75percent").font(.callout).monospacedDigit()
                }
            }
            Group {
                if let date = t.date { Text("Updated \(date.formatted(.relative(presentation: .named)))") } else { Text("No state received yet") }
            }.font(.caption).foregroundStyle(.secondary)
            if let command = armed { confirm(command) } else { commands }
            ControlHintView(hint: ControlHint(store: store, mower: mower), compact: true)
        }
    }
    private var commands: some View {
        VStack(spacing: 6) {
            commandButton(.start, icon: "play.fill", enabled: store.canStart)
            commandButton(.pause, icon: "pause.fill", enabled: store.canPause)
            commandButton(.safeHome, icon: "house.fill", enabled: store.canHome)
        }
    }
    private func commandButton(_ command: MowerCommand, icon: String, enabled: Bool) -> some View {
        Button { armed = command } label: { Label(command.label, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.bordered).controlSize(.large).disabled(!enabled)
    }
    /// Two-step confirmation inside the panel: a system dialog would close the menu bar window.
    private func confirm(_ command: MowerCommand) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(command.label)?").font(.headline)
            Text(command == .start ? "Make sure the area is clear." : command == .pause ? "The mower stops where it is." : "Make sure the mower can move.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { armed = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Confirm") { armed = nil; Task { await store.send(command) } }
                    .buttonStyle(.borderedProminent).tint(command == .start ? .green : .accentColor).keyboardShortcut(.defaultAction)
            }.controlSize(.large)
        }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
    private func openMain() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open MowerBar") { openMain() }
            Spacer()
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh").disabled(store.busy || !store.sessionAvailable)
            Menu {
                Button("Hide the menu bar icon") { showIcon = false }
                Divider()
                Button("Quit MowerBar") { store.shutdown(); NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
}
