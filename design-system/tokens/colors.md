# Colour Tokens

> **Status: inferred** — extracted from `ios/AudioNote/Views/`, 2026-09-24.
> Every value below is something the code already uses; nothing invented.

## §1. Semantic foreground / background

These are iOS system semantic colours (Dark Mode aware by default). No raw hex.

| Token | Value | Used in |
|---|---|---|
| `Color.accentColor` | (asset-catalog tint, blue-ish by default) | tab icons, primary buttons, language-tag selected, save button, share/copy/pencil action buttons |
| `.primary` | label | title text, content text |
| `.secondary` | secondaryLabel | captions, secondary metadata, search-bar leading icon |
| `.white` | white | icon over accent fills, toast text, primary button text |
| `.orange` | systemOrange | permission-denied hint, "处理失败" status, archived badge, archived-banner |
| `.green` | systemGreen | "优化后" (optimised) seal + text, recognition-mode `.online` |
| `.yellow` | systemYellow | recognition-mode `.onDevice` |
| `.blue` | systemBlue | recognition-mode `.enhanced`, "在线升级识别" button bg/foreground |
| `.red` | systemRed | recognition-mode `.failed`, recording indicator dot, recording button stroke + fill (active) |
| `Color(.systemGray5)` | systemGray5 | unselected language chip background |
| `Color(.systemGray6)` | systemGray6 | text-card / search-bar background (10× uses — dominant) |
| `Color(.systemBackground)` | systemBackground | permission overlay backdrop |
| `Color.black.opacity(0.8)` | — | toast background |

## §2. Recognition-mode colour mapping (semantic mapping)

> This is a **deduplication candidate**. Currently two files duplicate this
> mapping: `RecordingView.swift:567-583` (`modeColor` / `modeLabel`) and
> `TranscriptionDetailView.swift:254-282` (`recognitionModeColor` / `…Label` /
> `…Icon`). They agree today, but having two sources of truth is fragile.

| Mode | Token colour | SF Symbol | Label (zh) |
|---|---|---|---|
| `.online` | `.green` | `cloud.fill` | 在线识别 |
| `.onDevice` | `.yellow` | `iphone.gen1` | 离线识别 |
| `.enhanced` | `.blue` | `cloud.fill.badge.checkmark` | 已在线升级 |
| `.failed` | `.red` | `xmark.shield.fill` | 识别失败 |
| `.none` | `.secondary` | `questionmark.circle` | 未知 |

`RecordingView` currently uses label + colour but **no icon**; `TranscriptionDetailView` uses all three.

## §3. Recording state colour

| State | Token colour |
|---|---|
| Idle / pre-record | `Color.accentColor` (outer ring 0.3 opacity, inner fill 1.0) |
| Recording | `Color.red` (outer ring 1.0, inner fill 1.0, pulse halo 0.1 opacity) |
| Disabled (permission denied) | outer ring `accentColor 0.3`, fill blocked by `.disabled()` |

Shadow on inner button: `radius: 10, x: 0, y: 4, opacity: 0.4` of the active fill colour.

## §4. States covered

- ✅ idle
- ✅ recording
- ✅ disabled (permission denied / out-of-window)
- ✅ loading (LLM processing spinner)
- ✅ error (LLM failed)
- ✅ success (optimised seal)
- ❓ first-use — no special empty/onboarding state in code

## §5. Self-review

- [x] Did I check `design-system/` for existing? — bootstrap
- [x] Rationale? — code extraction only, no new visual rules
- [x] States covered? — see §4
- [x] Provenance? — **inferred** (auto)

## §6. Open questions

1. Should the recognition-mode mapping move out of two view files into `RecognitionModeStyle`?
2. Is `Color(.systemGray6)` worth promoting to a semantic `CardBackground` token?
3. The pulse halo's `Color.red.opacity(0.1)` is a one-off — keep as-is or tokenise?