# Spacing, Radius & Shape Tokens

> **Status: inferred** — extracted from `ios/AudioNote/Views/`, 2026-09-24.

## §1. Corner radius distribution

| Radius | Count | Role |
|---|---|---|
| `12` | 9 | text-card, playback bar, primary CTA (permission overlay) |
| `10` | 3 | search bar, action buttons |
| `8` | 3 | tag chips, secondary cards, tag pills |
| `16` | 1 | tagChip (LibraryListView) |
| `20` | 2 | toast (pill shape) |
| `4` | 1 | inline mode-badge |

**Dominant radius is 12** — the codebase already gravitates to it for cards and text containers.

## §2. Padding distribution (per side)

### Horizontal

| Value | Use |
|---|---|
| `16` | screen-edge padding (Recording + Library + Detail), toast, primary CTA |
| `12` | search bar inner padding |
| `14` | language chip inner padding |
| `8` | tag pill inner padding, content card text padding |
| `6` | small badge inner padding |

### Vertical

| Value | Use |
|---|---|
| `12` | playback bar inner, top safe-area |
| `16` | recording view top padding |
| `20` | recording view bottom padding |
| `10` | toast, action button inner padding, archived-banner inner |
| `8` | search bar inner, content card text padding |
| `6` | tag chip inner padding |
| `2` | inline mode-badge inner padding |
| `4` | tag pill, mini metadata spacing |

## §3. HStack / VStack spacing

| Value | Use |
|---|---|
| `16` | playback bar (icon ↔ slider ↔ time) |
| `12` | permission overlay vertical stack |
| `8` | metadata vertical stack, action button rows, search bar |
| `6` | mode badge inner, recording-real-time inner |
| `4` | metadata horizontal, library row text vertical |
| `2` | provider-row secondary text vertical |

## §4. Frame sizes (fixed-pixel components)

| Size | Use | File |
|---|---|---|
| `100 × 100` | recording button outer ring + tappable area | `RecordingView.swift:191/197/213` |
| `80 × 80` | recording button inner solid fill | `RecordingView.swift:204` |
| `8 × 8` | mode indicator dot (live) | `RecordingView.swift:166` |
| `6 × 6` | "Recording.RealTime" inline dot | `RecordingView.swift:257` |
| `60 × 60` (Image font) | empty-state icon | `LibraryListView.swift:180/197/432` |
| `32` (Image font) | recording-button mic/stop icon | `RecordingView.swift:209` |
| `48` (Text font) | recording-duration display | `RecordingView.swift:151` |
| `12` (Image font) | language-chip icon | `RecordingView.swift:123` |

## §5. Shape primitives

| Primitive | Use | File |
|---|---|---|
| `Circle().stroke(lineWidth: 4)` | recording button outer ring | `RecordingView.swift:186-191` |
| `Circle().fill(opacity: 0.1)` | pulse halo | `RecordingView.swift:195-197` |
| `Circle().fill()` | recording button inner fill | `RecordingView.swift:202-204` |
| `Circle().fill(opacity: 0.4)` (shadow) | inner-button glow | `RecordingView.swift:205` |
| `Capsule().fill()` | language chip background | `RecordingView.swift:130-134` |
| `Color(.systemBackground).opacity(0.9)` | permission overlay backdrop | `RecordingView.swift:480-481` |

## §6. Card pattern (most-repeated, worth a component)

The "text card" shape — gray6 background + 12 radius + padded content — appears
6+ times in `RecordingView.swift` alone (recording/loading/failed/result/edit/
empty sub-states) and 1+ times elsewhere.

Pseudocode shape:

```
.background(Color(.systemGray6))
.cornerRadius(12)
.frame(minHeight: 120, maxHeight: 250)  // RecordingView only
.padding(8)                              // text container only
```

See `components/text-card.md` for extraction.

## §7. States covered

- ✅ idle / loading / error / disabled / success / first-use (all implicit via parent view state)
- ❌ pressed states — SwiftUI handles via `.buttonStyle` defaults; no custom pressed style exists

## §8. Self-review

- [x] Did I check `design-system/` for existing? — bootstrap
- [x] Rationale? — code extraction
- [x] States covered? — §7
- [x] Provenance? — **inferred**

## §9. Open questions

1. Promote `cornerRadius(12)` to a `CardRadius` token?
2. Promote `Color(.systemGray6)` to a `CardBackground` token?
3. Promote `frame(width: 100, height: 100)` + `80/80` to `RecordingButtonSize` constants?