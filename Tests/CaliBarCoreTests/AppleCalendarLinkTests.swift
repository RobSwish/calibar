import Foundation
import Testing
@testable import CaliBarCore

@Test func standaloneCalendarLinkEscapesIdentifiers() {
    let url = AppleCalendarLink.url(identifier: "id/a?b#c%", start: .distantPast, isRecurring: false, isAllDay: false)
    #expect(url?.absoluteString == "ical://ekevent/id%2Fa%3Fb%23c%25?method=show&options=more")
    #expect(AppleCalendarLink.url(identifier: "", start: .now, isRecurring: false, isAllDay: false) == nil)
}

@Test func recurringTimedLinkUsesUTC() {
    let date = ISO8601DateFormatter().date(from: "2026-09-29T09:30:00Z")!
    let url = AppleCalendarLink.url(identifier: "event-id", start: date, isRecurring: true, isAllDay: false,
                                    timeZone: TimeZone(identifier: "Europe/London")!)
    #expect(url?.absoluteString == "ical://ekevent/20260929T093000Z/event-id?method=show&options=more")
}

@Test func recurringAllDayLinkPreservesLocalDay() {
    // Midnight in London is the previous UTC date during summer time.
    let date = ISO8601DateFormatter().date(from: "2026-09-28T23:00:00Z")!
    let url = AppleCalendarLink.url(identifier: "event-id", start: date, isRecurring: true, isAllDay: true,
                                    timeZone: TimeZone(identifier: "Europe/London")!)
    #expect(url?.absoluteString == "ical://ekevent/20260929T000000Z/event-id?method=show&options=more")
}
