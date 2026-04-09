import Foundation
import Combine

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var llmToken: String = ""
    @Published var showSaveConfirmation: Bool = false
    @Published var enableLLMOptimization: Bool = false
    @Published var isValidating: Bool = false
    @Published var validationMessage: String?
    @Published var showValidationResult: Bool = false

    private let tokenKey = "audioNote:llmToken"
    private let optimizationKey = "audioNote:enableLLMOptimization"
    private let llmService = LLMService()

    init() {
        loadToken()
        loadOptimizationSetting()
    }

    func loadToken() {
        llmToken = UserDefaults.standard.string(forKey: tokenKey) ?? ""
    }

    func loadOptimizationSetting() {
        enableLLMOptimization = UserDefaults.standard.bool(forKey: optimizationKey)
    }

    func saveToken() {
        UserDefaults.standard.set(llmToken, forKey: tokenKey)
        showSaveConfirmation = true
    }

    func saveOptimizationSetting() {
        UserDefaults.standard.set(enableLLMOptimization, forKey: optimizationKey)
    }

    var hasToken: Bool {
        !llmToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func validateLLMConfiguration() {
        guard hasToken else {
            validationMessage = "请先配置 API Token"
            showValidationResult = true
            return
        }

        isValidating = true
        validationMessage = nil

        Task {
            do {
                let testText = "你好，这是一个测试。"
                _ = try await llmService.optimize(testText, token: llmToken)
                await MainActor.run {
                    self.isValidating = false
                    self.validationMessage = "验证成功！LLM 已可用"
                    self.showValidationResult = true
                    self.enableLLMOptimization = true
                    self.saveOptimizationSetting()
                }
            } catch {
                await MainActor.run {
                    self.isValidating = false
                    self.validationMessage = "验证失败: \(error.localizedDescription)"
                    self.showValidationResult = true
                    self.enableLLMOptimization = false
                }
            }
        }
    }
}
