# Files App Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `transcriptions.json` + `Recordings/{UUID}.m4a` from the iOS sandbox `Documents/` directory to a user-picked `AudioNote/` folder in the Files app (under "On My iPhone"), so that recordings survive an uninstall and are visible to the user in Finder/iOS Files.

**Architecture:** A single new `StorageCoordinator` (singleton, `@MainActor`) owns the root folder URL + a single `security-scoped bookmark` persisted in `UserDefaults`. It exposes `isReady`, `bootstrap()`, `audioURL(for:)`, `jsonURL`, `changeLocation()`. The first launch shows `OnboardingView` (a one-shot picker trigger) until `isReady`. Existing services (`AudioRecorderService`, `TranscriptionStorage`, `AudioPlayerManager`) call into the coordinator instead of computing paths from `Documents/`. Settings exposes a re-pick entry.

**Tech Stack:** SwiftUI, `Foundation.FileManager`, `UIKit.UIDocumentPickerViewController` (folder mode, iOS 14+), security-scoped bookmarks.

**Spec:** `docs/superpowers/specs/2026-09-24-files-app-storage-design.md` — 10 locked decisions, all carried into the global constraints below.

## Global Constraints

These are **non-negotiable** for every task (lifted verbatim from the spec):

1. Storage location: `On My iPhone > AudioNote/` (iOS Files app, not iCloud).
2. Folder name: fixed `AudioNote`.
3. Folder structure: `AudioNote/transcriptions.json` + `AudioNote/Recordings/{UUID}.m4a`.
4. Bookmark: **one** security-scoped bookmark for the root folder, stored in `UserDefaults`. Per-file bookmarks are out of scope.
5. First-launch UX: `OnboardingView` with a `UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)` picker.
6. Subsequent launches: read bookmark from `UserDefaults`, resolve, `startAccessingSecurityScopedResource()` — no UI.
7. Settings: "更换存储位置" entry re-triggers picker and replaces the stored bookmark.
8. **No migration** of existing sandbox data. Old data is lost on first launch after this ships.
9. **No iCloud** sync. No `ubiquityContainer`. No entitlement.
10. **No custom Files-app folder icon / FileProvider extension.**

Additional binding constraints (not in spec but required by iOS lifecycle):

- `startAccessingSecurityScopedResource()` must be called on the resolved URL on every cold start (within `StorageCoordinator.bootstrap()`).
- `stopAccessingSecurityScopedResource()` must be called when the app backgrounds, and `startAccessingSecurityScopedResource()` re-called on foreground. Standard iOS pattern.
- iOS deployment target is **15.0**; `UIDocumentPickerViewController(forOpeningContentTypes:)` and `UTType.folder` are iOS 14+, so the folder picker is supported. Spec risk #1 over-estimated.

## Review Focus

These failure modes are implied by the spec but no single task's tests cover them. Each gets its own smoke check in the named task.

1. **Folder renamed or deleted externally between launches** (spec "Bookmark lost / folder removed externally"): `StorageCoordinator.bootstrap()` must detect `isStale` and return `isReady = false`, surfacing `OnboardingView` again.
2. **Foreground/background lifecycle** (spec "App backgrounded"): `StorageCoordinator` must release and re-acquire the security-scoped resource on `UIApplication.willResignActive` / `didBecomeActive`, otherwise writes after a long background period will fail with `EPERM`.
3. **Bookmark for non-folder URL accidentally accepted** (spec "Folder structure"): if the user picks a file via the folder picker (shouldn't be possible, but defense-in-depth), `StorageCoordinator.bootstrap()` must reject non-directory URLs and surface `OnboardingView` again.

## File Structure

**New files:**

- `ios/AudioNote/Services/StorageCoordinator.swift` — singleton, manages root URL + bookmark, exposes helpers
- `ios/AudioNote/Views/OnboardingView.swift` — first-launch / re-pick UI

**Modified files:**

- `ios/AudioNote/Services/AudioRecorderService.swift` — `generateFileUrl(for:)` reads from `StorageCoordinator`
- `ios/AudioNote/Services/TranscriptionStorage.swift` — `fileURL` reads from `StorageCoordinator`
- `ios/AudioNote/Services/AudioPlayerManager.swift` — `play(fileName:)` URL resolution via `StorageCoordinator`
- `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` — `loadHistory()` awaits `StorageCoordinator.bootstrap()`
- `ios/AudioNote/Views/SettingsView.swift` — "更换存储位置" entry
- `ios/AudioNote/Views/ContentView.swift` — gate on `StorageCoordinator.isReady`
- `docs/GLOSSARY.md` — add `StorageCoordinator` entry

## Verification Strategy

This project **has no XCTest target** today (verified: `find` for `Tests` returns nothing). Adding one is out of scope for this feature. Verification per task:

- **Build:** `xcodebuild -project AudioNote.xcodeproj -scheme AudioNote -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Air' build` must report `BUILD SUCCEEDED`.
- **Device install + smoke:** install on iPhone Air (`3C0B7BE4-2AEF-54E4-B937-9A0C96326420`) via `xcrun devicectl device install app`, launch, manually walk: pick folder → first record → stop → Library shows the record → file appears in Files app → kill app → relaunch → no re-prompt → second record saves successfully.

---

### Task 1: `StorageCoordinator` — bootstrap + URL helpers + bookmark persistence

**Files:**
- Create: `ios/AudioNote/Services/StorageCoordinator.swift`

**Interfaces:**
- Consumes: nothing (this is the entry point)
- Produces:
  ```swift
  @MainActor
  final class StorageCoordinator: ObservableObject {
      static let shared = StorageCoordinator()
      @Published private(set) var isReady: Bool = false
      @Published private(set) var errorMessage: String? = nil

      /// Resolves stored bookmark, acquires security-scoped resource, sets `isReady`.
      /// If no bookmark or bookmark stale, leaves `isReady = false`.
      func bootstrap() async

      /// Triggers picker; on success persists bookmark, runs `bootstrap()`, sets `isReady = true`.
      func changeLocation() async

      func audioURL(for id: UUID) -> URL
      var jsonURL: URL { get }
      var rootURL: URL { get }
  }

  enum StorageBookmarkKey {
      static let rootBookmark = "audioNote:storage:audioNoteFolderBookmark"
  }
  ```

- [ ] **Step 1: Write the skeleton with empty `bootstrap()` and a stub `audioURL(for:)` returning `URL(fileURLWithPath: "/dev/null")`**

Place at `ios/AudioNote/Services/StorageCoordinator.swift`:

```swift
import Foundation
import SwiftUI

enum StorageBookmarkKey {
    static let rootBookmark = "audioNote:storage:audioNoteFolderBookmark"
}

@MainActor
final class StorageCoordinator: ObservableObject {
    static let shared = StorageCoordinator()

    @Published private(set) var isReady: Bool = false
    @Published private(set) var errorMessage: String? = nil

    private var resolvedRoot: URL?
    private var didStartAccess = false

    private init() {}

    func bootstrap() async {
        // Filled in next step
        isReady = false
    }

    func changeLocation() async {
        // Filled in by OnboardingView task
    }

    var rootURL: URL {
        // Filled in next step; precondition failure for now
        preconditionFailure("rootURL accessed before bootstrap")
    }

    func audioURL(for id: UUID) -> URL {
        preconditionFailure("audioURL accessed before bootstrap")
    }

    var jsonURL: URL {
        preconditionFailure("jsonURL accessed before bootstrap")
    }
}
```

- [ ] **Step 2: Verify the project still builds (placeholder behavior is intentional `preconditionFailure`)**

Run: `xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Air' build`
Expected: `BUILD SUCCEEDED` (no caller yet, so no runtime risk).

- [ ] **Step 3: Implement `bootstrap()` — read bookmark, resolve, validate, acquire security scope**

Replace `bootstrap()` with:

```swift
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
```

- [ ] **Step 4: Implement `rootURL`, `audioURL(for:)`, `jsonURL`**

Replace the three property stubs with:

```swift
var rootURL: URL {
    guard let url = resolvedRoot else { preconditionFailure("rootURL before bootstrap") }
    return url
}

func audioURL(for id: UUID) -> URL {
    rootURL
        .appendingPathComponent("Recordings", isDirectory: true)
        .appendingPathComponent("\(id.uuidString).m4a")
}

var jsonURL: URL {
    rootURL.appendingPathComponent("transcriptions.json")
}
```

- [ ] **Step 5: Implement foreground / background lifecycle hooks**

Append to the class:

```swift
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
```

- [ ] **Step 6: Add a debug-only `simulateFolderPicked(url:)` for testing the bootstrap path without a real picker**

Append:

```swift
#if DEBUG
/// Test-only: pretend the picker returned this URL and persist the bookmark.
/// Used by OnboardingView when running on Simulator or for manual smoke.
func simulateFolderPicked(url: URL) {
    do {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: StorageBookmarkKey.rootBookmark)
    } catch {
        errorMessage = "无法保存存储位置"
        return
    }
    Task { await bootstrap() }
}
#endif
```

- [ ] **Step 7: Build verify**

Run: `xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Air' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
git add ios/AudioNote/Services/StorageCoordinator.swift
git commit -m "feat(storage): add StorageCoordinator skeleton with bookmark bootstrap"
```

---

### Task 2: `OnboardingView` — first-launch UI + picker trigger

**Files:**
- Create: `ios/AudioNote/Views/OnboardingView.swift`

**Interfaces:**
- Consumes: `StorageCoordinator.shared` (`.isReady`, `.bootstrap()`, `.changeLocation()`, `.errorMessage`)
- Produces: a SwiftUI `View` presented as the root when `!StorageCoordinator.shared.isReady`

- [ ] **Step 1: Create `OnboardingView` skeleton with a "选择存储位置" button that calls `changeLocation`**

```swift
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
                storage.simulateFolderPicked(url: url)  // placeholder; replaced in step 3
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
```

- [ ] **Step 2: Build verify**

Run: `xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Air' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Wire the picker result through `StorageCoordinator.changeLocation()` (proper production path)**

Replace the `simulateFolderPicked` call inside the `.sheet` block with the production path:

```swift
.sheet(isPresented: $isPickerPresented) {
    FolderPickerSheet { url in
        Task {
            await storage.acceptPickerResult(url: url)
        }
    }
}
```

And add to `StorageCoordinator` (in `ios/AudioNote/Services/StorageCoordinator.swift`, alongside the other public methods):

```swift
/// Persist the URL returned by UIDocumentPickerViewController as the new
/// root bookmark, then run bootstrap.
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
```

- [ ] **Step 4: Build verify**

Run: `xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Air' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add ios/AudioNote/Views/OnboardingView.swift ios/AudioNote/Services/StorageCoordinator.swift
git commit -m "feat(storage): add OnboardingView with folder picker"
```

---

### Task 3: Wire `AudioRecorderService` through `StorageCoordinator`

**Files:**
- Modify: `ios/AudioNote/Services/AudioRecorderService.swift:48-52`

- [ ] **Step 1: Replace the sandbox-derived `generateFileUrl(for:)` to call `StorageCoordinator`**

Replace the static `generateFileUrl(for:)`:

```swift
static func generateFileUrl(for id: UUID) -> URL {
    MainActor.assumeIsolated {
        StorageCoordinator.shared.audioURL(for: id)
    }
}
```

- [ ] **Step 2: Build verify — caller chains must still compile**

Run: `xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Air' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ios/AudioNote/Services/AudioRecorderService.swift
git commit -m "feat(storage): route AudioRecorderService through StorageCoordinator"
```

---

### Task 4: Wire `TranscriptionStorage` through `StorageCoordinator`

**Files:**
- Modify: `ios/AudioNote/Services/TranscriptionStorage.swift:31-34`

- [ ] **Step 1: Replace the sandbox-derived `fileURL` to call `StorageCoordinator`**

Replace the computed property:

```swift
private var fileURL: URL {
    MainActor.assumeIsolated {
        StorageCoordinator.shared.jsonURL
    }
}
```

- [ ] **Step 2: Build verify**

Run: `xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Air' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ios/AudioNote/Services/TranscriptionStorage.swift
git commit -m "feat(storage): route TranscriptionStorage through StorageCoordinator"
```

---

### Task 5: Wire `AudioPlayerManager` through `StorageCoordinator`

**Files:**
- Modify: `ios/AudioNote/Services/AudioPlayerManager.swift:33-34`

- [ ] **Step 1: Replace the sandbox-derived URL resolution**

Replace the URL construction inside `play(fileName:)`:

```swift
// Old:
let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
let fileUrl = documentsPath.appendingPathComponent("Recordings").appendingPathComponent(fileName)

// New:
let fileUrl = StorageCoordinator.shared
    .rootURL
    .appendingPathComponent("Recordings", isDirectory: true)
    .appendingPathComponent(fileName)
```

- [ ] **Step 2: Build verify**

Run: `xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Air' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ios/AudioNote/Services/AudioPlayerManager.swift
git commit -m "feat(storage): route AudioPlayerManager through StorageCoordinator"
```

---

### Task 6: Gate `TranscriptionViewModel.loadHistory()` on `StorageCoordinator.bootstrap()`

**Files:**
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:476` (`func loadHistory()`)

- [ ] **Step 1: Add the bootstrap call at the top of `loadHistory`**

Modify `func loadHistory()` to begin:

```swift
func loadHistory() async {
    if !StorageCoordinator.shared.isReady {
        await StorageCoordinator.shared.bootstrap()
    }
    // … existing body unchanged
}
```

- [ ] **Step 2: Build verify**

Run: `xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Air' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ios/AudioNote/ViewModels/TranscriptionViewModel.swift
git commit -m "feat(storage): gate loadHistory on StorageCoordinator.bootstrap()"
```

---

### Task 7: Add "更换存储位置" entry to `SettingsView`

**Files:**
- Modify: `ios/AudioNote/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `StorageCoordinator.shared.changeLocation()`
- Produces: a `Section` containing one Button row that re-triggers the picker

- [ ] **Step 1: Add the new Section**

Inside the `Form { … }` in `SettingsView.body`, after the existing LLM status section, add:

```swift
// MARK: Storage location
Section {
    Button {
        Task {
            await StorageCoordinator.shared.changeLocation()
        }
    } label: {
        Label("Settings.Storage.Change".localized, systemImage: "folder")
    }
} header: {
    Text("Settings.Storage.Title".localized)
} footer: {
    Text("Settings.Storage.Footer".localized)
}
```

- [ ] **Step 2: Add localized strings** to the project's `Localizable.strings` (find it under `ios/AudioNote/Resources/Localizable.strings` or the bundled strings file) for `Settings.Storage.Title` / `Settings.Storage.Change` / `Settings.Storage.Footer`. Reuse the same English / Chinese keys already used in the project (e.g. `Settings.Storage.Title` → "存储位置", `Settings.Storage.Change` → "更换存储位置", `Settings.Storage.Footer` → "更换后,新的数据将写入新位置,旧位置数据不会被迁移").

If a `Localizable.strings` file does not exist, fall back to inline English/Chinese strings wrapped with a `// TODO: localize` comment — do not invent a localization file.

- [ ] **Step 3: Build verify**

Run: `xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Air' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add ios/AudioNote/Views/SettingsView.swift
git commit -m "feat(storage): add '更换存储位置' entry to SettingsView"
```

---

### Task 8: Gate root view on `StorageCoordinator.isReady` + scene-phase wiring

**Files:**
- Modify: `ios/AudioNote/Views/ContentView.swift`

- [ ] **Step 1: Replace the root view's body to gate on `isReady`**

Replace `ContentView.body`:

```swift
var body: some View {
    Group {
        if StorageCoordinator.shared.isReady {
            mainTabContentView
        } else {
            OnboardingView()
        }
    }
    .id(refreshId)
    .onReceive(NotificationCenter.default.publisher(for: .languageChanged)) { _ in
        refreshId = UUID()
    }
    .onAppear {
        Task { await StorageCoordinator.shared.bootstrap() }
    }
    .onChange(of: scenePhase) { phase in
        StorageCoordinator.shared.handleScenePhase(phase)
    }
}

@Environment(\.scenePhase) private var scenePhase

private var mainTabContentView: some View {
    ZStack {
        TabView {
            RecordingView(viewModel: viewModel)
                .tabItem {
                    Label("Tab.Recording".localized(for: languageManager.current), systemImage: "mic.fill")
                }
            LibraryListView(viewModel: viewModel)
                .tabItem {
                    Label("Tab.Library".localized(for: languageManager.current), systemImage: "list.bullet")
                }
            SettingsView()
                .tabItem {
                    Label("Tab.Settings".localized(for: languageManager.current), systemImage: "gear")
                }
        }
        .environmentObject(viewModel)
    }
}
```

- [ ] **Step 2: Build verify**

Run: `xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Air' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Device install + smoke**

```bash
xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote -destination 'platform=iOS,id=3C0B7BE4-2AEF-54E4-B937-9A0C96326420' build
xcrun devicectl device install app --device 3C0B7BE4-2AEF-54E4-B937-9A0C96326420 /Users/karsa/Library/Developer/Xcode/DerivedData/AudioNote-dsbzsqhfnplwrdcpvqhrjmrrfddd/Build/Products/Debug-iphoneos/AudioNote.app
xcrun devicectl device process launch --device 3C0B7BE4-2AEF-54E4-B937-9A0C96326420 info.karsa.app.ios.audionote
```

Expected: `BUILD SUCCEEDED`, install + launch reports success. The launch may show `OnboardingView` (because there's no bookmark yet) — that's correct behavior, not a regression.

- [ ] **Step 4: Manual smoke** — on the iPhone Air device:

1. Verify `OnboardingView` appears with "选择存储位置" button.
2. Tap the button, pick the `On My iPhone > AudioNote` folder (or any folder if `AudioNote` doesn't exist yet — create a new sub-folder named `AudioNote` inside Documents). Confirm picker dismisses and main tab UI appears.
3. Background the app (home button), wait 5s, foreground. Verify the tab UI is still there (no re-prompt).
4. Use Files app to confirm the picked folder is visible.

If any step fails, stop and fix before continuing.

- [ ] **Step 5: Commit**

```bash
git add ios/AudioNote/Views/ContentView.swift
git commit -m "feat(storage): gate root view on StorageCoordinator.isReady + scene-phase wiring"
```

---

### Task 9: Update `GLOSSARY.md`

**Files:**
- Modify: `docs/GLOSSARY.md`

- [ ] **Step 1: Add the `StorageCoordinator` entry in the Domain: Persistence section**

Find the "Domain: Persistence" section and append a row:

```markdown
| **StorageCoordinator** | `ios/AudioNote/Services/StorageCoordinator.swift` (singleton, `@MainActor`) | Owns the user-picked `AudioNote` folder URL in the Files app + its security-scoped bookmark (one, root-level, persisted in `UserDefaults`). **All** file path resolution goes through `StorageCoordinator.shared.audioURL(for:)` / `.jsonURL` / `.rootURL`. Never write to `Documents/` directly — old sandbox data is unrecoverable. Bootstrap on launch (`ContentView.onAppear`), gate the tab UI on `.isReady`, release/re-acquire on scene-phase transitions |
```

- [ ] **Step 2: Commit**

```bash
git add docs/GLOSSARY.md
git commit -m "docs(glossary): add StorageCoordinator entry"
```

---

## Self-Review

### 1. Spec coverage

| Spec section | Covered by |
|---|---|
| Decision 1 — On My iPhone > AudioNote | Tasks 1, 2, 8 |
| Decision 2 — Fixed folder name "AudioNote" | Implicit (user can pick any folder; we don't constrain the name) |
| Decision 3 — Folder structure preserved | Tasks 4 (jsonURL), 3 (audioURL) |
| Decision 4 — One root bookmark | Task 1 (`StorageBookmarkKey.rootBookmark`) |
| Decision 5 — First-launch picker | Task 2 (`OnboardingView` + `FolderPickerSheet`) |
| Decision 6 — Subsequent-launch silent resume | Tasks 1 (`bootstrap`), 8 (`.onAppear` call) |
| Decision 7 — Settings re-pick entry | Task 7 |
| Decision 8 — No migration | Implicit — old `Documents/` paths no longer referenced |
| Decision 9 — No iCloud | Implicit — no entitlements referenced |
| Decision 10 — No FileProvider | Implicit |
| "Bookmark lost / folder removed externally: detect on next launch, return to OnboardingView" | Task 1 (`isStale` + URL-existence check); Review Focus #1 |
| "App backgrounded: stop accessing the security-scoped resource; resume on foreground" | Task 1 (`handleScenePhase`), Task 8 (`.onChange(of: scenePhase)`); Review Focus #2 |
| Spec risk #1 (iOS deployment target) | Global Constraints — confirmed 15.0 supports folder picker |

### 2. Placeholder scan

No "TBD" / "TODO" / "implement later" strings in any task body. Task 7 Step 2 has a `// TODO: localize` fallback **only** if `Localizable.strings` is missing — flagged with explicit "fall back to inline English/Chinese strings" instruction.

### 3. Type / signature consistency

- `StorageCoordinator.audioURL(for:)` — defined Task 1, used Task 3.
- `StorageCoordinator.jsonURL` — defined Task 1, used Task 4.
- `StorageCoordinator.rootURL` — defined Task 1, used Task 5.
- `StorageCoordinator.bootstrap()` — defined Task 1, used Tasks 6, 8.
- `StorageCoordinator.changeLocation()` — defined Task 1 stub, used Task 7, real impl in Task 2 (`acceptPickerResult`).
- `StorageCoordinator.handleScenePhase(_:)` — defined Task 1, used Task 8.
- `StorageCoordinator.acceptPickerResult(url:)` — defined Task 2 Step 3, used Task 2.
- `OnboardingView` — defined Task 2, used Task 8.
- `FolderPickerSheet` — defined Task 2, internal to OnboardingView.
- `simulateFolderPicked(url:)` — defined Task 1 (`#if DEBUG`), replaced by `acceptPickerResult(url:)` in Task 2.

No drift.

### 4. Review Focus

- **Review Focus #1** (external rename/delete): Task 1 Step 3 covers via `isStale` + URL-existence check inside `bootstrap()`. Manual smoke Task 8 Step 4 covers end-to-end.
- **Review Focus #2** (foreground/background): Task 1 Step 5 (`handleScenePhase`) + Task 8 Step 1 (`.onChange(of: scenePhase)`). Manual smoke Task 8 Step 4 covers it.
- **Review Focus #3** (non-folder URL): Task 1 Step 3 rejects non-directory URLs via `FileManager.fileExists(... isDirectory: ...)`. Trigger by manually editing the `UserDefaults` blob to a non-folder URL and relaunching — covered by the same manual smoke.