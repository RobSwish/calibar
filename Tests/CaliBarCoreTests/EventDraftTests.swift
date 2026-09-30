import EventKit
import Foundation
import Testing
@testable import CaliBarCore

@Suite("Event creation")
struct EventDraftTests {
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    var london: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }
    func draft() -> EventDraft {
        var d = EventDraft(day: date("2026-03-29T12:00:00Z"), now: date("2026-03-01T12:00:00Z"), calendar: london)
        d.calendarID = "test-calendar"
        d.title = "Design review"
        return d
    }
    @Test func allDayUsesExclusiveEndAcrossDST() throws {
        var d = draft()
        d.isAllDay = true
        d.end = d.start
        #expect(d.savedStart == date("2026-03-29T00:00:00Z"))
        #expect(d.savedEnd == date("2026-03-29T23:00:00Z"))
        #expect(d.savedEnd.timeIntervalSince(d.savedStart) == 23 * 3600)
        let event = try d.makeEvent(in: EKEventStore())
        #expect(event.isAllDay)
        #expect(event.timeZone == nil)
        #expect(event.endDate == d.savedEnd.addingTimeInterval(-1))
        #expect(CalendarDates.exclusiveEnd(event.endDate, isAllDay: true, calendar: london) == d.savedEnd)
    }
    @Test func multiDayAndInvalidDates() {
        var d = draft()
        d.isAllDay = true
        d.end = london.date(byAdding: .day, value: 2, to: d.start)!
        #expect(d.savedEnd == date("2026-03-31T23:00:00Z"))
        d.end = london.date(byAdding: .day, value: -1, to: d.start)!
        #expect(d.validationMessage == "The end must be after the start.")
        d.isAllDay = false
        d.end = d.start
        #expect(d.validationMessage != nil)
    }
    @Test func changingStartPreservesDuration() {
        var d = draft()
        let duration = d.end.timeIntervalSince(d.start)
        d.moveStart(to: d.start.addingTimeInterval(7200))
        #expect(d.end.timeIntervalSince(d.start) == duration)
        d.isAllDay = true
        d.end = london.date(byAdding: .day, value: 2, to: d.start)!
        d.moveStart(to: london.date(byAdding: .month, value: 1, to: d.start)!)
        #expect(london.dateComponents([.day], from: d.start, to: d.end).day == 2)
    }
    @Test func zoneChangePreservesWallClockAndFloatingSavesNil() throws {
        var d = draft()
        let originalHour = london.component(.hour, from: d.start)
        d.changeTimeZone(to: "America/New_York")
        #expect(d.calendar.component(.hour, from: d.start) == originalHour)
        #expect(d.end.timeIntervalSince(d.start) == 3600)
        #expect(try d.makeEvent(in: EKEventStore()).timeZone?.identifier == "America/New_York")
        d.changeTimeZone(to: "")
        #expect(try d.makeEvent(in: EKEventStore()).timeZone == nil)
    }
    @Test func allDayAfterZoneChangeKeepsTheChosenCalendarDay() throws {
        var d = draft()
        d.changeTimeZone(to: "America/New_York")
        d.setAllDay(true)
        #expect(d.calendar.timeZone.identifier == "Europe/London")
        #expect(d.savedStart == date("2026-03-29T00:00:00Z"))
        #expect(d.savedEnd == date("2026-03-29T23:00:00Z"))
        d.setAllDay(false)
        #expect(d.calendar.component(.hour, from: d.start) == 9)
        #expect(d.calendar.timeZone.identifier == "America/New_York")
    }
    @Test func linksAndNotesSurviveTogether() throws {
        var d = draft()
        d.title = "  Design review  "
        d.location = "  London  "
        d.notes = "Bring mockups"
        d.url = "https://example.com/agenda"
        d.meetingURL = "https://meet.google.com/abc-defg-hij"
        let e = try d.makeEvent(in: EKEventStore())
        #expect(e.title == "Design review")
        #expect(e.location == "London")
        #expect(e.url?.absoluteString == d.url)
        #expect(e.notes == "Bring mockups\n\nVideo call: https://meet.google.com/abc-defg-hij")
        #expect(MeetingLink.find(url: e.url, location: e.location, notes: e.notes)?.provider == "Google Meet")
    }
    @Test func validationPreventsIncompleteOrUnsafeDrafts() {
        var d = draft()
        d.title = " \n "
        #expect(d.validationMessage == "Enter an event title.")
        d.title = "Event"
        d.calendarID = ""
        #expect(d.validationMessage != nil)
        d.calendarID = "test"
        for invalid in ["javascript:alert(1)", "file:///tmp/file", "https://", "meet.google.com/abc"] {
            d.meetingURL = invalid
            #expect(d.validationMessage != nil)
        }
        d.meetingURL = "https://meet.google.com/abc"
        #expect(d.validationMessage == nil)
    }
    @Test func customWeeklyAndCount() throws {
        var d = draft()
        d.recurrence.frequency = .weekly
        d.recurrence.interval = 2
        d.recurrence.weekdays = [2, 4, 6]
        d.recurrence.ending = .after
        d.recurrence.count = 12
        let e = try d.makeEvent(in: EKEventStore())
        let rule = try #require(e.recurrenceRules?.first)
        #expect(rule.frequency == .weekly)
        #expect(rule.interval == 2)
        #expect(rule.daysOfTheWeek?.map(\.dayOfTheWeek.rawValue) == [2, 4, 6])
        #expect(rule.recurrenceEnd?.occurrenceCount == 12)
    }
    @Test func lastWeekdayAndInclusiveRepeatEnd() throws {
        var d = draft()
        d.recurrence.frequency = .monthly
        d.recurrence.usesOrdinal = true
        d.recurrence.ordinal = -1
        d.recurrence.ordinalDay = 9
        d.recurrence.ending = .onDate
        d.recurrence.until = date("2026-10-25T12:00:00Z")
        let rule = try #require(try d.makeEvent(in: EKEventStore()).recurrenceRules?.first)
        #expect(rule.setPositions == [-1])
        #expect(rule.daysOfTheWeek?.map(\.dayOfTheWeek.rawValue) == [2, 3, 4, 5, 6])
        #expect(rule.recurrenceEnd?.endDate == date("2026-10-25T23:59:59Z"))
    }
    @Test func monthlyDatesAndYearlyMonths() throws {
        var d = draft()
        d.recurrence.frequency = .monthly
        d.recurrence.monthDays = [1, 15, 31]
        let monthly = try #require(try d.makeEvent(in: EKEventStore()).recurrenceRules?.first)
        #expect(monthly.daysOfTheMonth == [1, 15, 31])
        d.recurrence.frequency = .yearly
        d.recurrence.months = [3, 9]
        let yearly = try #require(try d.makeEvent(in: EKEventStore()).recurrenceRules?.first)
        #expect(yearly.monthsOfTheYear == [3, 9])
        #expect(yearly.daysOfTheMonth == nil)
    }
    @Test func yearlyOrdinalAppliesToEachChosenMonth() throws {
        var d = draft()
        d.recurrence.frequency = .yearly
        d.recurrence.months = [3, 9]
        d.recurrence.usesOrdinal = true
        d.recurrence.ordinal = 2
        d.recurrence.ordinalDay = 2
        let rule = try #require(try d.makeEvent(in: EKEventStore()).recurrenceRules?.first)
        #expect(rule.daysOfTheWeek?.first?.weekNumber == 2)
        #expect(rule.setPositions == nil)
        #expect(rule.monthsOfTheYear == [3, 9])
        d.recurrence.ordinalDay = 9
        #expect(d.validationMessage != nil)
        d.recurrence.months = []
        let implicitMonth = try #require(try d.makeEvent(in: EKEventStore()).recurrenceRules?.first)
        #expect(implicitMonth.monthsOfTheYear == [3])
    }
    @Test func invalidRepeatsDoNotReachEventKit() {
        var d = draft()
        d.recurrence.frequency = .weekly
        d.recurrence.interval = 0
        #expect(throws: EventCreationError.self) { try d.makeEvent(in: EKEventStore()) }
        d.recurrence.interval = 1
        d.recurrence.ending = .onDate
        d.recurrence.until = date("2026-01-01T12:00:00Z")
        #expect(d.validationMessage != nil)
    }
    @Test func multipleAlertsAndActions() throws {
        var d = draft()
        var before = EventAlert(date: d.start)
        before.amount = 2; before.unit = .hours; before.action = .sound
        var after = EventAlert(date: d.start)
        after.timing = .after; after.amount = 5
        var absolute = EventAlert(date: date("2026-03-28T10:00:00Z"))
        absolute.timing = .onDate; absolute.action = .email; absolute.email = "test@example.com"
        d.alerts = [before, after, absolute]
        let alerts = try #require(try d.makeEvent(in: EKEventStore()).alarms)
        #expect(alerts.count == 3)
        #expect(alerts.contains { $0.relativeOffset == -7200 && $0.soundName == "Glass" })
        #expect(alerts.contains { $0.relativeOffset == 300 })
        #expect(alerts.contains { $0.absoluteDate == absolute.date && $0.emailAddress == "test@example.com" })
    }
}
