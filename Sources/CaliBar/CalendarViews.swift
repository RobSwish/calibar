import CaliBarCore
import SwiftUI

struct CalendarPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: CalendarModel
    @State private var showingSettings = false
    @State private var selectedEventID: String?
    @Namespace private var agendaScrollSpace
    @State private var eventsUnderDayHeader = false
    @State private var refreshIndicatorStarted: ContinuousClock.Instant?

    init(model: CalendarModel) {
        self.model = model
        let arguments = ProcessInfo.processInfo.arguments
        _showingSettings = State(initialValue: model.isDemo && arguments.contains("--demo-settings"))
        _selectedEventID = State(initialValue:
            model.isDemo && arguments.contains("--demo-event") ? model.selectedEvents.first?.id : nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let draft = model.eventDraft {
                    EventEditor(model: model, draft: draft, close: { selectedEventID = nil }, saved: { selectedEventID = $0.id })
                        .transition(eventTransition)
                } else if showingSettings {
                    CalendarSettings(model: model) { showingSettings = false }
                        .transition(eventTransition)
                } else if !model.ready {
                    WelcomeView(model: model)
                        .transition(eventTransition)
                } else {
                    eventNavigation
                        .transition(eventTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.15), value: showingSettings)
            footer
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 0.5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
        .frame(width: 368, height: 640)
        .background {
            // Match Eluma's light touch of contrast over the native glass.
            (colorScheme == .dark ? Color.black : Color.white)
                .opacity(0.2)
                .allowsHitTesting(false)
        }
        .tint(.red)
        // This transient panel remains active while one of its dropdowns owns
        // keyboard focus. Do not fade the form into its inactive appearance.
        .environment(\.controlActiveState, .active)
        .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.15), value: model.eventDraft != nil)
        .task(id: model.isLoading) {
            if model.isLoading {
                refreshIndicatorStarted = .now
            } else if let started = refreshIndicatorStarted {
                let remaining = Duration.seconds(2) - started.duration(to: .now)
                if remaining > .zero {
                    do { try await Task.sleep(for: remaining) }
                    catch { return }
                }
                guard !Task.isCancelled, !model.isLoading else { return }
                refreshIndicatorStarted = nil
            }
        }
        .alert("CaliBar", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var eventNavigation: some View {
        ZStack {
            if let id = selectedEventID {
                Group {
                    if let event = model.visibleEvents.first(where: { $0.id == id }) {
                        EventDetails(event: event, model: model) { selectedEventID = nil }
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "calendar.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                            Text("This event is no longer available.")
                            Button("Back to Calendar") { selectedEventID = nil }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(eventTransition)
                .zIndex(1)
            } else {
                agenda
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(eventTransition)
                    .zIndex(0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.15), value: selectedEventID)
    }

    private var eventTransition: AnyTransition {
        reduceMotion ? .opacity : .modifier(
            active: EventBlurFade(progress: 0),
            identity: EventBlurFade(progress: 1)
        )
    }

    private var agenda: some View {
        VStack(spacing: 0) {
            MonthView(model: model)
                .padding(.top, 20).padding(.bottom, 12)
            HStack {
                Text(dayTitle).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(model.selectedEvents.count) \(model.selectedEvents.count == 1 ? "event" : "events")")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary).padding(.horizontal, 22).padding(.top, 17).padding(.bottom, 9)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 0.5)
                        .padding(.horizontal, 20)
                        .opacity(eventsUnderDayHeader && !model.selectedEvents.isEmpty ? 1 : 0)
                        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.18), value: eventsUnderDayHeader)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            if model.selectedEvents.isEmpty {
                Text(emptyTitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.selectedEvents) { event in
                            ZStack(alignment: Alignment(horizontal: .trailing, vertical: .eventTimeCenter)) {
                                Button { selectedEventID = event.id } label: {
                                    EventRow(event: event, now: model.now, timeColumnWidth: eventTimeColumnWidth)
                                }.buttonStyle(EventRowStyle())
                                if let meeting = event.meeting {
                                    Button("Join") {
                                        model.joinCall(meeting.url)
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .buttonStyle(JoinCallButtonStyle())
                                    .help(model.isDemo ? "Joining is disabled for preview events" : "Join on \(meeting.provider)")
                                    .accessibilityLabel("Join \(event.title)")
                                    .disabled(model.isDemo && !model.isScreenshot)
                                    .frame(width: 44)
                                    .padding(.trailing, eventTimeColumnWidth + 18)
                                }
                            }
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 10)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ContentUnderHeaderKey.self,
                                    value: geometry.frame(in: .named(agendaScrollSpace)).minY < -0.5
                                )
                            }
                        }
                }
                .coordinateSpace(name: agendaScrollSpace)
                .onPreferenceChange(ContentUnderHeaderKey.self) { eventsUnderDayHeader = $0 }
                .onDisappear { eventsUnderDayHeader = false }
                .id(model.selectedDate)
            }
        }
        .background(CalendarMonthSwipeArea(
            isEnabled: selectedEventID == nil && !showingSettings && model.eventDraft == nil,
            moveMonth: { model.moveMonth($0) }
        ))
    }

    private var dayTitle: String {
        let prefix = Calendar.current.isDateInToday(model.selectedDate) ? "Today · " : ""
        return prefix + model.selectedDate.formatted(.dateTime.weekday(.wide).day())
    }

    private var eventTimeColumnWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let labels = model.selectedEvents.flatMap { event in
            event.isAllDay ? ["all-day"] : [
                event.start.formatted(date: .omitted, time: .shortened),
                event.end.formatted(date: .omitted, time: .shortened)
            ]
        }
        return ceil(labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
    }
    private var emptyTitle: String {
        if model.isLoading { return "Loading calendars…" }
        if model.calendars.isEmpty { return "No calendars found" }
        if model.calendars.allSatisfy({ model.excludedIDs.contains($0.id) }) { return "No calendars selected" }
        return "No events"
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if !showingSettings && model.eventDraft == nil {
                Button { model.beginEvent(); selectedEventID = nil } label: {
                    Image(systemName: "plus").foregroundStyle(footerIconColor)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!model.ready)
                .keyboardShortcut("n")
                .help("New event (⌘N)").accessibilityLabel("New event")
            }
            if refreshIndicatorStarted != nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing calendars")
                    .transition(eventTransition)
            }
            Spacer()
            if model.isDemo && !model.isScreenshot { Text("Preview").font(.system(size: 10)).foregroundStyle(.tertiary) }
            Button { model.openCalendar(event: footerEvent) } label: {
                Image(systemName: "arrow.up.forward.app").foregroundStyle(footerIconColor)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .disabled(model.eventDraft != nil)
                .help(footerEvent == nil ? "Open Apple Calendar" : "Open event in Apple Calendar")
                .accessibilityLabel(footerEvent == nil ? "Open Apple Calendar" : "Open event in Apple Calendar")
            Menu {
                Button("Settings…") { selectedEventID = nil; showingSettings = true }
                    .disabled(model.eventDraft != nil)
                    .keyboardShortcut(",")
                Divider()
                Button("Refresh Calendars", systemImage: "arrow.clockwise") { model.refresh(remote: true) }
                    .keyboardShortcut("r")
                    .disabled(!model.ready)
                Divider()
                CheckForUpdatesButton(updater: model.updates)
                Divider()
                Button("Quit CaliBar") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(footerIconColor)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
                .menuStyle(.button).buttonStyle(.plain)
                .menuIndicator(.hidden).fixedSize().accessibilityLabel("More options")
                .tint(footerIconColor)
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .padding(.horizontal, 14).frame(height: 44)
        .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.15), value: refreshIndicatorStarted != nil)
    }

    private var footerIconColor: Color { Color(nsColor: .secondaryLabelColor) }

    private var footerEvent: CalendarEvent? {
        guard model.eventDraft == nil, !showingSettings, model.ready, let id = selectedEventID else { return nil }
        return model.visibleEvents.first { $0.id == id }
    }
}

private struct EventBlurFade: AnimatableModifier {
    nonisolated var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .blur(radius: 6 * (1 - progress))
            .opacity(progress)
    }
}

struct MonthView: View {
    @ObservedObject var model: CalendarModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private var weekdays: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.displayedMonth.formatted(.dateTime.month(.wide)))
                        .font(.system(size: 23, weight: .bold)).foregroundStyle(.primary)
                    Text(model.displayedMonth.formatted(.dateTime.year()))
                        .font(.system(size: 23, weight: .light)).foregroundStyle(.primary)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Button { model.moveMonth(-1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24)
                    }.accessibilityLabel("Previous month")
                    Button { model.today() } label: {
                        Text("Today").font(.system(size: 11)).padding(.horizontal, 11).frame(height: 24)
                    }
                    Button { model.moveMonth(1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24)
                    }.accessibilityLabel("Next month")
                }
                .buttonStyle(CalendarNavigationButtonStyle())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(height: 20)
                        .accessibilityHidden(true)
                }
                ForEach(model.days, id: \.self) { date in
                    DayCell(date: date, selectedDate: model.selectedDate, month: model.displayedMonth,
                            colors: eventColors(on: date)) { model.selectDate(date) }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private func eventColors(on date: Date) -> [Color] {
        var seen = Set<String>()
        return model.visibleEvents.filter { $0.occurs(on: date) && seen.insert($0.calendar.id).inserted }
            .prefix(3).map { $0.calendar.color }
    }
}

private struct CalendarNavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(Color(nsColor: .labelColor).opacity(configuration.isPressed ? 0.20 : 0.12), in: Capsule())
            .contentShape(Capsule())
    }
}

private struct DayCell: View {
    let date: Date
    let selectedDate: Date
    let month: Date
    let colors: [Color]
    let action: () -> Void
    private var selected: Bool { Calendar.current.isDate(date, inSameDayAs: selectedDate) }
    private var today: Bool { Calendar.current.isDateInToday(date) }
    private var inMonth: Bool { Calendar.current.isDate(date, equalTo: month, toGranularity: .month) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 13, weight: today || selected ? .semibold : .regular))
                    .foregroundStyle(selected ? (today ? Color.white : Color(nsColor: .windowBackgroundColor)) : today ? .red : .primary)
                    .frame(width: 28, height: 28)
                    .background { if selected { Circle().fill(today ? Color.red : Color.primary.opacity(0.9)) } }
                HStack(spacing: 2) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, color in Circle().fill(color).frame(width: 3, height: 3) }
                }.frame(height: 3)
            }
            .opacity(inMonth ? 1 : 0.3).frame(maxWidth: .infinity).frame(height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// Align the independent Join action to the time labels, even when the title wraps.
private enum EventTimeCenter: AlignmentID {
    static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[VerticalAlignment.center] }
}

private extension VerticalAlignment {
    static let eventTimeCenter = VerticalAlignment(EventTimeCenter.self)
}

private struct EventRow: View {
    let event: CalendarEvent
    let now: Date
    let timeColumnWidth: CGFloat
    private var ongoing: Bool { !event.isAllDay && event.start <= now && event.end > now }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.system(size: 13, weight: .medium)).lineLimit(2).foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if let meeting = event.meeting {
                        Image(systemName: "video").font(.system(size: 10))
                        Text(meeting.provider)
                    } else {
                        Text(event.location?.isEmpty == false ? event.location! : event.calendar.title).lineLimit(1)
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if event.meeting != nil {
                Color.clear.frame(width: 44, height: 1).accessibilityHidden(true)
            }
            VStack(alignment: .trailing, spacing: 3) {
                Text(event.isAllDay ? "all-day" : event.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, weight: .medium))
                if ongoing { Text("Now").font(.system(size: 9, weight: .semibold)).foregroundStyle(.red) }
                else if !event.isAllDay {
                    Text(event.end.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }.frame(width: timeColumnWidth, alignment: .trailing)
                .alignmentGuide(.eventTimeCenter) { $0[VerticalAlignment.center] }
        }
        .padding(.leading, 13)
        .overlay(alignment: .leading) {
            Capsule().fill(event.calendar.color).frame(width: 3)
        }
        .padding(.horizontal, 10).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

private struct EventRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }
    private struct HoverRow: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(.primary.opacity(configuration.isPressed ? 0.09 : hovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 7))
                .onHover { hovering = $0 }
        }
    }
}

private struct JoinCallButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(.primary)
            .background(Color(nsColor: .labelColor).opacity(configuration.isPressed ? 0.20 : 0.12), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct EventParticipantRow: View {
    let participant: CalendarParticipant
    let symbol: String
    let color: Color
    @State private var hovering = false
    @FocusState private var emailFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsEmailButton: Bool { hovering || emailFocused }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(participant.address + (participant.isOrganizer ? " (organiser)" : ""))
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let emailURL = participant.emailURL {
                Link(destination: emailURL) {
                    Image(systemName: "envelope")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(JoinCallButtonStyle())
                .focused($emailFocused)
                .opacity(showsEmailButton ? 1 : 0)
                .allowsHitTesting(showsEmailButton)
                .accessibilityLabel("Email \(participant.address)")
                .help("Email \(participant.address)")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.12), value: showsEmailButton)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(participant.address + (participant.isOrganizer ? ", organiser" : ""))
        .accessibilityValue(participant.status.label)
        .help(participant.status.label)
    }
}

struct EventDetails: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var detailsScrollSpace
    @State private var contentUnderHeader = false
    @State private var titleUnderHeader = false
    let event: CalendarEvent
    @ObservedObject var model: CalendarModel
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                backButton
                compactTitle
                    .opacity(titleUnderHeader ? 1 : 0)
                    .offset(y: titleUnderHeader || reduceMotion ? 0 : 5)
                    .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.18), value: titleUnderHeader)
                    .accessibilityHidden(!titleUnderHeader)
                Spacer(minLength: 0)
            }.font(.system(size: 12)).padding(20)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 0.5)
                        .opacity(contentUnderHeader ? 1 : 0)
                        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.18), value: contentUnderHeader)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.calendar.title).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(event.title).font(.system(size: 25, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(event.calendar.color)
                            .frame(width: 4)
                            .accessibilityHidden(true)
                    }
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: EventTitleUnderHeaderKey.self,
                                value: geometry.frame(in: .named(detailsScrollSpace)).maxY < 0
                            )
                        }
                    }
                    if let meeting = event.meeting {
                        HStack(spacing: 10) {
                            Image(systemName: "video.fill").foregroundStyle(.green).font(.system(size: 18))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Video call").font(.system(size: 13, weight: .semibold))
                                Text(meeting.provider).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Join call") {
                                model.joinCall(meeting.url)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .buttonStyle(JoinCallButtonStyle())
                            .help(model.isDemo ? "Joining is disabled for preview events" : "Join on \(meeting.url.host ?? meeting.provider)")
                            .disabled(model.isDemo && !model.isScreenshot)
                        }.padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        Text(timeDescription)
                        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !location.isEmpty, MeetingLink.find(url: nil, location: location, notes: nil) == nil {
                            Button { model.openMaps(location) } label: {
                                Text(location).underline()
                                    .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                            .help("Open in Maps")
                            .accessibilityLabel("Open \(location) in Maps")
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    if !event.participants.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(event.participants) { participant in
                                EventParticipantRow(
                                    participant: participant,
                                    symbol: participantSymbol(participant.status),
                                    color: participantColor(participant.status)
                                )
                            }
                        }
                    }
                    if let notes = event.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Notes").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            Text(notes).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
                        }
                    }
                    if let url = event.url, url != event.meeting?.url,
                       ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        Link(destination: url) { Label(url.host ?? "Event link", systemImage: "link") }.tint(.blue)
                    }
                }.padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 24)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ContentUnderHeaderKey.self,
                                value: geometry.frame(in: .named(detailsScrollSpace)).minY < -0.5
                            )
                        }
                    }
            }
            .coordinateSpace(name: detailsScrollSpace)
            .onPreferenceChange(ContentUnderHeaderKey.self) { contentUnderHeader = $0 }
            .onPreferenceChange(EventTitleUnderHeaderKey.self) { titleUnderHeader = $0 }
            .id(event.id)
            .onChange(of: event.id) { _, _ in
                contentUnderHeader = false
                titleUnderHeader = false
            }
        }.frame(maxHeight: .infinity)
    }

    private var compactTitle: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(event.calendar.color)
                .frame(width: 3, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.calendar.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .lineLimit(1)
        }
        .frame(height: 32)
        .help(event.title)
    }

    @ViewBuilder
    private var backButton: some View {
        if #available(macOS 26, *) {
            backAction.glassEffect(.clear.interactive(), in: Circle())
        } else {
            backAction.background(.ultraThinMaterial, in: Circle())
        }
    }

    private var backAction: some View {
        Button(action: back) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to Calendar")
        .help("Back to Calendar")
    }

    private var timeDescription: String {
        let calendar = Calendar.current
        if event.isAllDay {
            let lastDay = calendar.date(byAdding: .day, value: -1, to: event.end)!
            if calendar.isDate(event.start, inSameDayAs: lastDay) { return "All day" }
            return "All day · through \(lastDay.formatted(.dateTime.month(.abbreviated).day()))"
        }
        if calendar.isDate(event.start, inSameDayAs: event.end) {
            return "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
        }
        return "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
    }

    private func participantSymbol(_ status: ParticipationStatus) -> String {
        switch status {
        case .accepted: "checkmark.circle"
        case .declined: "xmark.circle"
        case .delegated: "arrowshape.turn.up.right.circle"
        case .completed: "checkmark.circle"
        case .inProcess: "clock"
        default: "questionmark.circle"
        }
    }

    private func participantColor(_ status: ParticipationStatus) -> Color {
        switch status {
        case .accepted, .completed: Color(nsColor: .systemGreen)
        case .declined: Color(nsColor: .systemRed)
        case .pending, .tentative, .unknown: Color(nsColor: .systemOrange)
        default: .secondary
        }
    }


}

struct WelcomeView: View {
    @ObservedObject var model: CalendarModel
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "calendar").font(.system(size: 48, weight: .light)).foregroundStyle(.red).padding(.bottom, 22)
            Text("Your day, at a glance.").font(.system(size: 24, weight: .semibold)).padding(.bottom, 12)
            Text("Your calendars, event details and video calls.\nAlways a click away in your menu bar.")
                .font(.system(size: 13)).lineSpacing(4).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                if model.access == .denied || model.access == .restricted {
                    Label(model.access == .restricted ? "Calendar access is restricted" : "Calendar access is turned off", systemImage: "lock")
                        .font(.system(size: 13, weight: .medium))
                    Text(model.access == .restricted ? "Access is managed by this Mac’s administrator." : "Allow Full Access for CaliBar in System Settings → Privacy & Security → Calendars.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.access != .restricted {
                        Button("Open System Settings") { model.openPrivacySettings() }.controlSize(.large)
                        Button("I’ve allowed access") { model.setSyncEnabled(true) }.buttonStyle(.link)
                    }
                } else {
                    HStack {
                        Label("Sync calendars", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .medium)).accessibilityHidden(true)
                        Spacer(minLength: 12)
                        Toggle("Sync calendars", isOn: Binding(get: { model.syncEnabled }, set: { model.setSyncEnabled($0) }))
                            .labelsHidden().toggleStyle(.switch).tint(.red).disabled(model.isRequesting)
                    }
                    Text("Includes all accounts enabled in Apple Calendar. Choose which calendars to show at any time.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.isRequesting { HStack { ProgressView().controlSize(.small); Text("Waiting for permission…").font(.caption) } }
                }
            }.padding(18).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                .padding(.top, 28).padding(.horizontal, 26)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

struct CalendarSettings: View {
    @ObservedObject var model: CalendarModel
    @Namespace private var settingsScrollSpace
    @State private var contentUnderHeader = false
    let back: () -> Void
    private var sources: [(id: String, title: String, calendars: [CalendarInfo])] {
        Dictionary(grouping: model.calendars, by: \.sourceID).map { id, calendars in
            (id: id, title: calendars.first?.sourceName ?? "Calendars", calendars: calendars)
        }.sorted { $0.title < $1.title }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 22, weight: .semibold))
                Spacer()
                doneButton
            }.padding(20)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 0.5)
                        .opacity(contentUnderHeader ? 1 : 0)
                        .animation(.easeInOut(duration: 0.18), value: contentUnderHeader)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Date").accessibilityHidden(true)
                            Spacer(minLength: 12)
                            dateFormatButton
                        }
                        HStack {
                            Text("Show next event").accessibilityHidden(true)
                            Spacer(minLength: 12)
                            Toggle("Show next event", isOn: Binding(get: { model.menuBarPreferences.showsNextEvent }, set: { model.setShowsNextEvent($0) }))
                                .labelsHidden().toggleStyle(.switch).tint(.red)
                        }
                        HStack {
                            Text("Today’s events only").accessibilityHidden(true)
                            Spacer(minLength: 12)
                            Toggle("Today’s events only", isOn: Binding(get: { model.menuBarPreferences.nextEventTodayOnly }, set: { model.setNextEventTodayOnly($0) }))
                                .labelsHidden().toggleStyle(.switch).tint(.red)
                        }
                        .disabled(!model.menuBarPreferences.showsNextEvent)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("Sync calendars").accessibilityHidden(true)
                            Spacer(minLength: 12)
                            Toggle("Sync calendars", isOn: Binding(get: { model.syncEnabled }, set: { model.setSyncEnabled($0) }))
                                .labelsHidden().toggleStyle(.switch).tint(.red).disabled(model.isRequesting || (model.isDemo && !model.isScreenshot))
                        }
                        Text("Uses the accounts in Apple Calendar. New calendars appear automatically.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if model.ready {
                        ForEach(sources, id: \.id) { source in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(source.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                ForEach(source.calendars) { calendar in
                                    Toggle(isOn: Binding(get: { !model.excludedIDs.contains(calendar.id) }, set: { _ in model.toggleCalendar(calendar.id) })) {
                                        Text(calendar.title).font(.system(size: 13))
                                    }.toggleStyle(CalendarCheckboxStyle(color: calendar.color))
                                }
                            }
                        }
                        if model.calendars.isEmpty { Text("No calendars found. Add an account in Apple Calendar.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Divider()
                    HStack {
                        Text("Video call browser").accessibilityHidden(true)
                        Spacer(minLength: 12)
                        videoCallBrowserButton
                    }
                    HStack {
                        Text("Open at Login").accessibilityHidden(true)
                        Spacer(minLength: 12)
                        Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                            .labelsHidden().toggleStyle(.switch).tint(.red)
                    }
                    AutomaticUpdatesToggle(updater: model.updates)
                    Text("CaliBar shows your calendars and saves events you create on this Mac. Turning syncing off clears events from CaliBar. You can revoke calendar access in System Settings.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                    Button("Calendar Privacy Settings") { model.openPrivacySettings() }.buttonStyle(.link)
                }.padding(.horizontal, 22).padding(.bottom, 20)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ContentUnderHeaderKey.self,
                                value: geometry.frame(in: .named(settingsScrollSpace)).minY < -0.5
                            )
                        }
                    }
            }
            .coordinateSpace(name: settingsScrollSpace)
            .onPreferenceChange(ContentUnderHeaderKey.self) { contentUnderHeader = $0 }
            Spacer(minLength: 0)
        }.frame(maxHeight: .infinity)
            .onAppear { model.refreshBrowsers() }
    }

    @ViewBuilder
    private var videoCallBrowserButton: some View {
        if #available(macOS 26, *) {
            videoCallBrowserMenu
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 8))
        } else {
            videoCallBrowserMenu
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var videoCallBrowserMenu: some View {
        Menu {
            Picker("Video call browser", selection: Binding(get: { model.videoCallBrowserID }, set: { model.setVideoCallBrowser($0) })) {
                Text("Default browser").tag("")
                Divider()
                ForEach(model.availableBrowsers) { browser in
                    Text(browser.name).tag(browser.id)
                }
                if !model.videoCallBrowserID.isEmpty,
                   !model.availableBrowsers.contains(where: { $0.id == model.videoCallBrowserID }) {
                    Text("Unavailable browser").tag(model.videoCallBrowserID).disabled(true)
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(model.videoCallBrowserName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Video call browser")
        .accessibilityValue(model.videoCallBrowserName)
    }

    private var dateFormatPreview: String {
        let style = model.menuBarPreferences.dateStyle
        return style == .hidden ? style.title : style.formatted(model.now)
    }

    @ViewBuilder
    private var dateFormatButton: some View {
        if #available(macOS 26, *) {
            dateFormatMenu
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 8))
        } else {
            dateFormatMenu
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var dateFormatMenu: some View {
        Menu {
            Picker("Date format", selection: Binding(get: { model.menuBarPreferences.dateStyle }, set: { model.setMenuBarDateStyle($0) })) {
                ForEach(MenuBarDateStyle.allCases) { style in
                    Text(style == .hidden ? style.title : "\(style.title) · \(style.formatted(model.now))").tag(style)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(dateFormatPreview).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Date format")
        .accessibilityValue("\(model.menuBarPreferences.dateStyle.title), \(dateFormatPreview)")
        .help("Date shown in the menu bar")
    }

    @ViewBuilder
    private var doneButton: some View {
        if #available(macOS 26, *) {
            doneAction
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.red).interactive(), in: Circle())
        } else {
            doneAction
                .buttonStyle(.plain)
                .background(.red, in: Circle())
        }
    }

    private var doneAction: some View {
        Button(action: back) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .accessibilityLabel("Done")
        .help("Done")
    }
}

private struct CalendarCheckboxStyle: ToggleStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    if configuration.isOn {
                        RoundedRectangle(cornerRadius: 3).fill(color)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .blendMode(.destinationOut)
                    } else {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(color, lineWidth: 1)
                    }
                }
                .frame(width: 14, height: 14)
                // Cut the tick out of the coloured square, preserving the glass beneath it.
                .compositingGroup()
                .accessibilityHidden(true)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}

private enum ContentUnderHeaderKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}


private enum EventTitleUnderHeaderKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
