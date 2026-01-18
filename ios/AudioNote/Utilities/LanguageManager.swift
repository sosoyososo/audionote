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
        }
    }

    @Published var showLanguageChangedToast = false

    static let shared = LanguageManager()

    func apply(_ language: AppLanguage) {
        guard language != current else { return }

        current = language

        // Trigger view refresh
        showLanguageChangedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showLanguageChangedToast = false
            NotificationCenter.default.post(name: .languageChanged, object: nil)
        }
    }

    func dismissToast() {
        showLanguageChangedToast = false
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
