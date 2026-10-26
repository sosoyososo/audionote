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

/// The app's relationship to its own data directory.
///
/// Replaces the old `isReady` Bool. That Bool had to mean five different
/// things at once: "never configured", "configured but the folder is
/// gone", "configured but the bookmark no longer resolves", "the directory
/// is reachable", and — by way of `TranscriptionStorage` — "the records
/// file parses".
///
/// Only the first three belong here. Whether the records file *parses* is
/// the storage layer's question, answered by
/// `TranscriptionStorage.LoadOutcome`. The split matters because the two
/// halves land on different screens: the access half on OnboardingView,
/// the file half on the library list.
enum StorageState: Equatable {
    /// 从没选过文件夹 —— 或者 app 被卸载重装，凭证随 app 一起没了。
    case unconfigured
    /// 选过，但现在够不着。带原因：处置方式不一样。
    case unreachable(UnreachableReason)
    /// 目录可达，可以读写。
    case ready
}

/// Why a previously-configured directory can't be reached right now.
///
/// Every one of these used to collapse into a silent `isReady = false`
/// and a blank OnboardingView that never said why.
enum UnreachableReason: Equatable {
    /// The bookmark no longer resolves. The folder may well still exist —
    /// this only says we can no longer prove it.
    case bookmarkInvalid
    /// The folder is not where the bookmark says it is. It may have been
    /// moved, renamed, or deleted.
    case folderMissing
    /// The folder is there but the sandbox extension cannot be acquired.
    case accessDenied
    /// A bookmark from an older build that was never security-scoped.
    /// Re-picking produces a usable one.
    case notSecurityScoped

    /// User-facing explanation. Shown on OnboardingView, where the user
    /// has no other way to tell "you never set this up" from "your folder
    /// went missing".
    var message: String {
        switch self {
        case .bookmarkInvalid:
            return "Storage.Unreachable.BookmarkInvalid".localized
        case .folderMissing:
            return "Storage.Unreachable.FolderMissing".localized
        case .accessDenied:
            return "Storage.Unreachable.AccessDenied".localized
        case .notSecurityScoped:
            return "Storage.Unreachable.NotSecurityScoped".localized
        }
    }
}

/// Owns the user-picked AudioNote folder URL + its security-scoped bookmark.
/// All file path resolution goes through this singleton.
@MainActor
final class StorageCoordinator: ObservableObject {
    static let shared = StorageCoordinator()

    @Published private(set) var state: StorageState = .unconfigured
    @Published private(set) var errorMessage: String? = nil

    /// True when the data directory is reachable and writable.
    ///
    /// Computed from `state` so the two can never disagree. It stopped
    /// being a stored `@Published` property when `state` arrived: a
    /// computed property still drives view updates, because changing
    /// `state` fires `objectWillChange` and every observer of this object
    /// re-reads it.
    var isReady: Bool { state == .ready }

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
        // Remember the folder's name where it outlives the app, so a
        // reinstall can tell the user which folder to pick again.
        StorageFolderHint.remember(folderName: url.lastPathComponent)
        // Real security-scope acquisition. The previous version only set
        // `didStartAccess = true` without calling `startAccessingSecurityScopedResource`,
        // so AVAudioFile writes to the Files-app folder failed with OSError -54
        // ("unable to make sandbox extension") on real devices (sim doesn't enforce).
        // On picker URLs (non-security-scoped) this returns false — no-op.
        _ = url.startAccessingSecurityScopedResource()
        didStartAccess = true
        errorMessage = nil
        state = .ready
    }

    /// The outcome of trying to locate the data directory.
    ///
    /// Three cases, not two. "No credential" and "credential that doesn't
    /// work" are different user-facing situations: the first is a first
    /// run (or a fresh reinstall), the second is something that broke and
    /// the user may be able to fix.
    private enum Resolution {
        /// Found and reachable.
        case resolved(URL)
        /// No stored credential at all — never configured, or the app was
        /// uninstalled and reinstalled. The bookmark lives in UserDefaults,
        /// which dies with the app; the data does not, which is exactly why
        /// this case has to say "pick the same folder again".
        case notConfigured
        /// A credential exists but doesn't work. The reason travels with
        /// it so the UI can say what happened.
        case failed(UnreachableReason)
    }

    /// Synchronous bookmark resolution. Has no `await` inside `bootstrap()`,
    /// so we expose this path for `init()`-time calls (eliminates the
    /// OnboardingView flash on subsequent launches).
    @MainActor
    func resolveSync() -> URL? {
        if case .resolved(let url) = resolve() { return url }
        return nil
    }

    /// Try the bookmark first; if missing/invalid, fall back to a
    /// path-string hint.
    private func resolve() -> Resolution {
        switch resolveBookmarkSync() {
        case .resolved(let url):
            return .resolved(url)
        case .notConfigured:
            // No bookmark at all. A path-string fallback may still know
            // where the user's folder was.
            return resolvePathFallbackSync()
        case .failed(let reason):
            // A broken bookmark is not proof the folder is gone. The
            // path-string fallback is a weaker credential, but it is worth
            // a try before telling the user anything.
            switch resolvePathFallbackSync() {
            case .resolved(let url):
                return .resolved(url)
            case .notConfigured:
                return .failed(reason)
            case .failed(let fallbackReason):
                return .failed(fallbackReason)
            }
        }
    }

    private func resolveBookmarkSync() -> Resolution {
        guard let data = UserDefaults.standard.data(forKey: StorageBookmarkKey.rootBookmark) else {
            return .notConfigured
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            // Do NOT delete the bookmark. It is the only credential the
            // app has, and a resolution failure does not prove the folder
            // is unreachable — it only proves this bookmark no longer
            // resolves. Destroying it here turned a recoverable "can't
            // find the folder" into "the user has to re-pick from
            // scratch", and the re-pick is exactly the step people get
            // wrong (they pick a new empty folder and conclude their
            // data is gone). The user's next pick overwrites it anyway.
            Logger.warning("Bookmark did not resolve — keeping it, reporting .bookmarkInvalid")
            return .failed(.bookmarkInvalid)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            // Same reasoning as above: the folder may have been moved,
            // renamed, or merely be unavailable right now (an iCloud
            // Drive folder that hasn't downloaded yet). Keep the
            // bookmark — a security-scoped bookmark tracks the file, not
            // the path, so it can resolve again once the folder is back.
            Logger.warning("Bookmark target missing — keeping it, reporting .folderMissing")
            return .failed(.folderMissing)
        }
        // Probe: if this bookmark is NOT security-scoped (e.g. was created
        // by an older build that deferred bookmark creation past the picker
        // session, when the URL was no longer security-scoped), the
        // resolved URL won't admit `startAccessingSecurityScopedResource()`
        // and AVAudioFile writes will fail with OSError -54. Detect that
        // here and discard the stale bookmark so the user gets a clean
        // re-pick prompt (and the picker-session fix in acceptPickerResult
        // produces a usable bookmark this time).
        if !url.startAccessingSecurityScopedResource() {
            url.stopAccessingSecurityScopedResource()
            // Kept for the same reason: the user's next pick overwrites
            // it, and keeping it costs nothing.
            Logger.warning("Bookmark is not security-scoped — keeping it, reporting .notSecurityScoped")
            return .failed(.notSecurityScoped)
        }
        // We started access for the probe. Caller (bootstrap/setReady)
        // will startAccessing again — that call is idempotent per Apple
        // docs. Balance this probe with a stop.
        url.stopAccessingSecurityScopedResource()
        if isStale {
            if let fresh = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(fresh, forKey: StorageBookmarkKey.rootBookmark)
            }
        }
        return .resolved(url)
    }

    private func resolvePathFallbackSync() -> Resolution {
        guard let path = UserDefaults.standard.string(forKey: StorageBookmarkKey.rootPathFallback) else {
            return .notConfigured
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else {
            // Kept for the same reason as the bookmark: it is a hint about
            // where the user's folder was, and the folder may come back.
            Logger.warning("Path fallback target missing — keeping it, reporting .folderMissing")
            return .failed(.folderMissing)
        }
        // Note: we don't try to upgrade this to a bookmark here — the
        // system picker grant is gone. The folder works for this session
        // but won't survive an uninstall until the user re-picks via the
        // "更换存储位置" entry in Settings (which re-triggers the grant).
        return .resolved(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Resolves the stored credential, acquires the security-scoped
    /// resource, and publishes the resulting `state`.
    ///
    /// The failure path now says *why* it failed. It used to set
    /// `isReady = false` and nothing else, which put a blank
    /// OnboardingView in front of a user who could not tell "you never
    /// set this up" from "your folder went missing".
    func bootstrap() async {
        switch resolve() {
        case .resolved(let url):
            resolvedRoot = url
            // Real security-scope acquisition (see setReady for context).
            _ = url.startAccessingSecurityScopedResource()
            didStartAccess = true
            errorMessage = nil
            state = .ready
        case .notConfigured:
            state = .unconfigured
            errorMessage = nil
        case .failed(let reason):
            state = .unreachable(reason)
            errorMessage = reason.message
            Logger.warning("Storage unreachable: \(reason)")
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
        // The picker URL is ONLY security-scoped while the picker sheet is
        // alive. Two things must happen synchronously here, on the picker
        // session's behalf, BEFORE the sheet is dismissed:
        //
        // 1. `startAccessingSecurityScopedResource()` — acquire the sandbox
        //    extension so subsequent writes in this session are permitted.
        //    Without this, AVAudioFile writes fail with OSError -54
        //    ("unable to make sandbox extension") immediately.
        //
        // 2. `bookmarkData(options: [])` — persist the access as a
        //    security-scoped bookmark. iOS does NOT need (and does NOT
        //    support) `.withSecurityScope` — security scope is implied
        //    automatically when the source URL is security-scoped. The
        //    previous design deferred bookmark creation to a background
        //    `Task.detached`, but by the time that Task runs the picker
        //    sheet has already been dismissed, the URL is no longer
        //    security-scoped, and `bookmarkData(options: [])` produces a
        //    NON-security-scoped bookmark. On the next cold start, that
        //    bookmark resolves to a URL where
        //    `startAccessingSecurityScopedResource()` returns false — so
        //    every write fails. That's the bug we hit.
        //
        // The picker sheet is still up while this synchronous block runs
        // (the caller is the picker's didPick handler), so the user doesn't
        // see the bookmarkData() latency — they're looking at the picker.
        // We trade aa51ef6's "instant UI swap" for "instant access" because
        // the previous trade-off silently broke security-scoped persistence.
        _ = url.startAccessingSecurityScopedResource()

        do {
            let data = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: StorageBookmarkKey.rootBookmark)
            UserDefaults.standard.removeObject(forKey: StorageBookmarkKey.rootPathFallback)
        } catch {
            // Sync bookmark creation failed — save the path string as last-resort.
            UserDefaults.standard.set(url.path, forKey: StorageBookmarkKey.rootPathFallback)
        }

        resolvedRoot = url
        // Remember the folder's name where it outlives the app.
        StorageFolderHint.remember(folderName: url.lastPathComponent)
        didStartAccess = true
        errorMessage = nil
        state = .ready
    }

    // MARK: - URL helpers (nonisolated so any actor can read them cheaply)

    nonisolated var rootURL: URL {
        guard let url = resolvedRoot else { preconditionFailure("rootURL accessed before bootstrap") }
        return url
    }

    nonisolated func audioURL(for id: UUID) -> URL {
        recordingsDirectoryURL
            .appendingPathComponent("\(id.uuidString).m4a")
    }

    /// The folder the `.m4a` files live in.
    ///
    /// Exposed because "the records file is gone but the audio is still
    /// there" is a state the app has to be able to *name* — and spotting
    /// it means looking at this directory.
    nonisolated var recordingsDirectoryURL: URL {
        rootURL.appendingPathComponent("Recordings", isDirectory: true)
    }

    nonisolated var jsonURL: URL {
        rootURL.appendingPathComponent("transcriptions.json")
    }

    nonisolated var relatedNotesURL: URL {
        rootURL.appendingPathComponent("relatedNotes.json")
    }

    /// The LLM provider profiles file.
    ///
    /// Lives in the data folder rather than in `UserDefaults` because a
    /// profile's `id` is the Keychain account its API key is stored
    /// under: a profile that did not come back after a reinstall left
    /// its key orphaned in the Keychain, and the user had to re-type it.
    /// See `ProviderProfileStorage` and ADR-0008.
    nonisolated var providerProfilesURL: URL {
        rootURL.appendingPathComponent("profiles.json")
    }

    /// The name of the folder the user picked.
    ///
    /// The last component of the path. The rest of it is the Files
    /// app's internal container location, which means nothing to a user
    /// and changes on every reinstall — but the name is what they see in
    /// the Files app, and what they have to pick again after a
    /// reinstall.
    var folderName: String? {
        resolvedRoot?.lastPathComponent
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