import AppKit
import SwiftUI
import DualDockCore

struct FolderAppearanceSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: AppStore

    private var appearance: DockFolderAppearance { store.configuration.folderAppearance }
    private var sampleIcons: [NSImage] { SettingsDockExample.apps.prefix(4).map { store.icon(for: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup(localize("图标风格", "Icon style")) {
                HStack(spacing: 6) {
                    ForEach(DockFolderStyle.allCases, id: \.self) { style in
                        styleButton(style)
                    }
                }
            }

            SettingsGroup(localize("背景", "Background")) {
                HStack(spacing: 16) {
                    FolderArtworkPreview(appearance: appearance, icons: sampleIcons)
                        .frame(width: 78, height: 78)
                        .padding(7)
                        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(localize("应用组图标预览", "Group icon preview"))
                        .accessibilityValue(styleTitle(appearance.style))
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Text(localize("背景颜色", "Background color"))
                            Spacer(minLength: 2)
                            Button(localize("使用风格原色", "Use Style Color")) {
                                store.update { $0.folderAppearance.backgroundColor = nil }
                            }
                            .controlSize(.small)
                            .disabled(appearance.backgroundColor == nil)
                            ColorPicker(localize("背景颜色", "Background color"), selection: color, supportsOpacity: false)
                                .labelsHidden()
                                .accessibilityLabel(localize("背景颜色", "Background color"))
                        }
                        Divider()
                        HStack {
                            Text(localize("背景不透明度", "Background opacity"))
                            Spacer()
                            Text(appearance.backgroundOpacity, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { appearance.backgroundOpacity },
                            set: { value in store.update { $0.folderAppearance.backgroundOpacity = value } }
                        ), in: 0...1, onEditingChanged: { editing in
                            if !editing { store.flushPendingSave() }
                        })
                        .accessibilityLabel(localize("背景不透明度", "Background opacity"))
                        .accessibilityValue(appearance.backgroundOpacity.formatted(.percent.precision(.fractionLength(0))))
                        .help(localize("设为 0% 可隐藏背景，保留成员图标。", "Set to 0% to hide the background and keep the app icons visible."))
                    }
                }
            }

            HStack(spacing: 12) {
                Text(localize("应用于所有屏幕上的应用组。", "Applies to app groups on every display."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(localize("恢复默认外观", "Restore Default Appearance")) {
                    store.update { $0.folderAppearance = DockFolderAppearance() }
                }
                .controlSize(.small)
                .disabled(appearance == DockFolderAppearance())
            }
            .padding(.horizontal, 2)
        }
    }

    private var color: Binding<Color> {
        Binding(get: {
            if let value = appearance.backgroundColor {
                return Color(.sRGB, red: value.red, green: value.green, blue: value.blue)
            }
            return Color(nsColor: DockFolderArtwork.defaultColor(for: appearance.style))
        }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            store.update {
                $0.folderAppearance.backgroundColor = DockFolderColor(
                    red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
            }
        })
    }

    private func styleTitle(_ style: DockFolderStyle) -> String {
        switch style {
        case .silver: return localize("银灰", "Silver")
        case .classic: return localize("经典", "Classic")
        case .flat: return localize("扁平", "Flat")
        case .skeuomorphic: return localize("皮革", "Leather")
        case .glass: return localize("玻璃", "Glass")
        }
    }

    private func styleButton(_ style: DockFolderStyle) -> some View {
        let selected = appearance.style == style
        return Button {
            store.update { $0.folderAppearance.style = style }
        } label: {
            VStack(spacing: 5) {
                FolderArtworkPreview(appearance: DockFolderAppearance(style: style), icons: sampleIcons)
                    .frame(width: 54, height: 54)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Text(styleTitle(style)).font(.system(size: 13)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selected ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(styleTitle(style))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct FolderArtworkPreview: NSViewRepresentable {
    let appearance: DockFolderAppearance
    let icons: [NSImage]

    final class ArtworkView: NSView {
        var folderAppearance = DockFolderAppearance()
        var icons: [NSImage] = []

        override func draw(_ dirtyRect: NSRect) {
            NSGraphicsContext.current?.imageInterpolation = .high
            DockFolderArtwork.draw(in: bounds, appearance: folderAppearance, icons: icons)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }

    func makeNSView(context: Context) -> ArtworkView { ArtworkView() }
    func updateNSView(_ view: ArtworkView, context: Context) {
        guard view.folderAppearance != appearance || view.icons != icons else { return }
        view.folderAppearance = appearance
        view.icons = icons
        view.needsDisplay = true
    }
}
