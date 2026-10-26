import Foundation

/// The name of the folder the user picked, remembered across installs.
///
/// `UserDefaults` dies with the app, so after a reinstall the app knows
/// nothing about where the user's data was. The onboarding copy can
/// then only say "pick the same folder again", and the user has to
/// remember which folder that was.
///
/// The Keychain does not die with the app, so a name stored there is
/// still there after a reinstall. Only the *name* is worth keeping: the
/// internal path contains a per-install container id, so it changes on
/// every reinstall — but the name is what the user sees in the Files
/// app, and it is what they have to pick again.
///
/// **This is a hint, never a credential.** It tells the user which
/// folder to pick; the user still has to pick it, and the app still
/// has to be granted access. The access bookmark stays in
/// `UserDefaults` on purpose — a fresh install must not inherit folder
/// access without the user asking.
enum StorageFolderHint {
    private static let service = "audioNote.storage"
    private static let account = "lastFolderName"

    /// Remember the folder the user just picked.
    static func remember(folderName: String) {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainStore(service: service).set(trimmed, account: account)
        } catch {
            // A missing hint is a small loss — the user just has to
            // remember the folder's name themselves. It must not fail
            // the pick.
            Logger.warning(
                "StorageFolderHint: could not remember the folder name: \(error.localizedDescription)"
            )
        }
    }

    /// The folder name from a previous install, if there was one.
    static func lastKnownFolderName() -> String? {
        do {
            guard let name = try KeychainStore(service: service).get(account: account) else {
                return nil
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    /// Forget the hint. Used by the tests, and available for the case
    /// where the user deliberately points the app at a different folder
    /// and the old one should stop being advertised.
    static func forget() {
        try? KeychainStore(service: service).delete(account: account)
    }
}
