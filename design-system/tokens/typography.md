# Typography Tokens

> **Status: inferred** — extracted from `ios/AudioNote/Views/`, 2026-09-24.
> Uses Apple's system font scale (Dynamic Type-friendly). No custom fonts.

## §1. Usage distribution

| Font | Count | Role |
|---|---|---|
| `.caption` | 23 | de-emphasised text: timestamps, status hints, mode labels |
| `.subheadline` | 16 | secondary content, metadata, action buttons |
| `.body` | 8 | primary content (transcripts, summaries) |
| `.headline` | 5 | titles, empty-state primary text |
| `.caption2` | 4 | sub-caption (archived badge, tag score) |
| `.title2` | 2 | section titles, error-state titles |
| `.title3` | 1 | profile row icon |
| `.callout` | 1 | empty-state copy |
| `.footnote` | 1 | profile footer |

## §2. Semantic role mapping (inferred)

| Role | Token |
|---|---|
| Page-level primary | `.headline` |
| Body content | `.body` |
| Body secondary (metadata) | `.subheadline` |
| Caption / status / metadata | `.caption` |
| Sub-caption (badge scores, sub-badges) | `.caption2` |
| Empty-state hero title | `.headline` |
| Empty-state icon | `.system(size: 60)` (Image font, not text) |
| Recording duration display | `.system(size: 48, weight: .light, design: .monospaced)` |
| Recording button icon | `.system(size: 32)` |
| Language chip icon | `.system(size: 12)` |

## §3. Weight usage

| Weight | Count | Used by |
|---|---|---|
| default | most | — |
| `.medium` | 4 | toast, language chip, button-strip action text |
| `.semibold` | 2 | save button (editing mode), permission-overlay CTA |
| `.light` | 1 | recording duration (`48 .light .monospaced`) |

## §4. Special: monospaced digit

Used in two places:

- `RecordingView.swift:151` — duration timer (monospaced + light)
- `SharedComponents.swift:113` — playback time `0:00 / 0:00`
- `TranscriptionDetailView.swift:469` — tag score `0.85`

Rationale (inferred): prevent numeric jitter on timer ticks and tag score.

## §5. States covered

- ✅ Dynamic Type (uses semantic fonts; all sizes scale)
- ✅ Dark mode (system font weights + colours, no overrides)
- ❓ Bold/banner style — none in code

## §6. Self-review

- [x] Did I check `design-system/` for existing? — bootstrap
- [x] Rationale? — code extraction only
- [x] States covered? — §5
- [x] Provenance? — **inferred**

## §7. Open questions

1. Should `.system(size: 60)` (empty-state icon) become a token like `EmptyStateIconSize`?
2. Should the duration timer's `.light + monospaced` combo become `DurationDisplay` token?
3. The codebase mixes `Label`/`Text` for tab bar — keep or pick one?