import Foundation
import SwiftUI

enum StorageBookmarkKey {
    static let rootBookmark = "audioNote:storage:audioNoteFolderBookmark"
}

/// Owns the user-picked AudioNote folder URL + its security-scoped bookmark.
/// All file path resolution goes through this singleton.
@MainActor
final class StorageCoordinator: ObservableObject {
    static let shared = StorageCoordinator()

    @Published private(set) var isReady: Bool = false
    @Published private(set) var errorMessage: String? = nil

    /// Cached root URL. Writes only happen on @MainActor inside `bootstrap()`.
    /// Read-access from any actor via `nonisolated` getters below.
    private nonisolated(unsafe) var resolvedRoot: URL?
    private var didStartAccess = false

    private init() {}

    // MARK: - Bootstrap

    /// Resolves stored bookmark, acquires security-scoped resource, sets `isReady`.
    /// If no bookmark, bookmark stale, or the URL no longer points at a directory,
    /// leaves `isReady = false` (so `OnboardingView` is shown again).
    func bootstrap() async {
        guard let data = UserDefaults.standard.data(forKey: StorageBookmarkKey.rootBookmark) else {
            isReady = false
            return
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            // Reject if URL doesn't exist or isn't a directory
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else {
                UserDefaults.standard.removeObject(forKey: StorageBookmarkKey.rootBookmark)
                isReady = false
                return
            }
            guard url.startAccessingSecurityScopedResource() else {
                isReady = false
                errorMessage = "无法访问存储位置,请重新选择"
                return
            }
            // If stale, refresh bookmark on next changeLocation call
            if isStale {
                // Best-effort refresh — re-create bookmark data and re-save
                if let fresh = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(fresh, forKey: StorageBookmarkKey.rootBookmark)
                }
            }
            resolvedRoot = url
            didStartAccess = true
            errorMessage = nil
            isReady = true
        } catch {
            UserDefaults.standard.removeObject(forKey: StorageBookmarkKey.rootBookmark)
            isReady = false
            errorMessage = "存储位置读取失败,请重新选择"
        }
    }

    /// Persist the URL returned by UIDocumentPickerViewController as the new
    /// root bookmark, then run `bootstrap()`.
    func acceptPickerResult(url: URL) async {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: StorageBookmarkKey.rootBookmark)
            await bootstrap()
        } catch {
            errorMessage = "无法保存存储位置"
        }
    }

    /// Trigger re-pick flow (placeholder; OnboardingView drives the actual picker UI).
    func changeLocation() async {
        // Filled in by OnboardingView task
    }

    // MARK: - URL helpers (nonisolated so any actor can read them cheaply)

    nonisolated var rootURL: URL {
        guard let url = resolvedRoot else { preconditionFailure("rootURL accessed before bootstrap") }
        return url
    }

    nonisolated func audioURL(for id: UUID) -> URL {
        rootURL
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).m4a")
    }

    nonisolated var jsonURL: URL {
        rootURL.appendingPathComponent("transcriptions.json")
    }

    // MARK: - Scene phase

    /// Release/re-acquire security-scoped resource based on scene phase.
    /// Call from SwiftUI `.onChange(of: scenePhase)`.
    func handleScenePhase(_ phase: ScenePhase) {
        guard let url = resolvedRoot else { return }
        switch phase {
        case .active:
            if !didStartAccess {
                _ = url.startAccessingSecurityScopedResource()
                didStartAccess = true
            }
        case .background, .inactive:
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
                didStartAccess = false
            }
        @unknown default:
            break
        }
    }
}