import Foundation

public enum ParticipationStatus: String, Sendable {
    case unknown, pending, accepted, declined, tentative, delegated, completed, inProcess

    public var label: String {
        switch self {
        case .unknown: "Response unknown"
        case .pending: "Awaiting response"
        case .accepted: "Accepted"
        case .declined: "Declined"
        case .tentative: "Maybe"
        case .delegated: "Delegated"
        case .completed: "Completed"
        case .inProcess: "In progress"
        }
    }
}

public struct CalendarParticipant: Identifiable, Sendable {
    public let id: String
    public let address: String
    public let status: ParticipationStatus
    public let isOrganizer: Bool

    public init(url: URL, name: String? = nil, status: ParticipationStatus = .unknown, isOrganizer: Bool = false) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let email = url.scheme?.lowercased() == "mailto" ? components?.path : nil
        self.address = email.flatMap { $0.isEmpty ? nil : $0 }
            ?? name.flatMap { $0.isEmpty ? nil : $0 } ?? url.absoluteString
        self.id = (email ?? url.absoluteString).lowercased()
        self.status = status
        self.isOrganizer = isOrganizer
    }

    private init(copying participant: Self, status: ParticipationStatus, isOrganizer: Bool) {
        self.id = participant.id
        self.address = participant.address
        self.status = status
        self.isOrganizer = isOrganizer
    }

    public static func ordered(organizer: Self?, attendees: [Self]) -> [Self] {
        var result: [Self] = []
        var seen = Set<String>()
        if let organizer {
            // The attendee entry carries the RSVP when the organiser record has no response.
            let response = attendees.first { $0.id == organizer.id && $0.status != .unknown }?.status
            result.append(Self(copying: organizer, status: response ?? organizer.status, isOrganizer: true))
            seen.insert(organizer.id)
        }
        for attendee in attendees where seen.insert(attendee.id).inserted {
            result.append(attendee)
        }
        return result
    }
}
