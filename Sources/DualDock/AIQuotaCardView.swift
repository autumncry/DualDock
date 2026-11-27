import SwiftUI
import AppKit

extension AIQuotaProvider {
    var symbol: String {
        switch self { case .codex: return "terminal"; case .claude: return "asterisk"; case .gemini: return "sparkles"; case .cursor: return "cursorarrow" }
    }
    var tint: Color {
        switch self { case .codex: return .blue; case .claude: return .orange; case .gemini: return .purple; case .cursor: return .primary }
    }

    func quotaTitle(in language: AppLanguage) -> String {
        if self == .gemini { return ShelfLayout.Kind.geminiQuota.name(in: language) }
        return language("\(name) 余量", "\(name) quota")
    }
}

private func quotaReset(_ date: Date, language: AppLanguage) -> String {
    let f = DateComponentsFormatter();f.unitsStyle = .abbreviated
    var calendar = Calendar.current
    calendar.locale = Locale(identifier: language.rawValue)
    f.calendar = calendar
    f.allowedUnits = [.day,.hour,.minute];f.maximumUnitCount = 2
    let interval = date.timeIntervalSinceNow
    guard interval > 0 else { return language("等待更新","Awaiting update") }
    let remaining = f.string(from:max(60,interval)) ?? ""
    return language("\(remaining)后重置","Resets in \(remaining)")
}

/// A passive face shared with Settings. Rendering it neither connects providers
/// nor reads the pasteboard, requests credentials, or schedules a refresh.
struct AIQuotaPreviewView: View {
    @Environment(\.dualDockLanguage) private var language
    let provider: AIQuotaProvider
    @ObservedObject var service: AIQuotaService
    let span: Int
    var horizontal: Bool = true

    private var summary: String {
        if let w = service.selected(provider) {
            return service.isExpired(w) ? language("等待更新","Awaiting update") : w.amount
        }
        if provider != .codex {
            if provider == .cursor && service.cursorSource == nil { return language("选择套餐", "Choose plan") }
            if service.isRefreshing(provider) { return language("查询中", "Loading") }
            if service.issues[provider] == .signIn { return language("待登录", "Sign in") }
            return service.issues[provider] == nil ? language("点击刷新", "Click to refresh")
                                                  : language("暂不可用", "Unavailable")
        }
        if service.issues[provider] != nil { return language("暂不可用","Unavailable") }
        if service.codexBusy && provider == .codex { return language("查询中","Loading") }
        if service.isConnected(provider) { return language("等待数据","Awaiting data") }
        return language("待连接","Connect")
    }
    private var caption: String {
        if provider != .codex && service.isRefreshing(provider) { return language("正在刷新", "Refreshing…") }
        if let win = service.selected(provider) {
            if service.isExpired(win) { return win.title(in: language) }
            if service.isStale(provider) { return language("上次读数","Last reading") }
            if span >= 3, let reset = win.reset { return quotaReset(reset, language: language) }
            return win.title(in: language)
        }
        if provider == .gemini { return "Antigravity" }
        return provider.name
    }
    var body: some View {
        ViewThatFits(in:.horizontal) {
            if horizontal && span >= 2 {
                HStack(spacing:4) {
                    Image(systemName:provider.symbol).foregroundStyle(provider.tint)
                    VStack(alignment:.leading,spacing:1) {
                        let selected = service.selected(provider)
                        Text(provider.name + (selected.map { " · " + $0.title(in: language) } ?? ""))
                            .font(.system(size:10)).lineLimit(1)
                        Text(selected.map { service.isExpired($0) ? summary : language("剩余 ","Left ") + summary } ?? summary)
                            .font(.system(size:12,weight:.semibold)).monospacedDigit().lineLimit(1)
                        if span >= 3 { Text(caption).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
            VStack(spacing:2) {
                HStack(spacing:1) {
                    Image(systemName:provider.symbol).foregroundStyle(provider.tint)
                    if service.isStale(provider) { Image(systemName:"clock").font(.system(size:8)).foregroundStyle(.secondary) }
                }
                Text(summary).font(.system(size:10,weight:.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.76)
            }
        }.accessibilityElement(children:.ignore)
            .accessibilityLabel(provider.quotaTitle(in: language))
            .accessibilityValue(summary + " · " + caption)
    }
}

struct AIQuotaCardView: View {
    let provider: AIQuotaProvider
    @ObservedObject var service: AIQuotaService
    let span: Int
    let horizontal: Bool
    var onDetailChange: (Bool) -> Void
    @State private var open = false
    @State private var detailID = UUID()
    var body: some View {
        Button {
            if provider != .codex || service.isConnected(.codex) { service.refresh(provider) }
            open = true
        } label: {
            AIQuotaPreviewView(provider:provider,service:service,span:span,horizontal:horizontal)
                .frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityIdentifier("DualDock.Quota.Card." + provider.rawValue)
        .help(provider == .gemini ? L("刷新 Antigravity 的 Gemini 额度", "Refresh Gemini quota from Antigravity")
                                  : L("查看 \(provider.name) 的剩余额度", "View remaining \(provider.name) quota"))
        .popover(isPresented:$open) {
            AIQuotaDetail(provider:provider,service:service)
        }
        .onChange(of:open) { _, active in
            service.setDetail(active ? provider : nil,id:detailID)
            onDetailChange(active)
        }
        .onDisappear {
            service.setDetail(nil,id:detailID);onDetailChange(false)
        }
    }
}

struct AIQuotaDetail: View {
    @Environment(\.dualDockLanguage) private var language
    let provider: AIQuotaProvider
    @ObservedObject var service: AIQuotaService
    @State private var confirmingClaude = false

    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing: 8) {
                Label(provider.quotaTitle(in: language), systemImage: provider.symbol)
                    .font(.system(size: 15, weight: .semibold))
                if provider != .codex && (provider != .cursor || service.cursorSource != nil) {
                    Spacer(minLength: 0)
                    if service.isRefreshing(provider) {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel(language("正在查询额度", "Checking quota"))
                    }
                    Button {
                        service.refresh(provider)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(service.isRefreshing(provider))
                    .accessibilityLabel(language("刷新额度", "Refresh quota"))
                    .accessibilityIdentifier(provider == .gemini ? "DualDock.Quota.Antigravity.Refresh" : "DualDock.Quota." + provider.rawValue + ".Refresh")
                    .help(language("刷新额度", "Refresh quota"))
                }
            }
            if let reading = service.snapshots[provider], !reading.windows.isEmpty {
                let rows = VStack(alignment: .leading, spacing: 8) {
                    ForEach(reading.windows) { w in
                        HStack(alignment:.top,spacing:8) {
                            VStack(alignment:.leading,spacing:3) {
                                HStack {
                                    Text(w.title(in: language))
                                    Spacer()
                                    let amount = language("剩余 " + w.amount, w.amount + " left")
                                    Text(service.isExpired(w) ? language("等待更新", "Awaiting update") : amount)
                                        .monospacedDigit()
                                }
                                if let p = w.remainingPercent, !service.isExpired(w) {
                                    ProgressView(value:p,total:100).tint(p <= 20 ? .orange : provider.tint)
                                }
                                if let reset = w.reset {
                                    Text(language("重置 ", "Resets ") + formattedDate(reset))
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if let reset = w.resetDescription {
                                    Text(language("重置日期 ", "Reset date ") + reset)
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if provider != .codex {
                                    Text(language("重置时间暂未提供", "Reset time unavailable"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button { service.pin(w.id,for:provider) } label: {
                                Image(systemName:service.selected(provider)?.id == w.id ? "pin.fill" : "pin")
                            }.buttonStyle(.plain)
                                .accessibilityLabel(language("固定此窗口", "Pin this limit to the Dock"))
                        }
                    }
                }
                if reading.windows.count <= 3 {
                    rows.fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView { rows }.frame(height: 195)
                }
                Text((provider == .claude ? language("读取于 ", "Read at ") : language("更新于 ", "Updated ")) + formattedDate(reading.updated))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = service.issues[provider], provider == .codex || provider == .claude {
                Text(issue.text).font(.callout).foregroundStyle(.secondary)
            }
            switch provider {
            case .codex:
                Text(L("来源：本机 Codex CLI 的 ChatGPT 账号限额。", "Source: ChatGPT limits from your local Codex CLI."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(service.isConnected(.codex) ? L("刷新","Refresh") : L("连接 Codex CLI","Connect Codex CLI")) {
                        if service.isConnected(.codex) { service.refreshCodex() } else { service.connectCodex() }
                    }.disabled(service.codexBusy)
                    Button(L("选择 CLI…","Select CLI…")) {
                        let panel = NSOpenPanel();panel.canChooseDirectories=false;panel.canChooseFiles=true
                        if panel.runModal() == .OK, let url=panel.url { service.connectCodex(executable:url.path) }
                    }
                }
            case .claude:
                Text(service.claudeFromStatusLine ? L("上次状态行读数", "Last status-line reading")
                     : (service.snapshots[.claude]?.sourceIsCached == true
                        ? L("Claude Code 返回了上次记录的额度。", "Claude Code returned last-known usage.")
                        : L("从官方 Claude Code 的 /usage 读取；CLI 可能复用近期缓存。", "Read from Claude Code /usage. The CLI may reuse a recent reading.")))
                    .font(.caption).foregroundStyle(.secondary)
                if service.claudeToken != nil {
                    Text(L("已启用备用状态行。主动查询不可用时，可查看上次状态行读数。",
                           "Status-line fallback is enabled. Its last reading can be shown when an active query is unavailable."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if confirmingClaude {
                    Text(L("连接后会保留你原有的状态行命令，并接替可验证的旧试用版回调。下次会话起只保存限额和重置时间。",
                           "Keep your existing status-line command and replace a verified preview callback. Only limits and reset times are saved, starting with the next session."))
                        .font(.callout)
                    HStack {
                        Button(L("允许接入","Allow Connection")) { service.connectClaude();confirmingClaude = false }
                        Button(L("取消","Cancel")) { confirmingClaude = false }
                    }
                } else { Button(L("启用备用状态行…","Connect Claude Code Status Line…")) { confirmingClaude = true } }
            case .cursor:
                CursorQuotaSourceView(service: service)
            case .gemini:
                AntigravityQuotaStatusView(service: service)
            }
            if (provider == .codex && service.isConnected(.codex)) || (provider == .claude && service.claudeToken != nil) {
                Divider()
                Button(L("断开连接并清除读数", "Disconnect and clear readings")) {
                    service.disconnect(provider)
                }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .font(.system(size:13)).frame(width:285,alignment:.leading).padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DualDock.Quota.Detail." + provider.rawValue)
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened,
                                        locale: Locale(identifier: language.rawValue)))
    }
}
