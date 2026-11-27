import SwiftUI

struct CursorQuotaSourceView: View {
    @Environment(\.dualDockLanguage) private var language
    @ObservedObject var service: AIQuotaService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(language("订阅", "Subscription"), selection: Binding(
                get: { service.cursorSource },
                set: { if let source = $0 { service.setCursorSource(source) } }
            )) {
                if service.cursorSource == nil {
                    Text(language("选择订阅…", "Choose a plan…")).tag(nil as CursorQuotaSource?)
                }
                Text(language("Cursor 原套餐（试验）", "Legacy Cursor (experimental)"))
                    .tag(Optional(CursorQuotaSource.cursorCLI))
                Text(language("X 订阅共享额度", "X shared plan")).tag(Optional(CursorQuotaSource.xSubscription))
            }
            .controlSize(.small)
            if let source = service.cursorSource {
                if let issue = service.issues[.cursor] {
                    Text(message(issue, source: source))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if source == .xSubscription {
                    Text(language("显示当前 Grok 账号与 Cursor 共用的周额度。请使用同一 X 订阅账号。", "Shows the weekly pool shared with Cursor. Sign in to Grok with the same X subscription."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Link(language("官方用量页", "Usage dashboard"), destination: source == .cursorCLI
                         ? URL(string: "https://cursor.com/dashboard/spending")! : URL(string: "https://grok.com/dashboard")!)
                    if service.issues[.cursor] == .cursorMissing || service.issues[.cursor] == .cursorOutdated || service.issues[.cursor] == .grokMissing {
                        Link(language("安装指南", "CLI setup"), destination: source == .cursorCLI
                             ? URL(string: "https://cursor.com/docs/cli/installation")! : URL(string: "https://docs.x.ai/build/overview")!)
                    }
                }.font(.caption)
            } else {
                Text(language("选择你的 Cursor 套餐以读取相应额度。", "Choose your Cursor plan to read its allowance."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func message(_ issue: AIQuotaError, source: CursorQuotaSource) -> String {
        switch issue {
        case .cursorMissing: return language("未找到 cursor-agent。请先安装官方 Cursor CLI。", "Install the official Cursor CLI (cursor-agent) first.")
        case .cursorOutdated: return language("请更新官方 Cursor CLI 到 2026.07.13 或更高版本。", "Update the official Cursor CLI to 2026.07.13 or newer.")
        case .grokMissing: return language("未找到 Grok CLI。请先安装并使用同一 X 账号登录。", "Install the Grok CLI and sign in with your X plan account.")
        case .signIn: return source == .cursorCLI ? language("在终端运行 cursor-agent login 登录，然后刷新。", "Run cursor-agent login in Terminal, then refresh.")
            : language("在终端运行 grok login 登录相应的 X 订阅账号，然后刷新。", "Run grok login with your X plan account, then refresh.")
        case .timeout, .invalid, .unavailable:
            return language("客户端暂未提供可识别的套餐余量。请在官方用量页查看，或稍后刷新。", "The CLI did not provide a usable plan allowance. Check the dashboard or refresh later.")
        default: return issue.text
        }
    }
}
