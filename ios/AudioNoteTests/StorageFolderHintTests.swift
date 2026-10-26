import XCTest
@testable import AudioNote

/// Tests for the folder hint that outlives the app.
///
/// The hint is the one thing that lets a reinstalled app say *which*
/// folder to pick again. The Keychain is what makes it possible: it is
/// the only store in the app that survives an uninstall.
final class StorageFolderHintTests: XCTestCase {

    override func tearDown() {
        StorageFolderHint.forget()
        super.tearDown()
    }

    func testTheHintIsEmptyBeforeAnythingIsRemembered() {
        XCTAssertNil(StorageFolderHint.lastKnownFolderName())
    }

    func testTheRememberedNameComesBack() {
        StorageFolderHint.remember(folderName: "AudioNote")
        XCTAssertEqual(StorageFolderHint.lastKnownFolderName(), "AudioNote")
    }

    /// The name is the last component of the internal path, and the
    /// internal path is what the app actually has. This test pins the
    /// derivation: it is the *name* that is worth keeping, because the
    /// rest of the path changes on every reinstall.
    func testTheNameIsTheLastPathComponent() {
        let path = "/var/mobile/Containers/Shared/AppGroup/ABC-123/File Provider Storage/AudioNote"
        StorageFolderHint.remember(folderName: (path as NSString).lastPathComponent)
        XCTAssertEqual(StorageFolderHint.lastKnownFolderName(), "AudioNote")
    }

    /// A blank name would make the onboarding copy read "pick the
    ///  folder again".
    func testABlankNameIsNotRemembered() {
        StorageFolderHint.remember(folderName: "   ")
        XCTAssertNil(StorageFolderHint.lastKnownFolderName())
    }

    func testTheHintIsOverwrittenByALaterFolder() {
        StorageFolderHint.remember(folderName: "Old")
        StorageFolderHint.remember(folderName: "New")
        XCTAssertEqual(StorageFolderHint.lastKnownFolderName(), "New")
    }

    func testForgettingClearsTheHint() {
        StorageFolderHint.remember(folderName: "AudioNote")
        StorageFolderHint.forget()
        XCTAssertNil(StorageFolderHint.lastKnownFolderName())
    }
}
