import SwiftUI

struct AntigravityQuotaStatusView: View {
    @Environment(\.dualDockLanguage) private var language
    @ObservedObject var service: AIQuotaService
    @State private var showsImportedSnapshot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let issue = service.issues[.gemini], !service.antigravityBusy {
                Text(message(for: issue))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if issue == .signIn || issue == .antigravityMissing || issue == .antigravityOutdated {
                    Link(language("Antigravity 官方指南", "Antigravity setup guide"),
                         destination: URL(string: "https://antigravity.google/docs/install/")!)
                        .font(.caption)
                }
            } else if service.antigravityBusy && service.snapshots[.gemini] == nil {
                Text(language("正在向 Antigravity 查询剩余额度…", "Checking remaining quota with Antigravity…"))
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let archive = service.importedGeminiSnapshot {
                Divider()
                DisclosureGroup(language("旧版 Gemini CLI 快照", "Previous Gemini CLI snapshot"),
                                isExpanded: $showsImportedSnapshot) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(language("手动导入于 ", "Manually imported ") + archive.updated.formatted(
                            Date.FormatStyle(date: .abbreviated, time: .shortened,
                                             locale: Locale(identifier: language.rawValue))))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(archive.windows) { window in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(window.title(in: language)).lineLimit(1)
                                        Spacer()
                                        Text(window.amount).monospacedDigit()
                                    }
                                }
                            }
                        }
                        .frame(height: min(100, CGFloat(archive.windows.count) * 19))
                    }
                    .font(.caption).padding(.top, 4)
                }
                .controlSize(.small)
            }
        }
    }

    private func message(for issue: AIQuotaError) -> String {
        switch issue {
        case .signIn:
            return language("在终端运行 agy，按提示完成 Google 登录，然后回到这里刷新。",
                            "Run agy in Terminal, sign in to Google when prompted, then refresh here.")
        case .antigravityMissing:
            return language("请先安装 Antigravity CLI，然后在终端运行 agy 完成登录。",
                            "Install Antigravity CLI, then run agy in Terminal to sign in.")
        case .antigravityOutdated:
            return language("请将 Antigravity CLI 更新至 1.1.11 或更高版本，以查询额度。",
                            "Update Antigravity CLI to version 1.1.11 or later to check quota.")
        case .invalid:
            return language("无法识别 Antigravity 返回的额度数据。", "Couldn’t read the quota report from Antigravity.")
        case .unavailable:
            return language("暂未取得 Gemini 额度。请检查网络连接，然后刷新。",
                            "Gemini quota is unavailable. Check your connection and refresh.")
        default: return issue.text
        }
    }
}
