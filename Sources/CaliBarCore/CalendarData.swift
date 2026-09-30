import Foundation

public struct CalendarInfo: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let sourceID: String
    public let sourceName: String
    public let red: Double
    public let green: Double
    public let blue: Double
    public let allowsContentModifications: Bool
    public let supportedAvailabilities: [EventAvailability]
    public let isDefault: Bool

    public init(id: String, title: String, sourceID: String, sourceName: String, red: Double, green: Double, blue: Double, allowsContentModifications: Bool = false,
                supportedAvailabilities: [EventAvailability] = [], isDefault: Bool = false) {
        self.id = id; self.title = title; self.sourceID = sourceID; self.sourceName = sourceName
        self.red = red; self.green = green; self.blue = blue
        self.allowsContentModifications = allowsContentModifications
        self.supportedAvailabilities = supportedAvailabilities
        self.isDefault = isDefault
    }
}

public struct CalendarEvent: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendar: CalendarInfo
    public let location: String?
    public let notes: String?
    public let url: URL?
    public let participants: [CalendarParticipant]
    public let meeting: MeetingLink?
    public let appleCalendarURL: URL?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, calendar: CalendarInfo,
                location: String? = nil, notes: String? = nil, url: URL? = nil, organizer: CalendarParticipant? = nil, attendees: [CalendarParticipant] = [],
                appleCalendarURL: URL? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay; self.calendar = calendar
        self.location = location; self.notes = notes; self.url = url
        self.participants = CalendarParticipant.ordered(organizer: organizer, attendees: attendees)
        self.meeting = MeetingLink.find(url: url, location: location, notes: notes)
        self.appleCalendarURL = appleCalendarURL
    }

    public func occurs(on day: Date, using calendar: Calendar = .current) -> Bool {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return false }
        if start == end { return interval.start <= start && start < interval.end }
        // End dates are exclusive, including all-day events ending at midnight.
        return start < interval.end && end > interval.start
    }
}

public enum CalendarDates {
    /// Normalize macOS EventKit's inclusive all-day end into the app's half-open interval.
    public static func exclusiveEnd(_ end: Date, isAllDay: Bool, calendar: Calendar = .current) -> Date {
        guard isAllDay, calendar.startOfDay(for: end) != end else { return end }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
    }

    public static func monthDays(containing date: Date, calendar: Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return [] }
        let offset = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -offset, to: month.start) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    public static func events(on date: Date, from events: [CalendarEvent], calendar: Calendar = .current) -> [CalendarEvent] {
        events.filter { $0.occurs(on: date, using: calendar) }.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}
