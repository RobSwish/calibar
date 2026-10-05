import Foundation

/// Formats event notes for display. Invitations from Google Calendar, Zoom, Ashby and similar
/// services often store notes as HTML, which is converted into styled text with links.
/// Plain-text notes keep their line breaks and gain links for any web addresses they contain.
public enum EventNotes {
    public static func formatted(_ notes: String) -> AttributedString {
        var runs = [Run(text: notes.trimmingCharacters(in: .whitespacesAndNewlines))]
        if isHTML(notes) {
            var parser = HTMLNotesParser(notes)
            runs = parser.parse()
        }
        var result = AttributedString()
        for run in runs { result += linkified(run) }
        return result
    }

    public static func isHTML(_ text: String) -> Bool {
        text.range(of: #"</?(a|p|br|div|span|ul|ol|li|b|strong|i|em|u|h[1-6]|blockquote|table|tr|td|font)\b[^>]*>"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func allowedLink(_ url: URL) -> Bool {
        ["https", "http", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "")
    }

    struct Run: Equatable {
        var text: String
        var bold = false
        var italic = false
        var link: URL?

        func sameStyle(as other: Run) -> Bool { bold == other.bold && italic == other.italic && link == other.link }
    }

    private static func styled(_ text: String, _ run: Run, link: URL?) -> AttributedString {
        var string = AttributedString(text)
        var intent: InlinePresentationIntent = []
        if run.bold { intent.insert(.stronglyEmphasized) }
        if run.italic { intent.insert(.emphasized) }
        if !intent.isEmpty { string.inlinePresentationIntent = intent }
        string.link = link
        return string
    }

    /// Adds links to bare web and email addresses outside existing links.
    private static func linkified(_ run: Run) -> AttributedString {
        guard run.link == nil, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return styled(run.text, run, link: run.link)
        }
        let text = run.text
        var result = AttributedString()
        var cursor = text.startIndex
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, allowedLink(url), let range = Range(match.range, in: text) else { continue }
            result += styled(String(text[cursor..<range.lowerBound]), run, link: nil)
            result += styled(String(text[range]), run, link: url)
            cursor = range.upperBound
        }
        result += styled(String(text[cursor...]), run, link: nil)
        return result
    }
}

/// A small, forgiving HTML reader for the subset of markup used in calendar invitations.
/// It never loads remote content and ignores scripts, styles, images and unknown tags.
private struct HTMLNotesParser {
    typealias Run = EventNotes.Run

    private let html: String
    private var runs: [Run] = []
    private var pendingBreaks = 0
    private var pendingBullet: String?
    private var lists: [(ordered: Bool, count: Int)] = []
    private var boldDepth = 0
    private var italicDepth = 0
    private var links: [URL?] = []
    private var skippedElement: String?

    init(_ html: String) { self.html = html }

    mutating func parse() -> [Run] {
        var index = html.startIndex
        var text = ""
        while index < html.endIndex {
            if html[index] == "<", let tagEnd = tagEnd(from: index) {
                appendText(text); text = ""
                handleTag(String(html[html.index(after: index)..<tagEnd]))
                index = html.index(after: tagEnd)
            } else {
                text.append(html[index])
                index = html.index(after: index)
            }
        }
        appendText(text)
        trimTrailingWhitespace()
        return runs
    }

    /// Finds the closing `>` of a tag or comment, or nil when `<` is just text such as "a < b".
    private func tagEnd(from start: String.Index) -> String.Index? {
        let rest = html[html.index(after: start)...]
        if rest.hasPrefix("!--") {
            guard let end = rest.range(of: "-->") else { return html.index(before: html.endIndex) }
            return html.index(before: end.upperBound)
        }
        guard let first = rest.first, first.isLetter || first == "/" || first == "!" else { return nil }
        return rest.firstIndex(of: ">")
    }

    private mutating func handleTag(_ raw: String) {
        guard !raw.hasPrefix("!") else { return }
        let closing = raw.hasPrefix("/")
        let body = closing ? raw.dropFirst() : Substring(raw)
        let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()

        if let skipped = skippedElement {
            if closing, name == skipped { skippedElement = nil }
            return
        }
        switch name {
        case "script", "style", "head", "title":
            if !closing, !raw.hasSuffix("/") { skippedElement = name }
        case "br":
            lineBreak()
        case "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote":
            requestBreaks(lists.isEmpty ? 2 : 1)
        case "div", "tr", "table", "hr":
            requestBreaks(1)
        case "ul", "ol":
            requestBreaks(1)
            if closing { if !lists.isEmpty { lists.removeLast() } } else { lists.append((name == "ol", 0)) }
        case "li":
            requestBreaks(1)
            if !closing { startListItem() } else { pendingBullet = nil }
        case "td", "th":
            if closing { pendingSpace() }
        case "b", "strong":
            boldDepth = max(0, boldDepth + (closing ? -1 : 1))
        case "i", "em":
            italicDepth = max(0, italicDepth + (closing ? -1 : 1))
        case "a":
            if closing { if !links.isEmpty { links.removeLast() } } else { links.append(Self.href(in: String(body))) }
        default:
            break
        }
    }

    private mutating func startListItem() {
        let depth = max(lists.count, 1)
        var marker = depth == 1 ? "•" : "◦"
        if !lists.isEmpty, lists[lists.count - 1].ordered {
            lists[lists.count - 1].count += 1
            marker = "\(lists[lists.count - 1].count)."
        }
        pendingBullet = String(repeating: "    ", count: depth - 1) + marker + " "
    }

    // MARK: Output

    private var currentStyle: Run {
        Run(text: "", bold: boldDepth > 0, italic: italicDepth > 0, link: links.last(where: { $0 != nil }) ?? nil)
    }

    private var atLineStart: Bool { runs.last.map { $0.text.isEmpty || $0.text.hasSuffix("\n") } ?? true }

    private var trailingNewlines: Int {
        var count = 0
        for run in runs.reversed() {
            for character in run.text.reversed() {
                guard character == "\n" else { return count }
                count += 1
            }
        }
        return count
    }

    private mutating func appendText(_ raw: String) {
        guard skippedElement == nil, !raw.isEmpty else { return }
        // HTML collapses runs of whitespace (including source line breaks) into one space.
        let collapsed = raw.replacingOccurrences(of: #"[ \t\r\n\f]+"#, with: " ", options: .regularExpression)
        var text = Self.decodeEntities(collapsed)
        if text.allSatisfy({ $0 == " " }) {
            if !runs.isEmpty, pendingBreaks == 0, pendingBullet == nil { pendingSpace() }
            return
        }
        flushBreaks()
        if let bullet = pendingBullet {
            append(Run(text: bullet))
            pendingBullet = nil
        }
        if atLineStart || runs.last?.text.hasSuffix(" ") == true {
            text = String(text.drop { $0 == " " })
        }
        var run = currentStyle
        run.text = text
        append(run)
    }

    private mutating func append(_ run: Run) {
        guard !run.text.isEmpty else { return }
        if let last = runs.last, last.sameStyle(as: run) {
            runs[runs.count - 1].text += run.text
        } else {
            runs.append(run)
        }
    }

    private mutating func pendingSpace() {
        guard !atLineStart, runs.last?.text.hasSuffix(" ") == false else { return }
        append(Run(text: " "))
    }

    private mutating func requestBreaks(_ count: Int) {
        guard !runs.isEmpty else { return }
        pendingBreaks = max(pendingBreaks, count)
    }

    private mutating func lineBreak() {
        flushBreaks()
        trimTrailingSpaces()
        // Allow at most one blank line in a row.
        if trailingNewlines < 2 { append(Run(text: "\n")) }
    }

    private mutating func flushBreaks() {
        guard pendingBreaks > 0 else { return }
        trimTrailingSpaces()
        let needed = pendingBreaks - trailingNewlines
        if needed > 0 { append(Run(text: String(repeating: "\n", count: needed))) }
        pendingBreaks = 0
    }

    private mutating func trimTrailingSpaces() {
        while let last = runs.last, last.text.hasSuffix(" ") {
            runs[runs.count - 1].text = last.text.droppingTrailing { $0 == " " }
            if runs[runs.count - 1].text.isEmpty { runs.removeLast() }
        }
    }

    private mutating func trimTrailingWhitespace() {
        while let last = runs.last {
            let trimmed = last.text.droppingTrailing { $0.isWhitespace }
            if trimmed.isEmpty { runs.removeLast() } else { runs[runs.count - 1].text = trimmed; break }
        }
    }

    // MARK: Attributes and entities

    private static func href(in tag: String) -> URL? {
        let pattern = #"\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) {
                let value = decodeEntities(String(tag[range])).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: value), EventNotes.allowedLink(url) else { return nil }
                return url
            }
        }
        return nil
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "bull": "•", "middot": "·",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£", "times": "×"
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            let name = text[text.index(after: index)..<semicolon]
            var decoded: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                decoded = UInt32(name.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                decoded = UInt32(name.dropFirst()).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            } else {
                decoded = namedEntities[name.lowercased()]
            }
            if let decoded {
                result += decoded
                index = text.index(after: semicolon)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }
}

private extension String {
    func droppingTrailing(while predicate: (Character) -> Bool) -> String {
        var end = endIndex
        while end > startIndex, predicate(self[index(before: end)]) { end = index(before: end) }
        return String(self[..<end])
    }
}
