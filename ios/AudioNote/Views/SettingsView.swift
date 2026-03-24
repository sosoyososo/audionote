import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @EnvironmentObject private var languageManager: LanguageManager

    var body: some View {
        NavigationView {
            Form {
                Section {
                    SecureField("LLM API Token", text: $viewModel.llmToken)
                        .textContentType(.password)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    Button("Action.Save".localized) {
                        viewModel.saveToken()
                    }
                    .disabled(viewModel.llmToken.isEmpty)
                } header: {
                    Text("Settings.LLM.Title")
                } footer: {
                    Text("Settings.LLM.Footer")
                }

                Section {
                    HStack {
                        Text("Settings.LLM.Status")
                        Spacer()
                        if viewModel.hasToken {
                            Text("✅ Configured")
                                .foregroundColor(.secondary)
                        } else {
                            Text("⚠️ Not Set")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Tab.Settings".localized)
            .overlay(alignment: .bottom) {
                if viewModel.showSaveConfirmation {
                    ToastView(message: "Settings.Saved".localized, isShowing: $viewModel.showSaveConfirmation)
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(LanguageManager.shared)
}
