import Foundation
import Testing
@testable import CaliBarCore

@Suite("Menu bar display")
struct MenuBarDisplayTests {
    let info = CalendarInfo(id: "work", title: "Work", sourceID: "local", sourceName: "On My Mac", red: 0, green: 0, blue: 1)
    let locale = Locale(identifier: "en_GB")
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/London")!
        return value
    }
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func event(_ title: String, start: Date, end: Date? = nil, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: title, title: title, start: start, end: end ?? start.addingTimeInterval(1800), isAllDay: allDay, calendar: info)
    }

    @Test func nextEventDefaultsOnAndExplicitOffSurvivesRelaunch() {
        let name = "CaliBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(MenuBarPreferences.load(from: defaults).showsNextEvent)
        #expect(!MenuBarPreferences.load(from: defaults).nextEventTodayOnly)
        var preferences = MenuBarPreferences()
        preferences.showsNextEvent = false
        preferences.nextEventTodayOnly = true
        preferences.dateStyle = .hidden
        preferences.save(to: defaults)
        let reloaded = MenuBarPreferences.load(from: defaults)
        #expect(!reloaded.showsNextEvent)
        #expect(reloaded.dateStyle == .hidden)
        #expect(reloaded.nextEventTodayOnly)
        preferences.nextEventTodayOnly = false
        preferences.save(to: defaults)
        #expect(!MenuBarPreferences.load(from: defaults).nextEventTodayOnly)
    }

    @Test func picksEarliestFutureTimedEvent() {
        let now = date("2026-09-29T10:00:00Z")
        let next = event("Next", start: now.addingTimeInterval(600))
        let events = [
            event("Later", start: now.addingTimeInterval(3600)),
            event("Just ended", start: now.addingTimeInterval(-1800), end: now),
            event("All day", start: now.addingTimeInterval(1), allDay: true),
            next,
            event("Past", start: now.addingTimeInterval(-7200))
        ]
        #expect(MenuBarDisplay.nextEvent(in: events, now: now, calendar: calendar)?.id == "Next")
        let farFuture = event("Far away", start: now.addingTimeInterval(40 * 86400))
        #expect(MenuBarDisplay.nextEvent(in: [farFuture], now: now, calendar: calendar) == nil)
    }

    @Test(arguments: [
        ("2026-09-29T20:00:00Z", "2026-09-29T22:59:59Z", "2026-09-29T23:00:00Z"),
        ("2026-03-29T00:30:00Z", "2026-03-29T22:59:59Z", "2026-03-29T23:00:00Z"),
        ("2026-10-25T00:30:00Z", "2026-10-25T23:59:59Z", "2026-10-26T00:00:00Z")
    ])
    func todayOnlyEndsAtLocalMidnight(times: (String, String, String)) {
        let now = date(times.0)
        let tonight = event("Tonight", start: date(times.1))
        let tomorrow = event("Tomorrow", start: date(times.2))
        let excluded = [
            event("Finished", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-60)),
            event("All day", start: now, allDay: true),
            tomorrow
        ]
        #expect(MenuBarDisplay.nextEvent(in: excluded + [tonight], now: now, todayOnly: true, calendar: calendar)?.id == "Tonight")
        #expect(MenuBarDisplay.nextEvent(in: excluded, now: now, todayOnly: true, calendar: calendar) == nil)
        #expect(MenuBarDisplay.nextEvent(in: excluded, now: now, calendar: calendar)?.id == "Tomorrow")
        #expect(MenuBarDisplay.nextEvent(in: [tomorrow], now: tomorrow.start, todayOnly: true, calendar: calendar)?.id == "Tomorrow")
    }

    @Test func ongoingEventStaysUntilItEnds() {
        let now = date("2026-09-29T10:00:00Z")
        let ongoing = event("Standup", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(900))
        let soon = event("Design review", start: now.addingTimeInterval(300))
        let allDay = event("Holiday", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(80000), allDay: true)
        let events = [soon, ongoing, allDay]
        #expect(MenuBarDisplay.nextEvent(in: events, now: now, calendar: calendar)?.id == "Standup")
        #expect(MenuBarDisplay.nextEvent(in: events, now: now, todayOnly: true, calendar: calendar)?.id == "Standup")
        // The moment it ends, the next event takes over.
        #expect(MenuBarDisplay.nextEvent(in: events, now: ongoing.end, calendar: calendar)?.id == "Design review")
        // An all-day event alone never counts as "now".
        #expect(MenuBarDisplay.nextEvent(in: [allDay], now: now, calendar: calendar) == nil)
    }

    @Test func overlappingEventsPreferTheMostRecentStart() {
        let now = date("2026-09-29T10:00:00Z")
        let block = event("Focus block", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(7200))
        let call = event("Client call", start: now.addingTimeInterval(-300), end: now.addingTimeInterval(1500))
        #expect(MenuBarDisplay.nextEvent(in: [block, call], now: now, calendar: calendar)?.id == "Client call")
    }

    @Test func ongoingTitleShowsWhenItEnds() {
        let now = date("2026-09-29T10:00:00Z")
        let ongoing = event("Standup", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(900))
        var preferences = MenuBarPreferences()
        preferences.dateStyle = .hidden
        #expect(MenuBarDisplay.title(now: now, preferences: preferences, nextEvent: ongoing, locale: locale, calendar: calendar)
            == "Standup · until 11:15")
        // An event starting exactly now is in progress, not upcoming.
        let starting = event("Lunch", start: now, end: now.addingTimeInterval(3600))
        #expect(MenuBarDisplay.title(now: now, preferences: preferences, nextEvent: starting, locale: locale, calendar: calendar)
            == "Lunch · until 12:00")
    }

    @Test func dateCanBeHiddenIndependentlyOfTheEvent() {
        let now = date("2026-09-29T10:00:00Z")
        let next = event("Design review", start: now.addingTimeInterval(3600))
        var preferences = MenuBarPreferences()
        preferences.dateStyle = .hidden
        let title = MenuBarDisplay.title(now: now, preferences: preferences, nextEvent: next, locale: locale, calendar: calendar)
        #expect(title == "Design review · 12:00")
        preferences.showsNextEvent = false
        #expect(MenuBarDisplay.title(now: now, preferences: preferences, nextEvent: next).isEmpty)
        preferences.dateStyle = .day
        #expect(MenuBarDisplay.title(now: now, preferences: preferences, nextEvent: next, locale: locale, calendar: calendar) == "29")
    }

    @Test func formatsDateInLocalTimezone() {
        let nearMidnight = date("2026-09-29T23:30:00Z")
        #expect(MenuBarDateStyle.day.formatted(nearMidnight, locale: locale, calendar: calendar) == "30")
        #expect(MenuBarDateStyle.weekdayAndDay.formatted(nearMidnight, locale: locale, calendar: calendar).contains("Wed"))
        #expect(MenuBarDateStyle.fullDate.formatted(nearMidnight, locale: locale, calendar: calendar).contains("2026"))
        #expect(MenuBarDateStyle.hidden.formatted(nearMidnight).isEmpty)
    }

    @Test func tomorrowLabelUsesCalendarDaysAcrossDST() {
        let now = date("2026-03-28T23:30:00Z")
        let start = date("2026-03-29T08:00:00Z")
        #expect(MenuBarDisplay.eventTime(start, now: now, locale: locale, calendar: calendar) == "Tomorrow 09:00")
    }

    @Test func longTitlesStayCompactAndSingleLine() {
        let now = date("2026-09-29T10:00:00Z")
        let next = event("A very long\nproject review with everyone in the team", start: now.addingTimeInterval(60))
        let title = MenuBarDisplay.title(now: now, preferences: MenuBarPreferences(), nextEvent: next, locale: locale, calendar: calendar)
        #expect(!title.contains("\n"))
        #expect(title.contains("…"))
        #expect(title.hasSuffix("11:01"))
    }
}
