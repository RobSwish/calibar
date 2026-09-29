import Foundation
import Testing
@testable import CaliBarCore

@Suite("Event participants")
struct CalendarParticipantTests {
    func person(_ email: String, _ status: ParticipationStatus = .unknown) -> CalendarParticipant {
        CalendarParticipant(url: URL(string: "mailto:" + email)!, status: status)
    }

    @Test func organizerComesFirstOnceWithActualRSVP() {
        let people = CalendarParticipant.ordered(
            organizer: person("Alex@example.com"),
            attendees: [person("sam@example.com", .declined), person("alex@example.com", .accepted),
                        person("sam@example.com", .declined)])
        #expect(people.map(\.address) == ["Alex@example.com", "sam@example.com"])
        #expect(people.map(\.status) == [.accepted, .declined])
        #expect(people.map(\.isOrganizer) == [true, false])
    }

    @Test func organizerAbsentFromAttendeesKeepsUnknownResponse() {
        let people = CalendarParticipant.ordered(organizer: person("alex@example.com"),
                                                attendees: [person("sam@example.com", .tentative)])
        #expect(people.count == 2)
        #expect(people[0].isOrganizer)
        #expect(people[0].status == .unknown)
        #expect(people[1].status == .tentative)
    }

    @Test func emailPreferredOverNameAndMailtoQueryRemoved() {
        let participant = CalendarParticipant(
            url: URL(string: "mailto:alex%2Bwork@example.com?subject=Meeting")!, name: "Alex")
        #expect(participant.address == "alex+work@example.com")
        #expect(participant.id == "alex+work@example.com")
    }

    @Test func noOrganizerPreservesAttendeesAndResponses() {
        let people = CalendarParticipant.ordered(organizer: nil, attendees: [
            person("one@example.com", .pending), person("two@example.com", .tentative)])
        #expect(people.map(\.status) == [.pending, .tentative])
        #expect(people.allSatisfy { !$0.isOrganizer })
    }

    @Test func nonEmailParticipantFallsBackToName() {
        let participant = CalendarParticipant(url: URL(string: "urn:uuid:123")!, name: "Meeting room")
        #expect(participant.address == "Meeting room")
        #expect(participant.id == "urn:uuid:123")
    }
}
