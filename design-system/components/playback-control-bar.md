# PlaybackControlBar

> **Status: inferred** (existing reusable component).

## §1. Where used

`ios/AudioNote/Views/TranscriptionDetailView.swift:42` — the only consumer.

## §2. Current shape

```swift
struct PlaybackControlBar: View {
    @ObservedObject var playerManager = AudioPlayerManager.shared
    let audioFileName: String
    // … time formatting

    var body: some View {
        HStack(spacing: 16) {
            Button { … togglePlayPause(fileName:) } label: {
                Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
            }
            Slider(value: Binding(
                get: { playerManager.progress },
                set: { playerManager.seek(to: $0) }
            ))
            .tint(.accentColor)
            Text("\(formattedCurrentTime)/\(formattedDuration)")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}
```

## §3. Token values

| Token | Value | Source |
|---|---|---|
| container bg | `Color(.systemGray6)` | `tokens/colors.md §1` |
| container radius | `12` | `tokens/spacing-and-shape.md §1` |
| container padding | `.horizontal 16, .vertical 12` | `tokens/spacing-and-shape.md §2` |
| internal spacing | `16` | `tokens/spacing-and-shape.md §3` |
| icon | `play.fill` / `pause.fill`, `.title2`, `.accentColor` | `tokens/icons.md §4`, `tokens/typography.md §1` |
| time text | `.caption`, `.secondary`, `.monospacedDigit` | `tokens/typography.md §1, §4` |

## §4. States covered

- ✅ idle / playing / paused (driven by `AudioPlayerManager.isPlaying`)
- ❌ disabled — no n/a (always shown once `audioFileName` is set)

## §5. Self-review

- [x] Did I check `design-system/`? — bootstrap
- [x] Rationale? — existing component
- [x] States covered? — §4
- [x] Provenance? — **inferred** for the design-system document; the
       component is in code (treated as confirmed in practice)

## §6. Open questions

1. Should `PlaybackControlBar` be moved to `SharedComponents.swift`? Today
   it lives there but the file name doesn't communicate the dependency on
   `AudioPlayerManager` clearly.
2. Should it support a "scrub to time" gesture hint? No n/a — out of scope.