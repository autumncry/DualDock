import AppKit
import SwiftUI

struct AboutView: View {
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
                    Text("应用有序收纳，Dock 多屏同在。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("原生 macOS 多屏 Dock")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                detailRow("版本") {
                    Text(versionDescription)
                        .textSelection(.enabled)
                }
                Divider()
                detailRow("许可证") {
                    Text("MIT 开源协议")
                }
                Divider()
                detailRow("作者与版权") {
                    Text("Copyright © 2026 Ronny Cao")
                        .textSelection(.enabled)
                }
                Divider()
                detailRow("项目主页") {
                    VStack(alignment: .leading, spacing: 4) {
                        Link(destination: projectURL) {
                            Label("GitHub 项目主页", systemImage: "arrow.up.right.square")
                        }
                        Text(projectURL.absoluteString)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                detailRow("版本与下载") {
                    Link(destination: releasesURL) {
                        Label("查看发布版本", systemImage: "arrow.down.circle")
                    }
                }
                Divider()
                detailRow("问题反馈") {
                    Link(destination: issuesURL) {
                        Label("提交问题与建议", systemImage: "bubble.left")
                    }
                }
            }
            .padding(.horizontal, 18)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            }

            HStack(alignment: .center, spacing: 16) {
                Text("如果喜欢 DualDock，欢迎在 GitHub 点 Star 支持。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Link(destination: projectURL) {
                    Label("去 GitHub 支持项目", systemImage: "star")
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
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "开发版本" }
        let versionText = "版本 " + version
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return versionText }
        return versionText + " · 构建 " + build
    }
}
