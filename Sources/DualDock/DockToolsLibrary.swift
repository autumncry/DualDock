import SwiftUI
import DualDockCore

enum ToolLibraryCategory: CaseIterable, Identifiable {
    case all, system, tools, ai, media, life
    var id: Self { self }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .all: return language("全部", "All")
        case .system: return language("系统", "System")
        case .tools: return language("工具", "Tools")
        case .ai: return "AI"
        case .media: return language("媒体", "Media")
        case .life: return language("生活", "Life")
        }
    }
}

enum ToolLibraryItem: Hashable, Identifiable {
    case widget(ShelfLayout.Kind)
    case destination(ShelfLayout.Destination.Kind)

    var id: Self { self }
    var dragID: String {
        switch self {
        case .widget(let kind): return "widget." + kind.rawValue
        case .destination(let kind): return "destination." + kind.rawValue
        }
    }
    init?(dragID: String) {
        guard let value = Self.items.first(where: { $0.dragID == dragID }) else { return nil }
        self = value
    }

    static let items: [Self] = [
        .widget(.systemStatus), .widget(.focusTimer), .widget(.codexQuota), .widget(.music),
        .widget(.weather), .widget(.calendar), .widget(.claudeQuota), .widget(.geminiQuota),
        .widget(.battery), .widget(.storage), .destination(.shortcut), .destination(.application),
        .destination(.website), .destination(.file)
    ]

    var category: ToolLibraryCategory {
        switch self {
        case .widget(.systemStatus), .widget(.battery), .widget(.storage): return .system
        case .widget(.codexQuota), .widget(.claudeQuota), .widget(.geminiQuota): return .ai
        case .widget(.music): return .media
        case .widget(.calendar), .widget(.weather): return .life
        case .widget(.focusTimer), .widget(.launcher), .destination: return .tools
        }
    }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .widget(let kind): return kind.name(in: language)
        case .destination(.shortcut): return language("快捷指令", "macOS Shortcut")
        case .destination(.application): return language("应用入口", "Application")
        case .destination(.website): return language("网址", "Website")
        case .destination(.file): return language("文件或文件夹", "File or Folder")
        }
    }

    func summary(_ l: AppLanguage) -> String {
        switch self {
        case .widget(.systemStatus): return l("CPU、内存和交换空间", "CPU, memory and swap")
        case .widget(.battery): return l("查看本机电池电量", "Mac battery charge")
        case .widget(.storage): return l("查看磁盘可用空间", "Available disk space")
        case .widget(.focusTimer): return l("开始或暂停专注倒计时", "Start or pause a focus timer")
        case .widget(.codexQuota): return l("查看套餐窗口余量与重置时间", "Plan limits and reset times")
        case .widget(.claudeQuota): return l("查看短周期与每周余量", "Session and weekly limits")
        case .widget(.geminiQuota): return l("从 Gemini CLI 导入模型余量", "Import model quotas from Gemini CLI")
        case .widget(.music): return l("查看正在播放的音乐与播放列表", "Now Playing and the current playlist")
        case .widget(.weather): return l("查看所选城市的天气", "Forecast for a city")
        case .widget(.calendar): return l("月视图、周视图与日程", "Month, week and upcoming events")
        case .destination(.application): return l("打开所选应用", "Launch a chosen app")
        case .destination(.file): return l("打开本机文件或目录", "Open a local item")
        case .destination(.website): return l("打开指定网页", "Open a web address")
        case .destination(.shortcut): return l("运行已有的系统快捷指令", "Run a saved shortcut")
        case .widget(.launcher): return l("打开自选项目", "Open a saved item")
        }
    }

    func source(_ l: AppLanguage) -> String {
        switch self {
        case .widget(.codexQuota): return l("本机 Codex 的账号限额", "Account limits from local Codex")
        case .widget(.claudeQuota): return l("Claude Code 状态行", "Claude Code status line")
        case .widget(.geminiQuota): return l("Gemini CLI 的模型配额", "Model quotas from Gemini CLI")
        case .widget(.music): return l("本机音乐 App，按需授权", "Music app with your permission")
        case .widget(.weather): return "MET Norway / Open-Meteo"
        case .widget(.calendar): return l("系统日期，日程需日历访问权限", "System date and optional calendar access")
        case .widget(.systemStatus), .widget(.storage), .widget(.battery): return "macOS"
        case .widget(.focusTimer): return "DualDock"
        case .destination(.shortcut): return l("本机快捷指令 App", "Shortcuts on this Mac")
        case .destination, .widget(.launcher): return l("由你选择的目标", "A destination you choose")
        }
    }

    var symbol: String {
        switch self {
        case .widget(let kind): return kind.symbol
        case .destination(.application): return "app"
        case .destination(.file): return "folder"
        case .destination(.website): return "globe"
        case .destination(.shortcut): return "square.2.layers.3d"
        }
    }

    var color: Color {
        switch self {
        case .widget(.codexQuota): return .blue
        case .widget(.claudeQuota): return .orange
        case .widget(.geminiQuota): return .indigo
        case .widget(.music): return .pink
        case .widget(.focusTimer): return .blue
        case .widget(.weather): return .cyan
        case .widget(.calendar): return .orange
        case .widget(.systemStatus), .widget(.battery): return .green
        case .widget(.storage): return .teal
        default: return .accentColor
        }
    }

    static func matching(category: ToolLibraryCategory, query: String) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return items.filter { item in
            guard category == .all || category == item.category else { return false }
            let names = [AppLanguage.english, .simplifiedChinese].flatMap {
                [item.title($0), item.summary($0), item.category.title($0)]
            }.joined(separator: " ")
            return terms.allSatisfy { names.localizedCaseInsensitiveContains(String($0)) }
        }
    }
}

struct DockToolsLibrary: View {
    @Environment(\.dualDockLanguage) private var language
    let query: String
    let layout: ShelfLayout
    let isEditing: Bool
    @Binding var category: ToolLibraryCategory
    let showsCategoryStrip: Bool
    let add: (ToolLibraryItem) -> Void
    @State private var inspected: ToolLibraryItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsCategoryStrip {
                Picker(language("组件分类", "Widget category"), selection: $category) {
                    ForEach(ToolLibraryCategory.allCases) { Text($0.title(language)).tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let results = ToolLibraryItem.matching(category: category, query: query)
                    if results.isEmpty {
                        Label(language("没有匹配的组件", "No matching widgets"), systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary).padding(.vertical, 12)
                    } else if category == .ai {
                        HStack {
                            Text(language("AI 余量", "AI quotas")).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(language("示例预览", "Sample previews")).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(results) { entry in
                            libraryRow(entry, wide: true)
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))], spacing: 8) {
                            ForEach(results) { entry in libraryRow(entry, wide: false) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, 5)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func libraryRow(_ entry: ToolLibraryItem, wide: Bool) -> some View {
        let installed: Bool = {
            if case .widget(let kind) = entry { return layout.contains(kind) }
            return false
        }()
        let draggable = isEditing && !installed
        return HStack(spacing: 8) {
            Button {
                inspected = entry
            } label: {
                HStack(spacing: 9) {
                    libraryArtwork(entry)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title(language)).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary).lineLimit(2)
                        Text(entry.summary(language)).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if wide { quotaSample(entry) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(entry.title(language))
                .help(entry.summary(language))
                .overlay {
                    if draggable {
                        ToolWidgetDragHandle(payload: "dualdock-library:" + entry.dragID,
                                             title: entry.title(language), symbol: entry.symbol) { inspected = entry }
                    }
                }
                .popover(isPresented: Binding(get: { inspected == entry }, set: { if !$0 { inspected = nil } })) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title(language)).font(.headline)
                        Text(entry.summary(language))
                        LabeledContent(language("来源", "Source"), value: entry.source(language))
                        LabeledContent(language("宽度", "Width"), value: language("1–4 格", "1–4 slots"))
                    }.font(.system(size: 12)).textSelection(.enabled).padding().frame(minWidth: 220, maxWidth: 300)
                }
            Button {
                add(entry)
            } label: {
                Image(systemName: installed ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(installed ? Color.accentColor : Color.secondary)
                    .frame(width: 25, height: 29)
            }.buttonStyle(.plain).disabled(installed)
                .accessibilityLabel((installed ? language("已添加", "Added") : language("添加", "Add")) + " · " + entry.title(language))
                .help(installed ? language("已在工具页中", "Already on the tools page") : language("添加到工具页", "Add to the tools page"))
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: wide ? 62 : 57, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5).allowsHitTesting(false))
    }

    private func libraryArtwork(_ entry: ToolLibraryItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(entry.color.opacity(0.09))
            switch entry {
            case .widget(.systemStatus):
                Canvas { context, size in
                    let points: [CGPoint] = [.init(x: 0, y: 0.78), .init(x: 0.16, y: 0.66), .init(x: 0.31, y: 0.72),
                                              .init(x: 0.43, y: 0.36), .init(x: 0.55, y: 0.51), .init(x: 0.67, y: 0.19),
                                              .init(x: 0.81, y: 0.65), .init(x: 1, y: 0.52)]
                    var path = Path()
                    for (i, p) in points.enumerated() {
                        let at = CGPoint(x: p.x * size.width, y: p.y * size.height)
                        if i == 0 { path.move(to: at) } else { path.addLine(to: at) }
                    }
                    context.stroke(path, with: .color(entry.color), lineWidth: 1.8)
                }.frame(width: 32, height: 20)
            case .widget(.focusTimer):
                Text("25:00").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(entry.color)
            case .widget(.weather):
                HStack(spacing: 2) {
                    Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor)
                    Text("24°").monospacedDigit()
                }.font(.system(size: 10, weight: .medium))
            case .widget(.calendar):
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2).fill(.orange).frame(width: 21, height: 4)
                    Text("26").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                }.padding(.bottom, 2).background(.background, in: RoundedRectangle(cornerRadius: 3))
            default:
                Image(systemName: entry.symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(entry.color)
            }
        }.frame(width: 42, height: 32).accessibilityHidden(true)
    }

    @ViewBuilder private func quotaSample(_ entry: ToolLibraryItem) -> some View {
        if entry == .widget(.geminiQuota) {
            VStack(alignment: .leading, spacing: 3) {
                Text("—").font(.caption)
                Text(language("待连接", "Not connected")).font(.caption).foregroundStyle(.secondary)
            }.frame(width: 98, alignment: .leading)
        } else {
            let fraction = entry == .widget(.codexQuota) ? 0.68 : 0.24
            VStack(alignment: .leading, spacing: 3) {
                Text(language("余量 ", "Remaining ") + fraction.formatted(.percent)).font(.caption)
                ProgressView(value: fraction).tint(entry.color).frame(width: 98)
                Text(entry == .widget(.codexQuota) ? language("2 小时后重置", "Resets in 2h") : language("周五重置", "Resets Friday"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Plain SwiftUI buttons track mouse-down themselves. Give the card face a
/// single native owner for clicks and drags; its separate add/resize controls
/// remain regular controls and the underlying button retains keyboard/AX access.
struct ToolWidgetDragHandle: NSViewRepresentable {
    let payload: String
    let title: String
    let symbol: String
    let onClick: () -> Void

    func makeNSView(context: Context) -> Handle {
        Handle(frame: .zero)
    }

    func updateNSView(_ view: Handle, context: Context) {
        view.payload = payload
        view.title = title
        view.symbol = symbol
        view.onClick = onClick
        view.setAccessibilityElement(false)
    }

    final class Handle: NSView, NSDraggingSource {
        var payload = ""
        var title = ""
        var symbol = ""
        var onClick: (() -> Void)?
        private var down: NSPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            down = event.locationInWindow
        }

        override func mouseUp(with event: NSEvent) {
            guard down != nil else { return }
            down = nil
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let item = dragItem(at: event.locationInWindow) else { return }
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func dragItem(at point: NSPoint) -> NSDraggingItem? {
            guard let down, hypot(point.x - down.x, point.y - down.y) >= 4 else { return nil }
            self.down = nil
            let item = NSDraggingItem(pasteboardWriter: payload as NSString)
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let style: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let name = title as NSString
            let size = NSSize(width: name.size(withAttributes: style).width.rounded(.up) + 39, height: 28)
            let preview = NSImage(size: size, flipped: false) { [symbol] rect in
                NSColor.controlBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.draw(in: NSRect(x: 7, y: 6, width: 16, height: 16))
                name.draw(at: NSPoint(x: 28, y: 6), withAttributes: style)
                return true
            }
            let p = convert(point, from: nil)
            item.setDraggingFrame(NSRect(x: p.x - 10, y: p.y - 14, width: size.width, height: size.height), contents: preview)
            return item
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            guard context == .withinApplication else { return [] }
            // SwiftUI may negotiate copy for plain text. The drop destination
            // owns the draft mutation, including a reorder or removal.
            return payload.hasPrefix("dualdock-slot:") ? [.move, .copy] : .copy
        }
    }
}
