import Foundation

enum AppLanguage: String, CaseIterable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let preferenceKey = "DualDockDisplayLanguage"

    private static var localFile: URL?
    private static var localLanguage: AppLanguage = .simplifiedChinese

    static func useLocalSettings(in directory: URL, fallback: AppLanguage = .simplifiedChinese) {
        let file = directory.appendingPathComponent("language.txt")
        let saved = try? String(contentsOf: file, encoding: .utf8)
        localLanguage = saved.flatMap(Self.init(rawValue:)) ?? fallback
        localFile = file
    }

    static var current: AppLanguage {
        if localFile != nil { return localLanguage }
        return UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .simplifiedChinese
    }

    @MainActor static func set(_ language: AppLanguage) {
        guard language != current else { return }
        if let localFile {
            do { try language.rawValue.write(to: localFile, atomically: true, encoding: .utf8) }
            catch { return }
            localLanguage = language
        } else {
            UserDefaults.standard.set(language.rawValue, forKey: preferenceKey)
        }
        NotificationCenter.default.post(name: .dualDockLanguageDidChange, object: nil)
    }
}

extension Notification.Name {
    static let dualDockLanguageDidChange = Notification.Name("DualDock.displayLanguageDidChange")
}

func L(_ chinese: String, _ english: String) -> String {
    AppLanguage.current == .english ? english : chinese
}

/// Persistent user-facing feedback resolves when its view draws, so changing
/// the app language also updates messages already on screen.
struct LocalizedNotice: Equatable, Sendable {
    let chinese: String
    let english: String

    init(_ chinese: String, _ english: String) {
        self.chinese = chinese
        self.english = english
    }

    init(verbatim value: String) { self.init(value, value) }

    var text: String { L(chinese, english) }

    func appending(_ detail: LocalizedNotice, separator: String = " · ") -> LocalizedNotice {
        .init(chinese + separator + detail.chinese, english + separator + detail.english)
    }
}
