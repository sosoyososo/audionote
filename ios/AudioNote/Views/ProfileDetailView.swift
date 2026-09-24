import SwiftUI

/// Add/edit sheet for a single `LLMProviderProfile`. Owns its own
/// `@State` so the parent store doesn't get churned on every keystroke;
/// `save` is what actually writes to the store + Keychain.
struct ProfileDetailView: View {
    enum Mode {
        case create
        case edit(LLMProviderProfile)
    }

    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var displayName: String = ""
    @State private var baseURLString: String = ""
    @State private var model: String = ""
    @State private var requiresAPIKey: Bool = true
    @State private var apiKey: String = ""
    @State private var validationError: String? = nil
    @State private var isTesting: Bool = false
    @State private var testResult: TestResult? = nil

    enum TestResult: Equatable {
        case success
        case failure(String)
    }

    private let store: ProviderProfileStore
    private let llmService = LLMService()

    init(mode: Mode, store: ProviderProfileStore = .shared) {
        self.mode = mode
        self.store = store
        if case .edit(let profile) = mode {
            _displayName = State(initialValue: profile.displayName)
            _baseURLString = State(initialValue: profile.baseURL.absoluteString)
            _model = State(initialValue: profile.model)
            _requiresAPIKey = State(initialValue: profile.requiresAPIKey)
            // API key never comes back from disk — leave empty. Saving a
            // non-empty value replaces the Keychain entry; saving empty
            // leaves the existing key untouched.
            _apiKey = State(initialValue: "")
        }
    }

    private var existingId: UUID? {
        if case .edit(let profile) = mode { return profile.id }
        return nil
    }

    private var canSave: Bool {
        !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (requiresAPIKey ? !apiKey.isEmpty || existingId != nil : true)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Settings.LLM.Profile.DisplayName".localized, text: $displayName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }

                Section {
                    TextField("https://api.openai.com/v1/chat/completions", text: $baseURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                    TextField("Settings.LLM.Profile.Model".localized, text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("Settings.LLM.Profile.Provider".localized)
                } footer: {
                    Text("Settings.LLM.Profile.BaseURL.Hint".localized)
                }

                Section {
                    Toggle("Settings.LLM.Profile.RequiresAPIKey".localized, isOn: $requiresAPIKey)
                    if requiresAPIKey {
                        SecureField("Settings.LLM.Profile.APIKey".localized, text: $apiKey)
                            .textContentType(.password)
                    }
                } header: {
                    Text("Settings.LLM.Profile.Auth".localized)
                } footer: {
                    Text("Settings.LLM.Profile.Auth.Footer".localized)
                }

                Section {
                    Button(action: testConnection) {
                        HStack {
                            if isTesting {
                                ProgressView().padding(.trailing, 4)
                            }
                            Text("Settings.LLM.Profile.Test".localized)
                        }
                    }
                    .disabled(!canSave || isTesting)
                    if let result = testResult {
                        switch result {
                        case .success:
                            Label("Settings.LLM.Test.Success".localized, systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        case .failure(let reason):
                            Label(String(format: "Settings.LLM.Test.Fail".localized, reason),
                                  systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                }

                if let validationError {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Settings.LLM.Profile.Cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Settings.LLM.Profile.Save".localized) { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .create: return "Settings.LLM.Profile.New".localized
        case .edit:   return "Settings.LLM.Profile.Edit".localized
        }
    }

    // MARK: - Actions

    private func save() {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            validationError = "Settings.LLM.Profile.Error.InvalidURL".localized
            return
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = LLMProviderProfile(
            id: existingId ?? UUID(),
            displayName: trimmedName,
            baseURL: url,
            model: trimmedModel,
            requiresAPIKey: requiresAPIKey,
            createdAt: existingId.flatMap { id in store.profiles.first(where: { $0.id == id })?.createdAt } ?? Date()
        )
        if let err = profile.validate() {
            validationError = err
            return
        }
        let keyToWrite: String? = requiresAPIKey && !apiKey.isEmpty ? apiKey : nil
        do {
            try store.upsert(profile, apiKey: keyToWrite)
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func testConnection() {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            validationError = "Settings.LLM.Profile.Error.InvalidURL".localized
            return
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = LLMProviderProfile(
            id: existingId ?? UUID(),
            displayName: displayName,
            baseURL: url,
            model: trimmedModel,
            requiresAPIKey: requiresAPIKey
        )
        if let err = profile.validate() {
            validationError = err
            return
        }
        let keyForTest: String?
        if requiresAPIKey {
            // Prefer the field's current value; fall back to whatever is
            // already stored under this profile's id.
            keyForTest = apiKey.isEmpty
                ? (existingId.flatMap { store.apiKey(for: $0) })
                : apiKey
        } else {
            keyForTest = nil
        }

        isTesting = true
        testResult = nil
        Task {
            do {
                try await llmService.ping(profile: profile, apiKey: keyForTest)
                await MainActor.run {
                    self.isTesting = false
                    self.testResult = .success
                }
            } catch let error as LLMError {
                await MainActor.run {
                    self.isTesting = false
                    self.testResult = .failure(error.errorDescription ?? "Unknown error")
                }
            } catch {
                await MainActor.run {
                    self.isTesting = false
                    self.testResult = .failure(error.localizedDescription)
                }
            }
        }
    }
}
