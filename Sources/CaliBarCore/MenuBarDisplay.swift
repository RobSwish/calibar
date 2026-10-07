import Foundation

public enum MenuBarDateStyle: String, CaseIterable, Identifiable, Sendable {
    case hidden, day, weekdayAndDay, dayAndMonth, weekdayAndMonth, fullDate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hidden: "Hidden"
        case .day: "Day number"
        case .weekdayAndDay: "Weekday and day"
        case .dayAndMonth: "Day and month"
        case .weekdayAndMonth: "Weekday, day and month"
        case .fullDate: "Full date"
        }
    }

    public func formatted(_ date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        switch self {
        case .hidden: return ""
        case .day: formatter.setLocalizedDateFormatFromTemplate("d")
        case .weekdayAndDay: formatter.setLocalizedDateFormatFromTemplate("EEEd")
        case .dayAndMonth: formatter.setLocalizedDateFormatFromTemplate("dMMM")
        case .weekdayAndMonth: formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        case .fullDate: formatter.setLocalizedDateFormatFromTemplate("EEEdMMMy")
        }
        return formatter.string(from: date)
    }
}

public struct MenuBarPreferences: Sendable {
    public var dateStyle: MenuBarDateStyle = .day
    public var showsNextEvent: Bool = true
    public var nextEventTodayOnly: Bool = false

    public init() {}

    public static func load(from defaults: UserDefaults) -> MenuBarPreferences {
        var preferences = MenuBarPreferences()
        if let value = defaults.string(forKey: "menuBarDateStyle"), let style = MenuBarDateStyle(rawValue: value) {
            preferences.dateStyle = style
        }
        // An absent setting opts in; an explicitly saved false stays off.
        preferences.showsNextEvent = defaults.object(forKey: "menuBarShowsNextEvent") as? Bool ?? true
        preferences.nextEventTodayOnly = defaults.bool(forKey: "menuBarNextEventTodayOnly")
        return preferences
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(dateStyle.rawValue, forKey: "menuBarDateStyle")
        defaults.set(showsNextEvent, forKey: "menuBarShowsNextEvent")
        defaults.set(nextEventTodayOnly, forKey: "menuBarNextEventTodayOnly")
    }
}

public enum MenuBarDisplay {
    /// The event in progress, if any, otherwise the next one to start.
    public static func nextEvent(in events: [CalendarEvent], now: Date, todayOnly: Bool = false,
                                 calendar: Calendar = .current) -> CalendarEvent? {
        let timed = events.filter { !$0.isAllDay }
        // While an appointment is on, keep it in the menu bar until it ends. With
        // overlaps, the one that began most recently is the one you're likely in.
        if let current = timed.filter({ isOngoing($0, now: now) }).max(by: { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end > rhs.end }
            return lhs.id > rhs.id
        }) {
            return current
        }
        let end = todayOnly ? calendar.dateInterval(of: .day, for: now)?.end : calendar.date(byAdding: .day, value: 30, to: now)
        guard let horizon = end else { return nil }
        return timed.filter { $0.start >= now && $0.start < horizon }
            .min { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.id < rhs.id
            }
    }

    public static func title(now: Date, preferences: MenuBarPreferences, nextEvent: CalendarEvent?,
                             locale: Locale = .current, calendar: Calendar = .current) -> String {
        var components = [preferences.dateStyle.formatted(now, locale: locale, calendar: calendar)]
        if preferences.showsNextEvent, let nextEvent {
            let title = nextEvent.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            components.append(title.count > 24 ? String(title.prefix(23)) + "…" : title)
            components.append(isOngoing(nextEvent, now: now)
                ? "until " + eventTime(nextEvent.end, now: now, locale: locale, calendar: calendar)
                : eventTime(nextEvent.start, now: now, locale: locale, calendar: calendar))
        }
        return components.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public static func isOngoing(_ event: CalendarEvent, now: Date) -> Bool {
        event.start <= now && now < event.end
    }

    public static func eventTime(_ start: Date, now: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        if calendar.isDate(start, inSameDayAs: now) { return formatter.string(from: start) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: tomorrow) {
            return "Tomorrow " + formatter.string(from: start)
        }
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        let day = formatter.string(from: start)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return day + " " + formatter.string(from: start)
    }
}
