import SwiftUI
import DualDockCore

struct AppearanceSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: AppStore
    @Binding var selectedDisplayID: String?
    @State private var advanced = false
    @State private var focus: DockPreviewFocus = .none
    private let showsScope: Bool
    init(store: AppStore, selectedDisplayID: Binding<String?>, advancedInitially: Bool = false, showsScope: Bool = true) {
        self.store = store
        _selectedDisplayID = selectedDisplayID
        _advanced = State(initialValue: advancedInitially)
        self.showsScope = showsScope
    }
    private var adaptive: Bool { store.configuration.adaptiveSizing }
    private var displays: [DockDisplayInfo] { store.displays.filter { !$0.isMirrored } }
    private var preferences: DockCustomSizing { store.customSizing(for: selectedDisplayID) }
    private var presentation: DockPresentation { store.presentation(for: selectedDisplayID) }
    private var bounds: DockResizeBounds { store.customSizingBounds(for: selectedDisplayID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsScope {
                HStack { Spacer(); SettingsDisplayScope(store: store, selectedDisplayID: $selectedDisplayID) }
            }
            HStack(spacing: 12) {
                Picker(localize("尺寸模式", "Sizing mode"), selection: Binding(get: { adaptive }, set: { store.setAdaptiveSizing($0) })) {
                    Text(localize("自定义", "Custom")).tag(false)
                    Text(localize("跟随系统 Dock", "Follow System Dock")).tag(true)
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
                Spacer(minLength: 8)
                if !adaptive {
                    HStack(spacing: 7) {
                        preset(localize("小巧", "Compact"), size: 36, spacing: 10)
                        preset(localize("标准", "Standard"), size: 48, spacing: 20)
                        preset(localize("舒展", "Spacious"), size: 60, spacing: 40)
                    }
                }
            }.controlSize(.small)
            if displays.isEmpty {
                SettingsGroup(localize("等待显示器", "Waiting for a display")) {
                    Label(localize("连接显示器后，即可预览和调整 Dock。", "Connect a display to preview and adjust the Dock."), systemImage: "display")
                        .foregroundStyle(.secondary)
                }
            } else {
                if presentation.edge.isHorizontal {
                    sample
                    baseControls
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        sample.frame(width: 104)
                        baseControls.environment(\.settingsLabelWidth, 82)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !adaptive {
                    advancedControls
                    HStack {
                        Spacer(minLength: 8)
                        Button(store.configuration.synchronizeSizes ? localize("恢复所有屏幕尺寸", "Reset Size on All Displays") : localize("恢复此屏幕尺寸", "Reset Size on This Display")) {
                            store.resetCustomSizing(for: selectedDisplayID)
                        }.controlSize(.small).help(localize("恢复推荐尺寸，保留应用、分组和屏幕位置", "Restore recommended sizes and keep apps, groups, and display positions"))
                    }
                }
            }
        }
    }

    private var sample: some View {
        SettingsDockPreview(store: store, displayID: selectedDisplayID, focus: focus)
    }

    @ViewBuilder private var baseControls: some View {
        if adaptive {
            VStack(alignment: .leading, spacing: 10) {
                Text(localize("大小、间距、留白与悬停放大跟随系统。切回自定义后保留你的配置。", "Size, spacing, padding, and magnification follow the system Dock. Switching back restores your custom settings."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                positionRow
            }
        } else {
            primaryControls
        }
    }

    private var primaryControls: some View {
        VStack(spacing: 0) {
            SettingsFormSlider(title: localize("大小", "Size"), note: localize("图标与默认栏高", "Icons and Dock height"), value: binding(\.iconSize),
                range: 16...max(16, min(128, bounds.maxThickness - 8)), onEditingChanged: finishEditing,
                onFocus: { focus = $0 ? .size : .none })
            if presentation.style.iconSize + 0.5 < preferences.iconSize {
                supportingText(localize("受屏幕空间限制，实际图标为 \(dockPoints(presentation.style.iconSize))。", "Display space limits the actual icon size to \(dockPoints(presentation.style.iconSize))."))
            }
            Divider()
            SettingsFormSlider(title: localize("图标间距", "Icon spacing"), note: localize("贴合 → 一个图标宽", "Touching to one icon apart"), value: Binding(
                get: { store.spacingPercent(for: selectedDisplayID) },
                set: { store.setSpacingPercent($0, for: selectedDisplayID) }),
                range: 0...100, unit: "%", onEditingChanged: finishEditing,
                onFocus: { focus = $0 ? .density : .none })
            Divider()
            SettingsFormRow(localize("长度", "Length"), note: lengthDescription) {
                Picker(localize("长度", "Length"), selection: Binding(get: { preferences.lengthMode }, set: { value in
                    store.updateCustomSizing(for: selectedDisplayID) { $0.lengthMode = value; $0.legacyFixedLength = nil }
                    if value == .fixed { advanced = true }
                })) {
                    Text(localize("贴合内容", "Fit Content")).tag(DockLengthMode.fit)
                    Text(localize("占满", "Fill")).tag(DockLengthMode.fill)
                    Text(localize("固定", "Fixed")).tag(DockLengthMode.fixed)
                }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 330, alignment: .leading)
                .onHover { focus = $0 ? .length : .none }
            }
            Divider()
            positionRow
        }
    }

    private var advancedControls: some View {
        DisclosureGroup(isExpanded: $advanced) {
            VStack(alignment: .leading, spacing: 0) {
                overrideControl(localize("两端留白", "End padding"), field: .padding, keyPath: \.paddingOverride,
                    actual: presentation.style.leadingPadding, range: 2...max(60, preferences.paddingOverride ?? 0), focus: .density)
                Divider()
                overrideControl(localize("Dock 高度", "Dock height"), field: .minimumHeight, keyPath: \.minimumHeightOverride,
                    actual: presentation.style.barThickness, range: bounds.minThickness...bounds.maxThickness, focus: .height)
                Text(localize("高度会为图标自动留足空间，上限为适用屏幕短边的 12%。", "The Dock grows to fit its icons, up to 12% of the available display’s shorter side."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 6)
                Divider()
                SettingsFormSlider(title: localize("固定长度占比", "Fixed length"), note: localize("按屏幕可用边长", "Share of available edge"), value: Binding(get: { preferences.fixedLengthPercent }, set: { value in
                    store.updateCustomSizing(for: selectedDisplayID) {
                        $0.fixedLengthPercent = value; $0.lengthMode = .fixed; $0.legacyFixedLength = nil
                    }
                }), range: 20...100, unit: "%", onEditingChanged: finishEditing,
                    onFocus: { focus = $0 ? .length : .none })
                HStack {
                    Text(preferences.lengthMode == .fixed ? localize("已使用固定长度", "Fixed length is active") : localize("调整后切换为固定长度", "Adjust to use a fixed length"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if preferences.lengthMode == .fixed {
                        Button(localize("恢复贴合内容", "Reset to Fit Content")) { store.resetCustomSizingOverride(.fixedLength, for: selectedDisplayID) }
                            .controlSize(.small)
                    }
                }.padding(.bottom, 6)
                Divider()
                SettingsFormRow(localize("内容较少时", "Content alignment")) {
                    Picker(localize("内容较少时", "Content alignment"), selection: binding(\.alignment)) {
                        Text(localize("居中", "Center")).tag(DockContentAlignment.center)
                        if preferences.spacingPercent == nil { Text(localize("均分", "Distribute")).tag(DockContentAlignment.distribute) }
                        Text(localize("靠起点", "Start")).tag(DockContentAlignment.start)
                    }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 330, alignment: .leading)
                }
                Divider()
                Toggle(isOn: binding(\.shrinkBeforeScroll)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(localize("放不下时先缩小图标", "Shrink icons before scrolling")).fontWeight(.medium)
                        Text(preferences.spacingPercent == nil
                            ? localize("优先收紧间距；仍然放不下时可沿 Dock 滚动。", "Spacing tightens first. Scroll along the Dock if content still overflows.")
                            : localize("保持间距比例；缩小后仍放不下时可滚动。", "Keeps the spacing ratio. Scroll if icons still overflow."))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 8)
            }.padding(.top, 2)
        } label: {
            HStack {
                Text(localize("高级设置", "Advanced")).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(overrideCount > 0 ? localize("\(overrideCount) 项自定", "\(overrideCount) custom") : localize("留白、高度与溢出", "Padding, height, and overflow"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .disclosureGroupStyle(SettingsDisclosureStyle())
        .padding(.horizontal, 12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    private var positionRow: some View {
        SettingsFormRow(localize("位置", "Position"), note: localize("仅当前屏幕", "This display only")) {
            Picker(localize("位置", "Position"), selection: Binding(get: { selectedDisplayID.map { store.edge(for: $0) } ?? .bottom }, set: { edge in
                if let selectedDisplayID { store.setEdge(edge, for: selectedDisplayID) }
            })) {
                ForEach([DockEdge.bottom, .left, .right, .top], id: \.self) { edge in Text(edgeTitle(edge)).tag(edge) }
            }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 330, alignment: .leading)
        }
    }
    private func supportingText(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 126).padding(.bottom, 10)
    }
    private func preset(_ title: String, size: Double, spacing: Double) -> some View {
        Button(title) {
            store.updateCustomSizing(for: selectedDisplayID) {
                $0.iconSize = size; $0.spacingPercent = spacing; $0.gapOverride = nil
                if $0.alignment == .distribute { $0.alignment = .center }
            }
        }
        .tint(abs(preferences.iconSize - size) < 0.01 && abs((preferences.spacingPercent ?? -1) - spacing) < 0.01 ? Color.accentColor : nil)
        .help(localize("\(title)：图标 \(Int(size)) pt，留白与高度自定值保持不变", "\(title) preset with \(Int(size)) pt icons. Keeps custom padding and height."))
    }
    private func overrideControl(_ title: String, field: DockSizingOverride,
                                 keyPath: WritableKeyPath<DockCustomSizing, Double?>,
                                 actual: CGFloat, range: ClosedRange<Double>, focus subject: DockPreviewFocus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsFormSlider(title: title, note: preferences[keyPath: keyPath] == nil ? localize("自动计算", "Automatic") : localize("手动固定", "Manual"),
                value: Binding(get: { preferences[keyPath: keyPath] ?? Double(actual) }, set: { value in
                    store.updateCustomSizing(for: selectedDisplayID) { $0[keyPath: keyPath] = value }
                }), range: range, onEditingChanged: finishEditing, onFocus: { focus = $0 ? subject : .none })
            if preferences[keyPath: keyPath] != nil {
                HStack { Spacer(); Button(localize("恢复自动", "Reset to Automatic")) { store.resetCustomSizingOverride(field, for: selectedDisplayID) }
                    .controlSize(.small).accessibilityLabel(localize("\(title)恢复自动", "Reset \(title) to automatic"))
                }.padding(.bottom, 10)
            }
        }
    }
    private func binding<Value>(_ keyPath: WritableKeyPath<DockCustomSizing, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: keyPath] }, set: { value in
            store.updateCustomSizing(for: selectedDisplayID) { $0[keyPath: keyPath] = value }
        })
    }
    private var overrideCount: Int {
        [preferences.paddingOverride, preferences.minimumHeightOverride].compactMap { $0 }.count
            + (preferences.lengthMode == .fixed ? 1 : 0)
    }
    private var lengthDescription: String {
        switch preferences.lengthMode {
        case .fit: return localize("随应用数量伸缩", "Fits the app count")
        case .fill: return localize("铺满可用长度", "Uses the full edge")
        case .fixed: return localize("高级设置中调整", "Set in Advanced")
        }
    }
    private func finishEditing(_ editing: Bool) { if !editing { store.flushPendingSave() } }
}

struct SettingsDisplayScope: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: AppStore
    @Binding var selectedDisplayID: String?
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Picker(localize("配置屏幕", "Display to configure"), selection: $selectedDisplayID) {
                ForEach(store.displays.filter { !$0.isMirrored }) { display in
                    Text(display.name).tag(Optional(display.id))
                }
            }.labelsHidden().frame(maxWidth: 172).disabled(store.displays.allSatisfy(\.isMirrored))
            Toggle(localize("同步各屏尺寸", "Sync sizes across displays"), isOn: Binding(get: { store.configuration.synchronizeSizes }, set: {
                store.setSizeSynchronization($0, sourceDisplayID: selectedDisplayID)
            })).disabled(store.configuration.adaptiveSizing)
                .font(.system(size: 13)).controlSize(.small).fixedSize()
        }
    }
}
