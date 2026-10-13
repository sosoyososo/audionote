# CopyIconButton

> **Status: inferred** — introduced 2026-10-13 in
> `ios/AudioNote/Views/SharedComponents.swift`, used by
> `TranscriptionDetailView` on three section label rows. Design rationale and
> the rejected alternatives are in
> `docs/superpowers/specs/2026-10-13-detail-section-copy-buttons-design.md`.

## §1. Current shape

```swift
public struct CopyIconButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) { self.action = action }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .padding(8)
        .contentShape(Rectangle())
    }
}
```

## §2. Where it sits

On the **right edge of a section's caption label row**, not in a toolbar:

```
优化后  转写内容                              📋
识别到的正文……

标题                                          📋
优化后原文的标题

摘要                                          📋
这段录音的摘要……
```

## §3. Tokens

| Property | Value | Why |
|---|---|---|
| Symbol | `doc.on.doc` | the app's copy token — see `tokens/icons.md` |
| Font | `.caption` | matches its label row; a `.body` icon beside `.caption` text reads as content, not as a control |
| Tint | `.secondary` | same reason — `.tint` would promote it above the value text it serves |
| Button style | `.plain` | suppresses the default chrome tinting the whole cell |
| Hit area | `.padding(8)` + `.contentShape(Rectangle())` | ≥ 44 pt tall (iOS HIG) while the icon itself stays `.caption` |

## §4. Why not a toolbar button

The detail sheet previously carried one toolbar copy button that copied the
body only. Adding a second entry point for the same value leaves the user
unable to tell which is canonical — that ambiguity is what the per-section
placement exists to remove. The toolbar copy button was therefore **removed**,
not supplemented.

Consequence, accepted: in **edit mode** the detail sheet has no copy control
at all. That is correct — the text on screen is `editedContent`, which has not
been written back, so a copy button would silently hand over the pre-edit
value.

## §5. Consumers

| Screen | Location |
|---|---|
| Detail — body | `TranscriptionDetailView.contentSection` |
| Detail — LLM title | `TranscriptionDetailView.llmResultsSection` |
| Detail — LLM summary | `TranscriptionDetailView.llmResultsSection` |

`LibraryListView.swift:292` and `RecordingView.swift:303/:521` keep their own
`doc.on.doc` buttons — list row and recording card are different contexts and
were not converted.

## §6. States covered

- ✅ pressed (SwiftUI default `.plain` feedback)
- ❌ disabled — never rendered; call sites gate on "is there anything to copy"
- ❌ dark mode — template rendering, no custom variant needed
- ❓ accidental taps while scrolling — the 44 pt target around a `.caption`
  icon may be larger than it looks; unverified on device (spec §12.2)

## §7. Self-review

- [x] Did I check `design-system/`? — yes; reuses the existing `doc.on.doc`
      copy token and the caption-label-row convention from
      `patterns/detail-sheet.md §3`.
- [x] Rationale? — §4.
- [x] States covered? — §6.
- [x] Provenance? — **inferred** (extracted at implementation time from a spec,
      not promoted from observed duplication the way `recognition-mode-badge`
      was).

## §8. Open questions

1. Should the hit area be reduced from 44 pt to ~32 pt? It is generous for a
   `.caption` glyph and sits inside a horizontally-scrolling chip row's
   neighbours, but shrinking it breaks HIG minimums. Needs a device pass.
2. Should `LibraryListView`'s row copy button and `RecordingView`'s copy
   buttons migrate to this component for visual consistency? They are
   differently-sized controls in differently-shaped rows; converting them
   would restyle two working screens.
3. Tags deliberately have **no** copy button (`spec §9`) — copying a list of
   scored tags has no obvious target format. Revisit if a user asks.
