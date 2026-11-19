import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject private var updates = SoftwareUpdateService.shared
    private let projectURL = URL(string: "https://github.com/autumncry/DualDock")!
    private let releasesURL = URL(string: "https://github.com/autumncry/DualDock/releases/latest")!
    private let issuesURL = URL(string: "https://github.com/autumncry/DualDock/issues")!

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 20) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("DualDock")
                        .font(.system(size: 25, weight: .semibold))
                    Text(localize("应用有序收纳，Dock 多屏同在。", "Organized apps. A Dock on every display."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(localize("原生 macOS 多屏 Dock", "A native multi-display Dock for macOS"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                detailRow(localize("版本", "Version")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Text(versionDescription)
                                .textSelection(.enabled)
                            Button {
                                updates.check()
                            } label: {
                                Label(localize("检查更新…", "Check for Updates…"), systemImage: "arrow.triangle.2.circlepath")
                            }
                            .controlSize(.small)
                            .disabled(!updates.canCheck)
                        }
                        if let error = updates.startupError {
                            Text(localize("无法启动更新检查。", "Could not start the update check.") + " " + error)
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Divider()
                detailRow(localize("许可证", "License")) {
                    Text(localize("MIT 开源协议", "MIT License"))
                }
                Divider()
                detailRow(localize("作者与版权", "Author and copyright")) {
                    Text("Copyright © 2026 Ronny Cao")
                        .textSelection(.enabled)
                }
                Divider()
                detailRow(localize("项目主页", "Project website")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Link(destination: projectURL) {
                            Label(localize("GitHub 项目主页", "GitHub repository"), systemImage: "arrow.up.right.square")
                        }
                        Text(projectURL.absoluteString)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                detailRow(localize("版本与下载", "Releases")) {
                    Link(destination: releasesURL) {
                        Label(localize("查看发布版本", "View Releases"), systemImage: "arrow.down.circle")
                    }
                }
                Divider()
                detailRow(localize("问题反馈", "Feedback")) {
                    Link(destination: issuesURL) {
                        Label(localize("提交问题与建议", "Report an Issue"), systemImage: "bubble.left")
                    }
                }
            }
            .padding(.horizontal, 18)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            }

            HStack(alignment: .center, spacing: 16) {
                Text(localize("如果喜欢 DualDock，欢迎在 GitHub 点 Star 支持。", "If you enjoy DualDock, give the project a star on GitHub."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Link(destination: projectURL) {
                    Label(localize("去 GitHub 支持项目", "Star on GitHub"), systemImage: "star")
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44)
        .padding(.vertical, 4)
    }

    private var versionDescription: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return localize("开发版本", "Development build") }
        let versionText = localize("版本 ", "Version ") + version
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return versionText }
        return versionText + localize(" · 构建 ", " · Build ") + build
    }
}
