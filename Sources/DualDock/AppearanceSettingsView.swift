import SwiftUI
import DualDockCore

struct AppearanceSettingsView: View {
    @ObservedObject var store: AppStore
    @Binding var selectedDisplayID: String?
    @State private var advanced = false
    @State private var focus: DockPreviewFocus = .none
    init(store: AppStore, selectedDisplayID: Binding<String?>, advancedInitially: Bool = false) {
        self.store = store
        _selectedDisplayID = selectedDisplayID
        _advanced = State(initialValue: advancedInitially)
    }
    private var adaptive: Bool { store.configuration.adaptiveSizing }
    private var displays: [DockDisplayInfo] { store.displays.filter { !$0.isMirrored } }
    private var preferences: DockCustomSizing { store.customSizing(for: selectedDisplayID) }
    private var presentation: DockPresentation { store.presentation(for: selectedDisplayID) }
    private var bounds: DockResizeBounds { store.customSizingBounds(for: selectedDisplayID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Picker("配置屏幕", selection: $selectedDisplayID) {
                    ForEach(displays) { display in Text(display.name).tag(Optional(display.id)) }
                }.frame(maxWidth: 280).disabled(displays.isEmpty)
                Spacer(minLength: 8)
                Toggle("同步各屏尺寸", isOn: Binding(get: { store.configuration.synchronizeSizes }, set: {
                    store.setSizeSynchronization($0, sourceDisplayID: selectedDisplayID)
                })).disabled(adaptive).fixedSize()
            }
            HStack(spacing: 16) {
                Picker("尺寸模式", selection: Binding(get: { adaptive }, set: { store.setAdaptiveSizing($0) })) {
                    Text("自定义").tag(false)
                    Text("跟随系统 Dock").tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 300)
                Spacer(minLength: 0)
                Text(adaptive ? "尺寸与放大随系统变化" : (store.configuration.synchronizeSizes ? "应用到所有屏幕" : "仅应用到所选屏幕"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if displays.isEmpty {
                SettingsGroup("等待显示器") {
                    Label("连接显示器后，即可预览和调整 Dock。", systemImage: "display")
                        .foregroundStyle(.secondary)
                }
            } else if adaptive {
                SettingsDockPreview(store: store, displayID: selectedDisplayID, compact: true)
                SettingsGroup("当前系统尺寸") {
                    HStack(spacing: 36) {
                        systemValue("图标", store.nativeDockMetrics.iconSize)
                        systemValue("高度", store.nativeDockMetrics.barThickness)
                        systemValue("间距", store.nativeDockMetrics.itemSpacing)
                    }
                    Text("使用系统 Dock 的大小、间距和悬停放大。切回自定义后保留你的配置。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                positionPicker
            } else {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 18) {
                        SettingsDockPreview(store: store, displayID: selectedDisplayID, focus: focus)
                        positionPicker
                    }.frame(minWidth: 220, maxWidth: .infinity)
                    primaryControls.frame(width: 280).controlSize(.small)
                }
                advancedControls
                HStack {
                    Text("高级自定值会保留；可逐项恢复自动。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(store.configuration.synchronizeSizes ? "恢复所有屏幕的推荐尺寸" : "恢复此屏幕的推荐尺寸") { store.resetCustomSizing(for: selectedDisplayID) }
                        .controlSize(.small).help("恢复当前作用范围内的尺寸设置，保留应用、分组和屏幕位置")
                }
            }
        }
    }

    private var primaryControls: some View {
        SettingsGroup("常用调整", spacing: 10) {
            HStack(spacing: 6) {
                preset("小巧", size: 36, density: 0.3)
                preset("标准", size: 48, density: 0.5)
                preset("舒展", size: 60, density: 0.7)
            }
            SettingsNumericSlider(title: "大小", value: binding(\.iconSize),
                range: 16...max(16, min(128, bounds.maxThickness - 8)), onEditingChanged: finishEditing,
                onFocus: { focus = $0 ? .size : .none })
            Text("图标大小决定默认栏高。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            SettingsNumericSlider(title: "疏密", value: Binding(get: { preferences.density * 100 }, set: { value in
                store.updateCustomSizing(for: selectedDisplayID) { $0.density = value / 100 }
            }), range: 0...100, unit: "%", onEditingChanged: finishEditing,
                onFocus: { focus = $0 ? .density : .none })
                .disabled(preferences.gapOverride != nil && preferences.paddingOverride != nil)
            if preferences.gapOverride != nil && preferences.paddingOverride != nil {
                HStack {
                    Text("间距与留白已自定").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("恢复联动") {
                        store.updateCustomSizing(for: selectedDisplayID) { $0.gapOverride = nil; $0.paddingOverride = nil }
                    }.controlSize(.small).help("将间距与两端留白恢复为自动计算")
                }
            }
            HStack { Text("紧凑"); Spacer(); Text("宽松") }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("长度").font(.system(size: 13, weight: .medium))
                Picker("长度", selection: Binding(get: { preferences.lengthMode }, set: { value in
                    store.updateCustomSizing(for: selectedDisplayID) { $0.lengthMode = value; $0.legacyFixedLength = nil }
                    if value == .fixed { advanced = true }
                })) {
                    Text("贴合内容").tag(DockLengthMode.fit)
                    Text("占满").tag(DockLengthMode.fill)
                    Text("固定").tag(DockLengthMode.fixed)
                }.labelsHidden().pickerStyle(.segmented)
                Text(lengthDescription).font(.system(size: 11)).foregroundStyle(.secondary)
            }.onHover { focus = $0 ? .length : .none }
            if presentation.style.iconSize + 0.5 < preferences.iconSize {
                Text("空间不足，图标暂时缩小至 \(dockPoints(presentation.style.iconSize))。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var advancedControls: some View {
        DisclosureGroup(isExpanded: $advanced) {
            VStack(alignment: .leading, spacing: 20) {
                Text("手动值优先；恢复自动后，参数重新跟随大小与疏密。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                overrideControl("图标间距", field: .gap, keyPath: \.gapOverride,
                    actual: presentation.style.gap, range: 0...max(40, preferences.gapOverride ?? 0), focus: .density)
                overrideControl("两端留白", field: .padding, keyPath: \.paddingOverride,
                    actual: presentation.style.leadingPadding, range: 2...max(60, preferences.paddingOverride ?? 0), focus: .density)
                overrideControl("Dock 高度下限", field: .minimumHeight, keyPath: \.minimumHeightOverride,
                    actual: presentation.style.barThickness, range: bounds.minThickness...bounds.maxThickness, focus: .height)
                Text("图标需要更多空间时，高度会自动增加；上限为当前适用屏幕短边的 12%。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                SettingsNumericSlider(title: "固定长度占比", value: Binding(get: { preferences.fixedLengthPercent }, set: { value in
                    store.updateCustomSizing(for: selectedDisplayID) {
                        $0.fixedLengthPercent = value; $0.lengthMode = .fixed; $0.legacyFixedLength = nil
                    }
                }), range: 20...100, unit: "%", onEditingChanged: finishEditing,
                    onFocus: { focus = $0 ? .length : .none })
                HStack {
                    Text(preferences.lengthMode == .fixed ? "按屏幕可用边长计算" : "调整后切换为固定长度")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if preferences.lengthMode == .fixed {
                        Button("恢复贴合内容") { store.resetCustomSizingOverride(.fixedLength, for: selectedDisplayID) }
                            .controlSize(.small)
                    }
                }
                Divider()
                Picker("内容较少时", selection: binding(\.alignment)) {
                    Text("居中").tag(DockContentAlignment.center)
                    Text("均分").tag(DockContentAlignment.distribute)
                    Text("靠起点").tag(DockContentAlignment.start)
                }.pickerStyle(.segmented)
                Toggle("放不下时先缩小图标", isOn: binding(\.shrinkBeforeScroll))
                Text("优先收紧间距；仍然放不下时可沿 Dock 滚动，不显示滚动条。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.top, 18)
        } label: {
            HStack {
                Text("高级设置").font(.system(size: 13, weight: .semibold))
                Spacer()
                if overrideCount > 0 {
                    Text("\(overrideCount) 项自定").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5))
    }

    private var positionPicker: some View {
        Picker("位置", selection: Binding(get: { selectedDisplayID.map { store.edge(for: $0) } ?? .bottom }, set: { edge in
            if let selectedDisplayID { store.setEdge(edge, for: selectedDisplayID) }
        })) {
            ForEach([DockEdge.bottom, .left, .right, .top], id: \.self) { edge in Text(edgeTitle(edge)).tag(edge) }
        }.pickerStyle(.segmented)
    }
    private func preset(_ title: String, size: Double, density: Double) -> some View {
        Button(title) {
            store.updateCustomSizing(for: selectedDisplayID) { $0.iconSize = size; $0.density = density }
        }
        .frame(maxWidth: .infinity)
        .controlSize(.small)
        .tint(abs(preferences.iconSize - size) < 0.01 && abs(preferences.density - density) < 0.01 ? Color.accentColor : nil)
        .help("\(title)：图标 \(Int(size)) pt，高级自定值保持不变")
    }
    private func systemValue(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(dockPoints(value)).font(.system(size: 16, weight: .medium)).monospacedDigit()
        }
    }
    private func overrideControl(_ title: String, field: DockSizingOverride,
                                 keyPath: WritableKeyPath<DockCustomSizing, Double?>,
                                 actual: CGFloat, range: ClosedRange<Double>, focus subject: DockPreviewFocus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsNumericSlider(title: title, value: Binding(get: { preferences[keyPath: keyPath] ?? Double(actual) }, set: { value in
                store.updateCustomSizing(for: selectedDisplayID) { $0[keyPath: keyPath] = value }
            }), range: range, onEditingChanged: finishEditing, onFocus: { focus = $0 ? subject : .none })
            HStack {
                Text(preferences[keyPath: keyPath] == nil ? "自动计算" : "手动固定")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if preferences[keyPath: keyPath] != nil {
                    Button("恢复自动") { store.resetCustomSizingOverride(field, for: selectedDisplayID) }
                        .controlSize(.small).accessibilityLabel("\(title)恢复自动")
                }
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
        case .fit: return "随应用增减伸缩，保持居中。"
        case .fill: return "使用屏幕的全部可用长度。"
        case .fixed: return "使用高级设置中的固定占比。"
        }
    }
    private func finishEditing(_ editing: Bool) { if !editing { store.flushPendingSave() } }
}
