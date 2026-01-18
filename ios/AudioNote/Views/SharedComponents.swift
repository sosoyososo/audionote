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
        toastMessage = "已复制到剪贴板"
        withAnimation {
            showCopiedToast = true
        }
    }

    public func showSaveConfirmation() {
        toastMessage = "保存成功"
        withAnimation {
            showSaveSuccess = true
        }
    }
}
