import AppKit
import EventKit
import Foundation

public struct CalendarSnapshot: Sendable {
    public let calendars: [CalendarInfo]
    public let events: [CalendarEvent]
}

public enum CalendarAccess: Sendable { case notRequested, allowed, denied, restricted }

public actor EventReader {
    private let store = EKEventStore()

    public init() {}

    public nonisolated static var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .allowed
        case .notDetermined: .notRequested
        case .restricted: .restricted
        default: .denied
        }
    }

    public func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    public func fetch(start: Date, end: Date, excludedIDs: Set<String>, refreshSources: Bool = false) -> CalendarSnapshot? {
        guard Self.access == .allowed else { return nil }
        if refreshSources { store.refreshSourcesIfNecessary() }
        let calendars = store.calendars(for: .event)
        let infos = calendars.map(Self.info).sorted {
            ($0.sourceName, $0.title) < ($1.sourceName, $1.title)
        }
        let byID = Dictionary(uniqueKeysWithValues: infos.map { ($0.id, $0) })
        let selected = calendars.filter { !excludedIDs.contains($0.calendarIdentifier) }
        // An empty selection must not become a nil calendar predicate (which means ALL calendars).
        guard !selected.isEmpty else { return CalendarSnapshot(calendars: infos, events: []) }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        let events = store.events(matching: predicate).compactMap { event -> CalendarEvent? in
            guard event.status != .canceled, let calendar = byID[event.calendar.calendarIdentifier],
                  let start = event.startDate, let end = event.endDate else { return nil }
            // Recurring occurrences share an event identifier; include the occurrence date.
            let id = "\(calendar.id)|\(event.calendarItemIdentifier)|\(start.timeIntervalSinceReferenceDate)"
            return CalendarEvent(id: id, title: event.title ?? "Untitled event", start: start, end: end,
                                 isAllDay: event.isAllDay, calendar: calendar, location: event.location,
                                 notes: event.notes, url: event.url, organizer: event.organizer.map(Self.participant),
                                 attendees: event.attendees?.map(Self.participant) ?? [],
                                 appleCalendarURL: AppleCalendarLink.url(identifier: event.calendarItemIdentifier,
                                     start: start, isRecurring: event.hasRecurrenceRules, isAllDay: event.isAllDay))
        }
        return CalendarSnapshot(calendars: infos, events: events)
    }

    private static func participant(_ participant: EKParticipant) -> CalendarParticipant {
        let status: ParticipationStatus
        switch participant.participantStatus {
        case .accepted: status = .accepted
        case .declined: status = .declined
        case .tentative: status = .tentative
        case .pending: status = .pending
        case .delegated: status = .delegated
        case .completed: status = .completed
        case .inProcess: status = .inProcess
        default: status = .unknown
        }
        return CalendarParticipant(url: participant.url, name: participant.name, status: status)
    }

    private static func info(_ calendar: EKCalendar) -> CalendarInfo {
        let color = calendar.cgColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) } ?? .systemBlue
        return CalendarInfo(id: calendar.calendarIdentifier, title: calendar.title,
                            sourceID: calendar.source.sourceIdentifier, sourceName: calendar.source.title,
                            red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }
}
