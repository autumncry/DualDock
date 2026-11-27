import EventKit
import Foundation

enum ToolCalendarState: Equatable, Sendable {
    case notDetermined, denied, empty, unavailable
    case upcoming(title: String, start: Date, isAllDay: Bool)

    enum ReadAccess { case notDetermined, denied, allowed, unavailable }

    var readAccess: ReadAccess {
        switch self {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .empty, .upcoming: return .allowed
        case .unavailable: return .unavailable
        }
    }
}

/// EventKit objects stay on this actor. Event titles and times live in memory.
actor ToolCalendarClient {
    private var store: EKEventStore?

    func load(requestPermission: Bool) async -> ToolCalendarState {
        var status = EKEventStore.authorizationStatus(for: .event)
        if requestPermission && (status == .notDetermined || status == .writeOnly) {
            do {
                _ = try await eventStore().requestFullAccessToEvents()
                status = EKEventStore.authorizationStatus(for: .event)
            } catch {
                return EKEventStore.authorizationStatus(for: .event) == .denied ? .denied : .unavailable
            }
        }
        switch status {
        case .notDetermined, .writeOnly: return .notDetermined
        case .restricted, .denied: return .denied
        case .fullAccess: break
        @unknown default: return .unavailable
        }
        guard !Task.isCancelled else { return .unavailable }
        let now = Date()
        let cal = Calendar.current
        guard let horizon = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: now)) else { return .unavailable }
        let source = eventStore()
        let predicate = source.predicateForEvents(withStart: cal.startOfDay(for: now), end: horizon, calendars: nil)
        let candidates = source.events(matching: predicate).filter {
            $0.status != .canceled && $0.endDate > now && ($0.isAllDay || $0.startDate >= now)
        }
        guard let event = candidates.min(by: { a, b in a.startDate < b.startDate }) else { return .empty }
        return .upcoming(title: event.title ?? "", start: event.startDate, isAllDay: event.isAllDay)
    }

    func events(in interval: DateInterval) -> ToolCalendarRead {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined, .writeOnly: return .notDetermined
        case .restricted, .denied: return .denied
        case .fullAccess: break
        @unknown default: return .unavailable
        }
        guard !Task.isCancelled else { return .unavailable }
        let source = eventStore()
        let predicate = source.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return .events(source.events(matching: predicate).compactMap { event in
            guard event.status != .canceled, let start = event.startDate, let end = event.endDate else { return nil }
            return ToolCalendarEvent(title: event.title ?? "", start: start, end: end, allDay: event.isAllDay)
        })
    }

    private func eventStore() -> EKEventStore {
        if let store { return store }
        let created = EKEventStore()
        store = created
        return created
    }
}
