import SwiftUI
import UIKit

struct OnboardingView: View {
    @ObservedObject private var storage = StorageCoordinator.shared
    @State private var isPickerPresented = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("存储位置设置")
                .font(.title2.weight(.semibold))

            Text("请选择一个文件夹用于保存录音转写数据。卸载 App 后数据仍会保留,并可通过“文件”App 查看。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button {
                isPickerPresented = true
            } label: {
                Text("选择存储位置")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)

            if let err = storage.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .sheet(isPresented: $isPickerPresented) {
            FolderPickerSheet { url in
                Task { await storage.acceptPickerResult(url: url) }
            }
        }
    }
}

/// SwiftUI wrapper for UIDocumentPickerViewController folder mode.
struct FolderPickerSheet: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) { self.onPicked = onPicked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPicked(url)
        }
    }
}
