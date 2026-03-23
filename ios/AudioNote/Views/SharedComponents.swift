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
