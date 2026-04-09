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
                        Text("启用录音内容优化")
                        Spacer()
                        if viewModel.isValidating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Toggle("", isOn: $viewModel.enableLLMOptimization)
                                .labelsHidden()
                                .disabled(!viewModel.hasToken)
                                .onChange(of: viewModel.enableLLMOptimization) { newValue in
                                    if newValue && !viewModel.isValidating {
                                        viewModel.validateLLMConfiguration()
                                    } else if !newValue {
                                        viewModel.saveOptimizationSetting()
                                    }
                                }
                        }
                    }

                    if !viewModel.hasToken {
                        Text("请先配置 API Token")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("LLM 优化设置")
                } footer: {
                    Text("开启后，录音结束后自动优化转录文本，修正标点和同音词错误")
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
                } else if viewModel.showValidationResult, let message = viewModel.validationMessage {
                    ToastView(message: message, isShowing: $viewModel.showValidationResult)
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
