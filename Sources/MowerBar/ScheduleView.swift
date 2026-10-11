import SwiftUI
import MowerBarCore

/// Day names, clock times and durations for the weekly schedule (day 0 is Sunday, as sent by the mower).
enum ScheduleText {
    static func day(_ index: Int) -> String { Calendar.current.weekdaySymbols[index % 7].capitalizedFirst }
    static func shortDay(_ index: Int) -> String { Calendar.current.shortWeekdaySymbols[index % 7].capitalizedFirst }
    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    static func duration(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
    /// Columns in the order of the user's week (Monday first in France).
    static var weekOrder: [Int] { let first = Calendar.current.firstWeekday - 1; return (0..<7).map { (first + $0) % 7 } }
}

struct SlotDraft: Identifiable {
    var day: Int, second: Bool, isNew: Bool
    var start: Date, minutes: Int, edgeCut: Bool
    var id: String { "\(day)-\(second)" }

    init(_ slot: ScheduleSlot, isNew: Bool) {
        day = slot.day; second = slot.second; self.isNew = isNew
        start = Calendar.current.date(bySettingHour: slot.startMinutes / 60, minute: slot.startMinutes % 60, second: 0, of: Date()) ?? Date()
        minutes = slot.minutes; edgeCut = slot.edgeCut
    }
    var startMinutes: Int { let c = Calendar.current.dateComponents([.hour, .minute], from: start); return (c.hour ?? 0) * 60 + (c.minute ?? 0) }
    var slot: ScheduleSlot { ScheduleSlot(day: day, second: second, start: ScheduleText.clock(startMinutes), minutes: minutes, edgeCut: edgeCut) }
    var fitsInDay: Bool { startMinutes + minutes <= 1440 }
}

struct ScheduleView: View {
    @EnvironmentObject var store: AppStore
    @State private var editing: SlotDraft?
    private let gridHeight: CGFloat = 440

    var body: some View {
        ScrollView {
            if let mower = store.mower, mower.protocolVersion == 0, mower.config.schedule != nil {
                VStack(alignment: .leading, spacing: 16) {
                    summary(mower.config.slots)
                    weekGrid(mower.config)
                    if !store.canChangeSettings { ControlHintView(hint: ControlHint(store: store, mower: mower)) }
                    if let setting = store.pendingSetting {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Waiting for the mower to confirm: \(store.describe(setting))") }
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Click a slot to change its hours or edge cutting, or + to add one. Each day has up to two slots. Changes are sent to the mower, which keeps the schedule itself; they never make it move.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(24).frame(maxWidth: 980).frame(maxWidth: .infinity)
            } else if store.mower == nil {
                ContentUnavailableView("No mower found", systemImage: "leaf", description: Text("Refresh or reconnect your Worx account."))
            } else {
                ContentUnavailableView("Schedule not available", systemImage: "calendar",
                    description: Text("The schedule has not been received yet, or this model is not supported. Refresh to try again."))
            }
        }
        .sheet(item: $editing) { draft in
            SlotEditor(draft: draft, canDelete: !draft.isNew) { setting in
                editing = nil
                Task { await store.apply(setting) }
            }
        }
    }

    private func summary(_ slots: [ScheduleSlot]) -> some View {
        let total = slots.reduce(0) { $0 + $1.minutes }
        let edges = slots.filter(\.edgeCut).count
        return HStack(spacing: 24) {
            stat(ScheduleText.duration(total), String(localized: "of mowing per week"))
            stat("\(slots.count)", String(localized: "slots"))
            stat("\(edges)", String(localized: "with edge cut"))
            Spacer()
        }
    }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Week grid

    /// Hours shown: the slots' span with an hour of margin, at least 08:00–20:00.
    private func hourRange(_ slots: [ScheduleSlot]) -> ClosedRange<Int> {
        let first = slots.map { $0.startMinutes / 60 }.min() ?? 8
        let last = slots.map { ($0.endMinutes + 59) / 60 }.max() ?? 20
        return max(0, min(first - 1, 8))...min(24, max(last + 1, 20))
    }
    private func weekGrid(_ config: MowerConfig) -> some View {
        let range = hourRange(config.slots)
        let y: (Int) -> CGFloat = { minutes in
            CGFloat(minutes - range.lowerBound * 60) / CGFloat((range.upperBound - range.lowerBound) * 60) * gridHeight
        }
        return HStack(alignment: .top, spacing: 6) {
            // Hour axis, aligned with the columns below their headers.
            VStack(spacing: 0) {
                Color.clear.frame(height: 34)
                ZStack(alignment: .topTrailing) {
                    ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: 2)), id: \.self) { hour in
                        Text(ScheduleText.clock(hour * 60)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            .offset(y: y(hour * 60) - 6)
                    }
                }.frame(width: 40, height: gridHeight, alignment: .topTrailing)
            }
            ForEach(ScheduleText.weekOrder, id: \.self) { day in
                dayColumn(day, config: config, range: range, y: y)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.07), lineWidth: 1))
    }
    private func dayColumn(_ day: Int, config: MowerConfig, range: ClosedRange<Int>, y: @escaping (Int) -> CGFloat) -> some View {
        let slots = config.slots.filter { $0.day == day }
        let free = config.freePosition(day: day)
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(ScheduleText.shortDay(day)).font(.subheadline.bold())
                Spacer(minLength: 0)
                Button { addSlot(day: day, second: free ?? false, after: slots) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Add a slot")
                    .disabled(free == nil || !store.canChangeSettings)
            }.frame(height: 26).padding(.horizontal, 4).padding(.bottom, 8)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35))
                ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: 2)), id: \.self) { hour in
                    Rectangle().fill(.primary.opacity(0.06)).frame(height: 1).offset(y: y(hour * 60))
                }
                ForEach(slots, id: \.self) { slot in
                    slotBlock(slot, height: max(y(slot.endMinutes) - y(slot.startMinutes), 30))
                        .offset(y: y(slot.startMinutes))
                }
            }.frame(height: gridHeight, alignment: .top).clipped()
        }.frame(maxWidth: .infinity)
    }
    private func slotBlock(_ slot: ScheduleSlot, height: CGFloat) -> some View {
        Button { editing = SlotDraft(slot, isNew: false) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(slot.start)–\(ScheduleText.clock(slot.endMinutes))").font(.caption.bold()).monospacedDigit()
                Text(ScheduleText.duration(slot.minutes)).font(.caption2)
                if slot.edgeCut { Label("Edge cut", systemImage: "scissors").font(.caption2) }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white).padding(6)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(Color.green.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).padding(.horizontal, 3)
        .help(store.canChangeSettings ? String(localized: "Edit this slot") : String(localized: "Refresh the mower’s state to edit"))
        .disabled(!store.canChangeSettings)
    }
    private func addSlot(day: Int, second: Bool, after slots: [ScheduleSlot]) {
        // Start a new second slot after the existing one; otherwise in the morning.
        let start = min(slots.map(\.endMinutes).max().map { $0 + 30 } ?? 9 * 60, 22 * 60)
        editing = SlotDraft(ScheduleSlot(day: day, second: second, start: ScheduleText.clock(start), minutes: 120, edgeCut: false), isNew: true)
    }
}

struct SlotEditor: View {
    @State var draft: SlotDraft
    let canDelete: Bool
    let send: (MowerSetting) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.isNew ? String(localized: "New slot · \(ScheduleText.day(draft.day))") : ScheduleText.day(draft.day)).font(.title3.bold())
            Form {
                DatePicker("Start", selection: $draft.start, displayedComponents: .hourAndMinute)
                Stepper(value: $draft.minutes, in: 15...1440, step: 15) {
                    LabeledContent("Duration", value: ScheduleText.duration(draft.minutes))
                }
                LabeledContent("End", value: draft.fitsInDay ? ScheduleText.clock(draft.startMinutes + draft.minutes) : "—")
                Toggle("Edge cut at the start of the slot", isOn: $draft.edgeCut)
            }.formStyle(.grouped).frame(height: 230)
            if !draft.fitsInDay {
                Label("A slot must end before midnight.", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            Text("The schedule is sent to the mower. It will not move now.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if canDelete { Button("Delete", role: .destructive) { confirmDelete = true } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send to the mower") { send(.slot(draft.slot)) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!draft.fitsInDay)
            }
        }
        .padding(20).frame(width: 400)
        .confirmationDialog("Delete this slot?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { send(.removeSlot(day: draft.day, second: draft.second)) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The mower will no longer mow at this time.") }
    }
}
