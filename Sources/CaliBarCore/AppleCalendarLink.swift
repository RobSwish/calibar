import Foundation

public enum AppleCalendarLink {
    // Calendar's macOS URL handler is undocumented. Use the EventKit calendar-item
    // identifier, and include the occurrence date only for recurring events.
    public static func url(identifier: String, start: Date, isRecurring: Bool, isAllDay: Bool,
                           timeZone: TimeZone = .current) -> URL? {
        guard !identifier.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard let encodedID = identifier.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var occurrence = ""
        if isRecurring {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = isAllDay ? timeZone : TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            occurrence = "/" + formatter.string(from: start)
        }
        var components = URLComponents()
        components.scheme = "ical"
        components.host = "ekevent"
        components.percentEncodedPath = occurrence + "/" + encodedID
        components.queryItems = [URLQueryItem(name: "method", value: "show"), URLQueryItem(name: "options", value: "more")]
        return components.url
    }
}
