import Foundation

/// Turns what people type or paste into the invitee field into email addresses.
public enum Invitees {
    /// Splits on commas, semicolons and whitespace, and accepts `Name <email>` as pasted from Mail.
    /// Returns the addresses it recognised and any text it couldn’t, so the field can keep showing it.
    public static func parse(_ text: String) -> (addresses: [String], leftover: String) {
        var addresses: [String] = []
        var leftover: [String] = []
        var remaining = text
        // Pull out bracketed addresses first, since display names can contain spaces and commas.
        while let open = remaining.firstIndex(of: "<"), let close = remaining[open...].firstIndex(of: ">") {
            let inside = String(remaining[remaining.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            if isEmailAddress(inside) {
                addresses.append(inside)
                // Drop the display name before the bracket, back to the previous separator outside quotes.
                var start = remaining.startIndex
                var quoted = false
                var index = remaining.startIndex
                while index < open {
                    let character = remaining[index]
                    if character == "\"" { quoted.toggle() }
                    else if !quoted, character == "," || character == ";" || character.isNewline { start = remaining.index(after: index) }
                    index = remaining.index(after: index)
                }
                remaining.replaceSubrange(start...close, with: " ")
            } else {
                remaining.replaceSubrange(open...close, with: " ")
            }
        }
        for token in remaining.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
            var value = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'()"))
            if value.lowercased().hasPrefix("mailto:") { value.removeFirst(7) }
            if isEmailAddress(value) { addresses.append(value) } else if !value.isEmpty { leftover.append(String(token)) }
        }
        return (addresses, leftover.joined(separator: " "))
    }

    /// Adds addresses that aren’t already present (case-insensitive), keeping the existing order.
    public static func merging(_ new: [String], into existing: [String]) -> [String] {
        var result = existing
        var seen = Set(existing.map { $0.lowercased() })
        for address in new where seen.insert(address.lowercased()).inserted { result.append(address) }
        return result
    }

    /// A practical check: one @, a non-empty local part, and a dotted domain without spaces.
    public static func isEmailAddress(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, value.count <= 254,
              !value.contains(where: { $0.isWhitespace || "<>,;\"()[]\\".contains($0) }) else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }
            && (labels.last?.count ?? 0) >= 2
    }
}

/// Why an event with invitees can’t be saved as it stands. Invitations go through Google, so nothing is saved.
public enum InvitationError: LocalizedError, Equatable {
    case needsGoogleCalendar(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .needsGoogleCalendar(let email):
            "Invitations can only be sent from a Google calendar in \(email). Choose one, or remove the invitees."
        case .unsupported(let feature):
            "Google Calendar can’t save \(feature) on an event with invitees. Change it, or remove the invitees."
        }
    }
}
