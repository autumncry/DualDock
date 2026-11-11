import AppKit
import SwiftUI

struct AboutView: View {
    private let projectURL = URL(string: "https://github.com/autumncry/DualDock")!
    private let releasesURL = URL(string: "https://github.com/autumncry/DualDock/releases/latest")!
    private let issuesURL = URL(string: "https://github.com/autumncry/DualDock/issues")!

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 18) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 76, height: 76)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text("DualDock").font(.system(size: 26, weight: .semibold))
                    Text(versionDescription).foregroundStyle(.secondary)
                    Text("每块屏幕，同一套工作空间。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Copyright © 2026 Ronny Cao").textSelection(.enabled)
                Text("采用 MIT 开源协议。").foregroundStyle(.secondary)
                Link(destination: projectURL) { Label("GitHub 项目主页", systemImage: "arrow.up.right.square") }
                Text(projectURL.absoluteString).font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 20) {
                    Link("版本与下载", destination: releasesURL)
                    Link("问题反馈", destination: issuesURL)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("如果喜欢 DualDock，欢迎在 GitHub 点 Star 支持。")
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: projectURL) { Label("去 GitHub 支持项目", systemImage: "star") }
                    .buttonStyle(.bordered)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var versionDescription: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "开发版本" }
        let versionText = "版本 " + version
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return versionText }
        return versionText + " · 构建 " + build
    }
}
