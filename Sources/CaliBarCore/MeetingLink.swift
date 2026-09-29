import Foundation

public struct MeetingLink: Equatable, Sendable {
    public let url: URL
    public let provider: String

    public static func find(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        if let url, let meeting = recognize(url) { return meeting }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in [location, notes].compactMap({ $0 }) {
            // Calendar invitations sometimes contain HTML-escaped query strings.
            let decoded = text.replacingOccurrences(of: "&amp;", with: "&")
            for match in detector.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)) {
                if let url = match.url, let meeting = recognize(url) { return meeting }
            }
        }
        return nil
    }

    public static func recognize(_ url: URL) -> MeetingLink? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        func domain(_ root: String) -> Bool { host == root || host.hasSuffix("." + root) }
        let provider: String
        if (domain("zoom.us") || domain("zoomgov.com")), path.hasPrefix("/j/") || path.hasPrefix("/my/") || path.hasPrefix("/s/") {
            provider = "Zoom"
        } else if host == "meet.google.com", path.range(of: "^/[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil {
            provider = "Google Meet"
        } else if ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host),
                  path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/") {
            provider = "Microsoft Teams"
        } else if domain("webex.com"), path.hasPrefix("/meet/") || path.hasPrefix("/join/") || path.hasSuffix("/j.php") {
            provider = "Webex"
        } else if host == "facetime.apple.com", path.hasPrefix("/join") {
            provider = "FaceTime"
        } else { return nil }
        return MeetingLink(url: url, provider: provider)
    }
}
