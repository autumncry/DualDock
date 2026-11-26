import AppKit
import SwiftUI
import DualDockCore

struct DockToolsShelfView: View {
    @ObservedObject var store: DockToolsStore
    let displayID: String
    let edge: DockEdge
    let iconSize: CGFloat
    @State private var language = AppLanguage.current

    var body: some View {
        GeometryReader { proxy in
            let horizontal = edge.isHorizontal
            let cross = max(1, horizontal ? proxy.size.height : proxy.size.width)
            let main = max(1, horizontal ? proxy.size.width : proxy.size.height)
            let unit = max(30, min(max(1, iconSize), cross - 4))
            if store.layout.slots.isEmpty {
                Button(action: DockToolsStore.openSettings) {
                    Label(language("添加工具", "Add Tools"), systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let flow = horizontal ? AnyLayout(HStackLayout(spacing: 5)) : AnyLayout(VStackLayout(spacing: 5))
                ScrollView(horizontal ? .horizontal : .vertical) {
                    flow {
                        ForEach(store.layout.slots) { slot in
                            let length = unit * CGFloat(slot.span) + CGFloat(slot.span - 1) * 5
                            if let card = store.selectedCard(in: slot, on: displayID) {
                                DockToolTile(store: store, data: store.data, slot: slot, card: card,
                                             displayID: displayID, horizontal: horizontal,
                                             width: horizontal ? length : max(1, cross - 4),
                                             height: horizontal ? max(1, cross - 4) : length)
                                .id(card.id)
                            }
                        }
                    }
                    .padding(horizontal ? .horizontal : .vertical, 4)
                    .frame(minWidth: horizontal ? main : nil, minHeight: horizontal ? nil : main)
                    .frame(width: horizontal ? nil : cross, height: horizontal ? cross : nil)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: horizontal ? .horizontal : .vertical)
            }
        }
        .environment(\.dualDockLanguage, language)
        .environment(\.locale, Locale(identifier: language.rawValue))
        .onReceive(NotificationCenter.default.publisher(for: .dualDockLanguageDidChange)) { _ in language = .current }
        .accessibilityIdentifier("DualDock3.ToolsShelf")
    }
}

private struct DockToolTile: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: DockToolsStore
    @ObservedObject var data: ToolDataService
    let slot: ShelfLayout.Slot
    let card: ShelfLayout.Card
    let displayID: String
    let horizontal: Bool
    let width: CGFloat
    let height: CGFloat
    @State private var showDetail = false
    @State private var actionFailed = false

    var body: some View {
        let rowLayout = horizontal ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
        rowLayout {
            Button(action: primaryAction) { face }
                .buttonStyle(.plain)
                .disabled(card.kind == .music && data.musicBusy)
                .accessibilityLabel("\(card.title) · \(title)")
                .help("\(title) · \(subtitle)")
                .popover(isPresented: $showDetail) { detail }
            if case .track = data.music, card.kind == .music, slot.span >= 2 {
                iconButton(symbol: "forward.end.fill", label: localize("下一首", "Next Track")) { data.nextTrack() }
                    .disabled(data.musicBusy)
            }
            if slot.cards.count > 1 {
                let index = (slot.cards.firstIndex(of: card) ?? 0) + 1
                iconButton(symbol: horizontal ? "chevron.right" : "chevron.down",
                           label: localize("下一张卡片", "Next Card") + " (\(index)/\(slot.cards.count))") {
                    store.advance(slot, on: displayID)
                }
            }
        }
        .padding(.horizontal, width > 48 ? 5 : 2)
        .padding(.vertical, 2)
        .frame(width: width, height: height)
        .background(.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: min(11, min(width, height) / 3)))
        .onChange(of: showDetail) { _, isOpen in store.setDetailOpen(isOpen, cardID: card.id, on: displayID) }
        .onDisappear { store.setDetailOpen(false, cardID: card.id, on: displayID) }
        .contextMenu {
            if card.kind == .music, case .track = data.music {
                Button(localize("下一首", "Next Track")) { data.nextTrack() }
                    .disabled(data.musicBusy)
                Divider()
            }
            Button(localize("工具页设置…", "Tools Page Settings…"), action: DockToolsStore.openSettings)
            if slot.cards.count > 1 {
                Divider()
                ForEach(Array(slot.cards.enumerated()), id: \.element.id) { index, entry in
                    Button(entry.title) {
                        let current = slot.cards.firstIndex(of: card) ?? 0
                        store.advance(slot, on: displayID, by: index - current)
                    }
                }
            }
        }
    }

    private var face: some View {
        let roomForText = horizontal ? width >= (slot.cards.count > 1 ? 78 : 64) : height >= 58 && width >= 30
        let direction = horizontal ? AnyLayout(HStackLayout(spacing: 5)) : AnyLayout(VStackLayout(spacing: 3))
        return direction {
            if card.kind == .launcher, let entry = card.destination, entry.kind == .application, let url = entry.url {
                Image(nsImage: DockToolArtwork.icon(at: url)).resizable()
                    .aspectRatio(contentMode: .fit).frame(width: symbolSize + 4, height: symbolSize + 4)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(tint)
            }
            if roomForText {
                VStack(alignment: horizontal ? .leading : .center, spacing: 1) {
                    Text(title).font(.system(size: min(12, max(9, min(width, height) * 0.23)), weight: .semibold))
                        .lineLimit(horizontal ? 1 : 2).truncationMode(.tail)
                    if min(width, height) >= 37 {
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else if card.kind == .weather, case .conditions(let reading, _) = data.weather,
                      width >= 34 && slot.cards.count == 1 {
                Text(degrees(reading)).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: horizontal && roomForText ? .leading : .center)
        .contentShape(Rectangle())
    }

    private var symbolSize: CGFloat { min(21, max(9, min(width, height) * 0.38)) }

    private func iconButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: horizontal ? min(20, width * 0.30) : max(12, width - 8),
                       height: horizontal ? min(34, max(14, height - 4)) : min(19, height * 0.23))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label).help(label)
    }

    private var tint: Color {
        switch card.kind {
        case .music: return .pink
        case .calendar: return .orange
        case .weather: return .cyan
        case .launcher: return .accentColor
        }
    }

    private func degrees(_ reading: ToolWeatherReading) -> String {
        reading.temperature.formatted(.number.precision(.fractionLength(0))) + "°"
    }

    private func weatherCondition(_ code: Int) -> (symbol: String, text: String) {
        switch code {
        case -2: return ("cloud.sleet.fill", localize("雨夹雪", "Sleet"))
        case 0: return ("sun.max.fill", localize("晴", "Clear"))
        case 1...2: return ("cloud.sun.fill", localize("局部多云", "Partly cloudy"))
        case 3: return ("cloud.fill", localize("阴", "Overcast"))
        case 45, 48: return ("cloud.fog.fill", localize("雾", "Fog"))
        case 51...57: return ("cloud.drizzle.fill", localize("毛毛雨", "Drizzle"))
        case 61...67, 80...82: return ("cloud.rain.fill", localize("雨", "Rain"))
        case 71...77, 85...86: return ("cloud.snow.fill", localize("雪", "Snow"))
        case 95...99: return ("cloud.bolt.rain.fill", localize("雷阵雨", "Thunderstorms"))
        default: return ("cloud.fill", localize("天气", "Weather"))
        }
    }

    private var symbol: String {
        switch card.kind {
        case .music:
            if case .track(_, _, let playing) = data.music { return playing ? "pause.fill" : "play.fill" }
            return "music.note"
        case .weather:
            if case .conditions(let value, _) = data.weather { return weatherCondition(value.code).symbol }
            return "cloud.sun.fill"
        case .calendar, .launcher:
            return card.symbol
        }
    }

    private var title: String {
        switch card.kind {
        case .music:
            if case .track(let name, _, _) = data.music { return name }
            return localize("音乐", "Music")
        case .weather:
            if case .conditions(let value, _) = data.weather { return degrees(value) + "  " + value.city.name }
            return store.city?.name ?? localize("设置城市", "Choose City")
        case .calendar:
            if case .upcoming(let event, _, _) = data.calendar { return event }
            return Date.now.formatted(.dateTime.month().day().locale(Locale(identifier: localize.rawValue)))
        case .launcher: return card.title
        }
    }

    private var subtitle: String {
        switch card.kind {
        case .music:
            switch data.music {
            case .disconnected: return localize("连接 Apple Music", "Connect Apple Music")
            case .notRunning: return localize("打开音乐", "Open Music")
            case .idle: return localize("播放音乐", "Play music")
            case .track(_, let artist, _): return artist.isEmpty ? localize("正在播放的曲目", "Current track") : artist
            case .denied: return localize("需要自动化权限", "Automation access needed")
            case .unavailable: return localize("播放器未响应", "Player unavailable")
            }
        case .weather:
            switch data.weather {
            case .noCity: return localize("选择城市", "Choose a city")
            case .loading: return localize("更新中…", "Updating…")
            case .unavailable: return localize("天气暂不可用", "Weather unavailable")
            case .conditions(let reading, let stale):
                return stale ? localize("上次天气", "Last update") : weatherCondition(reading.code).text
            }
        case .calendar:
            switch data.calendar {
            case .notDetermined: return localize("连接日历", "Connect calendars")
            case .denied: return localize("需要日历权限", "Calendar access needed")
            case .empty: return localize("未来 7 天无日程", "No events in 7 days")
            case .unavailable: return localize("日历暂不可用", "Calendar unavailable")
            case .upcoming(_, let start, let allDay):
                let locale = Locale(identifier: localize.rawValue)
                let day = start.formatted(.dateTime.weekday(.abbreviated).locale(locale))
                if allDay { return day + " · " + localize("全天", "All day") }
                let time = start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
                return Calendar.current.isDateInToday(start) || !horizontal ? time : day + " " + time
            }
        case .launcher:
            guard let entry = card.destination else { return "" }
            switch entry.kind {
            case .shortcut: return localize("运行快捷指令", "Run shortcut")
            case .website: return entry.url?.host ?? localize("网址", "Website")
            case .application: return localize("打开应用", "Open app")
            case .file: return localize("打开项目", "Open item")
            }
        }
    }

    private func primaryAction() {
        actionFailed = false
        switch card.kind {
        case .music:
            switch data.music {
            case .disconnected: data.enableMusic()
            case .notRunning:
                if !DockToolsStore.openApp("com.apple.Music") { actionFailed = true; showDetail = true }
            case .track, .idle: data.togglePlayback()
            case .unavailable: data.enableMusic()
            case .denied: showDetail = true
            }
        case .weather:
            if store.city == nil { DockToolsStore.openSettings() } else { showDetail = true }
        case .calendar: showDetail = true
        case .launcher:
            guard let d = card.destination, DockToolsStore.open(d) else {
                actionFailed = true
                showDetail = true
                return
            }
        }
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title).font(.headline)
            if actionFailed {
                Text(localize("无法打开这个项目。请在工具页设置中检查目标。", "This item could not be opened. Check its target in Tools Page Settings."))
                Button(localize("工具页设置…", "Tools Page Settings…"), action: DockToolsStore.openSettings)
            } else {
                switch card.kind {
                case .calendar:
                    Text(title).font(.body)
                    Text(subtitle).foregroundStyle(.secondary)
                    switch data.calendar {
                    case .notDetermined:
                        Button(localize("授权读取日程", "Allow Calendar Access")) { data.authorizeCalendar() }.disabled(data.calendarBusy)
                    case .denied:
                        Button(localize("打开日历隐私设置", "Calendar Privacy Settings")) { openPrivacy("Calendars") }
                    default:
                        Button(localize("打开日历", "Open Calendar")) { _ = DockToolsStore.openApp("com.apple.iCal") }
                    }
                case .weather:
                    Text(title).font(.title2)
                    if case .conditions(let reading, let stale) = data.weather {
                        Text(localize("近时预报", "Near-term forecast") + " · " + weatherCondition(reading.code).text + " · °C")
                        if let forecastAt = reading.forecastAt {
                            Text(localize("预报时段 ", "Forecast for ") + forecastAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text((stale ? localize("上次更新 ", "Last updated ") : localize("更新于 ", "Updated ")) +
                             reading.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Link(reading.attributionName, destination: reading.attributionURL)
                            Text("·")
                            Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                        }.font(.caption)
                    } else { Text(subtitle).foregroundStyle(.secondary) }
                    HStack {
                        Button(localize("刷新", "Refresh")) { data.refreshWeather() }
                        Button(localize("更改城市…", "Change City…"), action: DockToolsStore.openSettings)
                    }
                case .music:
                    Text(subtitle).foregroundStyle(.secondary)
                    Button(localize("打开自动化隐私设置", "Automation Privacy Settings")) { openPrivacy("Automation") }
                case .launcher: EmptyView()
                }
            }
        }
        .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        .frame(width: 230, alignment: .leading).padding(14)
    }

    private func openPrivacy(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + anchor) else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private enum DockToolArtwork {
    static let cache = NSCache<NSString, NSImage>()
    static func icon(at url: URL) -> NSImage {
        let key = url.path as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }
}
