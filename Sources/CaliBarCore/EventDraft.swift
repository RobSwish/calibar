import EventKit
import Foundation

/// A value-only draft. Nothing reaches the calendar store until the user saves.
public struct EventDraft: Equatable, Sendable {
    public var title = ""
    public var calendarID = ""
    public var start: Date
    /// The last visible day for all-day events; converted to an exclusive end when saved.
    public var end: Date
    public var isAllDay = false
    private var localTimeZoneID = TimeZone.current.identifier
    public var timeZoneID = TimeZone.current.identifier
    public var location = ""
    public var meetingURL = ""
    public var url = ""
    public var notes = ""
    public var availability = EventAvailability.busy
    public var recurrence = EventRecurrence()
    public var alerts: [EventAlert] = []

    public init(day: Date, now: Date = Date(), calendar: Calendar = .current) {
        if calendar.isDate(day, inSameDayAs: now) {
            let hour = calendar.dateInterval(of: .hour, for: now)!.start
            let nextHalfHour = hour.addingTimeInterval(calendar.component(.minute, from: now) < 30 ? 1800 : 3600)
            start = nextHalfHour
        } else {
            start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        }
        end = start.addingTimeInterval(3600)
        localTimeZoneID = calendar.timeZone.identifier
        timeZoneID = calendar.timeZone.identifier
        recurrence.until = calendar.date(byAdding: .year, value: 1, to: start)!
    }

    public var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: isAllDay ? localTimeZoneID : timeZoneID) ?? .current
        return value
    }

    public var savedStart: Date { isAllDay ? calendar.startOfDay(for: start) : start }
    public var savedEnd: Date {
        isAllDay ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))! : end
    }

    public mutating func setAllDay(_ value: Bool) {
        let previous = calendar
        isAllDay = value
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        start = calendar.date(from: previous.dateComponents(components, from: start)) ?? start
        end = calendar.date(from: previous.dateComponents(components, from: end)) ?? end
        recurrence.until = calendar.date(from: previous.dateComponents(components, from: recurrence.until)) ?? recurrence.until
    }

    public mutating func moveStart(to value: Date) {
        if isAllDay {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
            end = calendar.date(byAdding: .day, value: max(0, days), to: value) ?? value
        } else {
            end = value.addingTimeInterval(max(60, end.timeIntervalSince(start)))
        }
        start = value
    }

    /// Changing the zone keeps the date/time the user entered, as in Calendar's editor.
    public mutating func changeTimeZone(to identifier: String) {
        let previous = calendar
        timeZoneID = identifier
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        start = calendar.date(from: previous.dateComponents(components, from: start)) ?? start
        end = calendar.date(from: previous.dateComponents(components, from: end)) ?? end
        recurrence.until = calendar.date(from: previous.dateComponents(components, from: recurrence.until)) ?? recurrence.until
    }

    public var validationMessage: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter an event title." }
        if calendarID.isEmpty { return "Choose a calendar you can add events to." }
        if !timeZoneID.isEmpty && TimeZone(identifier: timeZoneID) == nil { return "Choose a valid time zone." }
        if savedEnd <= savedStart { return "The end must be after the start." }
        for (text, label) in [(url, "URL"), (meetingURL, "video call link")] {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Self.webURL(text) == nil {
                return "Enter a complete http or https \(label)."
            }
        }
        if let message = recurrence.validationMessage(start: savedStart, calendar: calendar) { return message }
        if alerts.contains(where: { !(0...999).contains($0.amount) }) { return "Alert interval must be between 0 and 999." }
        if alerts.contains(where: { $0.action == .email && (!$0.email.contains("@") || $0.email.contains(where: \.isWhitespace)) }) {
            return "Enter a valid email address for the alert."
        }
        return nil
    }

    public static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Builds an unsaved event; also used by tests without touching personal calendars.
    public func makeEvent(in store: EKEventStore) throws -> EKEvent {
        if let message = validationMessage { throw EventCreationError.invalid(message) }
        let event = EKEvent(eventStore: store)
        event.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // macOS EventKit uses an inclusive final day (23:59:59) for all-day events.
        event.isAllDay = isAllDay
        event.timeZone = isAllDay || timeZoneID.isEmpty ? nil : TimeZone(identifier: timeZoneID)
        event.startDate = savedStart
        event.endDate = isAllDay ? savedEnd.addingTimeInterval(-1) : savedEnd
        event.location = location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        event.url = Self.webURL(url) ?? Self.webURL(meetingURL)
        var savedNotes = notes
        if let call = Self.webURL(meetingURL), event.url != call {
            savedNotes += (savedNotes.isEmpty ? "" : "\n\n") + "Video call: \(call.absoluteString)"
        }
        event.notes = savedNotes.nilIfEmpty
        event.alarms = alerts.map { $0.makeAlarm() }
        var schedule = recurrence
        if schedule.frequency == .yearly && schedule.months.isEmpty {
            schedule.months = [calendar.component(.month, from: savedStart)]
        }
        if let rule = schedule.makeRule(calendar: calendar) { event.addRecurrenceRule(rule) }
        return event
    }
}

public enum EventCreationError: LocalizedError {
    case invalid(String), accessDenied, calendarUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .accessDenied: "Calendar access is unavailable. Enable Sync calendars and allow access in System Settings."
        case .calendarUnavailable: "This calendar is no longer writable. Choose another calendar and try again."
        }
    }
}

public enum EventAvailability: String, CaseIterable, Sendable {
    case busy = "Busy", free = "Free", tentative = "Tentative", unavailable = "Unavailable"
    public var eventKitValue: EKEventAvailability {
        switch self { case .busy: .busy; case .free: .free; case .tentative: .tentative; case .unavailable: .unavailable }
    }
    public var mask: EKCalendarEventAvailabilityMask {
        switch self { case .busy: .busy; case .free: .free; case .tentative: .tentative; case .unavailable: .unavailable }
    }
}

public struct EventRecurrence: Equatable, Sendable {
    public enum Frequency: String, CaseIterable, Sendable {
        case never = "Never", daily = "Daily", weekly = "Weekly", monthly = "Monthly", yearly = "Yearly"
    }
    public enum Ending: String, CaseIterable, Sendable { case never = "Never", onDate = "On date", after = "After" }
    public var frequency = Frequency.never
    public var interval = 1
    public var weekdays: Set<Int> = [] // Sunday = 1, matching EventKit.
    public var monthDays: Set<Int> = []
    public var months: Set<Int> = []
    public var usesOrdinal = false
    public var ordinal = 1
    /// 1...7 = individual weekday; 8 = day; 9 = weekday; 10 = weekend day.
    public var ordinalDay = 2
    public var ending = Ending.never
    public var until = Date()
    public var count = 10

    public init() {}
    public func validationMessage(start: Date, calendar: Calendar) -> String? {
        guard frequency != .never else { return nil }
        if !(1...999).contains(interval) { return "Repeat interval must be between 1 and 999." }
        if ending == .after && !(1...9999).contains(count) { return "Enter between 1 and 9,999 occurrences." }
        if ending == .onDate && calendar.startOfDay(for: until) < calendar.startOfDay(for: start) { return "End repeat cannot be before the event starts." }
        if weekdays.contains(where: { !(1...7).contains($0) }) || monthDays.contains(where: { !(1...31).contains($0) }) || months.contains(where: { !(1...12).contains($0) }) { return "Choose a valid repeat pattern." }
        if frequency == .yearly && usesOrdinal && ordinalDay >= 8 && months.count > 1 { return "Choose one month for a day, weekday or weekend-day pattern." }
        if usesOrdinal && (![1, 2, 3, 4, 5, -1].contains(ordinal) || !(1...10).contains(ordinalDay)) { return "Choose a valid weekday pattern." }
        return nil
    }

    public func makeRule(calendar: Calendar) -> EKRecurrenceRule? {
        guard frequency != .never else { return nil }
        let type: EKRecurrenceFrequency
        switch frequency { case .daily: type = .daily; case .weekly: type = .weekly; case .monthly: type = .monthly; default: type = .yearly }
        var days: [EKRecurrenceDayOfWeek]?
        var positions: [NSNumber]?
        if frequency == .weekly && !weekdays.isEmpty {
            days = weekdays.sorted().compactMap { EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0) } }
        } else if usesOrdinal && (frequency == .monthly || frequency == .yearly) {
            let values = ordinalDay == 8 ? Array(1...7) : ordinalDay == 9 ? Array(2...6) : ordinalDay == 10 ? [1, 7] : [ordinalDay]
            if ordinalDay <= 7 {
                days = values.compactMap { EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0, weekNumber: ordinal) } }
            } else {
                days = values.compactMap { EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0) } }
                positions = [NSNumber(value: ordinal)]
            }
        }
        let end: EKRecurrenceEnd?
        switch ending {
        case .never: end = nil
        case .after: end = EKRecurrenceEnd(occurrenceCount: max(1, count))
        case .onDate:
            let exclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: until))!
            end = EKRecurrenceEnd(end: exclusive.addingTimeInterval(-1))
        }
        return EKRecurrenceRule(recurrenceWith: type, interval: max(1, interval), daysOfTheWeek: days,
            daysOfTheMonth: frequency == .monthly && !usesOrdinal && !monthDays.isEmpty ? monthDays.sorted().map { NSNumber(value: $0) } : nil,
            monthsOfTheYear: frequency == .yearly && !months.isEmpty ? months.sorted().map { NSNumber(value: $0) } : nil,
            weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: positions, end: end)
    }
}

public struct EventAlert: Identifiable, Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable { case message = "Message", sound = "Message with sound", email = "Email" }
    public enum Timing: String, CaseIterable, Sendable { case before = "Before", after = "After", onDate = "On date" }
    public enum Unit: Int, CaseIterable, Sendable {
        case minutes = 60, hours = 3600, days = 86400, weeks = 604800
        public var title: String { switch self { case .minutes: "minutes"; case .hours: "hours"; case .days: "days"; case .weeks: "weeks" } }
    }
    public let id = UUID()
    public var action = Action.message
    public var timing = Timing.before
    public var amount = 15
    public var unit = Unit.minutes
    public var date: Date
    public var email = ""
    public var sound = "Glass"
    public init(date: Date) { self.date = date }
    public func makeAlarm() -> EKAlarm {
        let alarm = timing == .onDate ? EKAlarm(absoluteDate: date) : EKAlarm(relativeOffset: Double(amount * unit.rawValue) * (timing == .before ? -1 : 1))
        switch action { case .message: break; case .sound: alarm.soundName = sound; case .email: alarm.emailAddress = email }
        return alarm
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
