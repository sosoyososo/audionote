import SwiftUI
import UIKit

struct OnboardingView: View {
    @ObservedObject private var storage = StorageCoordinator.shared
    @State private var isPickerPresented = false
    @State private var isApplyingPick = false

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
                if isApplyingPick {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("正在保存…").font(.headline)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor.opacity(0.7))
                    .cornerRadius(12)
                } else {
                    Text("选择存储位置")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .cornerRadius(12)
                }
            }
            .disabled(isApplyingPick)
            .padding(.horizontal, 40)

            if isApplyingPick {
                Text("首次保存该目录的书签,请稍候…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let err = storage.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .sheet(isPresented: $isPickerPresented) {
            FolderPickerSheet { url in
                isPickerPresented = false
                // acceptPickerResult is now sync from the caller's POV:
                // it sets isReady immediately (UI swap is instant), then
                // persists the bookmark in the background. We just need
                // to drop the loading flag once the SwiftUI re-render
                // catches up — a tiny delay keeps the spinner from
                // flashing off-then-on as the swap happens.
                DispatchQueue.main.async {
                    storage.acceptPickerResult(url: url)
                    isApplyingPick = false
                }
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
