import Foundation

enum AppLanguage: String, CaseIterable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let preferenceKey = "DualDockDisplayLanguage"

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .simplifiedChinese
    }

    @MainActor static func set(_ language: AppLanguage) {
        guard language != current else { return }
        UserDefaults.standard.set(language.rawValue, forKey: preferenceKey)
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
