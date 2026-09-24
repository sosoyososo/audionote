import SwiftUI

// MARK: - Share Sheet

public struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Toast View

public struct ToastView: View {
    let message: String
    @Binding public var isShowing: Bool

    public init(message: String, isShowing: Binding<Bool>) {
        self.message = message
        self._isShowing = isShowing
    }

    public var body: some View {
        if isShowing {
            Text(message)
                .font(.caption.weight(.medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.8))
                .cornerRadius(20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation {
                            isShowing = false
                        }
                    }
                }
        }
    }
}

// MARK: - Record Actions View Model

@MainActor
public final class RecordActionsViewModel: ObservableObject {
    @Published public var showShareSheet = false
    @Published public var showCopiedToast = false
    @Published public var showSaveSuccess = false
    @Published public var toastMessage = ""

    public init() {}

    public func copyText(_ text: String) {
        UIPasteboard.general.string = text
        toastMessage = "Toast.Copied".localized
        withAnimation {
            showCopiedToast = true
        }
    }

    public func showSaveConfirmation() {
        toastMessage = "Toast.Saved".localized
        withAnimation {
            showSaveSuccess = true
        }
    }
}

// MARK: - Recognition Mode Style
//
// Extracted from `RecordingView.modeColor/Label` and
// `TranscriptionDetailView.recognitionModeColor/Icon/Label`, which were
// duplicate maps for the same RecognitionMode. See
// `design-system/components/recognition-mode-badge.md`.
//
// Status: `inferred` (auto-promoted from duplicated code). User review
// pending — supersede by adding a `design-system/decisions/` record.

struct RecognitionModeStyle {
    let mode: RecognitionMode

    var color: Color {
        switch mode {
        case .online: return .green
        case .onDevice: return .yellow
        case .enhanced: return .blue
        case .failed: return .red
        }
    }

    var icon: String {
        switch mode {
        case .online: return "cloud.fill"
        case .onDevice: return "iphone.gen1"
        case .enhanced: return "cloud.fill.badge.checkmark"
        case .failed: return "xmark.shield.fill"
        }
    }

    var label: String {
        switch mode {
        case .online: return "在线识别"
        case .onDevice: return "离线识别"
        case .enhanced: return "已在线升级"
        case .failed: return "识别失败"
        }
    }
}

/// Compact pill (used in RecordingView header strip). One source of truth
/// for icon + colour + label — drops the previous inline copy in
/// `RecordingView.swift:296-302`.
struct ModeBadge: View {
    let mode: RecognitionMode

    var body: some View {
        let style = RecognitionModeStyle(mode: mode)
        HStack(spacing: 4) {
            Image(systemName: style.icon)
            Text(style.label)
        }
        .font(.caption2)
        .foregroundColor(style.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(style.color.opacity(0.1))
        .cornerRadius(4)
    }
}

// MARK: - Text Card Style
//
// Reusable modifier for the gray6-bg + rounded-corner container that
// appears 7× in `RecordingView` and 1× in `TranscriptionDetailView`.
// See `design-system/components/text-card.md`.

extension View {
    /// Apply the canonical gray6 background + rounded-corner container
    /// used for the recording screen's text cards.
    /// - Parameter radius: corner radius. Default `12` matches the dominant
    ///   recording-screen pattern; pass `8` for the detail-page edit card.
    func textCard(radius: CGFloat = 12) -> some View {
        self
            .background(Color(.systemGray6))
            .cornerRadius(radius)
    }
}

// MARK: - Empty State
//
// Used by `LibraryListView` (3 sites: empty, no-results, archived-empty)
// and reusable for any future screen that needs an empty / no-results
// placeholder. See `design-system/components/empty-state.md`.

struct EmptyState: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Playback Control Bar

struct PlaybackControlBar: View {
    @ObservedObject var playerManager = AudioPlayerManager.shared
    let audioFileName: String

    private var formattedCurrentTime: String {
        formatTime(playerManager.currentTime)
    }

    private var formattedDuration: String {
        formatTime(playerManager.duration)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        HStack(spacing: 16) {
            Button {
                playerManager.togglePlayPause(fileName: audioFileName)
            } label: {
                Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
            }

            Slider(value: Binding(
                get: { playerManager.progress },
                set: { playerManager.seek(to: $0) }
            ))
            .tint(.accentColor)

            Text("\(formattedCurrentTime)/\(formattedDuration)")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}
