import SwiftUI

struct RecordingView: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    @EnvironmentObject private var languageManager: LanguageManager
    @State private var showPermissionAlert = false
    @State private var showLanguageSelector = false
    @State private var editedText = ""
    @State private var isEditing = false
    @State private var showCopiedToast = false
    @State private var showShareSheet = false
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        NavigationView {
            ZStack {
                // Main content
                VStack(spacing: 0) {
                    // Header with language selector
                    headerSection
                        .padding(.horizontal)
                        .padding(.top, 16)

                    Spacer()

                    // Recording controls - center of screen
                    recordingControlSection

                    Spacer()

                    // Text display/edit area
                    textSection
                        .padding(.horizontal)
                        .padding(.bottom, 20)
                }

                // Permission overlay
                if viewModel.authorizationStatus == .denied ||
                   viewModel.authorizationStatus == .restricted {
                    permissionOverlay
                }
            }
            .overlay(alignment: .top) {
                toastOverlay
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: [viewModel.transcribedText])
            }
            .sheet(isPresented: $showLanguageSelector) {
                if #available(iOS 16.0, *) {
                    LanguageSelectorView()
                        .environmentObject(languageManager)
                        .presentationDetents([.height(220)])
                        .presentationDragIndicator(.visible)
                } else {
                    LanguageSelectorView()
                        .environmentObject(languageManager)
                        .frame(maxHeight: 220)
                }
            }
            .alert("Permission.Title".localized, isPresented: $showPermissionAlert) {
                Button("Permission.Settings".localized) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Action.Cancel".localized, role: .cancel) {}
            } message: {
                Text("Permission.Message".localized)
            }
            .onAppear {
                viewModel.updateAuthorizationStatus()
            }
            .onChange(of: viewModel.authorizationStatus) { newStatus in
                if newStatus == .denied || newStatus == .restricted {
                    showPermissionAlert = true
                }
            }
            .onChange(of: viewModel.errorMessage) { _ in
                if viewModel.errorMessage != nil {
                    showPermissionAlert = true
                }
            }
            .navigationTitle("Recording.Title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing:
                Button {
                    showLanguageSelector = true
                } label: {
                    Image(systemName: "globe")
                        .foregroundColor(.accentColor)
                }
            )
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Language.Selection".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RecognitionLanguage.sortedCases) { language in
                        languageTag(for: language)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func languageTag(for language: RecognitionLanguage) -> some View {
        Button {
            guard !viewModel.isRecording else { return }
            viewModel.setLanguage(language)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: language.icon)
                    .font(.system(size: 12))
                Text(language.displayName)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(viewModel.selectedLanguage == language
                          ? Color.accentColor
                          : Color(.systemGray5))
            )
            .foregroundColor(viewModel.selectedLanguage == language
                             ? .white
                             : .primary)
        }
        .disabled(viewModel.isRecording)
        .opacity(viewModel.isRecording ? 0.5 : 1.0)
    }

    // MARK: - Recording Control Section

    private var recordingControlSection: some View {
        VStack(spacing: 20) {
            // Duration display
            if viewModel.isRecording {
                VStack(spacing: 4) {
                    Text(viewModel.formattedDuration)
                        .font(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundColor(.primary)
                        .id(viewModel.formattedDuration)

                    Text("Recording.Recording".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            // Main recording button
            Button {
                Task {
                    if viewModel.isRecording {
                        await viewModel.stopRecording()
                    } else {
                        await viewModel.startRecording()
                    }
                }
            } label: {
                ZStack {
                    // Outer ring
                    Circle()
                        .stroke(
                            viewModel.isRecording ? Color.red : Color.accentColor.opacity(0.3),
                            lineWidth: 4
                        )
                        .frame(width: 100, height: 100)

                    // Pulsing animation when recording
                    if viewModel.isRecording {
                        Circle()
                            .fill(Color.red.opacity(0.1))
                            .frame(width: 100, height: 100)
                            .modifier(PulsingModifier(isAnimating: viewModel.isRecording))
                    }

                    // Inner circle
                    Circle()
                        .fill(viewModel.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 80, height: 80)
                        .shadow(color: (viewModel.isRecording ? Color.red : Color.accentColor).opacity(0.4), radius: 10, x: 0, y: 4)

                    // Icon
                    Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 100, height: 100)
            .disabled(viewModel.authorizationStatus == .denied || viewModel.authorizationStatus == .restricted)

            // Status text when not recording
            if !viewModel.isRecording && viewModel.transcribedText.isEmpty {
                Text("Recording.TapToStart".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Permission denied hint
            if viewModel.authorizationStatus == .denied || viewModel.authorizationStatus == .restricted {
                Text("Recording.PermissionDeniedHint".localized)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - Text Section

    private var textSection: some View {
        VStack(spacing: 12) {
            // Text area header
            HStack {
                if isEditing {
                    Button("Action.Cancel".localized) {
                        cancelEditing()
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                    Spacer()

                    Button("Action.Save".localized) {
                        saveEditedText()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.accentColor)
                } else if viewModel.isRecording {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                        Text("Recording.RealTime".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    Text("Recording.Result".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()

                    if !viewModel.transcribedText.isEmpty {
                        HStack(spacing: 16) {
                            Button {
                                copyText()
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.subheadline)
                            }

                            Button {
                                showShareSheet = true
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.subheadline)
                            }

                            Button {
                                enterEditingMode()
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.subheadline)
                            }
                        }
                        .foregroundColor(.accentColor)
                    }
                }
            }

            // Text content
            Group {
                if viewModel.isRecording {
                    // Live partial text
                    recordingTextView
                } else if isEditing {
                    // Editable text editor
                    editingTextView
                } else {
                    // Final transcribed text
                    resultTextView
                }
            }
            .frame(minHeight: 120, maxHeight: 250)
        }
    }

    private var recordingTextView: some View {
        Group {
            if !viewModel.partialText.isEmpty {
                ScrollView {
                    Text(viewModel.partialText)
                        .font(.body)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(Color(.systemGray6))
                .cornerRadius(12)
            } else {
                VStack {
                    ProgressView()
                        .padding()
                    Text("Recording.Speaking".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.bottom)
                }
                .frame(maxWidth: .infinity)
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
        }
    }

    private var editingTextView: some View {
        TextEditor(text: $editedText)
            .font(.body)
            .focused($isEditorFocused)
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .onAppear {
                isEditorFocused = true
            }
    }

    private var resultTextView: some View {
        Group {
            if !viewModel.transcribedText.isEmpty {
                ScrollView {
                    Text(viewModel.transcribedText)
                        .font(.body)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(Color(.systemGray6))
                .cornerRadius(12)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.badge.xmark")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Recording.NoResult".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: 120)
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Overlays

    private var toastOverlay: some View {
        VStack {
            if showCopiedToast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Toast.Copied".localized)
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.8))
                .cornerRadius(20)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, 60)
        .animation(.easeInOut(duration: 0.2), value: showCopiedToast)
    }

    private var permissionOverlay: some View {
        Color(.systemBackground)
            .opacity(0.9)
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 20) {
                    Image(systemName: "mic.slash.circle")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)

                    Text("Permission.MicRequired".localized)
                        .font(.title2.weight(.semibold))

                    Text("Permission.MicMessage".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("Permission.Settings".localized)
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 40)
                }
            }
    }

    // MARK: - Actions

    private func enterEditingMode() {
        editedText = viewModel.transcribedText
        isEditing = true
    }

    private func cancelEditing() {
        editedText = viewModel.transcribedText
        isEditing = false
        isEditorFocused = false
    }

    private func saveEditedText() {
        let recordId = viewModel.currentRecordId
        let updatedRecord = TranscriptionRecord(
            id: recordId ?? UUID(),
            content: editedText,
            createdAt: Date(),
            duration: viewModel.recordingDuration,
            language: viewModel.selectedLanguage.rawValue
        )

        Task {
            do {
                try await viewModel.updateRecord(updatedRecord)
                await MainActor.run {
                    viewModel.transcribedText = editedText
                    isEditing = false
                    isEditorFocused = false
                    showCopiedToast = true
                    autoHideToast()
                }
            } catch {
                Logger.error("Failed to save: \(error.localizedDescription)")
            }
        }
    }

    private func copyText() {
        UIPasteboard.general.string = viewModel.transcribedText
        showCopiedToast = true
        autoHideToast()
    }

    private func autoHideToast() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopiedToast = false
        }
    }
}

// MARK: - Pulsing Modifier

struct PulsingModifier: ViewModifier {
    let isAnimating: Bool
    @State private var pulseScale: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(pulseScale)
            .animation(
                Animation.easeInOut(duration: 1.0)
                    .repeatForever(autoreverses: true),
                value: isAnimating
            )
            .onAppear {
                if isAnimating {
                    pulseScale = 1.2
                }
            }
            .onChange(of: isAnimating) { newValue in
                if newValue {
                    pulseScale = 1.2
                } else {
                    pulseScale = 1.0
                }
            }
    }
}

#Preview {
    NavigationView {
        RecordingView(viewModel: TranscriptionViewModel())
    }
}
