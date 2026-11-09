import Foundation

/// A Google Calendar API event insert, optionally with invitees and a new Meet conference.
public struct GoogleEventBody: Encodable, Equatable, Sendable {
    public struct Time: Encodable, Equatable, Sendable {
        public var date: String?
        public var dateTime: String?
        public var timeZone: String?
    }
    public struct Reminder: Encodable, Equatable, Sendable {
        public var method: String
        public var minutes: Int
    }
    public struct Reminders: Encodable, Equatable, Sendable {
        public var useDefault: Bool
        public var overrides: [Reminder]
    }
    public struct ConferenceData: Encodable, Equatable, Sendable {
        public struct Key: Encodable, Equatable, Sendable { public var type = "hangoutsMeet" }
        public struct CreateRequest: Encodable, Equatable, Sendable {
            public var requestId: String
            public var conferenceSolutionKey = Key()
        }
        public struct Solution: Encodable, Equatable, Sendable { public var key = Key() }
        public struct EntryPoint: Encodable, Equatable, Sendable {
            public var entryPointType = "video"
            public var uri: String
            public var label: String
        }
        /// Asks Google to create a new Meet room for the event.
        public var createRequest: CreateRequest?
        /// Or attaches a Meet room created earlier (Google needs the solution and at least one entry point).
        public var conferenceId: String?
        public var conferenceSolution: Solution?
        public var entryPoints: [EntryPoint]?

        public init(createRequest: CreateRequest) { self.createRequest = createRequest }

        /// Attaches the Meet room already shown in the editor, so the saved event keeps that link.
        public init?(existing url: URL) {
            guard url.host?.lowercased() == "meet.google.com", MeetingLink.recognize(url) != nil else { return nil }
            let code = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            conferenceId = code
            conferenceSolution = Solution()
            entryPoints = [EntryPoint(uri: "https://meet.google.com/\(code)", label: "meet.google.com/\(code)")]
        }
    }
    public struct Attendee: Encodable, Equatable, Sendable {
        public var email: String
    }

    public static let maximumReminderMinutes = 40_320
    public static let maximumReminders = 5

    public var summary: String
    public var location: String?
    public var description: String?
    public var start: Time
    public var end: Time
    public var recurrence: [String]?
    public var transparency: String?
    public var reminders: Reminders
    public var attendees: [Attendee]?
    public var conferenceData: ConferenceData?

    /// Whether Google should email the invitees (`sendUpdates=all`).
    public var sendsInvitations: Bool { !(attendees ?? []).isEmpty }

    /// Returns nil when Google Calendar can’t represent the draft faithfully; for a Meet-only draft the
    /// caller then saves through Apple Calendar with a standalone link, so nothing the user chose is lost.
    public init?(draft: EventDraft, accountEmail: String, requestID: String = UUID().uuidString) {
        guard draft.validationMessage == nil, Self.unsupportedFeature(in: draft, accountEmail: accountEmail) == nil,
              let reminders = Self.reminders(for: draft.alerts, accountEmail: accountEmail) else { return nil }
        let calendar = draft.calendar
        summary = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let call = EventDraft.webURL(draft.meetingURL)
        // A Meet room made from the editor is attached as the event’s conference rather than written into the notes.
        let existingMeet = draft.addsGoogleMeet ? call.flatMap(ConferenceData.init(existing:)) : nil
        var lines = [draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        if let url = EventDraft.webURL(draft.url) { lines.append(url.absoluteString) }
        if let call, existingMeet == nil { lines.append("Video call: \(call.absoluteString)") }
        description = lines.joined(separator: "\n\n").nilIfEmpty
        if draft.isAllDay {
            start = Time(date: Self.format(draft.savedStart, "yyyy-MM-dd", calendar.timeZone))
            end = Time(date: Self.format(draft.savedEnd, "yyyy-MM-dd", calendar.timeZone))
        } else {
            // Google has no floating time; a floating draft uses this Mac’s zone, as Apple Calendar does on sync.
            let zone = calendar.timeZone
            start = Time(dateTime: Self.format(draft.savedStart, "yyyy-MM-dd'T'HH:mm:ssxxxxx", zone), timeZone: zone.identifier)
            end = Time(dateTime: Self.format(draft.savedEnd, "yyyy-MM-dd'T'HH:mm:ssxxxxx", zone), timeZone: zone.identifier)
        }
        recurrence = draft.recurrence.rrule(start: draft.savedStart, calendar: calendar, isAllDay: draft.isAllDay).map { [$0] }
        transparency = draft.availability == .free ? "transparent" : "opaque"
        self.reminders = reminders
        let guests = Invitees.merging(draft.invitees, into: [])
            .filter { $0.caseInsensitiveCompare(accountEmail) != .orderedSame }
        attendees = guests.isEmpty ? nil : guests.map { Attendee(email: $0) }
        conferenceData = existingMeet ?? (draft.addsGoogleMeet ? ConferenceData(createRequest: .init(requestId: requestID)) : nil)
    }

    /// Names what Google Calendar can’t store, for the message shown when invitees require Google.
    public static func unsupportedFeature(in draft: EventDraft, accountEmail: String) -> String? {
        if ![.busy, .free].contains(draft.availability) { return "“Show as \(draft.availability.rawValue)”" }
        if draft.alerts.count > maximumReminders { return "more than \(maximumReminders) alerts" }
        for alert in draft.alerts {
            if alert.timing != .before { return "alerts after the start or on a set date" }
            if alert.action == .sound { return "alerts with sound" }
            if alert.amount * alert.unit.rawValue / 60 > maximumReminderMinutes { return "alerts more than four weeks before" }
            if alert.action == .email, alert.email.caseInsensitiveCompare(accountEmail) != .orderedSame {
                return "email alerts to another address"
            }
        }
        return nil
    }

    /// Google reminders are relative and before the event only; popups or emails to the calendar owner.
    static func reminders(for alerts: [EventAlert], accountEmail: String) -> Reminders? {
        guard alerts.count <= maximumReminders else { return nil }
        var overrides: [Reminder] = []
        for alert in alerts {
            guard alert.timing == .before else { return nil }
            let minutes = alert.amount * alert.unit.rawValue / 60
            guard (0...maximumReminderMinutes).contains(minutes) else { return nil }
            switch alert.action {
            case .message: overrides.append(Reminder(method: "popup", minutes: minutes))
            case .email:
                guard alert.email.caseInsensitiveCompare(accountEmail) == .orderedSame else { return nil }
                overrides.append(Reminder(method: "email", minutes: minutes))
            case .sound: return nil
            }
        }
        // CaliBar drafts start without alerts; keep that rather than applying Google’s calendar defaults.
        return Reminders(useDefault: false, overrides: overrides)
    }

    static func format(_ date: Date, _ pattern: String, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

extension EventRecurrence {
    private static let weekdayCodes = [1: "SU", 2: "MO", 3: "TU", 4: "WE", 5: "TH", 6: "FR", 7: "SA"]

    /// RFC 5545 RRULE matching `makeRule(calendar:)`, for calendars written through an API rather than EventKit.
    public func rrule(start: Date, calendar: Calendar, isAllDay: Bool) -> String? {
        guard frequency != .never else { return nil }
        let name: String
        switch frequency { case .daily: name = "DAILY"; case .weekly: name = "WEEKLY"; case .monthly: name = "MONTHLY"; default: name = "YEARLY" }
        var parts = ["FREQ=\(name)", "INTERVAL=\(max(1, interval))"]
        if frequency == .weekly && !weekdays.isEmpty {
            parts.append("BYDAY=" + weekdays.sorted().compactMap { Self.weekdayCodes[$0] }.joined(separator: ","))
        } else if usesOrdinal && (frequency == .monthly || frequency == .yearly) {
            if ordinalDay <= 7 {
                parts.append("BYDAY=\(ordinal)\(Self.weekdayCodes[ordinalDay] ?? "MO")")
            } else {
                let days = ordinalDay == 8 ? Array(1...7) : ordinalDay == 9 ? Array(2...6) : [1, 7]
                parts.append("BYDAY=" + days.compactMap { Self.weekdayCodes[$0] }.joined(separator: ","))
                parts.append("BYSETPOS=\(ordinal)")
            }
        }
        if frequency == .monthly && !usesOrdinal && !monthDays.isEmpty {
            parts.append("BYMONTHDAY=" + monthDays.sorted().map(String.init).joined(separator: ","))
        }
        if frequency == .yearly {
            let chosen = months.isEmpty ? [calendar.component(.month, from: start)] : months.sorted()
            parts.append("BYMONTH=" + chosen.map(String.init).joined(separator: ","))
        }
        switch ending {
        case .never: break
        case .after: parts.append("COUNT=\(max(1, count))")
        case .onDate:
            let lastDay = calendar.startOfDay(for: until)
            if isAllDay {
                parts.append("UNTIL=" + GoogleEventBody.format(lastDay, "yyyyMMdd", calendar.timeZone))
            } else {
                let last = calendar.date(byAdding: .day, value: 1, to: lastDay)!.addingTimeInterval(-1)
                parts.append("UNTIL=" + GoogleEventBody.format(last, "yyyyMMdd'T'HHmmss'Z'", TimeZone(identifier: "UTC")!))
            }
        }
        return "RRULE:" + parts.joined(separator: ";")
    }
}

public struct GoogleCalendarListEntry: Decodable, Equatable, Sendable {
    public let id: String
    public let summary: String?
    public let summaryOverride: String?
    public let primary: Bool?
    public let accessRole: String?

    public init(id: String, summary: String?, summaryOverride: String? = nil, primary: Bool? = nil, accessRole: String? = "owner") {
        self.id = id; self.summary = summary; self.summaryOverride = summaryOverride; self.primary = primary; self.accessRole = accessRole
    }

    var isWritable: Bool { ["owner", "writer"].contains(accessRole ?? "") }
    var names: Set<String> {
        var values = [summaryOverride, summary].compactMap { $0?.lowercased() }
        if primary == true { values.append(id.lowercased()) }
        return Set(values.filter { !$0.isEmpty })
    }
}

public struct GoogleCreatedEvent: Decodable, Sendable {
    struct Conference: Decodable, Sendable {
        struct EntryPoint: Decodable, Sendable { let entryPointType: String?; let uri: String? }
        let entryPoints: [EntryPoint]?
    }
    public let id: String
    public let htmlLink: URL?
    public let hangoutLink: URL?
    let conferenceData: Conference?

    public var meetURL: URL? {
        hangoutLink ?? conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri.flatMap(URL.init(string:))
    }
}

public enum GoogleCalendarMatch {
    /// A best guess, without asking Google, at whether a calendar is synced from a Google account. EventKit
    /// doesn’t say which server an account uses, so this reads the account’s name and its calendars’ titles.
    public static func looksLikeGoogle(_ calendar: CalendarInfo, among calendars: [CalendarInfo]) -> Bool {
        func isGoogleAddress(_ text: String) -> Bool {
            let value = text.lowercased()
            return value.hasSuffix("@gmail.com") || value.hasSuffix("@googlemail.com")
        }
        let sourceName = calendar.sourceName.lowercased()
        if sourceName.contains("google") || sourceName.contains("gmail") { return true }
        if sourceName == "icloud" { return false }
        let source = calendars.filter { $0.sourceID == calendar.sourceID }
        if isGoogleAddress(sourceName) || source.contains(where: { isGoogleAddress($0.title) }) { return true }
        // A CalDAV account named by an email address, or whose main calendar is titled with one, is almost
        // always Google (including Workspace domains): Google names each account’s primary calendar after it.
        return calendar.isCalDAV && (Invitees.isEmailAddress(calendar.sourceName) || source.contains { Invitees.isEmailAddress($0.title) })
    }

    /// The Google account emails a calendar’s Apple Calendar account might belong to: its name when that’s an
    /// email address, otherwise its calendars titled with one (Google names each primary calendar after the account).
    public static func accountEmails(for calendar: CalendarInfo, among calendars: [CalendarInfo]) -> [String] {
        if Invitees.isEmailAddress(calendar.sourceName) { return [calendar.sourceName.lowercased()] }
        var seen = Set<String>()
        return calendars.filter { $0.sourceID == calendar.sourceID && Invitees.isEmailAddress($0.title) }
            .map { $0.title.lowercased() }
            .filter { seen.insert($0).inserted }
    }

    /// Finds the Google calendar behind an Apple Calendar (CalDAV) calendar. EventKit doesn’t expose
    /// Google’s calendar IDs, so this matches on the account and calendar names and returns nil when unsure.
    public static func calendarID(for calendar: CalendarInfo, among calendars: [CalendarInfo],
                                  google entries: [GoogleCalendarListEntry], accountEmail: String) -> String? {
        let email = accountEmail.lowercased()
        let source = calendars.filter { $0.sourceID == calendar.sourceID }
        let primaryNames = entries.first { $0.primary == true }?.names ?? [email]
        let sourceName = calendar.sourceName.lowercased()
        guard sourceName != "icloud" else { return nil }
        // People often rename the account in Apple Calendar (“Work”) and the primary calendar in Google (“General”),
        // so a CalDAV account holding a calendar named like this account’s primary one counts too.
        let sourceIsAccount = sourceName == email
            || source.contains { $0.title.lowercased() == email }
            || ((sourceName.contains("google") || calendar.isCalDAV) && source.contains { primaryNames.contains($0.title.lowercased()) })
        guard sourceIsAccount else { return nil }
        let title = calendar.title.lowercased()
        let matches = entries.filter { $0.isWritable && $0.names.contains(title) }
        return matches.count == 1 ? matches[0].id : nil
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
