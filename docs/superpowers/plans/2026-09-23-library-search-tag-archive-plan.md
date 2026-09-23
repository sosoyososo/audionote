# 思录 (Library) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to work through this plan. Status is in this **document** (`docs/superpowers/plans/2026-09-23-library-search-tag-archive-plan.md`) — flip `- [ ]` to `- [x]` as you complete each task. Don't re-derive from conversation history; the spec + this plan are the only source of truth.
>
> **Spec:** [`docs/superpowers/specs/2026-09-23-library-search-tag-archive-design.md`](../specs/2026-09-23-library-search-tag-archive-design.md) — design decisions live there. This plan focuses on **task ordering + verification**.

**Goal:** Rename `历史` tab → `思录`; add full-text search, tag filter chips, archive action, and archived-hit banner to the records library.

**Architecture (one-line):** Existing `TranscriptionViewModel` gains filter state + computed properties + archive methods. `HistoryListView` is renamed to `LibraryListView` and rewritten to host search bar + chips + banner + new row layout. `TranscriptionDetailView` gains an archive button.

**Tech Stack:** Swift 5.9, SwiftUI (existing).

---

## Task Status Legend

- `[ ]` = pending
- `[~]` = in progress (claim before starting, flip back to `[ ]` if blocked)
- `[x]` = completed
- `[!]` = blocked / needs decision (leave a note)
- `(skip)` = not applicable (e.g., optional test missing)

**Discipline:** If you start a task, immediately mark `[~]`. If you finish, mark `[x]` AND commit with the conventional message in the task. If you can't finish, leave `[!]` with a one-line reason — never silently revert to `[ ]`.

---

## File Manifest

| File | Touched by |
|---|---|
| `ios/AudioNote/Models/TranscriptionRecord.swift` | T1 |
| `ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings` | T2 |
| `ios/AudioNote/Resources/en.lproj/Localizable.strings` | T2 |
| `ios/AudioNote/Views/ContentView.swift` | T3 |
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` | T4, T5 |
| `ios/AudioNote/Views/HistoryListView.swift` → `LibraryListView.swift` (Xcode rename) | T6, T7, T8 |
| `ios/AudioNote/Views/TranscriptionDetailView.swift` | T9 |
| `docs/GLOSSARY.md` | T10 |
| verification (xcodebuild + manual) | T11 |

---

### Task T1: Extend `TranscriptionRecord` schema  `[x]`

**Files:** `ios/AudioNote/Models/TranscriptionRecord.swift`

**Acceptance criteria:**
- [x] Two new fields exist on `TranscriptionRecord`:
  - `var archived: Bool = false`
  - `var archivedAt: Date? = nil`
- [x] `init` signature extended with `archived: Bool = false, archivedAt: Date? = nil` parameters
- [x] All existing init call sites continue to compile (default values)
- [x] Old JSON files (no archived fields) decode successfully with `archived=false, archivedAt=nil`

**Implementation outline:**
- Add fields after `recognitionMode`
- Update `init(...)` parameter list with the two new params (trailing position, default values)
- Update `init` body assignments

**Verification:**
```bash
xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`

**Commit:** `feat: add archived/archivedAt fields to TranscriptionRecord`

---

### Task T2: Add i18n keys  `[x]`

**Files:**
- `ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings`
- `ios/AudioNote/Resources/en.lproj/Localizable.strings`

**Acceptance criteria:**
- [x] All 11 keys from spec §"i18n 新增键" present in BOTH bundles (10 new + Tab.Library replacing Tab.History in usage)
- [x] `Tab.History` key DELETED from both bundles (no callers should remain after T3)
- [x] `Tab.Library` key added in both bundles

**Implementation outline:**
- Open each `.strings` file, append the 10 new key=value pairs (zh and en values per spec table)
- Remove `Tab.History` key
- Add `Tab.Library` key
- Note: use the exact key names from the spec

**Verification:** Search both files for the 11 keys — all present. Search for `Tab.History` — not present.

**Commit:** `feat(i18n): add 思录 (Library) strings to zh-Hans and en bundles`

---

### Task T3: Update `ContentView` tab label  `[x]`

**Files:** `ios/AudioNote/Views/ContentView.swift`

**Acceptance criteria:**
- [x] `HistoryListView` tab item uses `Tab.Library.localized` (replacing `Tab.History.localized`)
- [x] No other references to `Tab.History` in the file

**Implementation outline:**
- Change the `Label(...)` call for the history tab item

**Verification:** Grep confirms only `Tab.Library` reference.

**Commit:** `feat: rename History tab label to Tab.Library in ContentView`

---

### Task T4: Add filter state + computed properties to `TranscriptionViewModel`  `[x]`

**Files:** `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`

**Acceptance criteria:**
- [x] Two new `@Published` properties (state): `searchQuery: String = ""`, `selectedTags: Set<String> = []`
- [x] Five new computed properties: `displayedRecords`, `availableTags`, `tagCounts`, `archivedHitIDs`, `archivedHitCount`
- [x] `setSearchQuery(_:)`, `toggleTag(_:)`, `clearFilters()` mutators
- [x] When `historyRecords` changes, all derived views refresh (computed properties re-evaluate)
- [x] Search matches title + summary + tags (joined) + content, case-insensitive
- [x] Sort: when tags selected, tag-match-count desc → createdAt desc; else createdAt desc

**Implementation outline:**
- Search algorithm: `record.searchableText` helper = `(title ?? "") + " " + (summary ?? "") + " " + (tags?.joined(separator: " ") ?? "") + " " + content`; case-insensitive `localizedCaseInsensitiveContains(query)`
- Tag filter: `selectedTags.isEmpty || (record.tags ?? []).contains(where: selectedTags.contains)`
- Sort: when `selectedTags.isEmpty`, sort by `createdAt` desc (existing behavior); else compute `matchCount = (record.tags ?? []).filter(selectedTags.contains).count`, sort by `matchCount` desc then `createdAt` desc

**Verification:** Build succeeds.

**Commit:** `feat(vm): add search/filter state and computed properties to TranscriptionViewModel`

---

### Task T5: Add archive/unarchive actions to `TranscriptionViewModel`  `[x]`

**Files:** `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`

**Acceptance criteria:**
- [x] `archiveRecord(id: UUID)` async method: sets `archived=true, archivedAt=now`, saves via storage, refreshes historyRecords
- [x] `unarchiveRecord(id: UUID)` async method: sets `archived=false, archivedAt=nil`, saves, refreshes historyRecords
- [x] No new `RecognitionMode` cases (per ADR-0001)

**Implementation outline:**
- Both methods can use `try? await storage.get(id:)` and `try? await storage.save(updated)` to follow existing error-tolerant pattern in this VM

**Verification:** Build succeeds.

**Commit:** `feat(vm): add archive/unarchive actions to TranscriptionViewModel`

---

### Task T6: Rename `HistoryListView.swift` → `LibraryListView.swift` (Xcode + struct rename)  `[x]`

**Files:**
- `ios/AudioNote/Views/HistoryListView.swift` → `LibraryListView.swift` (file rename)
- Internal: rename struct `HistoryListView` → `LibraryListView`

**Acceptance criteria:**
- [x] File renamed in the Xcode project (NOT just the filesystem; reference updated)
- [x] Struct renamed
- [x] All references to `HistoryListView` updated to `LibraryListView` (search results should show zero `HistoryListView` references after this task)
- [x] Project still builds

**Xcode-specific rename steps:**
1. Right-click `HistoryListView.swift` in Project Navigator → "Refactor → Rename..." → `LibraryListView`
2. Choose "Rename related files" + "Update references"
3. Confirm

**If not using Xcode UI**, do manually:
1. `git mv ios/AudioNote/Views/HistoryListView.swift ios/AudioNote/Views/LibraryListView.swift`
2. Update Xcode project file (`.pbxproj`) — this is risky; prefer the UI method
3. Rename struct in file content

**Verification:**
```bash
grep -rn "HistoryListView" ios/AudioNote/ 2>/dev/null
```
Expected: no matches (after rename complete).

```bash
xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`

**Commit:** `refactor: rename HistoryListView to LibraryListView`

---

### Task T7: Rewrite `LibraryListView` UI — search bar + chips + banner + new row

**Files:** `ios/AudioNote/Views/LibraryListView.swift`

**Acceptance criteria:**
- [x] View structure: `NavigationView` → outer `VStack` containing (in order):
  1. Search bar (sticky at top)
  2. Tag chips horizontal scroll
  3. (conditional) Archived-hit banner
  4. List of records
- [x] Search bar: `TextField` with placeholder `Library.Search.Placeholder` + ✕ clear button when query non-empty
- [x] Search debounce 150ms (use `Task.sleep` + cancel previous)
- [x] Tag chips: `ScrollView(.horizontal)` with `Button` per tag from `viewModel.availableTags`, each shows `tagCounts[tag]` count; selected chips have visual highlight
- [x] Banner: shown when `viewModel.archivedHitCount > 0`, displays "已归档 N 条匹配 · 点击查看", wrapped in `NavigationLink` to `LibraryArchivedMatchesView`
- [x] List rows: title (`record.title` or content[:30]+"…" fallback) line 1, summary (`record.summary` or content[30:80]+"…" fallback) line 2 with `.lineLimit(2)` + `.truncationMode(.tail)`
- [x] Date grouping preserved (existing behavior)
- [x] Empty state: "无匹配记录" + "清除筛选" button when displayedRecords is empty AND search query non-empty

**Implementation outline:**
- Reference spec §"UI Visualization" for ASCII layouts
- Use `@State` for local UI state (search debounce task handle); `@ObservedObject` viewModel for data
- Keep `RecordRowView` as-is structurally, but its body now consumes the new layout

**Verification:**
```bash
xcodebuild ... build 2>&1 | tail -3  # BUILD SUCCEEDED
```
Manual smoke (will be in T11):
- Open app → Library tab visible (tab label "思录" / "Library")
- Search "周会" → list filters
- Tap tag chip → list filters further
- Tap archived banner → navigates to sub-page (still need T8)

**Commit:** `feat: rewrite LibraryListView with search, tag chips, archived banner`

---

### Task T8: Add `LibraryArchivedMatchesView` (pushed sub-page)

**Files:** `ios/AudioNote/Views/LibraryListView.swift` (same file)

**Acceptance criteria:**
- [x] New struct `LibraryArchivedMatchesView` in the same file
- [x] Receives `viewModel` and reads current `searchQuery` + `selectedTags` for filtering
- [x] Shows only records where `record.archived == true` AND matches current filters
- [x] Reuses the same row layout as the main list
- [x] Navigation title: "归档命中" / "Archived matches" (`Library.ArchivedSublistTitle`)
- [x] Back button: default NavigationView behavior

**Implementation outline:**
- `@ObservedObject var viewModel: TranscriptionViewModel`
- Computed `archivedMatches: [Record`]` = same filter logic as `displayedRecords` but `archived == true`
- Pass filter state implicitly through the shared VM

**Verification:**
```bash
xcodebuild ... build 2>&1 | tail -3  # BUILD SUCCEEDED
```
Manual smoke: archive a record, search for content in it, tap banner — sub-page shows just that record.

**Commit:** `feat: add LibraryArchivedMatchesView sub-page for archived hits`

---

### Task T9: Add archive button to `TranscriptionDetailView`

**Files:** `ios/AudioNote/Views/TranscriptionDetailView.swift`

**Acceptance criteria:**
- [x] Existing `actionsSection` HStack layout extended: `在线升级识别` button (existing, conditional) + spacer + archive button (NEW, always visible)
- [x] Archive button label: "归档" (`Detail.Action.Archive`) when `record.archived == false`; "已归档 ✓" (`Detail.Action.Archived`) when `record.archived == true`
- [x] Tap → `viewModel.archiveRecord(id: record.id)` or `viewModel.unarchiveRecord(id: record.id)` (async Task)
- [x] Visual state reflects current `record.archived` — refresh from VM after toggle
- [x] Archive button shown on ALL records (not gated by `audioFileName`)

**Implementation outline:**
- Add `@State var localArchived: Bool = false`, init from `record.archived`
- Add `archiveToggle()` private func that calls VM and updates localArchived on completion
- Wrap archive button in an HStack alongside the existing `在线升级识别` button

**Verification:**
```bash
xcodebuild ... build 2>&1 | tail -3  # BUILD SUCCEEDED
```
Manual smoke: open detail view of any record → archive button visible → tap → record archived → list filters it out → tap again → restored.

**Commit:** `feat: add archive/unarchive button to TranscriptionDetailView`

---

### Task T10: Update `docs/GLOSSARY.md`

**Files:** `docs/GLOSSARY.md`

**Acceptance criteria:**
- [x] New "Persistence" section entries:
  - `思录 / Library` — the renamed tab; conceptually the records library, entry at `ios/AudioNote/Views/LibraryListView.swift`
  - `archived` — `TranscriptionRecord.archived` field; Bool, default false; archived records hidden from main library list
  - `archivedAt` — `TranscriptionRecord.archivedAt` field; Date?, default nil; set when archived
- [x] Format matches existing glossary table style

**Verification:**
```bash
grep -E "思录|archived" docs/GLOSSARY.md
```
Expected: matches present.

**Commit:** `docs: add 思录 (Library), archived, archivedAt to GLOSSARY`

---

### Task T11: End-to-end verification

**Acceptance criteria:**
- [x] xcodebuild succeeds on Debug for `generic/platform=iOS Simulator`
- [x] xcodebuild succeeds on Release for `generic/platform=iOS Simulator`
- [x] Manual smoke checklist passes:

| # | Scenario | Expected |
|---|---|---|
| 1 | Cold start, no records | Library shows empty state |
| 2 | Record + LLM process | New record appears with title/summary from LLM |
| 3 | Type "周会" in search | List filters live (debounce ~150ms), record with "周会" in title/summary/content shows |
| 4 | Tap a tag chip | List further filters to records containing that tag |
| 5 | Select 2 tag chips | List shows records matching ≥1 tag (OR); sort by tag-match-count desc |
| 6 | Clear search + clear chips | All active records visible, newest first |
| 7 | Archive a record from detail page | Record disappears from main list; banner count decreases if it was in archived hits |
| 8 | Search for content of archived record | Banner "已归档 N 条匹配 · 点击查看" appears |
| 9 | Tap archived banner | Sub-page shows just the archived matches |
| 10 | Unarchive from detail page (or sub-page → detail) | Record returns to main list |
| 11 | Detail page "归档" button visible on records WITHOUT audio | (per user decision: all records) |
| 12 | Tab label in zh shows "思录"; in en shows "Library" | (per i18n) |
| 13 | No regression: old records still load; LLM analyze still works; recording still works | (regression sweep) |

**Verification command:**
```bash
xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
```

**If failures:** Open a follow-up commit per issue. Don't batch unrelated fixes.

**Commit:** `chore: end-to-end verification sign-off (or list of fixes)`

---

## Rollback Plan

If a task fails partway:
1. Mark task `[!]` in this file with a one-line note
2. `git reset --hard HEAD~N` to the last green commit (record N in the note)
3. Update this plan's status honestly before continuing

## Notes / Decisions During Execution

(Empty — fill with anything that comes up. Don't lose decisions to chat history.)