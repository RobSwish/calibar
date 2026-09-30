import AppKit
import Combine
import CaliBarCore
import EventKit
import ServiceManagement
import SwiftUI

@MainActor
final class CalendarModel: ObservableObject {
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var events: [CalendarEvent] = []
    @Published private var syncRequested: Bool
    @Published private(set) var access: CalendarAccess
    @Published private(set) var isLoading = false
    @Published private(set) var isRequesting = false
    @Published private(set) var excludedIDs: Set<String>
    @Published private(set) var menuBarPreferences: MenuBarPreferences
    @Published private(set) var videoCallBrowserID: String
    @Published private(set) var availableBrowsers: [VideoCallBrowser] = []
    @Published var selectedDate: Date
    @Published var displayedMonth: Date
    @Published var now: Date
    @Published var error: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var eventDraft: EventDraft?
    @Published private(set) var isSavingEvent = false
    @Published var creationError: String?
    let isDemo: Bool
    let isScreenshot: Bool
    let updates: AppUpdater

    private let reader = EventReader()
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    init(demo: Bool = false, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isDemo = demo
        isScreenshot = demo && ProcessInfo.processInfo.arguments.contains("--screenshot")
        updates = AppUpdater(enabled: !demo)
        let date = Date()
        now = date; selectedDate = date; displayedMonth = date
        syncRequested = demo || defaults.bool(forKey: "syncEnabled")
        excludedIDs = demo ? [] : Set(defaults.stringArray(forKey: "excludedCalendars") ?? [])
        menuBarPreferences = demo ? MenuBarPreferences() : MenuBarPreferences.load(from: defaults)
        videoCallBrowserID = demo ? "" : defaults.string(forKey: "videoCallBrowserID") ?? ""
        access = demo ? .allowed : EventReader.access
        if demo {
            calendars = DemoData.calendars
            events = DemoData.events(relativeTo: date)
            if ProcessInfo.processInfo.arguments.contains("--demo-add") {
                beginEvent()
                if isScreenshot {
                    eventDraft?.title = "Design workshop"
                    eventDraft?.location = "Studio, London"
                }
            }
        } else {
            NotificationCenter.default.publisher(for: .EKEventStoreChanged)
                .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
                .store(in: &cancellables)
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
                .store(in: &cancellables)
            NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
                .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
                .store(in: &cancellables)
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
                .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
                .store(in: &cancellables)
            Timer.publish(every: 60, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
                .store(in: &cancellables)
            refresh()
        }
    }

    // Keep the saved choice, but only show syncing as on when this build has access.
    var syncEnabled: Bool { syncRequested && access == .allowed }
    var ready: Bool { syncEnabled }
    var selectedEvents: [CalendarEvent] { CalendarDates.events(on: selectedDate, from: visibleEvents) }
    var visibleEvents: [CalendarEvent] { events.filter { !excludedIDs.contains($0.calendar.id) } }
    var nextEvent: CalendarEvent? {
        MenuBarDisplay.nextEvent(in: visibleEvents, now: now, todayOnly: menuBarPreferences.nextEventTodayOnly)
    }
    var days: [Date] { CalendarDates.monthDays(containing: displayedMonth) }

    var writableCalendars: [CalendarInfo] { calendars.filter(\.allowsContentModifications) }

    func beginEvent() {
        guard eventDraft == nil else { return }
        var draft = EventDraft(day: selectedDate)
        let candidates = writableCalendars
        draft.calendarID = candidates.first(where: { $0.isDefault })?.id
            ?? candidates.first(where: { !excludedIDs.contains($0.id) })?.id
            ?? candidates.first?.id ?? ""
        if let choice = candidates.first(where: { $0.id == draft.calendarID }),
           let availability = choice.supportedAvailabilities.first { draft.availability = availability }
        eventDraft = draft
        creationError = nil
    }

    func saveEvent() async -> CalendarEvent? {
        guard !isSavingEvent, let draft = eventDraft else { return nil }
        guard ready else { creationError = EventCreationError.accessDenied.localizedDescription; return nil }
        guard let calendar = writableCalendars.first(where: { $0.id == draft.calendarID }) else {
            creationError = EventCreationError.calendarUnavailable.localizedDescription; return nil
        }
        if let message = draft.validationMessage { creationError = message; return nil }
        isSavingEvent = true
        creationError = nil
        defer { isSavingEvent = false }
        do {
            let event: CalendarEvent
            if isDemo {
                // Preview saves stay in memory and never request access or touch EventKit.
                event = CalendarEvent(id: UUID().uuidString, title: draft.title, start: draft.savedStart,
                    end: draft.savedEnd, isAllDay: draft.isAllDay, calendar: calendar,
                    location: draft.location, notes: draft.notes,
                    url: EventDraft.webURL(draft.meetingURL) ?? EventDraft.webURL(draft.url))
            } else {
                event = try await reader.create(draft)
            }
            // Invalidate any refresh that began before the save, so it cannot erase the new row.
            generation += 1
            refreshTask?.cancel()
            isLoading = false
            events.removeAll { $0.id == event.id }
            events.append(event)
            excludedIDs.remove(calendar.id)
            if !isDemo { defaults.set(Array(excludedIDs), forKey: "excludedCalendars") }
            selectedDate = event.start
            displayedMonth = event.start
            eventDraft = nil
            refresh()
            return event
        } catch {
            creationError = error.localizedDescription
            return nil
        }
    }

    func setMenuBarDateStyle(_ style: MenuBarDateStyle) {
        menuBarPreferences.dateStyle = style
        if !isDemo { menuBarPreferences.save(to: defaults) }
    }

    func setShowsNextEvent(_ enabled: Bool) {
        menuBarPreferences.showsNextEvent = enabled
        if !isDemo { menuBarPreferences.save(to: defaults) }
    }

    func setNextEventTodayOnly(_ enabled: Bool) {
        menuBarPreferences.nextEventTodayOnly = enabled
        if !isDemo { menuBarPreferences.save(to: defaults) }
    }

    func refreshBrowsers() {
        var seen = Set<String>()
        availableBrowsers = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            .compactMap { url in
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      seen.insert(id).inserted else { return nil }
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                return VideoCallBrowser(id: id, name: name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var videoCallBrowserName: String {
        if videoCallBrowserID.isEmpty { return "Default browser" }
        return availableBrowsers.first { $0.id == videoCallBrowserID }?.name ?? "Unavailable browser"
    }

    func setVideoCallBrowser(_ id: String) {
        videoCallBrowserID = id
        if !isDemo { defaults.set(id, forKey: "videoCallBrowserID") }
    }

    func joinCall(_ url: URL) {
        guard !isDemo else { return }
        guard !videoCallBrowserID.isEmpty else { open(url); return }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: videoCallBrowserID) else {
            error = "Your selected browser is no longer available. Choose another video call browser in Settings."
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, launchError in
            if launchError != nil {
                Task { @MainActor in
                    self?.error = "The video call couldn’t be opened in your selected browser. Try again or choose another browser in Settings."
                }
            }
        }
    }

    func setSyncEnabled(_ enabled: Bool) {
        guard !isDemo else { return }
        if !enabled {
            generation += 1
            refreshTask?.cancel()
            syncRequested = false
            defaults.set(false, forKey: "syncEnabled")
            calendars = []; events = []; error = nil; isLoading = false
            return
        }
        guard !isRequesting else { return }
        isRequesting = true
        error = nil
        Task {
            defer { isRequesting = false }
            do {
                let granted = try await reader.requestAccess()
                access = EventReader.access
                if granted {
                    syncRequested = true
                    defaults.set(true, forKey: "syncEnabled")
                    refresh(remote: true)
                }
            } catch {
                self.error = "Calendar access couldn’t be enabled. \(error.localizedDescription)"
                access = EventReader.access
            }
        }
    }

    func refresh(remote: Bool = false) {
        let newNow = Date()
        let localCalendar = Calendar.current
        if localCalendar.isDate(selectedDate, inSameDayAs: now), !localCalendar.isDate(now, inSameDayAs: newNow) {
            selectedDate = newNow
            displayedMonth = newNow
        }
        now = newNow
        guard !isDemo else { return }
        access = EventReader.access
        generation += 1
        let request = generation
        refreshTask?.cancel()
        guard ready else { calendars = []; events = []; isLoading = false; return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = min(days.first ?? today, today)
        let end = max(calendar.date(byAdding: .day, value: 1, to: days.last ?? today)!,
                      calendar.date(byAdding: .day, value: 31, to: today)!)
        let excluded = excludedIDs
        isLoading = true
        refreshTask = Task {
            let snapshot = await reader.fetch(start: start, end: end, excludedIDs: excluded, refreshSources: remote)
            guard !Task.isCancelled, request == generation, ready else { return }
            isLoading = false
            guard let snapshot else {
                access = EventReader.access
                calendars = []; events = []
                return
            }
            calendars = snapshot.calendars
            events = snapshot.events
        }
    }

    func toggleCalendar(_ id: String) {
        if excludedIDs.contains(id) { excludedIDs.remove(id) } else { excludedIDs.insert(id) }
        if !isDemo { defaults.set(Array(excludedIDs), forKey: "excludedCalendars") }
        refresh()
    }

    func selectAllCalendars() {
        excludedIDs = []
        if !isDemo { defaults.set([], forKey: "excludedCalendars") }
        refresh()
    }

    func moveMonth(_ offset: Int) {
        let calendar = Calendar.current
        let first = calendar.dateInterval(of: .month, for: displayedMonth)!.start
        displayedMonth = calendar.date(byAdding: .month, value: offset, to: first)!
        selectedDate = displayedMonth
        refresh()
    }

    func selectDate(_ date: Date) {
        selectedDate = date
        if !Calendar.current.isDate(date, equalTo: displayedMonth, toGranularity: .month) {
            displayedMonth = date
            refresh()
        }
    }

    func today() { selectedDate = Date(); displayedMonth = selectedDate; refresh() }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isDemo else { launchAtLogin = enabled; return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { self.error = "Couldn’t change Open at Login. \(error.localizedDescription)" }
    }

    func openCalendar(event: CalendarEvent? = nil) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else {
            error = "Apple Calendar couldn’t be found on this Mac."
            return
        }
        if let eventURL = event?.appleCalendarURL, !isDemo {
            NSWorkspace.shared.open([eventURL], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                if error != nil { Task { @MainActor in self?.openCalendar() } }
            }
        } else {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    func openMaps(_ location: String) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "q", value: location)]
        guard let url = components.url else { return }
        guard let maps = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Maps") else {
            open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: maps, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, launchError in
            if launchError != nil {
                Task { @MainActor in self?.error = "This location couldn’t be opened in Maps. Try again." }
            }
        }
    }

    func openPrivacySettings() {
        open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) { error = "This link couldn’t be opened. Check that a browser is available." }
    }
}

struct VideoCallBrowser: Identifiable {
    let id: String
    let name: String
}

extension CalendarInfo {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

enum DemoData {
    static let calendars: [CalendarInfo] = [
        CalendarInfo(id: "work", title: "Work", sourceID: "google", sourceName: "Google", red: 0.25, green: 0.48, blue: 0.92, allowsContentModifications: true, supportedAvailabilities: [.busy, .free], isDefault: true),
        CalendarInfo(id: "home", title: "Personal", sourceID: "icloud", sourceName: "iCloud", red: 0.62, green: 0.34, blue: 0.85, allowsContentModifications: true, supportedAvailabilities: [.busy, .free]),
        CalendarInfo(id: "family", title: "Family", sourceID: "icloud", sourceName: "iCloud", red: 0.27, green: 0.67, blue: 0.42, allowsContentModifications: true)
    ]

    static func events(relativeTo date: Date) -> [CalendarEvent] {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        func time(_ hour: Int, _ minute: Int = 0, offset: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.date(byAdding: .day, value: offset, to: day)!)!
        }
        return [
            CalendarEvent(id: "demo-1", title: "Design catch-up", start: time(10), end: time(10, 30), calendar: calendars[0],
                          notes: "A little time to share what we’re working on.\n\n• Review the latest designs\n• Agree on next steps",
                          url: URL(string: "https://meet.google.com/abc-defg-hij"), organizer: CalendarParticipant(url: URL(string: "mailto:alex@example.com")!),
                          attendees: [
                              CalendarParticipant(url: URL(string: "mailto:sam@example.com")!, status: .tentative),
                              CalendarParticipant(url: URL(string: "mailto:alex@example.com")!, status: .accepted),
                              CalendarParticipant(url: URL(string: "mailto:jamie@example.com")!, status: .declined)
                          ]),
            CalendarEvent(id: "demo-2", title: "Lunch with Jamie", start: time(12, 30), end: time(13, 30), calendar: calendars[1], location: "The little café on the corner"),
            CalendarEvent(id: "demo-3", title: "Product review with the design team", start: time(15), end: time(16), calendar: calendars[0],
                          notes: "Join Zoom: https://us02web.zoom.us/j/12345678900?pwd=example"),
            CalendarEvent(id: "demo-4", title: "An evening walk", start: time(18), end: time(18, 45), calendar: calendars[2], location: "The park"),
            CalendarEvent(id: "demo-5", title: "A day to explore", start: time(0, offset: 2), end: time(0, offset: 3), isAllDay: true, calendar: calendars[1]),
            CalendarEvent(id: "demo-6", title: "Weekly planning", start: time(9, offset: 1), end: time(9, 30, offset: 1), calendar: calendars[0])
        ]
    }
}
