import Foundation
import Testing
@testable import CaliBarCore

@Suite("Invitees")
struct InviteeTests {
    @Test func parsesSeparatedAddresses() {
        let result = Invitees.parse("sam@example.com, jamie@example.org; alex@example.co.uk  pat@example.com")
        #expect(result.addresses == ["sam@example.com", "jamie@example.org", "alex@example.co.uk", "pat@example.com"])
        #expect(result.leftover.isEmpty)
    }

    @Test func parsesNamesPastedFromMail() {
        let result = Invitees.parse("Sam Smith <sam@example.com>, \"Doe, Jamie\" <jamie@example.org>, mailto:alex@example.com")
        #expect(result.addresses == ["sam@example.com", "jamie@example.org", "alex@example.com"])
        #expect(result.leftover.isEmpty)
    }

    @Test func keepsTextThatIsNotAnAddress() {
        let result = Invitees.parse("sam@example.com, jamie")
        #expect(result.addresses == ["sam@example.com"])
        #expect(result.leftover == "jamie")
    }

    @Test(arguments: ["sam@example", "@example.com", "sam@@example.com", "sam@example.c", "sam@-example.com", "sam @example.com", "sam@example..com"])
    func rejectsInvalidAddresses(_ value: String) {
        #expect(!Invitees.isEmailAddress(value))
    }

    @Test func mergesWithoutDuplicates() {
        #expect(Invitees.merging(["SAM@example.com", "jamie@example.com"], into: ["sam@example.com"]) == ["sam@example.com", "jamie@example.com"])
    }
}

@Suite("Google invitations")
struct GoogleInvitationTests {
    private func draft() -> EventDraft {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        var draft = EventDraft(day: Date(timeIntervalSince1970: 1_780_000_000), now: Date(timeIntervalSince1970: 0), calendar: calendar)
        draft.title = "Planning"
        draft.calendarID = "work"
        return draft
    }

    private func json(_ body: GoogleEventBody) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any]
    }

    @Test func addsAttendeesWithoutTheOrganizer() throws {
        var value = draft()
        value.invitees = ["sam@example.com", "Me@Example.com", "jamie@example.com"]
        let body = try #require(GoogleEventBody(draft: value, accountEmail: "me@example.com"))
        #expect(body.attendees == [.init(email: "sam@example.com"), .init(email: "jamie@example.com")])
        #expect(body.sendsInvitations)
        #expect(body.conferenceData == nil)
        let object = try json(body)
        #expect(object["conferenceData"] == nil)
        #expect((object["attendees"] as? [[String: String]])?.map { $0["email"] } == ["sam@example.com", "jamie@example.com"])
    }

    @Test func meetOnlyEventSendsNoInvitations() throws {
        var value = draft()
        value.addsGoogleMeet = true
        let body = try #require(GoogleEventBody(draft: value, accountEmail: "me@example.com"))
        #expect(body.attendees == nil)
        #expect(!body.sendsInvitations)
        #expect(body.conferenceData != nil)
        #expect(try json(body)["attendees"] == nil)
    }

    @Test func namesWhatGoogleCannotStore() {
        var value = draft()
        #expect(GoogleEventBody.unsupportedFeature(in: value, accountEmail: "me@example.com") == nil)
        value.availability = .tentative
        #expect(GoogleEventBody.unsupportedFeature(in: value, accountEmail: "me@example.com") == "“Show as Tentative”")
        value.availability = .busy
        var alert = EventAlert(date: value.start)
        alert.action = .sound
        value.alerts = [alert]
        #expect(GoogleEventBody.unsupportedFeature(in: value, accountEmail: "me@example.com") == "alerts with sound")
        #expect(GoogleEventBody(draft: value, accountEmail: "me@example.com") == nil)
    }

    @Test func guessesGoogleCalendarsByAccountName() {
        func info(_ id: String, _ title: String, source: String, name: String) -> CalendarInfo {
            CalendarInfo(id: id, title: title, sourceID: source, sourceName: name, red: 0, green: 0, blue: 0)
        }
        let calendars = [
            info("a", "Work", source: "g", name: "Google"),
            info("b", "Home", source: "i", name: "iCloud"),
            info("c", "Team", source: "w", name: "Work account"),
            info("d", "rob@gmail.com", source: "w2", name: "Personal"),
            info("e", "Family", source: "w2", name: "Personal")
        ]
        #expect(GoogleCalendarMatch.looksLikeGoogle(calendars[0], among: calendars))
        #expect(!GoogleCalendarMatch.looksLikeGoogle(calendars[1], among: calendars))
        #expect(!GoogleCalendarMatch.looksLikeGoogle(calendars[2], among: calendars))
        #expect(GoogleCalendarMatch.looksLikeGoogle(calendars[4], among: calendars))
    }

    @Test func readsTheAccountEmailFromTheSourceOrPrimaryCalendar() {
        func info(_ id: String, _ title: String, source: String, name: String) -> CalendarInfo {
            CalendarInfo(id: id, title: title, sourceID: source, sourceName: name, red: 0, green: 0, blue: 0, isCalDAV: true)
        }
        let calendars = [
            info("a", "Work", source: "s", name: "Rob@SwiftLab.co.uk"),
            info("b", "rob@walkies.app", source: "w", name: "Google"),
            info("c", "Walks", source: "w", name: "Google"),
            info("d", "Home", source: "g", name: "Google")
        ]
        #expect(GoogleCalendarMatch.accountEmails(for: calendars[0], among: calendars) == ["rob@swiftlab.co.uk"])
        #expect(GoogleCalendarMatch.accountEmails(for: calendars[2], among: calendars) == ["rob@walkies.app"])
        #expect(GoogleCalendarMatch.accountEmails(for: calendars[3], among: calendars).isEmpty)
    }

    @Test func recognisesWorkspaceAccountsButNotICloud() {
        func info(_ id: String, _ title: String, source: String, name: String, calDAV: Bool) -> CalendarInfo {
            CalendarInfo(id: id, title: title, sourceID: source, sourceName: name, red: 0, green: 0, blue: 0, isCalDAV: calDAV)
        }
        let calendars = [
            info("a", "rob@swiftlab.co.uk", source: "w", name: "Work", calDAV: true),
            info("b", "Team", source: "w", name: "Work", calDAV: true),
            info("c", "Home", source: "e", name: "rob@swiftlab.co.uk", calDAV: true),
            info("d", "me@icloud.com", source: "i", name: "iCloud", calDAV: true),
            info("e", "rob@corp.example", source: "x", name: "Exchange", calDAV: false)
        ]
        #expect(GoogleCalendarMatch.looksLikeGoogle(calendars[1], among: calendars))
        #expect(GoogleCalendarMatch.looksLikeGoogle(calendars[2], among: calendars))
        #expect(!GoogleCalendarMatch.looksLikeGoogle(calendars[3], among: calendars))
        #expect(!GoogleCalendarMatch.looksLikeGoogle(calendars[4], among: calendars))
    }
}
