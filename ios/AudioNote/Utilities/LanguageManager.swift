import Foundation
import SwiftUI

// MARK: - Notification

extension Notification.Name {
    static let languageChanged = Notification.Name("audioNote.languageChanged")
}

// MARK: - App Language

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .system: return "gear"
        case .chinese: return "character.cursor.ibeam"
        case .english: return "abc"
        }
    }

    var locale: Locale? {
        switch self {
        case .system: return nil
        case .chinese: return Locale(identifier: "zh-Hans")
        case .english: return Locale(identifier: "en")
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .system: return nil
        case .chinese: return "zh-Hans.lproj"
        case .english: return "en.lproj"
        }
    }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .chinese: return "中文简体"
        case .english: return "English"
        }
    }

    var displayNameEN: String {
        switch self {
        case .system: return "Follow System"
        case .chinese: return "Chinese"
        case .english: return "English"
        }
    }

    /// 获取实际使用的语言（处理 system 情况）
    /// 当系统语言非中文或英文时，默认返回英文
    func effectiveLanguage() -> AppLanguage {
        switch self {
        case .system:
            return AppLanguage.detectSystemLanguage()
        case .chinese, .english:
            return self
        }
    }

    /// 检测系统首选语言，返回中文或英文
    private static func detectSystemLanguage() -> AppLanguage {
        guard let preferredLanguage = Locale.preferredLanguages.first?.lowercased() else {
            return .english
        }

        if preferredLanguage.hasPrefix("zh") {
            return .chinese
        } else if preferredLanguage.hasPrefix("en") {
            return .english
        } else {
            return .english // 非中英文默认英文
        }
    }

    static var savedLanguage: AppLanguage {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: "audioNote:language"),
               let language = AppLanguage(rawValue: rawValue) {
                return language
            }
            return .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "audioNote:language")
        }
    }
}

@MainActor
final class LanguageManager: ObservableObject {
    @Published var current: AppLanguage = .savedLanguage {
        didSet {
            AppLanguage.savedLanguage = current
            // 发送通知触发视图刷新
            NotificationCenter.default.post(name: .languageChanged, object: nil)
        }
    }

    static let shared = LanguageManager()

    /// 切换到指定语言，立即生效，无提示
    func change(to language: AppLanguage) {
        guard language != current else { return }
        current = language
    }

    /// 获取当前实际使用的语言（处理 system 情况）
    func getEffectiveLanguage() -> AppLanguage {
        return current.effectiveLanguage()
    }
}

// MARK: - Custom Localization

extension String {
    func localized(for language: AppLanguage) -> String {
        guard let bundlePath = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: bundlePath) else {
            return NSLocalizedString(self, comment: "")
        }
        return bundle.localizedString(forKey: self, value: nil, table: nil)
    }
}

// MARK: - Localized Text View

struct LocalizedText: View {
    let key: String
    @EnvironmentObject private var languageManager: LanguageManager

    var body: some View {
        Text(key.localized(for: languageManager.current))
    }
}

// Helper for String context - use saved language directly to avoid actor isolation issues
extension String {
    var localized: String {
        let language = AppLanguage.savedLanguage
        guard let bundlePath = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: bundlePath) else {
            return NSLocalizedString(self, comment: "")
        }
        return bundle.localizedString(forKey: self, value: nil, table: nil)
    }
}
