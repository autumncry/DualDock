import SwiftUI
import AppKit

extension AIQuotaProvider {
    var symbol: String {
        switch self { case .codex: return "terminal"; case .claude: return "asterisk"; case .gemini: return "sparkles" }
    }
    var tint: Color {
        switch self { case .codex: return .blue; case .claude: return .orange; case .gemini: return .purple }
    }
}

private func quotaReset(_ date:Date) -> String {
    let f = DateComponentsFormatter();f.unitsStyle = .abbreviated
    f.allowedUnits = [.day,.hour,.minute];f.maximumUnitCount = 2
    let interval = date.timeIntervalSinceNow
    guard interval > 0 else { return L("等待更新","Awaiting update") }
    let remaining = f.string(from:max(60,interval)) ?? ""
    return L("\(remaining)后重置","Resets in \(remaining)")
}

/// A passive face shared with Settings. Rendering it neither connects providers
/// nor reads the pasteboard, requests credentials, or schedules a refresh.
struct AIQuotaPreviewView: View {
    let provider: AIQuotaProvider
    @ObservedObject var service: AIQuotaService
    let span: Int
    var horizontal: Bool = true

    private var summary: String {
        if let w = service.selected(provider) {
            return service.isExpired(w) ? L("等待更新","Awaiting update") : w.amount
        }
        if service.issues[provider] != nil { return L("暂不可用","Unavailable") }
        if service.codexBusy && provider == .codex { return L("查询中","Loading") }
        if service.isConnected(provider) { return L("等待数据","Awaiting data") }
        return L("待连接","Connect")
    }
    private var caption: String {
        if let win = service.selected(provider) {
            if service.isExpired(win) { return win.title }
            if service.isStale(provider) { return L("上次读数","Last reading") }
            if provider == .gemini { return L("手动快照","Imported") }
            if span >= 3, let reset = win.reset { return quotaReset(reset) }
            return win.title
        }
        return provider.name
    }
    var body: some View {
        ViewThatFits(in:.horizontal) {
            if horizontal && span >= 2 {
                HStack(spacing:4) {
                    Image(systemName:provider.symbol).foregroundStyle(provider.tint)
                    VStack(alignment:.leading,spacing:1) {
                        let selected = service.selected(provider)
                        Text(provider.name + (selected.map { " · " + $0.title } ?? ""))
                            .font(.system(size:10)).lineLimit(1)
                        Text(selected.map { service.isExpired($0) ? summary : L("剩余 ","Left ") + summary } ?? summary)
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
            .accessibilityLabel(L("\(provider.name) 余量","\(provider.name) quota"))
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
            open = true
        } label: {
            AIQuotaPreviewView(provider:provider,service:service,span:span,horizontal:horizontal)
                .frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .help(L("查看 \(provider.name) 的剩余额度","View remaining \(provider.name) quota"))
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

private struct AIQuotaDetail: View {
    let provider: AIQuotaProvider
    @ObservedObject var service: AIQuotaService
    @State private var confirmingClaude = false
    @State private var paste = ""
    @State private var importing = false
    @State private var hasPasteError = false

    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Label(provider.name + L(" 余量"," quota"),systemImage:provider.symbol)
                .font(.system(size:15,weight:.semibold))
            if let reading = service.snapshots[provider], !reading.windows.isEmpty {
                ScrollView {
                    VStack(alignment:.leading,spacing:8) {
                        ForEach(reading.windows) { w in
                            HStack(alignment:.top,spacing:8) {
                                VStack(alignment:.leading,spacing:3) {
                                    HStack { Text(w.title);Spacer()
                                        Text(service.isExpired(w) ? L("等待更新","Awaiting update") : w.amount)
                                            .monospacedDigit()
                                    }
                                    if let p = w.remainingPercent, !service.isExpired(w) {
                                        ProgressView(value:p,total:100).tint(p <= 20 ? .orange : provider.tint)
                                    }
                                    if let reset = w.reset {
                                        Text(L("重置 ","Resets ") + reset.formatted(date:.abbreviated,time:.shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Button { service.pin(w.id,for:provider) } label: {
                                    Image(systemName:service.selected(provider)?.id == w.id ? "pin.fill" : "pin")
                                }.buttonStyle(.plain).accessibilityLabel(L("固定此窗口","Pin this limit to the Dock"))
                            }
                        }
                    }
                }.frame(height:min(195,CGFloat(reading.windows.count)*49))
                Text((provider == .gemini ? L("手动快照 · 导入于 ","Snapshot imported ") : L("更新于 ","Updated ")) +
                     reading.updated.formatted(date:.abbreviated,time:.shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = service.issues[provider] { Text(issue.text).font(.callout).foregroundStyle(.secondary) }
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
                if service.isConnected(.claude) {
                    Text(L("来源：Claude Code 状态行。开始会话并收到一次回复后，这里会随状态行更新。",
                           "Source: Claude Code status line. Readings arrive after Claude responds in a session."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if confirmingClaude {
                    Text(L("将为 Claude Code 的用户设置添加状态行回调，保留原状态行的命令与输出。只保存限额和重置时间。下次会话起效，可随时断开。",
                           "Add a callback to Claude Code’s user status-line settings. Your existing command and output are preserved. Only limits and reset times are saved. Takes effect in a new session."))
                        .font(.callout)
                    HStack {
                        Button(L("允许接入","Allow Connection")) { service.connectClaude();confirmingClaude = false }
                        Button(L("取消","Cancel")) { confirmingClaude = false }
                    }
                } else { Button(L("连接 Claude Code 状态行…","Connect Claude Code Status Line…")) { confirmingClaude = true } }
            case .gemini:
                Text(L("来源：手动导入 Gemini CLI 的额度统计。复制 /stats 或 /stats model 中的配额段落。",
                       "Source: imported Gemini CLI quota. Copy the quota section from /stats or /stats model."))
                    .font(.caption).foregroundStyle(.secondary)
                if importing {
                    TextEditor(text:$paste).font(.system(size:11,design:.monospaced)).frame(height:56)
                        .accessibilityLabel(L("Gemini CLI 统计结果","Gemini CLI quota output"))
                    HStack {
                        Button(L("粘贴","Paste")) {
                            paste = NSPasteboard.general.string(forType:.string) ?? ""
                        }
                        Button(L("导入","Import")) {
                            if service.importGemini(paste) { paste="";importing=false;hasPasteError=false }
                            else { hasPasteError=true }
                        }.disabled(paste.isEmpty)
                        Button(L("取消","Cancel")) { paste="";importing=false;hasPasteError=false }
                    }
                    if hasPasteError {
                        Text(L("只接受限额窗口或模型额度表。会话 Token 数不能换算成余量。",
                               "Use a quota window or a model quota table. Session token totals cannot be converted into an allowance."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else { Button(L("导入额度快照…","Import quota snapshot…")) { importing=true } }
            }
            if service.isConnected(provider) {
                Divider()
                Button(L("断开连接并清除读数","Disconnect and clear readings")) { service.disconnect(provider) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .font(.system(size:13)).frame(width:285,alignment:.leading).padding(14)
    }
}
