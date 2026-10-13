# Detail Page — Per-Section Copy Buttons

**Status:** 📋 DESIGNED — not yet implemented
**Created:** 2026-10-13
**Branch at filing:** `main` (`cf37c8b`)

---

## 1. Problem

The detail sheet (`TranscriptionDetailView`) renders three copyable text
blocks — the transcribed/optimized body, the LLM title, and the LLM summary —
but exposes exactly **one** copy button. It lives in the navigation toolbar
(`TranscriptionDetailView.swift:82-86`) and copies `currentRecord.content`,
i.e. the body only.

Title and summary therefore have no dedicated extraction path. The only ways
to take them out of the app today are:

1. Long-press → select → the iOS selection menu (works, but it selects the
   prose, not a clean value, and gives no confirmation).
2. The share sheet — which is *also* body-only
   (`ShareSheet(items: [currentRecord.content])`, `:104`).

The user asked whether the page should carry three copy buttons, one per
block. This spec records the decision and its shape.

## 2. Current state (verified 2026-10-13, `main` @ `cf37c8b`)

| Element | Location | Notes |
|---|---|---|
| Toolbar copy button | `TranscriptionDetailView.swift:82-86` | `doc.on.doc` → `copyText(currentRecord.content)` |
| Toolbar share / edit | `:88-98` | `square.and.arrow.up`, `pencil` |
| Toast overlay | `:106-109` | `.overlay(alignment: .bottom)`, bottom-padded 40 |
| `contentSection` | `:171-257` | 「优化后」seal (`:188-197`, gated on `llmProcessingStatus == .completed`), then pending placeholder (`:238-249`) or `Text(editedContent)` (`:251`) |
| `llmResultsSection` | `:259-299` | 标题 `:265-273` / 摘要 `:275-283` / 标签 `:285-292`, all as `VStack(alignment: .leading)` with a `.caption` + `.secondary` label row |
| Copy trigger | `SharedComponents.swift:58-64` | `RecordActionsViewModel.copyText(_:)` → `UIPasteboard.general.string = text`, sets `toastMessage = "Toast.Copied"`, shows `ToastView` (1.5 s auto-hide) |

Two facts that shape the design:

- **Scroll order is metadata → body → actions → playback → LLM results.**
  Title/summary/tags sit *below* the body (`llmResultsSection` is last in the
  root `VStack`, `:32-47`). A button placed next to the summary is therefore
  the *hardest* one to reach, not the easiest.
- **The toast is a single global overlay driven by one
  `@StateObject RecordActionsViewModel`.** Three copy buttons can share it
  with no new state, as long as they live in the same view — they do.

## 3. Options considered

### 3.1 Three equal-weight buttons

Rejected. Splits one action across two entry points (toolbar + body block)
and gives the two lowest-frequency values (title, summary) affordances
weighted the same as the body, which is the one thing users actually carry
out of the app.

### 3.2 Toolbar button becomes "copy everything"

Rejected for now. Attractive (one tap gets title + summary + body), but it
changes the meaning of an existing control, needs a formatting decision for
the composite text, and forecloses per-block extraction — which is what was
asked for. Kept as a candidate for §7.

### 3.3 Low-key icon on each section's label row ✅ **CHOSEN**

The block's existing `.caption` + `.secondary` label row gains a trailing
`doc.on.doc` on its right edge. Renders only when that block has copyable
text. Reuses the `detail-sheet.md §3` convention instead of inventing a new
one.

## 4. Decision

**One copy affordance per copyable block, placed on that block's caption
label row, right-aligned. The toolbar copy button is removed.**

Three copy points:

| Block | Copies | Label row | Button visibility |
|---|---|---|---|
| Body | `currentRecord.content` | New always-present row 「转写内容」 (`Detail.Content.Label`), 「优化后」seal moves to be a **prefix inside** that row | `!isEditing` && body text non-empty |
| Title | `currentRecord.title` | `Detail.LLM.Title` (existing) | title non-empty (existing `:265` gate) |
| Summary | `currentRecord.summary` | `Detail.LLM.Summary` (existing) | summary non-empty (existing `:275` gate) |

### 4.1 Removing the toolbar copy button

Chosen deliberately. Keeping it would leave **two** ways to copy the body
with no way for the user to tell which is canonical — exactly the ambiguity
that motivated the change. Nothing is lost in reachability: `metadataSection`
is short, so the body label row is on screen before the user scrolls at all.

Consequences to accept:

- In **edit mode** the detail page has *no* copy entry point. That is correct —
  the text on screen is `editedContent`, which has not been written back yet,
  so any copy button would silently hand over a stale value. The user saves
  first.
- `LibraryListView.swift:292` keeps its own `doc.on.doc` (row context menu).
  Out of scope here.

## 5. Visual specification

```
优化后  转写内容                              📋
识别到的正文……

标题                                          📋
优化后原文的标题

摘要                                          📋
这段录音的摘要……

标签
```

Per block, the existing

```swift
VStack(alignment: .leading, spacing: 4) {
    Text(label).font(.caption).foregroundColor(.secondary)
    Text(value)
}
```

becomes

```swift
VStack(alignment: .leading, spacing: 4) {
    HStack {
        // 「优化后」seal — body block only, keeps its existing
        // llmProcessingStatus == .completed gate
        Text(label).font(.caption).foregroundColor(.secondary)
        Spacer(minLength: 8)
        CopyIconButton { actionsViewModel.copyText(<value>) }
    }
    Text(value)
}
```

`CopyIconButton` (new, `SharedComponents.swift`):

| Property | Value | Why |
|---|---|---|
| Symbol | `doc.on.doc` | Already the copy token — `icons.md` §2/§4 |
| Font | `.caption` | Matches its label row; a `.body` icon next to `.caption` text reads as content, not as a control |
| Tint | `.secondary` | Same; `.tint` would promote it above the value text |
| Button style | `.plain` | Avoids the default chrome tinting the whole cell |
| Hit area | `.padding(8)` + `.contentShape(Rectangle())` → ≥ 44 pt tall | iOS HIG minimum; visually still a small icon |

`Spacing` stays at `4` (matches `spacing-and-shape.md §3` — the existing
title/summary/tags label rows already use it).

## 6. Behaviour rules

1. **Copy is verbatim.** Each button copies the stored string exactly — no
   quoting, no `标题：…` prefix, no trimming. This matches the toolbar
   button's current semantics; changing them all at once would be a second,
   separate decision.
2. **All three share one `RecordActionsViewModel`** already declared on
   `TranscriptionDetailView` (`:7`). The toast is one overlay (`:106-109`),
   so three sources of "已复制到剪贴板" need no extra state. A second tap
   restarts the same toast — acceptable, and identical to today's behaviour.
3. **Body button gating reuses the pending placeholder's own text test.**
   The placeholder at `:207` is gated on
   `!PendingRecognitionPolicy.isLLMEligible(text: currentRecord.content) && recognitionMode == .pending`.
   The button must be the exact complement on the *text* test — visible
   whenever the body renders prose. Do **not** add a `recognitionMode`
   condition: that would split the pair again (the comment at `:233-237`
   records a past regression from doing exactly this). While editing,
   `isEditing` hides it.
4. **Title / summary buttons reuse their existing emptiness gates**; no new
   predicate is introduced.
5. **`.pending` empty records show no body button** — there is nothing to
   copy, and the placeholder already explains why.

## 7. Files that will change

- `ios/AudioNote/Views/TranscriptionDetailView.swift`
  - `contentSection:171-257` — always-present label row, seal moves inside
    it, body `CopyIconButton`.
  - `llmResultsSection:259-299` — title + summary `CopyIconButton`.
  - `:75-101` — drop the toolbar `doc.on.doc` button.
- `ios/AudioNote/Views/SharedComponents.swift` — new `CopyIconButton`.
- `ios/AudioNote/Resources/{zh-Hans,en}.lproj/Localizable.strings` — new
  `Detail.Content.Label` (`"转写内容"` / `"Transcript"`). `Toast.Copied` is
  reused as-is.
- `design-system/patterns/detail-sheet.md` — anatomy diagram + states table
  are now out of date (§2 lists the toolbar copy button).
- `design-system/components/copy-icon-button.md` — new component page.
- `design-system/tokens/icons.md` — `doc.on.doc` is no longer toolbar-only.

Not touched: `TranscriptionRecord` (no schema change), `TranscriptionStorage`,
`LibraryListView`, `RecordingView`, any ADR.

## 8. States covered

| State | Body button | Title / Summary button |
|---|---|---|
| Viewing, LLM done | ✅ | ✅ |
| Viewing, no LLM results yet | ✅ | — (blocks absent) |
| Editing | — | ✅ (title/summary are not editable) |
| `.pending`, empty | — (placeholder) | — |
| `.pending`, user typed and saved | ✅ | ✅ |
| Hand-edited body | ✅ (copies the edited text — it *is* `content` now) | ✅ |

## 9. Out of scope

- Copy for tags — structured data, and copying it as a run-on string has no
  obvious target format.
- Changing the share sheet's payload (still body-only).
- The "copy everything" composite (§3.2) — real idea, different feature.
- Long-press / selection-menu behaviour.

## 10. Tests / verification

Deferred to the plan. Note up front: `codegraph` reports **no covering tests**
for `TranscriptionDetailView` — the screen is untested today. Verification is
likely to be a manual smoke pass on the iPhone Air
(`memory/ios-device-registry.md`) rather than unit tests, unless the plan
extracts `CopyIconButton` + the gating predicate into something testable.

## 11. Self-review

- [x] Read `design-system/` first? — yes; §5 reuses the existing caption-label
      convention rather than introducing one.
- [x] Reused an existing token? — `doc.on.doc` / `.caption` / `.secondary` /
      spacing `4` are all already the copy + label tokens.
- [x] All states enumerated? — §8, including the two regressions the existing
      comments at `:215-237` warn about.
- [x] Blast radius known? — §7; no model/storage/ADR impact.
- [x] Copy semantics left unchanged? — deliberately (§6.1); this feature adds
      entry points, it does not redefine what "copy" means.

## 12. Open questions

1. Should the body label read 「转写内容」 in both languages, or follow the
   existing mixed convention (`detail-sheet.md` shows hard-coded Chinese
   labels such as 「优化后」 alongside localized `Detail.LLM.*` keys)?
2. Is a ~44 pt invisible hit area on a `.caption` icon too easy to hit by
   accident while scrolling? Needs a device pass.
3. The removed toolbar button is a regression for anyone used to it. If the
   §8 editing-state gap turns out to matter, the alternative is keeping the
   toolbar button only in non-edit mode and accepting the two-entry ambiguity
   from §3.1.
