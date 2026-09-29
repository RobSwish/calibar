import Foundation
import Testing
@testable import CaliBarCore

@Suite("Meeting links")
struct MeetingLinkTests {
    @Test(arguments: [
        ("https://us02web.zoom.us/j/123456789?pwd=abc", "Zoom"),
        ("https://company.zoom.us/my/design", "Zoom"),
        ("https://zoomgov.com/j/123456789", "Zoom"),
        ("https://meet.google.com/abc-defg-hij", "Google Meet"),
        ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=abc", "Microsoft Teams"),
        ("https://teams.live.com/meet/123456?p=secret", "Microsoft Teams"),
        ("https://teams.cloud.microsoft/meet/12345?p=secret", "Microsoft Teams"),
        ("https://company.webex.com/meet/alex", "Webex"),
        ("https://company.webex.com/company/j.php?MTID=abc", "Webex"),
        ("https://facetime.apple.com/join#v=1&p=example", "FaceTime")
    ])
    func detectsProviders(input: (String, String)) {
        let result = MeetingLink.recognize(URL(string: input.0)!)
        #expect(result?.provider == input.1)
        #expect(result?.url.absoluteString == input.0)
    }

    @Test(arguments: [
        "https://zoom.us.evil.example/j/123", "https://evilzoom.us/j/123", "https://zoom.us@evil.example/j/123",
        "https://user:password@zoom.us/j/123", "http://zoom.us/j/123", "javascript:alert(1)",
        "file:///tmp/meeting", "https://zoom.us/pricing", "https://meet.google.com/landing",
        "https://teams.microsoft.com/marketing", "https://zoom.us:8443/j/123", "https://example.com/meeting"
    ])
    func rejectsNonMeetingLinks(_ input: String) {
        #expect(MeetingLink.recognize(URL(string: input)!) == nil)
    }

    @Test func detectsNotesAfterUnrelatedURL() {
        let notes = "Read https://example.com/brief first.\nJoin: https://us02web.zoom.us/j/123456?pwd=secret&amp;from=invite"
        let result = MeetingLink.find(url: URL(string: "https://example.com/brief"), location: "Office", notes: notes)
        #expect(result?.provider == "Zoom")
        #expect(result?.url.query == "pwd=secret&from=invite")
    }

    @Test func prioritizesExplicitEventLink() {
        let result = MeetingLink.find(url: URL(string: "https://meet.google.com/abc-defg-hij"),
                                      location: "https://zoom.us/j/123456", notes: nil)
        #expect(result?.provider == "Google Meet")
    }

    @Test func detectsLinkInLocation() {
        let result = MeetingLink.find(url: nil, location: "Video: https://meet.google.com/abc-defg-hij", notes: nil)
        #expect(result?.provider == "Google Meet")
    }

    @Test func ordinaryEventsHaveNoJoinLink() {
        #expect(MeetingLink.find(url: nil, location: "Café on the corner", notes: "Lunch with friends.") == nil)
    }
}
