import SwiftUI

/// Settings tab. The LLM section is now a list of user-managed
/// `LLMProviderProfile`s, each editable in `ProfileDetailView`. The legacy
/// single-token form is gone — see
/// `docs/superpowers/specs/2026-09-24-multi-provider-llm-design.md`.
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @EnvironmentObject private var languageManager: LanguageManager
    @ObservedObject private var store = ProviderProfileStore.shared

    @State private var editingProfile: LLMProviderProfile? = nil
    @State private var isCreatingNew: Bool = false
    @State private var isPickerPresented: Bool = false

    var body: some View {
        NavigationView {
            Form {
                // MARK: Provider profiles
                Section {
                    if store.profiles.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.profiles) { profile in
                            profileRow(profile)
                        }
                        .onDelete(perform: deleteProfiles)
                    }
                    Button {
                        isCreatingNew = true
                    } label: {
                        Label("Settings.LLM.ProviderProfiles.Add".localized, systemImage: "plus.circle.fill")
                    }
                    if viewModel.isPinging {
                        HStack {
                            ProgressView().progressViewStyle(CircularProgressViewStyle())
                            Text("Settings.LLM.Profile.Test".localized)
                        }
                    } else {
                        Button("Settings.LLM.Profile.Test".localized) {
                            viewModel.testActiveConnection()
                        }
                        .disabled(viewModel.activeProfile == nil)
                    }
                } header: {
                    Text("Settings.LLM.ProviderProfiles.Title".localized)
                } footer: {
                    Text("Settings.LLM.ProviderProfiles.Footer".localized)
                }

                // MARK: Active profile status
                Section {
                    HStack {
                        Text("Settings.LLM.Status".localized)
                        Spacer()
                        if let active = viewModel.activeProfile {
                            Text("✅ " + active.effectiveDisplayName)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("⚠️ " + "Settings.LLM.Status.NotSet".localized)
                                .foregroundColor(.orange)
                        }
                    }
                }

                // MARK: Storage location
                Section {
                    Button {
                        isPickerPresented = true
                    } label: {
                        Label("Settings.Storage.Change".localized, systemImage: "folder")
                    }
                } header: {
                    Text("Settings.Storage.Title".localized)
                } footer: {
                    Text("Settings.Storage.Footer".localized)
                }
            }
            .navigationTitle("Tab.Settings".localized)
            .sheet(isPresented: $isPickerPresented) {
                FolderPickerSheet { url in
                    Task { await StorageCoordinator.shared.acceptPickerResult(url: url) }
                }
            }
            .sheet(isPresented: $isCreatingNew) {
                ProfileDetailView(mode: .create)
            }
            .sheet(item: $editingProfile) { profile in
                ProfileDetailView(mode: .edit(profile))
            }
            .overlay(alignment: .bottom) {
                if let toast = viewModel.migrationToast {
                    ToastView(message: toast, isShowing: Binding(
                        get: { viewModel.migrationToast != nil },
                        set: { newValue in if !newValue { viewModel.migrationToast = nil } }
                    ))
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let result = viewModel.pingResult {
                    ToastView(
                        message: pingMessage(for: result),
                        isShowing: Binding(
                            get: { viewModel.pingResult != nil },
                            set: { newValue in if !newValue { viewModel.pingResult = nil } }
                        )
                    )
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Row UI

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings.LLM.ProviderProfiles.NoneActive".localized)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func profileRow(_ profile: LLMProviderProfile) -> some View {
        Button {
            editingProfile = profile
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: profile.id == store.activeProfileId ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(profile.id == store.activeProfileId ? .accentColor : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.effectiveDisplayName)
                        .font(.body)
                        .foregroundColor(.primary)
                    Text(profile.baseURL.absoluteString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("model: \(profile.model)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if profile.id != store.activeProfileId {
                    Button("Settings.LLM.Profile.SetActive".localized) {
                        viewModel.setActive(profile.id)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func deleteProfiles(at offsets: IndexSet) {
        for idx in offsets {
            viewModel.delete(store.profiles[idx].id)
        }
    }

    private func pingMessage(for result: SettingsViewModel.PingResult) -> String {
        switch result {
        case .success:
            return "Settings.LLM.Test.Success".localized
        case .failure(let reason):
            return String(format: "Settings.LLM.Test.Fail".localized, reason)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(LanguageManager.shared)
}
