import Foundation
import SwiftUI

enum StorageBookmarkKey {
    static let rootBookmark = "audioNote:storage:audioNoteFolderBookmark"
    /// Fallback for when bookmark creation fails (e.g., the user picked a
    /// folder with thousands of files and `bookmarkData()` ran past iOS's
    /// picker-grant window). Stores the URL's path string as a last-resort
    /// hint — works only if the folder still exists at the same path AND
    /// the app wasn't reinstalled (system access grant is gone). Beats
    /// showing OnboardingView again with no saved location.
    static let rootPathFallback = "audioNote:storage:audioNoteFolderPathFallback"
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

    /// Apply a URL already resolved synchronously (called from
    /// `AudioNoteApp.init()` after `resolveSync()`). Sets state without
    /// any further UserDefaults reads or file system checks.
    @MainActor
    func setReady(url: URL) {
        resolvedRoot = url
        didStartAccess = true
        errorMessage = nil
        isReady = true
    }

    /// Synchronous bookmark resolution. Has no `await` inside `bootstrap()`,
    /// so we expose this path for `init()`-time calls (eliminates the
    /// OnboardingView flash on subsequent launches). Tries the bookmark
    /// first; if missing/invalid, falls back to a path-string hint. If
    /// both fail, returns `nil` and clears both UserDefaults entries.
    @MainActor
    func resolveSync() -> URL? {
        // 1. Bookmark path
        if let url = resolveBookmarkSync() { return url }

        // 2. Path-string fallback (last-resort hint when bookmark creation
        //    timed out during a previous session)
        if let url = resolvePathFallbackSync() { return url }

        return nil
    }

    private func resolveBookmarkSync() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: StorageBookmarkKey.rootBookmark) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            UserDefaults.standard.removeObject(forKey: StorageBookmarkKey.rootBookmark)
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            UserDefaults.standard.removeObject(forKey: StorageBookmarkKey.rootBookmark)
            return nil
        }
        if isStale {
            if let fresh = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(fresh, forKey: StorageBookmarkKey.rootBookmark)
            }
        }
        return url
    }

    private func resolvePathFallbackSync() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: StorageBookmarkKey.rootPathFallback) else {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else {
            UserDefaults.standard.removeObject(forKey: StorageBookmarkKey.rootPathFallback)
            return nil
        }
        // Note: we don't try to upgrade this to a bookmark here — the
        // system picker grant is gone. The folder works for this session
        // but won't survive an uninstall until the user re-picks via the
        // "更换存储位置" entry in Settings (which re-triggers the grant).
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Resolves stored bookmark, acquires security-scoped resource, sets `isReady`.
    /// If no bookmark, bookmark stale, or the URL no longer points at a directory,
    /// leaves `isReady = false` (so `OnboardingView` is shown again).
    func bootstrap() async {
        if let url = resolveSync() {
            resolvedRoot = url
            didStartAccess = true
            errorMessage = nil
            isReady = true
        } else {
            isReady = false
        }
    }

    /// Persist the URL returned by UIDocumentPickerViewController. Two-phase:
    ///
    /// 1. **Synchronously** swap the UI to the main UI by setting `isReady`
    ///    — the URL is accessible for the current session and the user
    ///    expects the app to react immediately. This is the main UX win:
    ///    the picker URL works without a bookmark as long as the app
    ///    hasn't been reinstalled.
    ///
    /// 2. **Asynchronously** create the bookmark + save it to UserDefaults
    ///    in the background. `url.bookmarkData()` enumerates the folder
    ///    contents to make the bookmark stable across launches; for
    ///    directories with thousands of files, that takes seconds and
    ///    would block the main thread if done inline. If bookmark
    ///    creation fails (e.g., the system picker-grant window expired
    ///    before we could read), fall back to a path-string UserDefaults
    ///    entry so we at least know the user's last intent.
    func acceptPickerResult(url: URL) {
        // Phase 1 — sync UI swap.
        resolvedRoot = url
        didStartAccess = true
        errorMessage = nil
        isReady = true

        // Phase 2 — background persistence.
        Task.detached(priority: .utility) {
            do {
                let data = try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(data, forKey: StorageBookmarkKey.rootBookmark)
                // Clear any stale path fallback — bookmark succeeded.
                UserDefaults.standard.removeObject(forKey: StorageBookmarkKey.rootPathFallback)
            } catch {
                // Bookmark failed — save the path string as last-resort.
                UserDefaults.standard.set(url.path, forKey: StorageBookmarkKey.rootPathFallback)
            }
        }
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