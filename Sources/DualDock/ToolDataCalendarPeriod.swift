import Foundation

enum ToolCalendarMode: String, Codable, CaseIterable {
    case week, month

    var component: Calendar.Component { self == .week ? .weekOfYear : .month }
}

/// Day and week boundaries are calculated in the host calendar, including its
/// first weekday and timezone. All event and grid intervals are half-open.
struct ToolCalendarPeriod {
    let interval: DateInterval
    let days: [Date]
    let leadingSlots: Int

    init?(containing date: Date, mode: ToolCalendarMode, calendar: Calendar) {
        guard let period = calendar.dateInterval(of: mode.component, for: date) else { return nil }
        interval = period
        leadingSlots = (calendar.component(.weekday, from: period.start) - calendar.firstWeekday + 7) % 7
        var values = [Date]()
        var day = period.start
        while day < period.end {
            values.append(day)
            guard let end = calendar.dateInterval(of: .day, for: day)?.end, end > day else { return nil }
            day = end
        }
        days = values
    }

    static func weekdayLabels(in calendar: Calendar, locale: Locale) -> [String] {
        var local = calendar
        local.locale = locale
        let weekdays = local.shortStandaloneWeekdaySymbols
        return (0..<weekdays.count).map { weekdays[($0 + calendar.firstWeekday - 1) % weekdays.count] }
    }
}

struct ToolCalendarEvent: Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
}

enum ToolCalendarRead: Sendable {
    case events([ToolCalendarEvent]), notDetermined, denied, unavailable
}

struct ToolCalendarAgenda {
    var byDay: [Date: [ToolCalendarEvent]] = [:]

    init(events: [ToolCalendarEvent], in period: DateInterval, calendar: Calendar) {
        let ordered = events.sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        for event in ordered where event.start < period.end && event.end >= period.start && event.end >= event.start {
            var day = calendar.startOfDay(for: max(event.start, period.start))
            // Zero-duration events belong to the day of their start.
            if event.start == event.end {
                byDay[day, default: []].append(event)
                continue
            }
            let end = min(event.end, period.end)
            while day < end {
                byDay[day, default: []].append(event)
                guard let next = calendar.dateInterval(of: .day, for: day)?.end, next > day else { break }
                day = next
            }
        }
    }
}
