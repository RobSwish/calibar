import Foundation
import Testing
@testable import CaliBarCore

@Suite("Calendar boundaries")
struct CalendarDateTests {
    let info = CalendarInfo(id: "work", title: "Work", sourceID: "local", sourceName: "On My Mac", red: 0, green: 0, blue: 1)
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func event(_ start: String, _ end: String, allDay: Bool = false, title: String = "Event") -> CalendarEvent {
        CalendarEvent(id: title, title: title, start: date(start), end: date(end), isAllDay: allDay, calendar: info)
    }

    @Test func allDayEndIsExclusive() {
        let event = event("2026-09-29T00:00:00Z", "2026-10-01T00:00:00Z", allDay: true)
        #expect(event.occurs(on: date("2026-09-29T12:00:00Z"), using: utc))
        #expect(event.occurs(on: date("2026-09-30T12:00:00Z"), using: utc))
        #expect(!event.occurs(on: date("2026-10-01T00:00:00Z"), using: utc))
    }

    @Test func midnightEndingEventDoesNotLeakIntoNextDay() {
        let event = event("2026-09-29T23:00:00Z", "2026-09-30T00:00:00Z")
        #expect(event.occurs(on: date("2026-09-29T00:00:00Z"), using: utc))
        #expect(!event.occurs(on: date("2026-09-30T00:00:00Z"), using: utc))
    }

    @Test func overnightEventAppearsOnBothDays() {
        let event = event("2026-09-29T23:00:00Z", "2026-09-30T01:00:00Z")
        #expect(event.occurs(on: date("2026-09-29T12:00:00Z"), using: utc))
        #expect(event.occurs(on: date("2026-09-30T12:00:00Z"), using: utc))
    }

    @Test func zeroDurationEventBelongsToOneDay() {
        let event = event("2026-09-30T00:00:00Z", "2026-09-30T00:00:00Z")
        #expect(!event.occurs(on: date("2026-09-29T12:00:00Z"), using: utc))
        #expect(event.occurs(on: date("2026-09-30T12:00:00Z"), using: utc))
    }

    @Test func monthGridRespectsWeekStartAndLeapDay() {
        let days = CalendarDates.monthDays(containing: date("2024-02-15T12:00:00Z"), calendar: utc)
        #expect(days.count == 42)
        #expect(days.first == date("2024-01-29T00:00:00Z"))
        #expect(days.contains(date("2024-02-29T00:00:00Z")))
        var sunday = utc
        sunday.firstWeekday = 1
        let other = CalendarDates.monthDays(containing: date("2024-02-15T12:00:00Z"), calendar: sunday)
        #expect(other.first == date("2024-01-28T00:00:00Z"))
    }

    @Test func gridUsesLocalDatesAcrossDaylightSaving() {
        var london = utc
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let days = CalendarDates.monthDays(containing: date("2026-03-15T12:00:00Z"), calendar: london)
        #expect(days.count == 42)
        #expect(Set(days).count == 42)
        #expect(days.allSatisfy { london.component(.hour, from: $0) == 0 })
        let march29 = days.first { london.component(.month, from: $0) == 3 && london.component(.day, from: $0) == 29 }!
        let march30 = london.date(byAdding: .day, value: 1, to: march29)!
        #expect(march30.timeIntervalSince(march29) == 23 * 60 * 60)
    }

    @Test func allDaySortsBeforeTimedEvents() {
        let timed = event("2026-09-29T09:00:00Z", "2026-09-29T10:00:00Z", title: "Timed")
        let allDay = event("2026-09-29T00:00:00Z", "2026-09-30T00:00:00Z", allDay: true, title: "All day")
        let other = event("2026-09-30T09:00:00Z", "2026-09-30T10:00:00Z", title: "Tomorrow")
        let selected = CalendarDates.events(on: date("2026-09-29T12:00:00Z"), from: [other, timed, allDay], calendar: utc)
        #expect(selected.map(\.title) == ["All day", "Timed"])
    }
}
