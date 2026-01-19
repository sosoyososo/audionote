import SwiftUI

struct LanguageSelectorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var languageManager: LanguageManager
    let onLanguageSelected: ((AppLanguage) -> Void)?

    init(onLanguageSelected: ((AppLanguage) -> Void)? = nil) {
        self.onLanguageSelected = onLanguageSelected
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Language.Selector.Title".localized)
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            .padding()

            Divider()

            // Language options
            ForEach(AppLanguage.allCases) { language in
                Button {
                    selectLanguage(language)
                } label: {
                    HStack {
                        Text(language.displayName)
                            .foregroundColor(.primary)
                        Spacer()
                        if language == languageManager.current {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 14)
                }
            }
        }
        .background(Color(.systemBackground))
    }

    private func selectLanguage(_ language: AppLanguage) {
        languageManager.change(to: language)
        onLanguageSelected?(language)
        dismiss()
    }
}

#Preview {
    LanguageSelectorView()
        .environmentObject(LanguageManager.shared)
}
