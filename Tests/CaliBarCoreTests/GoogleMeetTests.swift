import Foundation
import Testing
@testable import CaliBarCore

@Suite("Google OAuth")
struct GoogleOAuthTests {
    let configuration = GoogleOAuthConfiguration(clientID: "1234-abcd.apps.googleusercontent.com")!

    @Test func rejectsMissingOrUnexpandedClientIDs() {
        #expect(GoogleOAuthConfiguration(clientID: nil) == nil)
        #expect(GoogleOAuthConfiguration(clientID: "") == nil)
        #expect(GoogleOAuthConfiguration(clientID: "$(GOOGLE_CLIENT_ID)") == nil)
        #expect(GoogleOAuthConfiguration(clientID: ".apps.googleusercontent.com") == nil)
        #expect(GoogleOAuthConfiguration(clientID: "abc.example.com") == nil)
    }

    @Test func usesTheReversedClientIDAsRedirect() {
        #expect(configuration.callbackScheme == "com.googleusercontent.apps.1234-abcd")
        #expect(configuration.redirectURI == "com.googleusercontent.apps.1234-abcd:/oauth2redirect")
    }

    @Test func buildsAPKCEAuthorizationRequest() throws {
        let url = configuration.authorizationURL(challenge: "challenge", state: "state", loginHint: "me@example.com")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(url.host == "accounts.google.com")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") == "challenge")
        #expect(value("response_type") == "code")
        #expect(value("login_hint") == "me@example.com")
        #expect(value("scope")?.contains(GoogleOAuthConfiguration.meetScope) == true)
        #expect(value("scope")?.contains(GoogleOAuthConfiguration.calendarEventsScope) == true)
    }

    @Test func readsTheCallbackAndChecksState() throws {
        let callback = URL(string: "com.googleusercontent.apps.1234-abcd:/oauth2redirect?state=s1&code=4/abc")!
        #expect(try configuration.authorizationCode(from: callback, expectedState: "s1") == "4/abc")
        #expect(throws: GoogleError.invalidResponse) { try configuration.authorizationCode(from: callback, expectedState: "other") }
        let denied = URL(string: "com.googleusercontent.apps.1234-abcd:/oauth2redirect?state=s1&error=access_denied")!
        #expect(throws: GoogleError.signInCancelled) { try configuration.authorizationCode(from: denied, expectedState: "s1") }
    }

    @Test func pkceChallengeMatchesRFC7636Example() {
        // RFC 7636 appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE().verifier.count >= 43)
    }

    @Test func readsEmailFromIDToken() {
        let payload = Data(#"{"email":"me@example.com","sub":"1"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        #expect(GoogleIDToken.email(from: "header.\(payload).signature") == "me@example.com")
        #expect(GoogleIDToken.email(from: "not-a-token") == nil)
    }

    @Test func classifiesPermissionErrors() {
        let body = Data(#"{"error":{"code":403,"message":"Insufficient Permission","errors":[{"reason":"insufficientPermissions"}]}}"#.utf8)
        #expect(throws: GoogleError.missingPermission) { try GoogleClient.check(status: 403, data: body) }
        #expect(throws: GoogleError.http(status: 500, message: "Backend")) {
            try GoogleClient.check(status: 500, data: Data(#"{"error":{"message":"Backend"}}"#.utf8))
        }
        #expect(GoogleError.http(status: 400, message: "").isRejection)
        #expect(!GoogleError.http(status: 503, message: "").isRejection)
    }
}

@Suite("Google event body")
struct GoogleEventBodyTests {
    let london = TimeZone(identifier: "Europe/London")!

    func draft(_ start: String = "2026-11-10T09:00:00Z") -> EventDraft {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = london
        let date = ISO8601DateFormatter().date(from: start)!
        var draft = EventDraft(day: date, now: date.addingTimeInterval(-86400 * 3), calendar: calendar)
        draft.title = "  Planning  "
        draft.calendarID = "work"
        draft.addsGoogleMeet = true
        return draft
    }

    func json(_ body: GoogleEventBody) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }

    @Test func timedEventRequestsAMeetConference() throws {
        var value = draft()
        value.location = "Studio"
        value.notes = "Agenda"
        let body = try #require(GoogleEventBody(draft: value, accountEmail: "me@example.com", requestID: "req-1"))
        #expect(body.summary == "Planning")
        #expect(body.location == "Studio")
        #expect(body.description == "Agenda")
        #expect(body.start == .init(dateTime: "2026-11-10T09:00:00+00:00", timeZone: "Europe/London"))
        #expect(body.end == .init(dateTime: "2026-11-10T10:00:00+00:00", timeZone: "Europe/London"))
        #expect(body.recurrence == nil)
        #expect(body.transparency == "opaque")
        #expect(body.reminders == .init(useDefault: false, overrides: []))
        let object = try json(body)
        let conference = try #require(object["conferenceData"] as? [String: Any])
        let request = try #require(conference["createRequest"] as? [String: Any])
        #expect(request["requestId"] as? String == "req-1")
        #expect((request["conferenceSolutionKey"] as? [String: Any])?["type"] as? String == "hangoutsMeet")
        #expect(object["recurrence"] == nil)
        #expect((object["start"] as? [String: Any])?["date"] == nil)
    }

    @Test func allDayEventsUseExclusiveEndDates() throws {
        var value = draft()
        value.setAllDay(true)
        let body = try #require(GoogleEventBody(draft: value, accountEmail: "me@example.com"))
        #expect(body.start == .init(date: "2026-11-10"))
        #expect(body.end == .init(date: "2026-11-11"))
    }

    @Test func freeTimeIsTransparentAndUnsupportedAvailabilityFallsBack() {
        var value = draft()
        value.availability = .free
        #expect(GoogleEventBody(draft: value, accountEmail: "me@example.com")?.transparency == "transparent")
        value.availability = .tentative
        #expect(GoogleEventBody(draft: value, accountEmail: "me@example.com") == nil)
    }

    @Test func mapsAlertsGoogleCanRepresent() throws {
        var value = draft()
        var popup = EventAlert(date: value.start)
        popup.amount = 2; popup.unit = .hours
        var email = EventAlert(date: value.start)
        email.action = .email; email.email = "ME@example.com"; email.amount = 1; email.unit = .days
        value.alerts = [popup, email]
        let body = try #require(GoogleEventBody(draft: value, accountEmail: "me@example.com"))
        #expect(body.reminders.overrides == [.init(method: "popup", minutes: 120), .init(method: "email", minutes: 1440)])
    }

    @Test(arguments: [0, 1, 2, 3])
    func fallsBackForAlertsGoogleCannotRepresent(_ variant: Int) {
        var value = draft()
        var alert = EventAlert(date: value.start)
        switch variant {
        case 0: alert.timing = .after
        case 1: alert.action = .sound
        case 2: alert.action = .email; alert.email = "someone.else@example.com"
        default: alert.amount = 5; alert.unit = .weeks
        }
        value.alerts = [alert]
        #expect(GoogleEventBody(draft: value, accountEmail: "me@example.com") == nil)
    }

    @Test func keepsURLAndPastedLinksInTheDescription() throws {
        var value = draft()
        value.url = "https://example.com/doc"
        let body = try #require(GoogleEventBody(draft: value, accountEmail: "me@example.com"))
        #expect(body.description == "https://example.com/doc")
    }
}

@Suite("Google recurrence rules")
struct GoogleRecurrenceTests {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/London")!
        return value
    }
    let start = ISO8601DateFormatter().date(from: "2026-11-10T09:00:00Z")!

    @Test func weeklyOnChosenDaysWithCount() {
        var rule = EventRecurrence()
        rule.frequency = .weekly; rule.interval = 2; rule.weekdays = [6, 2]; rule.ending = .after; rule.count = 5
        #expect(rule.rrule(start: start, calendar: calendar, isAllDay: false) == "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR;COUNT=5")
    }

    @Test func monthlyOrdinalPatterns() {
        var rule = EventRecurrence()
        rule.frequency = .monthly; rule.usesOrdinal = true; rule.ordinal = -1; rule.ordinalDay = 6
        #expect(rule.rrule(start: start, calendar: calendar, isAllDay: false) == "RRULE:FREQ=MONTHLY;INTERVAL=1;BYDAY=-1FR")
        rule.ordinal = 2; rule.ordinalDay = 9
        #expect(rule.rrule(start: start, calendar: calendar, isAllDay: false) == "RRULE:FREQ=MONTHLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=2")
    }

    @Test func monthDaysAndYearlyDefaultMonth() {
        var rule = EventRecurrence()
        rule.frequency = .monthly; rule.monthDays = [15, 1]
        #expect(rule.rrule(start: start, calendar: calendar, isAllDay: false) == "RRULE:FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=1,15")
        rule = EventRecurrence(); rule.frequency = .yearly
        #expect(rule.rrule(start: start, calendar: calendar, isAllDay: false) == "RRULE:FREQ=YEARLY;INTERVAL=1;BYMONTH=11")
    }

    @Test func untilIncludesTheWholeLastDay() {
        var rule = EventRecurrence()
        rule.frequency = .daily; rule.ending = .onDate
        rule.until = ISO8601DateFormatter().date(from: "2026-06-30T12:00:00Z")!
        // 23:59:59 BST on 30 June is 22:59:59 UTC.
        #expect(rule.rrule(start: start, calendar: calendar, isAllDay: false) == "RRULE:FREQ=DAILY;INTERVAL=1;UNTIL=20260630T225959Z")
        #expect(rule.rrule(start: start, calendar: calendar, isAllDay: true) == "RRULE:FREQ=DAILY;INTERVAL=1;UNTIL=20260630")
    }

    @Test func neverRepeatsHasNoRule() {
        #expect(EventRecurrence().rrule(start: start, calendar: calendar, isAllDay: false) == nil)
    }
}

@Suite("Google calendar matching")
struct GoogleCalendarMatchTests {
    func info(_ id: String, _ title: String, source: String, sourceName: String) -> CalendarInfo {
        CalendarInfo(id: id, title: title, sourceID: source, sourceName: sourceName, red: 0, green: 0, blue: 0, allowsContentModifications: true)
    }

    let entries = [
        GoogleCalendarListEntry(id: "me@example.com", summary: "me@example.com", primary: true),
        GoogleCalendarListEntry(id: "team@group.calendar.google.com", summary: "Team", summaryOverride: "Work team", accessRole: "writer"),
        GoogleCalendarListEntry(id: "holidays@group.v.calendar.google.com", summary: "Holidays", accessRole: "reader")
    ]

    var calendars: [CalendarInfo] {
        [info("a", "me@example.com", source: "g", sourceName: "Google"),
         info("b", "Work team", source: "g", sourceName: "Google"),
         info("c", "Holidays", source: "g", sourceName: "Google"),
         info("d", "Work team", source: "icloud", sourceName: "iCloud")]
    }

    @Test func matchesPrimaryAndRenamedCalendarsInTheAccount() {
        #expect(GoogleCalendarMatch.calendarID(for: calendars[0], among: calendars, google: entries, accountEmail: "me@example.com") == "me@example.com")
        #expect(GoogleCalendarMatch.calendarID(for: calendars[1], among: calendars, google: entries, accountEmail: "Me@Example.com") == "team@group.calendar.google.com")
    }

    @Test func ignoresReadOnlyAndOtherAccounts() {
        #expect(GoogleCalendarMatch.calendarID(for: calendars[2], among: calendars, google: entries, accountEmail: "me@example.com") == nil)
        #expect(GoogleCalendarMatch.calendarID(for: calendars[3], among: calendars, google: entries, accountEmail: "me@example.com") == nil)
        // Signed in to a different Google account whose calendars happen to share a name.
        let other = [GoogleCalendarListEntry(id: "other@example.com", summary: "other@example.com", primary: true),
                     GoogleCalendarListEntry(id: "x@group.calendar.google.com", summary: "Work team")]
        #expect(GoogleCalendarMatch.calendarID(for: calendars[1], among: calendars, google: other, accountEmail: "other@example.com") == nil)
    }

    @Test func matchesASourceNamedAfterTheAccount() {
        let named = [info("x", "Team", source: "s", sourceName: "me@example.com")]
        #expect(GoogleCalendarMatch.calendarID(for: named[0], among: named, google: entries, accountEmail: "me@example.com") == "team@group.calendar.google.com")
    }

    @Test func refusesAmbiguousNames() {
        let duplicate = entries + [GoogleCalendarListEntry(id: "other@group.calendar.google.com", summary: "Work team")]
        #expect(GoogleCalendarMatch.calendarID(for: calendars[1], among: calendars, google: duplicate, accountEmail: "me@example.com") == nil)
    }
}
