# Plan — Detail Page Per-Section Copy Buttons

**Spec:** `docs/superpowers/specs/2026-10-13-detail-section-copy-buttons-design.md`
**Created:** 2026-10-13
**Branch:** `feat/detail-copy-buttons`
**Status:** not started

## Success criteria

1. Three copy points reachable from their own block's caption label row —
   body, title, summary — each on a ≥ 44 pt hit target, visually a
   `.caption` / `.secondary` `doc.on.doc`.
2. No second entry point for "copy the body": the toolbar `doc.on.doc` is gone.
3. No copy button renders for a block that has nothing to copy, and none
   renders for the body while editing or while the record is `.pending` empty.
4. All three reuse the single `RecordActionsViewModel` toast; no new toast
   state, no new localization key other than `Detail.Content.Label`.
5. `xcodebuild` (iphonesimulator + iphoneos) succeeds; manual smoke on the
   iPhone Air confirms each button pastes the intended string.

## Tasks

### Task 1 — `CopyIconButton` component

`ios/AudioNote/Views/SharedComponents.swift`, after `RecordActionsViewModel`.

- `struct CopyIconButton: View` — takes a trailing closure, no `@Binding`.
- `Image(systemName: "doc.on.doc").font(.caption).foregroundColor(.secondary)`
- `.buttonStyle(.plain)`
- `.padding(8).contentShape(Rectangle())` for the hit area.
- Reuse `PendingRecognitionTests`' existing coverage of
  `SharedComponents` symbols as the compile-check baseline — this file is
  already imported by `AudioNoteTests`.

**Verify:** `xcodebuild build` clean; no behaviour to test (pure view chrome).

### Task 2 — Body block label row

`TranscriptionDetailView.swift:171-257`.

- Add an always-present `HStack` label row to `contentSection`, above the
  `Group` that renders the body.
- Label text: `"Detail.Content.Label".localized`, `.caption`, `.secondary`.
- Move the 「优化后」 seal `:188-197` **into** that `HStack` as a prefix,
  keeping its `llmProcessingStatus == .completed` gate and its existing
  comment block intact — the comment explains *why the gate is on
  `llmProcessingStatus`* and must keep explaining it at its new home.
- Append `CopyIconButton { actionsViewModel.copyText(currentRecord.content) }`
  after a `Spacer(minLength: 8)`.
- Visibility: `if !isEditing && PendingRecognitionPolicy.isLLMEligible(text: currentRecord.content)`.
  This is the exact complement of the placeholder's text test at `:207`
  (§6.3 of the spec) — do **not** add `recognitionMode`.

**Verify:** build; then on device — body button hidden in edit mode, hidden
on a `.pending` empty record, shown on a normal record.

### Task 3 — Title + summary rows

`TranscriptionDetailView.swift:259-299`.

- Wrap each of the two label `Text`s in an `HStack { Text; Spacer(minLength: 8); CopyIconButton }`
  inside the existing `VStack(alignment: .leading, spacing: 4)`.
- Buttons reuse the existing `!title.isEmpty` / `!summary.isEmpty` gates —
  the button lives inside the already-gated `if let`, so it inherits them.
- Tags block untouched.

**Verify:** build; device — title button absent when no LLM results.

### Task 4 — Remove the toolbar copy button

`TranscriptionDetailView.swift:75-101`.

- Delete the `Button { actionsViewModel.copyText(...) }` at `:82-86`.
- The remaining `HStack` (share + pencil) collapses to its two buttons.

**Verify:** `grep -n "doc.on.doc" ios/AudioNote/Views/TranscriptionDetailView.swift`
returns exactly the `CopyIconButton` definition site (or nothing, if the
component is the only holder).

### Task 5 — Localization

`ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings` +
`ios/AudioNote/Resources/en.lproj/Localizable.strings`.

- Add `Detail.Content.Label` = `转写内容` / `Transcript`, placed next to the
  existing `Detail.LLM.*` keys (`:54-56` zh-Hans).
- Both files must stay key-for-key in sync (existing convention — the files
  are parallel). No new `Toast.*` key.

**Verify:** `diff <(grep -o '^"[^"]*"' zh-Hans) <(grep -o '^"[^"]*"' en)` is empty.

### Task 6 — design-system docs

- `design-system/components/copy-icon-button.md` — new component page
  (anatomy, tokens, states, provenance **inferred**).
- `design-system/patterns/detail-sheet.md` §2 anatomy diagram — toolbar no
  longer has `doc.on.doc`; §4 states table gains the per-block copy rows.
- `design-system/tokens/icons.md` §4 — `doc.on.doc` is now a section-label
  affordance, not a toolbar item.

**Verify:** no remaining claim in `design-system/` that the detail toolbar
carries a copy button.

### Task 7 — Verification pass

1. `xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote -destination
   'platform=iOS Simulator' build`
2. `xcodebuild … -destination 'generic/platform=iOS' build` (device slice)
3. Install + launch on the iPhone Air (`memory/ios-device-registry.md`).
4. Manual smoke, per block: tap each button, paste into Notes, confirm the
   string. Plus the negative cases from Success criteria 3.
5. `superpowers:verification-before-completion` before reporting done.

## Notes / risks

- **No unit tests.** `codegraph` reports zero covering tests for
  `TranscriptionDetailView`. The gating predicate in Task 2 is the only
  logic here worth a test, and it lives inside a computed `some View`. If the
  implementer wants teeth, extract the predicate to a free function
  (`shouldShowBodyCopyButton(isEditing:text:)`) in `SharedComponents` and
  unit-test it — but that is a judgement call, not a requirement.
- **Task 2 moves a heavily-commented block.** The comment at `:173-197` is
  load-bearing documentation of the `llmProcessingStatus` gate. It moves with
  the seal; do not summarise or trim it.
- Spec §12.3 (lost toolbar button) is accepted risk, not a blocker. Revisit
  only if the user reports the editing-state gap in practice.
