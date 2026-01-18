import Foundation

enum RecognitionLanguage: String, CaseIterable, Identifiable, Codable {
    case chinese = "zh-CN"
    case english = "en-US"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    var icon: String {
        switch self {
        case .chinese: return "character.textbox"
        case .english: return "textformat.abc"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    static var defaultLanguage: RecognitionLanguage {
        .chinese
    }

    static var sortedCases: [RecognitionLanguage] {
        // Chinese first, then English
        allCases.sorted { $0.displayName < $1.displayName }
    }
}
