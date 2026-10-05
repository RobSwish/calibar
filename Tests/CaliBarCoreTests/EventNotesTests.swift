import Foundation
import Testing
@testable import CaliBarCore

@Suite("Event notes")
struct EventNotesTests {
    private func plain(_ string: AttributedString) -> String { String(string.characters) }

    private func links(_ string: AttributedString) -> [(text: String, url: URL)] {
        string.runs.compactMap { run in run.link.map { (plain(AttributedString(string[run.range])), $0) } }
    }

    @Test func formatsInterviewInvitation() {
        let notes = """
        This is a Zoom meeting. Click this link to join: <a href="https://example.zoom.us/j/83121678999?pwd=abc.1">https://example.zoom.us/j/83121678999?pwd=abc.1</a><br />Meeting ID: 83121678999<br />Passcode: $oV2&amp;nE3nM (desktop) | 8536241587 (dial-in)<br /><br />To cancel or reschedule, use this link: https://you.ashbyhq.com/meeting/3fbfb492/ <ul><li><p>10:00 AM - 11:00 AM (Europe/London) - Coding Interview</p><ul><li><p>Alex Example (Software Engineer, <a target="_blank" href="http://www.linkedin.com/in/example?jobid=1234&amp;lipi=urn" rel="noopener ">LinkedIn</a>)</p></li></ul></li></ul><p><em>Note: we use an AI notetaker to transcribe interviews.</em></p><p></p>
        """
        let result = EventNotes.formatted(notes)
        #expect(plain(result) == """
        This is a Zoom meeting. Click this link to join: https://example.zoom.us/j/83121678999?pwd=abc.1
        Meeting ID: 83121678999
        Passcode: $oV2&nE3nM (desktop) | 8536241587 (dial-in)

        To cancel or reschedule, use this link: https://you.ashbyhq.com/meeting/3fbfb492/
        • 10:00 AM - 11:00 AM (Europe/London) - Coding Interview
            ◦ Alex Example (Software Engineer, LinkedIn)

        Note: we use an AI notetaker to transcribe interviews.
        """)

        let found = links(result)
        #expect(found.map(\.url.absoluteString) == [
            "https://example.zoom.us/j/83121678999?pwd=abc.1",
            "https://you.ashbyhq.com/meeting/3fbfb492/",
            "http://www.linkedin.com/in/example?jobid=1234&lipi=urn"
        ])
        #expect(found.last?.text == "LinkedIn")

        let italic = result.runs.first { $0.inlinePresentationIntent?.contains(.emphasized) == true }
        #expect(italic.map { plain(AttributedString(result[$0.range])) } == "Note: we use an AI notetaker to transcribe interviews.")
    }

    @Test func leavesPlainTextAloneApartFromLinks() {
        let notes = "  A little time to share.\n\n• Review designs\n• Agree on next steps < Friday & more\nhttps://example.com/brief  "
        let result = EventNotes.formatted(notes)
        #expect(plain(result) == "A little time to share.\n\n• Review designs\n• Agree on next steps < Friday & more\nhttps://example.com/brief")
        #expect(links(result).map(\.url.absoluteString) == ["https://example.com/brief"])
    }

    @Test func detectsHTMLOnlyFromRealTags() {
        #expect(EventNotes.isHTML("Line one<br>Line two"))
        #expect(EventNotes.isHTML("<P>Hello</P>"))
        #expect(!EventNotes.isHTML("Budget < 5k and x > y"))
        #expect(!EventNotes.isHTML("Use <name> as a placeholder"))
    }

    @Test func formatsInlineStylesListsAndEntities() {
        let notes = "<div>Hello&nbsp;<b>bold</b>   and <strong><i>both</i></strong> &#8211; &#x2014; &rsquo;</div><ol><li>One</li><li>Two</li></ol>"
        let result = EventNotes.formatted(notes)
        #expect(plain(result) == "Hello\u{00A0}bold and both – — ’\n1. One\n2. Two")
        let bold = result.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold.map { plain(AttributedString(result[$0.range])) } == ["bold", "both"])
        #expect(result.runs.contains { $0.inlinePresentationIntent == [.stronglyEmphasized, .emphasized] })
    }

    @Test func dropsUnsafeLinksScriptsAndComments() {
        let notes = "<p>Safe <a href=\"javascript:alert(1)\">text</a></p><script>alert(1)</script><style>p{}</style><!-- hidden --><p><a href='mailto:hi@example.com'>Email</a></p>"
        let result = EventNotes.formatted(notes)
        #expect(plain(result) == "Safe text\n\nEmail")
        #expect(links(result).map(\.url.absoluteString) == ["mailto:hi@example.com"])
    }

    @Test func limitsRepeatedBlankLines() {
        let result = EventNotes.formatted("One<br><br><br><br>Two<p></p><p></p><p>Three</p>")
        #expect(plain(result) == "One\n\nTwo\n\nThree")
    }
}
