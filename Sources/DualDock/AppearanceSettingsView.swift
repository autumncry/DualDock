import SwiftUI
import DualDockCore

struct AppearanceSettingsView: View {
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
        VStack(alignment: .leading, spacing: 12) {
            if showsScope {
                HStack { Spacer(); SettingsDisplayScope(store: store, selectedDisplayID: $selectedDisplayID) }
            }
            HStack(spacing: 12) {
                Picker("尺寸模式", selection: Binding(get: { adaptive }, set: { store.setAdaptiveSizing($0) })) {
                    Text("自定义").tag(false)
                    Text("跟随系统 Dock").tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 240, alignment: .leading)
                Spacer(minLength: 8)
                if !adaptive {
                    HStack(spacing: 7) {
                        preset("小巧", size: 36, density: 0.3)
                        preset("标准", size: 48, density: 0.5)
                        preset("舒展", size: 60, density: 0.7)
                    }
                }
            }.controlSize(.small)
            if displays.isEmpty {
                SettingsGroup("等待显示器") {
                    Label("连接显示器后，即可预览和调整 Dock。", systemImage: "display")
                        .foregroundStyle(.secondary)
                }
            } else {
                SettingsDockPreview(store: store, displayID: selectedDisplayID, focus: focus, compact: adaptive)
                if adaptive {
                    SettingsGroup("跟随系统 Dock") {
                        Text("大小、间距、留白与悬停放大跟随系统。切回自定义后保留你的配置。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        positionRow
                    }
                } else {
                    primaryControls
                    advancedControls
                    HStack {
                        Text(store.configuration.synchronizeSizes ? "尺寸改动应用到所有屏幕" : "尺寸改动仅应用到所选屏幕")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(store.configuration.synchronizeSizes ? "恢复所有屏幕尺寸" : "恢复此屏幕尺寸") {
                            store.resetCustomSizing(for: selectedDisplayID)
                        }.controlSize(.small).help("恢复推荐尺寸，保留应用、分组和屏幕位置")
                    }
                }
            }
        }
    }

    private var primaryControls: some View {
        VStack(spacing: 0) {
            SettingsFormSlider(title: "大小", note: "图标与默认栏高", value: binding(\.iconSize),
                range: 16...max(16, min(128, bounds.maxThickness - 8)), onEditingChanged: finishEditing,
                onFocus: { focus = $0 ? .size : .none })
            if presentation.style.iconSize + 0.5 < preferences.iconSize {
                supportingText("受屏幕空间限制，实际图标为 \(dockPoints(presentation.style.iconSize))。")
            }
            Divider()
            SettingsFormSlider(title: "疏密", note: "紧凑 → 宽松", value: Binding(get: { preferences.density * 100 }, set: { value in
                store.updateCustomSizing(for: selectedDisplayID) { $0.density = value / 100 }
            }), range: 0...100, unit: "%", onEditingChanged: finishEditing,
                onFocus: { focus = $0 ? .density : .none })
                .disabled(preferences.gapOverride != nil && preferences.paddingOverride != nil)
            if preferences.gapOverride != nil && preferences.paddingOverride != nil {
                HStack {
                    Text("间距与留白已自定").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("恢复联动") {
                        store.updateCustomSizing(for: selectedDisplayID) { $0.gapOverride = nil; $0.paddingOverride = nil }
                    }.controlSize(.small).help("将间距与两端留白恢复为自动计算")
                    Spacer()
                }.padding(.leading, 128).padding(.bottom, 10)
            }
            Divider()
            SettingsFormRow("长度", note: lengthDescription) {
                Picker("长度", selection: Binding(get: { preferences.lengthMode }, set: { value in
                    store.updateCustomSizing(for: selectedDisplayID) { $0.lengthMode = value; $0.legacyFixedLength = nil }
                    if value == .fixed { advanced = true }
                })) {
                    Text("贴合内容").tag(DockLengthMode.fit)
                    Text("占满").tag(DockLengthMode.fill)
                    Text("固定").tag(DockLengthMode.fixed)
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
                Text("手动值优先；恢复自动后，参数重新跟随大小与疏密。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 12)
                overrideControl("图标间距", field: .gap, keyPath: \.gapOverride,
                    actual: presentation.style.gap, range: 0...max(40, preferences.gapOverride ?? 0), focus: .density)
                Divider()
                overrideControl("两端留白", field: .padding, keyPath: \.paddingOverride,
                    actual: presentation.style.leadingPadding, range: 2...max(60, preferences.paddingOverride ?? 0), focus: .density)
                Divider()
                overrideControl("Dock 高度下限", field: .minimumHeight, keyPath: \.minimumHeightOverride,
                    actual: presentation.style.barThickness, range: bounds.minThickness...bounds.maxThickness, focus: .height)
                Text("高度会为图标自动留足空间，上限为适用屏幕短边的 12%。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 12)
                Divider()
                SettingsFormSlider(title: "固定长度占比", note: "按屏幕可用边长", value: Binding(get: { preferences.fixedLengthPercent }, set: { value in
                    store.updateCustomSizing(for: selectedDisplayID) {
                        $0.fixedLengthPercent = value; $0.lengthMode = .fixed; $0.legacyFixedLength = nil
                    }
                }), range: 20...100, unit: "%", onEditingChanged: finishEditing,
                    onFocus: { focus = $0 ? .length : .none })
                HStack {
                    Text(preferences.lengthMode == .fixed ? "已使用固定长度" : "调整后切换为固定长度")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if preferences.lengthMode == .fixed {
                        Button("恢复贴合内容") { store.resetCustomSizingOverride(.fixedLength, for: selectedDisplayID) }
                            .controlSize(.small)
                    }
                }.padding(.bottom, 12)
                Divider()
                SettingsFormRow("内容较少时") {
                    Picker("内容较少时", selection: binding(\.alignment)) {
                        Text("居中").tag(DockContentAlignment.center)
                        Text("均分").tag(DockContentAlignment.distribute)
                        Text("靠起点").tag(DockContentAlignment.start)
                    }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 330, alignment: .leading)
                }
                Divider()
                Toggle("放不下时先缩小图标", isOn: binding(\.shrinkBeforeScroll)).padding(.vertical, 12)
                Text("优先收紧间距；仍然放不下时可沿 Dock 滚动，不显示滚动条。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.top, 16)
        } label: {
            HStack {
                Text("高级设置").font(.system(size: 13, weight: .medium))
                Spacer()
                Text(overrideCount > 0 ? "\(overrideCount) 项自定" : "间距、留白与高度")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    private var positionRow: some View {
        SettingsFormRow("位置", note: "仅当前屏幕") {
            Picker("位置", selection: Binding(get: { selectedDisplayID.map { store.edge(for: $0) } ?? .bottom }, set: { edge in
                if let selectedDisplayID { store.setEdge(edge, for: selectedDisplayID) }
            })) {
                ForEach([DockEdge.bottom, .left, .right, .top], id: \.self) { edge in Text(edgeTitle(edge)).tag(edge) }
            }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 330, alignment: .leading)
        }
    }
    private func supportingText(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 128).padding(.bottom, 10)
    }
    private func preset(_ title: String, size: Double, density: Double) -> some View {
        Button(title) {
            store.updateCustomSizing(for: selectedDisplayID) { $0.iconSize = size; $0.density = density }
        }
        .tint(abs(preferences.iconSize - size) < 0.01 && abs(preferences.density - density) < 0.01 ? Color.accentColor : nil)
        .help("\(title)：图标 \(Int(size)) pt，高级自定值保持不变")
    }
    private func overrideControl(_ title: String, field: DockSizingOverride,
                                 keyPath: WritableKeyPath<DockCustomSizing, Double?>,
                                 actual: CGFloat, range: ClosedRange<Double>, focus subject: DockPreviewFocus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsFormSlider(title: title, note: preferences[keyPath: keyPath] == nil ? "自动计算" : "手动固定",
                value: Binding(get: { preferences[keyPath: keyPath] ?? Double(actual) }, set: { value in
                    store.updateCustomSizing(for: selectedDisplayID) { $0[keyPath: keyPath] = value }
                }), range: range, onEditingChanged: finishEditing, onFocus: { focus = $0 ? subject : .none })
            if preferences[keyPath: keyPath] != nil {
                HStack { Spacer(); Button("恢复自动") { store.resetCustomSizingOverride(field, for: selectedDisplayID) }
                    .controlSize(.small).accessibilityLabel("\(title)恢复自动")
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
        [preferences.gapOverride, preferences.paddingOverride, preferences.minimumHeightOverride].compactMap { $0 }.count
            + (preferences.lengthMode == .fixed ? 1 : 0)
    }
    private var lengthDescription: String {
        switch preferences.lengthMode {
        case .fit: return "随应用数量伸缩"
        case .fill: return "铺满可用长度"
        case .fixed: return "高级设置中调整"
        }
    }
    private func finishEditing(_ editing: Bool) { if !editing { store.flushPendingSave() } }
}

struct SettingsDisplayScope: View {
    @ObservedObject var store: AppStore
    @Binding var selectedDisplayID: String?
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Picker("配置屏幕", selection: $selectedDisplayID) {
                ForEach(store.displays.filter { !$0.isMirrored }) { display in
                    Text(display.name).tag(Optional(display.id))
                }
            }.labelsHidden().frame(width: 200).disabled(store.displays.allSatisfy(\.isMirrored))
            Toggle("同步各屏尺寸", isOn: Binding(get: { store.configuration.synchronizeSizes }, set: {
                store.setSizeSynchronization($0, sourceDisplayID: selectedDisplayID)
            })).disabled(store.configuration.adaptiveSizing)
                .font(.system(size: 11)).controlSize(.mini).fixedSize()
        }
    }
}
