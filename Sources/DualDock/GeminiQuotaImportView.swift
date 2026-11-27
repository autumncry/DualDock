import AppKit
import SwiftUI

struct GeminiQuotaImportView: View {
    @Environment(\.dualDockLanguage) private var language
    @ObservedObject var service: AIQuotaService
    var readClipboard: () -> String? = { NSPasteboard.general.string(forType: .string) }
    @State private var showsGuide = false
    @State private var isEditing = false
    @State private var input = ""
    @State private var feedback: Feedback?

    private enum Feedback { case emptyClipboard, missingQuota }
    private var hasSnapshot: Bool { service.snapshots[.gemini] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if hasSnapshot {
                DisclosureGroup(language("如何获取额度", "How to get your quota"), isExpanded: $showsGuide) {
                    guide.padding(.top, 6)
                }
            } else {
                Text(language("导入 Gemini CLI 的额度快照后，Dock 会显示剩余量。",
                              "Import a Gemini CLI snapshot to show the remaining quota in your Dock."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                guide
            }

            if isEditing {
                TextEditor(text: $input)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 58)
                    .accessibilityLabel(language("Gemini CLI 额度输出", "Gemini CLI quota output"))
                HStack {
                    Button(language("导入", "Import")) { submit(input) }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(language("取消", "Cancel")) { closeEditor() }
                }
            } else {
                HStack {
                    Button(language("粘贴并导入", "Paste and Import")) {
                        guard let value = readClipboard(),
                              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            feedback = .emptyClipboard
                            return
                        }
                        submit(value)
                    }
                    .accessibilityIdentifier("DualDock3.Gemini.PasteAndImport")
                    Button(language("手动粘贴…", "Paste Manually…")) {
                        feedback = nil
                        isEditing = true
                    }
                }
            }

            if let feedback {
                Text(feedback == .emptyClipboard
                     ? language("剪贴板中没有文本。请先复制终端的额度输出。",
                                "The clipboard has no text. Copy the quota output from your terminal first.")
                     : language("未找到额度。请连同表头复制模型配额；只有 Token 数时无法计算余量。",
                                "No quota found. Include the model quota heading. Token counts alone cannot show your allowance."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if hasSnapshot && !showsGuide {
                Text(language("点图钉选择 Dock 显示的额度。再次导入快照即可更新。",
                              "Pin a limit to show it in the Dock. Import a fresh snapshot to update it."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 8) {
            step("1", language("在终端运行 gemini，首次使用时按提示登录。",
                               "Run gemini in Terminal. Sign in if prompted."))
            step("2", language("在 Gemini 会话中输入 /stats model。若只看到 Token 统计，再输入 /model 查看额度。",
                               "Enter /stats model inside Gemini. If you only see token totals, open /model to look for quota."))
            step("3", language("复制“% used”或“Limit reached”所在行。若显示模型表，连同“Model usage”或“Usage left”表头一起复制。",
                               "Copy the “% used” or “Limit reached” line. For a model table, include its “Model usage” or “Usage left” heading."))
            Link(language("Gemini CLI 安装与登录指南", "Install and sign in to Gemini CLI"),
                 destination: URL(string: "https://github.com/google-gemini/gemini-cli/blob/main/docs/get-started/index.md#install")!)
                .font(.caption).padding(.leading, 20)
        }
    }

    private func step(_ number: String, _ instruction: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(number).monospacedDigit().foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
                .accessibilityHidden(true)
            Text(instruction).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.font(.system(size: 12))
    }

    private func submit(_ text: String) {
        if service.importGemini(text) {
            closeEditor()
            showsGuide = false
        } else {
            feedback = service.issues[.gemini] == .invalid ? .missingQuota : nil
        }
    }

    private func closeEditor() {
        isEditing = false
        input = ""
        feedback = nil
    }
}
