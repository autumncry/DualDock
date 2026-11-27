import AppKit
import SwiftUI
import XCTest
@testable import DualDock

@MainActor
final class CalendarWidgetTests: XCTestCase {
    private func gregorian(first: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = first
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testMonthAndWeekUseSystemWeekStartAcrossYearsLeapMonthsAndDST() throws {
        let cal = gregorian()
        let month = try XCTUnwrap(ToolCalendarPeriod(containing: date(2024, 2, 16, in: cal), mode: .month, calendar: cal))
        XCTAssertEqual(month.leadingSlots, 3)
        XCTAssertEqual(month.days.count, 29)
        let week = try XCTUnwrap(ToolCalendarPeriod(containing: date(2027, 1, 1, in: cal), mode: .week, calendar: cal))
        XCTAssertEqual(week.leadingSlots, 0)
        XCTAssertEqual(week.days.first, date(2026, 12, 28, in: cal))
        XCTAssertEqual(week.days.last, date(2027, 1, 3, in: cal))
        let sundayCal = gregorian(first: 1)
        let dst = try XCTUnwrap(ToolCalendarPeriod(containing: date(2026, 3, 8, in: sundayCal), mode: .week, calendar: sundayCal))
        XCTAssertEqual(dst.days.count, 7)
        XCTAssertEqual(dst.interval.duration / 3600, 167)
        XCTAssertEqual(ToolCalendarPeriod.weekdayLabels(in: cal, locale: Locale(identifier: "en_US")).first, "Mon")
        XCTAssertEqual(ToolCalendarPeriod.weekdayLabels(in: sundayCal, locale: Locale(identifier: "en_US")).first, "Sun")
    }

    func testEventMarkersUseHalfOpenDaysThroughDST() throws {
        let c = gregorian(first: 1)
        let first = date(2026, 3, 8, in: c), second = date(2026, 3, 9, in: c), third = date(2026, 3, 10, in: c)
        let week = try XCTUnwrap(ToolCalendarPeriod(containing: first, mode: .week, calendar: c))
        let allDay = ToolCalendarEvent(title: "All day", start: first, end: second, allDay: true)
        let spans = ToolCalendarEvent(title: "Overnight", start: first.addingTimeInterval(-3600), end: third, allDay: false)
        let point = ToolCalendarEvent(title: "Point", start: second, end: second, allDay: false)
        let outside = ToolCalendarEvent(title: "Out", start: week.interval.end, end: week.interval.end, allDay: false)
        let prior = ToolCalendarEvent(title: "Prior", start: first.addingTimeInterval(-7200), end: first, allDay: false)
        let agenda = ToolCalendarAgenda(events: [outside, spans, point, allDay, prior], in: week.interval, calendar: c)
        XCTAssertEqual(agenda.byDay[first], [allDay, spans])
        XCTAssertEqual(agenda.byDay[second], [spans, point])
        XCTAssertEqual(agenda.byDay.count, 2)
    }

    private actor Days {
        var requests = [DateInterval]()
        var permissionRequests = 0
        let result: ToolCalendarRead
        init(_ result: ToolCalendarRead) { self.result = result }
        func read(_ interval: DateInterval) -> ToolCalendarRead { requests.append(interval); return result }
        func authorize(_ explicit: Bool) -> ToolCalendarState {
            if explicit { permissionRequests += 1 }
            return .notDetermined
        }
    }

    private func environment(_ days: Days) -> ToolDataService.Environment {
        ToolDataService.Environment(music: { _, _ in .idle }, calendar: { await days.authorize($0) },
                                    conditions: { _ in throw URLError(.notConnectedToInternet) }, cities: { _, _ in [] },
                                    calendarEvents: { await days.read($0) })
    }

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testOldProviderStateAndSavedWeekPreference() throws {
        let directory = try scratch()
        let file = directory.appendingPathComponent("tool-provider-state.json")
        try Data(#"{"musicEnabled":true}"#.utf8).write(to: file)
        let env = environment(Days(.notDetermined))
        let data = ToolDataService(directory: directory, environment: env)
        XCTAssertEqual(data.calendarMode, .month)
        data.setCalendarMode(.week)
        XCTAssertEqual(ToolDataService(directory: directory, environment: env).calendarMode, .week)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["musicEnabled"] as? Bool, true)
        XCTAssertEqual(json["calendarMode"] as? String, "week")
    }

    func testOpeningCalendarWithUndeterminedAccessShowsCurrentMonthWithoutPrompting() async throws {
        _ = NSApplication.shared
        let calendar = gregorian()
        let today = date(2026, 11, 27, in: calendar)
        let days = Days(.notDetermined)
        let data = ToolDataService(directory: try scratch(), environment: environment(days))
        let root = ToolCalendarView(data: data, calendar: calendar, now: { today })
            .environment(\.dualDockLanguage, .english)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 290, height: 416), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = host
        defer { window.close() }
        host.view.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            if await days.requests.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let period = try XCTUnwrap(ToolCalendarPeriod(containing: today, mode: .month, calendar: calendar))
        let requests = await days.requests
        XCTAssertEqual(requests, [period.interval])
        let prompted = await days.permissionRequests
        XCTAssertEqual(prompted, 0)
        let size = host.sizeThatFits(in: CGSize(width: 290, height: 700))
        XCTAssertEqual(size.width, 290, accuracy: 1)
        XCTAssertGreaterThan(size.height, 275) // six calendar rows plus the permission and Calendar actions
        if let out = ProcessInfo.processInfo.environment["DUALDOCK_CALENDAR_RENDER_DIR"] {
            window.setContentSize(size)
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.layoutSubtreeIfNeeded()
            let url = URL(fileURLWithPath: out).appendingPathComponent("calendar-unconnected-en.png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let rep = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        }
    }

    func testNativePeriodSwitchRendersDatesAndRequestsOnlyVisibleIntervals() async throws {
        _ = NSApplication.shared
        let calendar = gregorian()
        let today = date(2026, 11, 27, in: calendar)
        let dayEnd = date(2026, 11, 28, in: calendar)
        let days = Days(.events([
            .init(title: "Design review", start: date(2026, 11, 27, 14, in: calendar), end: date(2026, 11, 27, 15, in: calendar), allDay: false),
            .init(title: "Studio day", start: today, end: dayEnd, allDay: true),
            .init(title: "Next week", start: date(2026, 11, 30, 11, in: calendar), end: date(2026, 11, 30, 12, in: calendar), allDay: false)
        ]))
        let data = ToolDataService(directory: try scratch(), environment: environment(days))
        let before = await days.requests
        XCTAssertTrue(before.isEmpty)
        let root = ToolCalendarView(data: data, calendar: calendar, now: { today })
            .environment(\.dualDockLanguage, .simplifiedChinese)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 290, height: 435), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = host
        let left = NSScreen.screens.map(\.frame.minX).min() ?? 0
        window.setFrameOrigin(NSPoint(x: left - 650, y: 0))
        window.orderBack(nil)
        defer { window.close() }

        func fit(_ name: String, expectedRequests: Int) async throws -> CGSize {
            for _ in 0..<100 {
                if await days.requests.count >= expectedRequests { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(80))
            let size = host.sizeThatFits(in: CGSize(width: 290, height: 700))
            window.setContentSize(size)
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(size.width, 290, accuracy: 1)
            XCTAssertLessThan(size.height, 440)
            if let out = ProcessInfo.processInfo.environment["DUALDOCK_CALENDAR_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: out)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let rep = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
            }
            return size
        }
        let month = try await fit("calendar-month", expectedRequests: 1)
        func click(at point: NSPoint) throws {
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: true)
            window.sendEvent(try event(.leftMouseDown))
            if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .now, inMode: .default, dequeue: true) { window.sendEvent(up) }
        }
        try click(at: NSPoint(x: 234, y: month.height - 22))
        let week = try await fit("calendar-week", expectedRequests: 2)
        XCTAssertEqual(data.calendarMode, .week)
        XCTAssertGreaterThan(month.height, week.height + 85)
        // Thursday has no fixture events. Picking it should replace Friday's
        // agenda immediately without reading the same seven days again.
        try click(at: NSPoint(x: week.width / 2, y: week.height - 110))
        let thursday = try await fit("calendar-selected-day", expectedRequests: 2)
        XCTAssertLessThan(thursday.height, week.height - 12)
        let ranges = await days.requests
        let expected = try [ToolCalendarMode.month, .week].map {
            try XCTUnwrap(ToolCalendarPeriod(containing: today, mode: $0, calendar: calendar)).interval
        }
        XCTAssertEqual(ranges, expected)
        let prompted = await days.permissionRequests
        XCTAssertEqual(prompted, 0)
    }
}
