import AppKit
import EventKit
import SwiftUI

struct ToolCalendarView: View {
    @Environment(\.dualDockLanguage) private var language
    @ObservedObject var data: ToolDataService
    let calendar: Calendar
    private let now: () -> Date
    @State private var selected: Date
    @State private var today: Date
    @State private var revision = 0
    @State private var result: (DateInterval, Contents)?

    private enum Contents {
        case agenda(ToolCalendarAgenda), notDetermined, denied, unavailable
    }

    private struct Query: Equatable {
        let interval: DateInterval
        let revision: Int
    }

    init(data: ToolDataService, calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = Date.init) {
        self.data = data
        self.calendar = calendar
        self.now = now
        let day = calendar.startOfDay(for: now())
        _selected = State(initialValue: day)
        _today = State(initialValue: day)
    }

    private var locale: Locale { Locale(identifier: language.rawValue) }
    private var dateStyle: Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(language("日历", "Calendar")).font(.headline)
                Spacer()
                Picker(language("日历视图", "Calendar view"), selection: Binding(
                    get: { data.calendarMode }, set: data.setCalendarMode
                )) {
                    Text(language("周", "Week")).tag(ToolCalendarMode.week)
                    Text(language("月", "Month")).tag(ToolCalendarMode.month)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                .accessibilityIdentifier("DualDock3.Calendar.View")
            }

            if let period = ToolCalendarPeriod(containing: selected, mode: data.calendarMode, calendar: calendar) {
                periodView(period)
            }
        }
        .padding(14).frame(width: 290).fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DualDock3.Calendar")
        .onChange(of: data.calendar.readAccess) { _, _ in
            result = nil
            revision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refreshToday() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refreshToday() }
    }

    private func periodView(_ period: ToolCalendarPeriod) -> some View {
        let contents = result?.0 == period.interval ? result?.1 : nil
        return VStack(alignment: .leading, spacing: 10) {
            titleBar(period)
            dateGrid(period, contents: contents)
            Divider()
            agenda(contents)
            Button(language("打开日历", "Open Calendar")) {
                _ = DockToolsStore.openApp("com.apple.iCal")
            }.controlSize(.small)
        }
        .task(id: Query(interval: period.interval, revision: revision)) {
            let read = await data.readCalendarEvents(in: period.interval)
            guard !Task.isCancelled else { return }
            switch read {
            case .events(let events):
                result = (period.interval, .agenda(ToolCalendarAgenda(events: events, in: period.interval, calendar: calendar)))
            case .notDetermined: result = (period.interval, .notDetermined)
            case .denied: result = (period.interval, .denied)
            case .unavailable: result = (period.interval, .unavailable)
            }
        }
        .onDisappear { result = nil }
    }

    private func refreshToday() {
        let newDay = calendar.startOfDay(for: now())
        if selected == today { selected = newDay }
        today = newDay
        revision += 1
    }

    private func titleBar(_ period: ToolCalendarPeriod) -> some View {
        HStack(spacing: 4) {
            Text(periodTitle(period)).font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
            navigationButton("chevron.left", data.calendarMode == .week ? language("上一周", "Previous week") : language("上个月", "Previous month"), by: -1)
            Button(language("今天", "Today")) { selected = calendar.startOfDay(for: now()) }
                .controlSize(.small)
            navigationButton("chevron.right", data.calendarMode == .week ? language("下一周", "Next week") : language("下个月", "Next month"), by: 1)
        }
    }

    private func periodTitle(_ period: ToolCalendarPeriod) -> String {
        guard data.calendarMode == .week, let finalDay = period.days.last else {
            return selected.formatted(dateStyle.year().month(.wide))
        }
        let format = DateIntervalFormatter()
        format.locale = locale
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateTemplate = "MMMd"
        return format.string(from: period.interval.start, to: finalDay)
    }

    private func navigationButton(_ symbol: String, _ title: String, by amount: Int) -> some View {
        Button {
            if let date = calendar.date(byAdding: data.calendarMode.component, value: amount, to: selected) {
                selected = calendar.startOfDay(for: date)
            }
        } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 19, height: 21).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(title).help(title)
    }

    private func dateGrid(_ period: ToolCalendarPeriod, contents: Contents?) -> some View {
        let labels = ToolCalendarPeriod.weekdayLabels(in: calendar, locale: locale)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
            ForEach(labels.indices, id: \.self) { index in
                Text(labels[index]).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .frame(height: 17)
            }
            ForEach(0..<period.leadingSlots, id: \.self) { _ in Color.clear.frame(height: 26).accessibilityHidden(true) }
            ForEach(period.days, id: \.self) { date in
                let count: Int = {
                    if case .agenda(let events) = contents { return events.byDay[date]?.count ?? 0 }
                    return 0
                }()
                let isSelected = calendar.isDate(selected, inSameDayAs: date)
                let isToday = calendar.isDate(today, inSameDayAs: date)
                Button { selected = date } label: {
                    ZStack(alignment: .bottom) {
                        Text(verbatim: String(calendar.component(.day, from: date)))
                            .font(.system(size: 12, weight: isToday || isSelected ? .bold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? Color.white : (isToday ? Color.accentColor : .primary))
                            .frame(width: 27, height: 26)
                        if count > 0 {
                            Circle().fill(isSelected ? Color.white : Color.orange)
                                .frame(width: 3, height: 3).padding(.bottom, 1)
                        }
                    }
                    .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        if isToday && !isSelected {
                            RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 1)
                        }
                    }
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(date.formatted(dateStyle.year().month().day().weekday(.wide)))
                .accessibilityValue([isToday ? language("今天", "Today") : nil,
                                     count > 0 ? language("\(count) 项日程", "\(count) events") : nil]
                    .compactMap { $0 }.joined(separator: ", "))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private func agenda(_ contents: Contents?) -> some View {
        switch contents {
        case .agenda(let agenda):
            let events = agenda.byDay[calendar.startOfDay(for: selected)] ?? []
            Text(selected.formatted(dateStyle.month().day().weekday(.wide))).font(.system(size: 12, weight: .semibold))
            if events.isEmpty {
                Text(language("当天没有日程", "No events on this day")).font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(events.indices, id: \.self) { i in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(timeLabel(events[i])).foregroundStyle(.secondary).monospacedDigit()
                                Text(events[i].title.isEmpty ? language("无标题日程", "Untitled event") : events[i].title)
                                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            }.font(.system(size: 12)).frame(minHeight: 18)
                                .help(events[i].title)
                        }
                    }
                }.frame(height: CGFloat(min(events.count, 4) * 22))
            }
        case .notDetermined:
            Button(language("授权读取日程", "Allow Calendar Access"), action: data.authorizeCalendar)
                .controlSize(.small).disabled(data.calendarBusy)
        case .denied:
            Button(language("打开日历隐私设置", "Calendar Privacy Settings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }.controlSize(.small)
        case .unavailable:
            Text(language("日程暂不可用", "Events are unavailable")).font(.callout).foregroundStyle(.secondary)
            Button(language("重试", "Retry")) { revision += 1 }.controlSize(.small)
        case nil: ProgressView().controlSize(.small)
        }
    }

    private func timeLabel(_ event: ToolCalendarEvent) -> String {
        if event.allDay { return language("全天", "All day") }
        if event.start < calendar.startOfDay(for: selected) { return language("跨日", "Ongoing") }
        return event.start.formatted(dateStyle.hour().minute())
    }
}
