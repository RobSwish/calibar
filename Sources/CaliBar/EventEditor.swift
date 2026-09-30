import CaliBarCore
import SwiftUI

struct EventEditor: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: EventDraft
    @State private var discardPrompt = false
    @State private var showingCustomRepeat = false
    @State private var repeatBackup: EventRecurrence?
    @State private var newCustomAlertID: UUID?
    @State private var contentUnderHeader = false
    @FocusState private var titleFocused: Bool
    @Namespace private var scrollSpace
    @State private var original: EventDraft
    let close: () -> Void
    let saved: (CalendarEvent) -> Void

    init(model: CalendarModel, draft: EventDraft, close: @escaping () -> Void, saved: @escaping (CalendarEvent) -> Void) {
        self.model = model
        _draft = State(initialValue: draft)
        _original = State(initialValue: draft)
        self.close = close
        self.saved = saved
    }

    private var selectedCalendar: CalendarInfo? { model.writableCalendars.first { $0.id == draft.calendarID } }
    private var canSave: Bool { model.ready && selectedCalendar != nil && draft.validationMessage == nil && !model.isSavingEvent }
    private var editorAnimation: Animation { .easeInOut(duration: reduceMotion ? 0.1 : 0.2) }
    private var alertAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.1) : .smooth(duration: 0.2, extraBounce: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                cancelButton
                Text("New event").font(.system(size: 17, weight: .semibold))
                Spacer()
                if model.isSavingEvent { ProgressView().controlSize(.small).accessibilityLabel("Saving event") }
                saveButton
            }
            .padding(20)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
                    .opacity(contentUnderHeader ? 1 : 0)
                    .animation(.easeInOut(duration: reduceMotion ? 0 : 0.15), value: contentUnderHeader)
            }
            if let error = model.creationError ?? (draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft.validationMessage) {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 10)
                    .accessibilityLabel("Couldn’t save event. \(error)")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    titleFields
                        .padding(.bottom, 6)
                    if !model.ready {
                        Text("Enable Sync calendars in Settings to save this event.").foregroundStyle(.secondary)
                    } else if model.writableCalendars.isEmpty {
                        Text("No writable calendars. Add an account or calendar in Apple Calendar first.").foregroundStyle(.secondary)
                    }
                    dateFields
                    recurrenceFields
                    alertFields
                    if let calendar = selectedCalendar, !calendar.supportedAvailabilities.isEmpty {
                        card {
                            EditorRow("Show as") {
                                EditorDropdown("Show as", selection: $draft.availability, values: calendar.supportedAvailabilities) { $0.rawValue }
                            }
                        }
                    }
                    card {
                        field("URL", text: $draft.url, prompt: "https://")
                    }
                    card {
                        Text("Notes").foregroundStyle(.secondary)
                        TextField("Add notes", text: $draft.notes, axis: .vertical)
                            .lineLimit(4...12).textFieldStyle(.plain)
                            .accessibilityLabel("Notes")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Button { save(openInCalendar: true) } label: {
                            Label("Save and open in Apple Calendar", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.plain).foregroundStyle(.primary).disabled(!canSave)
                        Text("Add invitees, attachments, travel time or a FaceTime link in Apple Calendar.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 20).padding(.bottom, 24).padding(.top, 2)
                .disabled(model.isSavingEvent)
                .animation(editorAnimation, value: draft.isAllDay)
                .animation(editorAnimation, value: draft.calendarID)
                .animation(editorAnimation, value: draft.recurrence.frequency)
                .animation(editorAnimation, value: draft.recurrence.usesOrdinal)
                .animation(editorAnimation, value: draft.recurrence.ending)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: EditorScrolledKey.self,
                            value: geometry.frame(in: .named(scrollSpace)).minY < -0.5)
                    }
                }
            }
            .coordinateSpace(name: scrollSpace)
            .onPreferenceChange(EditorScrolledKey.self) { contentUnderHeader = $0 }
        }
        .frame(maxHeight: .infinity)
        .onChange(of: draft) { _, value in
            if model.eventDraft != nil { model.eventDraft = value }
            model.creationError = nil
        }
        .onChange(of: draft.calendarID) { _, _ in
            if let values = selectedCalendar?.supportedAvailabilities, !values.contains(draft.availability), let first = values.first { draft.availability = first }
        }
        .task {
            guard !model.isScreenshot else { return }
            try? await Task.sleep(for: .milliseconds(180))
            if !Task.isCancelled { titleFocused = true }
        }
        .alert("Discard this event?", isPresented: $discardPrompt) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard", role: .destructive) { discard() }
        } message: { Text("Your event hasn’t been added to the calendar.") }
    }

    private var titleFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            EditorDropdown("Calendar", selection: $draft.calendarID, options: calendarOptions, inline: true)
            TextField("Event title", text: $draft.title, axis: .vertical)
                .font(.system(size: 23, weight: .semibold)).lineLimit(1...4)
                .textFieldStyle(.plain).focused($titleFocused).accessibilityLabel("Event title")
            TextField("Location or video call", text: Binding(
                get: { draft.meetingURL.isEmpty ? draft.location : draft.meetingURL },
                set: { draft.location = $0; draft.meetingURL = "" }
            ), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...3).accessibilityLabel("Location or video call")
        }
        .padding(.leading, 14)
        .overlay(alignment: .leading) {
            Capsule().fill(selectedCalendar?.color ?? .red).frame(width: 4)
        }
    }

    private var calendarOptions: [EditorDropdownOption<String>] {
        let groups = Dictionary(grouping: model.writableCalendars, by: \.sourceID)
        var seen = Set<String>()
        return model.writableCalendars.flatMap { calendar -> [EditorDropdownOption<String>] in
            guard seen.insert(calendar.sourceID).inserted else { return [] }
            return (groups[calendar.sourceID] ?? []).map {
                EditorDropdownOption(id: $0.id, title: $0.title, groupID: $0.sourceID,
                                     groupTitle: $0.sourceName, color: $0.color)
            }
        }
    }

    private var dateFields: some View {
        card {
            HStack {
                Text("All day").accessibilityHidden(true)
                Spacer()
                Toggle("All day", isOn: Binding(get: { draft.isAllDay }, set: { draft.setAllDay($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(.red)
            }
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5).accessibilityHidden(true)
            EditorRow("Starts") {
                DatePicker("Starts", selection: Binding(get: { draft.start }, set: { draft.moveStart(to: $0) }), displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    .datePickerStyle(.field).controlSize(.regular).font(.system(size: 13)).fixedSize()
            }
            EditorRow("Ends") {
                DatePicker("Ends", selection: $draft.end, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    .datePickerStyle(.field).controlSize(.regular).font(.system(size: 13)).fixedSize()
            }
            if !draft.isAllDay {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5).accessibilityHidden(true)
                EditorRow("Time zone") {
                    EditorDropdown("Time zone", selection: Binding(get: { draft.timeZoneID }, set: { draft.changeTimeZone(to: $0) }),
                                   values: [""] + TimeZone.knownTimeZoneIdentifiers) {
                        $0.isEmpty ? "Floating" : $0.replacingOccurrences(of: "_", with: " ")
                    }
                    .frame(maxWidth: 190, alignment: .trailing)
                }
            }
        }
        .environment(\.timeZone, draft.calendar.timeZone)
    }

    private var recurrenceFields: some View {
        card {
            EditorRow("Repeat") {
                EditorDropdown("Repeat", selection: Binding(get: { repeatChoice }, set: chooseRepeat),
                    options: RepeatChoice.allCases.map { .init(id: $0, title: $0.rawValue, separatorBefore: $0 == .custom) })
                    .popover(isPresented: $showingCustomRepeat) {
                        VStack(alignment: .leading, spacing: 12) {
                            EditorRow("Frequency") {
                                EditorDropdown("Frequency", selection: $draft.recurrence.frequency,
                                    values: EventRecurrence.Frequency.allCases.filter { $0 != .never }) { $0.rawValue }
                            }
                            customRepeatFields
                            HStack {
                                Spacer()
                                Button("Cancel") {
                                    if let repeatBackup { draft.recurrence = repeatBackup }
                                    self.repeatBackup = nil
                                    showingCustomRepeat = false
                                }
                                Button("OK") { repeatBackup = nil; showingCustomRepeat = false }
                                    .disabled(draft.recurrence.validationMessage(start: draft.start, calendar: draft.calendar) != nil)
                            }
                        }
                        .font(.system(size: 13)).padding(16).frame(width: 320)
                    }
            }
            if draft.recurrence.frequency != .never {
                EditorRow("End repeat") {
                    EditorDropdown("End repeat", selection: $draft.recurrence.ending, values: EventRecurrence.Ending.allCases) { $0 == .onDate ? "On Date…" : ($0 == .after ? "After…" : "Never") }
                }
                if draft.recurrence.ending == .onDate {
                    EditorRow("Last day") {
                        DatePicker("Last day", selection: $draft.recurrence.until, in: draft.start..., displayedComponents: .date)
                            .datePickerStyle(.field).controlSize(.regular).font(.system(size: 13))
                            .environment(\.timeZone, draft.calendar.timeZone).fixedSize()
                    }
                } else if draft.recurrence.ending == .after {
                    Stepper(value: $draft.recurrence.count, in: 1...9999) {
                        HStack(spacing: 6) {
                            TextField("Count", value: $draft.recurrence.count, format: .number)
                                .frame(width: 50).accessibilityLabel("Number of occurrences")
                            Text("occurrences")
                        }
                    }
                }
            }
        }
        .onChange(of: showingCustomRepeat) { _, open in
            if !open, let repeatBackup { draft.recurrence = repeatBackup; self.repeatBackup = nil }
        }
    }

    private var customRepeatFields: some View {
        VStack(alignment: .leading, spacing: 10) {
                Stepper(value: $draft.recurrence.interval, in: 1...999) {
                    HStack(spacing: 6) {
                        Text("Every")
                        TextField("Interval", value: $draft.recurrence.interval, format: .number)
                            .frame(width: 42).accessibilityLabel("Repeat interval")
                        Text(repeatUnit)
                    }
                }
                if draft.recurrence.frequency == .weekly {
                    weekdaySelection
                }
                if draft.recurrence.frequency == .monthly {
                    EditorRow("On") {
                        EditorDropdown("On", selection: $draft.recurrence.usesOrdinal, values: [false, true]) { $0 ? "A weekday pattern" : "Days of the month" }
                    }
                    if draft.recurrence.usesOrdinal { ordinalFields }
                    else {
                        selectionGrid(values: Array(1...31), selected: $draft.recurrence.monthDays, columns: 7) { String($0) }
                        Text(draft.recurrence.monthDays.isEmpty ? "On the event’s day of the month." : "Months without a selected date are skipped.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if draft.recurrence.frequency == .yearly {
                    selectionGrid(values: Array(1...12), selected: $draft.recurrence.months, columns: 4) { DateFormatter().shortMonthSymbols[$0 - 1] }
                    HStack {
                        Text("On a weekday pattern").accessibilityHidden(true)
                        Spacer()
                        Toggle("On a weekday pattern", isOn: $draft.recurrence.usesOrdinal)
                            .labelsHidden().toggleStyle(.switch).tint(.red)
                    }
                    if draft.recurrence.usesOrdinal { ordinalFields }
                }
        }
    }

    private var repeatChoice: RepeatChoice {
        let r = draft.recurrence
        if r.frequency == .never { return .never }
        if r.interval != 1 || !r.weekdays.isEmpty || !r.monthDays.isEmpty || !r.months.isEmpty || r.usesOrdinal { return .custom }
        return RepeatChoice(frequency: r.frequency)
    }
    private func chooseRepeat(_ choice: RepeatChoice) {
        if choice == .custom {
            repeatBackup = draft.recurrence
            if draft.recurrence.frequency == .never { draft.recurrence.frequency = .daily }
            showingCustomRepeat = true
        } else {
            let ending = draft.recurrence
            draft.recurrence = EventRecurrence()
            draft.recurrence.frequency = choice.frequency
            draft.recurrence.ending = ending.ending
            draft.recurrence.until = ending.until
            draft.recurrence.count = ending.count
        }
    }

    private var repeatUnit: String {
        switch draft.recurrence.frequency { case .daily: draft.recurrence.interval == 1 ? "day" : "days"; case .weekly: draft.recurrence.interval == 1 ? "week" : "weeks"; case .monthly: draft.recurrence.interval == 1 ? "month" : "months"; default: draft.recurrence.interval == 1 ? "year" : "years" }
    }
    private var weekdaySelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            selectionGrid(values: (0..<7).map { (Calendar.current.firstWeekday - 1 + $0) % 7 + 1 }, selected: $draft.recurrence.weekdays, columns: 7) { DateFormatter().shortWeekdaySymbols[$0 - 1] }
            if draft.recurrence.weekdays.isEmpty { Text("On the event’s weekday.").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
    private var ordinalFields: some View {
        VStack(spacing: 10) {
            EditorRow("Position") {
                EditorDropdown("Position", selection: $draft.recurrence.ordinal, values: [1, 2, 3, 4, 5, -1]) { [1: "First", 2: "Second", 3: "Third", 4: "Fourth", 5: "Fifth", -1: "Last"][$0] ?? "First" }
            }
            EditorRow("Day") {
                EditorDropdown("Day", selection: $draft.recurrence.ordinalDay, values: Array(1...10)) { $0 <= 7 ? DateFormatter().weekdaySymbols[$0 - 1] : [8: "Day", 9: "Weekday", 10: "Weekend day"][$0]! }
            }
        }
    }

    private var alertFields: some View {
        card {
            ZStack(alignment: .topLeading) {
                if draft.alerts.isEmpty {
                    EditorRow("Alert") {
                        EditorDropdown("Alert", selection: Binding(get: { -1 }, set: { value in
                            guard value != -1 else { return }
                            addAlert(preset: value)
                        }), options: alertPresetOptions)
                    }
                    .transition(.opacity)
                }
                VStack(spacing: 10) {
                    ForEach(draft.alerts) { alert in
                        EventAlertRow(alert: alertBinding(for: alert), initiallyCustom: newCustomAlertID == alert.id,
                                      showsRemoveButton: draft.alerts.count > 1) {
                            withAnimation(alertAnimation) {
                                draft.alerts.removeAll { $0.id == alert.id }
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
            if !draft.alerts.isEmpty {
                HStack {
                    Spacer()
                    Button { addAlert(preset: 15) } label: {
                        Image(systemName: "plus.circle")
                    }.buttonStyle(.plain).accessibilityLabel("Add alert")
                }
                .transition(.opacity)
            }
        }
    }

    private func addAlert(preset: Int) {
        var alert = EventAlert(date: draft.start.addingTimeInterval(-900))
        if preset == -2 { newCustomAlertID = alert.id } else { alert.applyPreset(preset) }
        withAnimation(alertAnimation) { draft.alerts.append(alert) }
    }

    private func alertBinding(for snapshot: EventAlert) -> Binding<EventAlert> {
        Binding(get: {
            // Keep the departing row's content stable until its fade completes.
            draft.alerts.first { $0.id == snapshot.id } ?? snapshot
        }, set: { value in
            guard let index = draft.alerts.firstIndex(where: { $0.id == snapshot.id }) else { return }
            draft.alerts[index] = value
        })
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.plain).accessibilityLabel(title)
        }
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .pickerStyle(.menu).controlSize(.small).tint(.primary)
    }
    private func selectionGrid(values: [Int], selected: Binding<Set<Int>>, columns: Int, title: @escaping (Int) -> String) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columns), spacing: 5) {
            ForEach(values, id: \.self) { value in
                Button {
                    if selected.wrappedValue.contains(value) { selected.wrappedValue.remove(value) }
                    else { selected.wrappedValue.insert(value) }
                } label: {
                    Text(title(value)).font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 27)
                        .foregroundStyle(selected.wrappedValue.contains(value) ? Color.white : .primary)
                        .background(selected.wrappedValue.contains(value) ? Color.red : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).accessibilityAddTraits(selected.wrappedValue.contains(value) ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var cancelButton: some View {
        let button = Button {
            if draft != original { discardPrompt = true } else { discard() }
        } label: {
            Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary).frame(width: 32, height: 32).contentShape(Circle())
        }.buttonStyle(.plain).disabled(model.isSavingEvent).accessibilityLabel("Cancel new event")
        if #available(macOS 26, *) { button.glassEffect(.clear.interactive(), in: Circle()) }
        else { button.background(.ultraThinMaterial, in: Circle()) }
    }
    @ViewBuilder private var saveButton: some View {
        let button = Button { save() } label: {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white).frame(width: 32, height: 32).contentShape(Circle())
        }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSave).accessibilityLabel("Add event").help("Add event (⌘Return)")
        if #available(macOS 26, *) { button.glassEffect(.regular.tint(.red).interactive(), in: Circle()).opacity(canSave ? 1 : 0.4) }
        else { button.background(.red, in: Circle()).opacity(canSave ? 1 : 0.4) }
    }
    private func discard() { model.eventDraft = nil; model.creationError = nil; close() }
    private func save(openInCalendar: Bool = false) {
        model.eventDraft = draft
        Task { @MainActor in
            if let event = await model.saveEvent() {
                saved(event)
                if openInCalendar { model.openCalendar(event: event) }
            }
        }
    }
}

private struct AlertEditor: View {
    @Binding var alert: EventAlert
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorRow("Type") {
                EditorDropdown("Type", selection: $alert.action, values: EventAlert.Action.allCases) { $0.rawValue }
            }
            if alert.action == .email { TextField("Email address", text: $alert.email).accessibilityLabel("Alert email address") }
            if alert.action == .sound {
                EditorRow("Sound") {
                    EditorDropdown("Sound", selection: $alert.sound, values: ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]) { $0 }
                }
            }
            EditorRow("When") {
                EditorDropdown("When", selection: $alert.timing, values: EventAlert.Timing.allCases) { $0.rawValue }
            }
            if alert.timing == .onDate {
                EditorRow("At") {
                    DatePicker("At", selection: $alert.date).datePickerStyle(.field).controlSize(.regular).font(.system(size: 13)).fixedSize()
                }
            } else {
                HStack {
                    Stepper(value: $alert.amount, in: 0...999) {
                        TextField("Amount", value: $alert.amount, format: .number)
                            .frame(width: 42).accessibilityLabel("Alert interval")
                    }
                    EditorDropdown("Unit", selection: $alert.unit, values: EventAlert.Unit.allCases) { $0.title }
                }
            }
        }
    }
}

private struct EditorScrolledKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct EditorRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).fixedSize().accessibilityHidden(true)
            Spacer(minLength: 8)
            content().labelsHidden()
        }
    }
}

private enum RepeatChoice: String, CaseIterable {
    case never = "Never", daily = "Every Day", weekly = "Every Week", monthly = "Every Month", yearly = "Every Year", custom = "Custom…"
    var frequency: EventRecurrence.Frequency {
        switch self { case .never: .never; case .daily, .custom: .daily; case .weekly: .weekly; case .monthly: .monthly; case .yearly: .yearly }
    }
    init(frequency: EventRecurrence.Frequency) {
        switch frequency { case .never: self = .never; case .daily: self = .daily; case .weekly: self = .weekly; case .monthly: self = .monthly; case .yearly: self = .yearly }
    }
}

@MainActor private var alertPresetOptions: [EditorDropdownOption<Int>] { [
    .init(id: -1, title: "None"), .init(id: 0, title: "At time of event"),
    .init(id: 5, title: "5 minutes before"), .init(id: 10, title: "10 minutes before"),
    .init(id: 15, title: "15 minutes before"), .init(id: 30, title: "30 minutes before"),
    .init(id: 60, title: "1 hour before"), .init(id: 120, title: "2 hours before"),
    .init(id: 1440, title: "1 day before"), .init(id: 2880, title: "2 days before"),
    .init(id: -2, title: "Custom…", separatorBefore: true)
] }

@MainActor private extension EventAlert {
    var preset: Int {
        let minutes = amount * unit.rawValue / 60
        return action == .message && timing == .before && alertPresetOptions.contains(where: { $0.id == minutes }) ? minutes : -2
    }
    mutating func applyPreset(_ minutes: Int) {
        action = .message
        timing = .before
        if minutes >= 1440 { amount = minutes / 1440; unit = .days }
        else if minutes >= 60 { amount = minutes / 60; unit = .hours }
        else { amount = minutes; unit = .minutes }
    }
}

private struct EventAlertRow: View {
    @Binding var alert: EventAlert
    let remove: () -> Void
    let showsRemoveButton: Bool
    @State private var showingCustom = false
    @State private var backup: EventAlert?
    @State private var newCustom: Bool
    let initiallyCustom: Bool

    init(alert: Binding<EventAlert>, initiallyCustom: Bool, showsRemoveButton: Bool, remove: @escaping () -> Void) {
        _alert = alert
        self.initiallyCustom = initiallyCustom
        self.showsRemoveButton = showsRemoveButton
        _newCustom = State(initialValue: initiallyCustom)
        self.remove = remove
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Alert").accessibilityHidden(true)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).accessibilityLabel("Remove alert")
                .opacity(showsRemoveButton ? 1 : 0)
                .disabled(!showsRemoveButton)
                .accessibilityHidden(!showsRemoveButton)
            Spacer(minLength: 8)
            EditorDropdown("Alert", selection: Binding(get: { alert.preset }, set: { value in
                if value == -1 { remove() }
                else if value == -2 { backup = alert; showingCustom = true }
                else { alert.applyPreset(value) }
            }), options: alertPresetOptions)
            .popover(isPresented: $showingCustom) {
                VStack(spacing: 14) {
                    AlertEditor(alert: $alert)
                    HStack {
                        Spacer()
                        Button("Cancel") { showingCustom = false }
                        Button("OK") { backup = nil; newCustom = false; showingCustom = false }
                    }
                }.font(.system(size: 13)).padding(16).frame(width: 310)
            }
        }
        .task {
            guard initiallyCustom else { return }
            // Anchor the custom editor only after its newly inserted row settles.
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            backup = alert
            showingCustom = true
        }
        .onChange(of: showingCustom) { _, open in
            if !open {
                if let backup { alert = backup; self.backup = nil }
                if newCustom { newCustom = false; remove() }
            }
        }
    }
}
