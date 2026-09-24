# AI Optimization By Default — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the `audioNote:enableLLMOptimization` toggle from Settings UI and from `assessAndEnhance`. Move consent disclosure to Provider creation. Improve the LLM prompt for homophone-error robustness.

**Architecture:** ADR-0004 collapses the LLM gate from 3 conditions to 2 (`ProviderProfileStore.shared.active != nil` + `NetworkMonitor.shared.checkConnectivity()`). The "data flow" copy moves from a per-recording toggle into `ProfileDetailView` create mode. The LLM prompt gains homophone anchors and over-correction guards.

**Tech Stack:** Swift 6.3, SwiftUI, OpenAI-compatible `/chat/completions`

**Pre-existing changes (already in working tree, not covered in tasks):** None.

---

## File Structure

| File | Responsibility |
|------|---------------|
| `LLMService.swift` | Prompt text update only |
| `SettingsView.swift` | Delete optimize-toggle section; move Test Connection button |
| `SettingsViewModel.swift` | Delete `canEnableOptimization` |
| `ProfileDetailView.swift` | Add data-flow disclosure Section in create mode |
| `TranscriptionViewModel.swift` | Simplify `assessAndEnhance` + remove inline reads |
| `ProviderProfileStore.swift` | Drop the `set false` line from `runLegacyTokenMigration` |
| `Localizable.strings` (en + zh-Hans) | Drop `Settings.LLM.Optimize.Title/Header/Footer`; add `ProfileDetail.DataFlow.*` keys |
| `GLOSSARY.md` | Drop `enableLLMOptimization` entry |

---

### Task 1: Update LLM prompt

**Files:**
- Modify: `ios/AudioNote/Services/LLMService.swift:107-118`

- [ ] **Step 1: Replace `optimizeAndProcessPrompt`**

Replace the entire `optimizeAndProcessPrompt` string with:

```swift
private static let optimizeAndProcessPrompt = """
你是一个语音转录文本优化助手和笔记组织助手。原始文本由 iOS Speech SDK 生成，可能存在以下问题：

- 标点缺失或错误
- 同音/近音词错误（例如 "语音" → "200题"、"摘要" → "简要"、"转录" → "转入"、"会议" → "回议"）
- 重复词、无意义语气词（"嗯"、"那个"、"然后那个"等）

请完成以下任务：

1. 优化转录文本：
   - 修正明显的标点和同音词错误，根据上下文推断正确用词
   - 不要翻译，保留原始语言（中文录音保持中文）
   - 不要过度修改用户措辞；不确定的内容保留原文
   - 保留原始语义和口语化风格
2. 为笔记提取标题（简短明了，8-20 字）
3. 生成 50-100 字摘要
4. 提取 3-5 个标签，每个标签附带 0.0-1.0 相关性分数（1.0=高度相关，0.0=边缘相关），按分数从高到低排序

请严格按照以下 JSON 格式返回，不要添加任何解释或 markdown 标记：
{"optimizedText": "...", "title": "...", "summary": "...", "tags": [{"name": "...", "score": 0.0}, ...]}
"""
```

Schema is **unchanged** (ADR-0002). Only the system-prompt text changes.

- [ ] **Step 2: Commit**

```bash
git add ios/AudioNote/Services/LLMService.swift
git commit -m "feat(llm): improve prompt with homophone anchors + over-correction guard"
```

---

### Task 2: Add data-flow disclosure to ProfileDetailView (create mode)

**Files:**
- Modify: `ios/AudioNote/Views/ProfileDetailView.swift`
- Modify: `ios/AudioNote/Resources/en.lproj/Localizable.strings`
- Modify: `ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings`

- [ ] **Step 1: Add localization keys**

In both `Localizable.strings` files, add:

```strings
// en
"ProfileDetail.DataFlow.Title" = "Data flow";
"ProfileDetail.DataFlow.Body" = "Once you save this Provider, transcribed text from your recordings will be sent to it for optimization (text cleanup / title / summary / tags).\n\nRaw audio continues to be processed only by Apple (on-device or Apple Cloud recognition) and is never sent to this Provider.\n\nIf you do not want text to leave the device, do not configure a Provider — recordings will still be saved with only local recognition applied.";

// zh-Hans
"ProfileDetail.DataFlow.Title" = "数据流向";
"ProfileDetail.DataFlow.Body" = "保存该 Provider 后,录音转成的文本将发送给该 Provider 用于优化(文本整理 / 标题 / 摘要 / 标签)。\n\n原始音频始终只与 Apple 通讯(设备本地识别或 Apple Cloud 识别),不会发送给该 Provider。\n\n如不希望文本离开本机,请不要配置 Provider —— 此时录音文本仅做本地识别与保存。";
```

(Adjust line breaks / escaping per `.strings` file conventions; use `\n` literal in the value.)

- [ ] **Step 2: Render the disclosure in create mode**

In `ProfileDetailView`, inside `body`'s top-level `Form { ... }`, **only when
`mode == .create`**, prepend this Section before the existing Provider /
Auth / Test sections:

```swift
if case .create = mode {
    Section {
        Text("ProfileDetail.DataFlow.Body".localized)
            .font(.footnote)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    } header: {
        Text("ProfileDetail.DataFlow.Title".localized)
    }
}
```

If the existing `Form` body structure doesn't allow easy mode-switching,
read `mode` from the view's existing state (the view already branches on
`mode` for `ToolbarItem`s).

- [ ] **Step 3: Commit**

```bash
git add ios/AudioNote/Views/ProfileDetailView.swift \
        ios/AudioNote/Resources/en.lproj/Localizable.strings \
        ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "feat(profile): add data-flow disclosure on Provider setup"
```

---

### Task 3: Remove the Settings toggle + move Test Connection

**Files:**
- Modify: `ios/AudioNote/Views/SettingsView.swift`
- Modify: `ios/AudioNote/ViewModels/SettingsViewModel.swift`
- Modify: `ios/AudioNote/Resources/en.lproj/Localizable.strings`
- Modify: `ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings`

- [ ] **Step 1: Drop `optimizeEnabled` @State**

Remove from `SettingsView`:

```swift
@State private var optimizeEnabled: Bool = false
```

- [ ] **Step 2: Delete the "优化开关 + 测试连接" Section**

Delete the entire Section at lines 40-64 (the one with the Toggle +
"Settings.LLM.Profile.Test" Button). Keep its surrounding logic.

- [ ] **Step 3: Add Test Connection into the Provider profiles Section**

In the existing "Provider profiles" Section's footer (or as the last row
of the section), add a Test Connection button:

```swift
Button("Settings.LLM.Profile.Test".localized) {
    viewModel.testActiveConnection()
}
.disabled(viewModel.activeProfile == nil || viewModel.isPinging)
```

Place it after the existing `profileRow(profile)` list. Keep its existing
behavior — no new state needed.

- [ ] **Step 4: Drop `canEnableOptimization` from SettingsViewModel**

Delete the property:

```swift
var canEnableOptimization: Bool { ... }
```

(There's no caller left after Step 2.)

- [ ] **Step 5: Drop obsolete localization keys**

In both `Localizable.strings` files, remove:

```strings
"Settings.LLM.Optimize.Title"
"Settings.LLM.Optimize.Header"
"Settings.LLM.Optimize.Footer"
```

- [ ] **Step 6: Commit**

```bash
git add ios/AudioNote/Views/SettingsView.swift \
        ios/AudioNote/ViewModels/SettingsViewModel.swift \
        ios/AudioNote/Resources/en.lproj/Localizable.strings \
        ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "feat(settings): drop optimize toggle; move Test Connection into profiles section"
```

---

### Task 4: Simplify `assessAndEnhance` + remove UserDefaults reads

**Files:**
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`
- Modify: `ios/AudioNote/Services/ProviderProfileStore.swift`
- Modify: `docs/GLOSSARY.md`

- [ ] **Step 1: Rewrite `assessAndEnhance`**

Replace the body of `assessAndEnhance(record:originalText:)`
(currently at line 236):

```swift
private func assessAndEnhance(record: TranscriptionRecord, originalText: String) async {
    switch record.recognitionMode {
    case .online:
        await processWithLLM(recordId: record.id, originalText: originalText)

    case .onDevice:
        if NetworkMonitor.shared.checkConnectivity() {
            await processWithLLM(recordId: record.id, originalText: originalText)
        }
        // offline: do nothing; raw text already saved

    case .failed:
        if NetworkMonitor.shared.checkConnectivity() {
            await retryRecognitionFromFile(recordId: record.id)
        }

    default:
        break
    }
}
```

The `let optimizationEnabled = UserDefaults.standard.bool(...)` line is gone.

- [ ] **Step 2: Drop the inline read in `retryRecognitionFromFile`**

In the same file, inside `retryRecognitionFromFile` (around line 336), delete:

```swift
let optimizationEnabled = UserDefaults.standard.bool(forKey: "audioNote:enableLLMOptimization")
if optimizationEnabled {
    await processWithLLM(recordId: record.id, originalText: text)
}
```

Replace with:

```swift
await processWithLLM(recordId: record.id, originalText: text)
```

(`processWithLLM` itself short-circuits on no Provider / no network, so
the read wasn't doing anything but guarding an already-guarded call.)

- [ ] **Step 3: Drop the UserDefaults write in `runLegacyTokenMigration`**

In `ios/AudioNote/Services/ProviderProfileStore.swift:146`, delete the
line:

```swift
defaults.set(false, forKey: "audioNote:enableLLMOptimization")
```

Leave the rest of the migration (`removeObject(forKey: Keys.legacyToken)`
and the `needsProviderSetup` flip) intact.

- [ ] **Step 4: Update GLOSSARY.md**

Delete the entry:

```markdown
| **enableLLMOptimization** | `UserDefaults` key `audioNote:enableLLMOptimization` | Read at `assessAndEnhance:234` and elsewhere. **Boolean UserDefaults, not a Settings field** — it's an old shortcut |
```

(And the matching row in the "SettingsViewModel" area if present.)

- [ ] **Step 5: Commit**

```bash
git add ios/AudioNote/ViewModels/TranscriptionViewModel.swift \
        ios/AudioNote/Services/ProviderProfileStore.swift \
        docs/GLOSSARY.md
git commit -m "refactor: drop enableLLMOptimization gate; LLM runs when Provider+online"
```

---

### Task 5: End-to-end verification on iPhone Air simulator

**Files:**
- Build: `ios/AudioNote.xcodeproj`
- Simulator: iPhone Air UDID from `~/.claude/projects/-Users-karsa-proj-audionote/memory/ios-device-registry.md`

- [ ] **Step 1: Build**

```bash
xcodebuild -project ios/AudioNote.xcodeproj -scheme AudioNote \
           -destination 'platform=iOS Simulator,name=iPhone Air' build 2>&1 | tail -30
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 2: Install fresh (no Provider, no legacy key)**

```bash
xcrun simctl uninstall booted <bundle-id> || true
xcrun simctl install booted <build-output-path>
xcrun simctl launch booted <bundle-id>
```

(If a build-output path is needed, pipe from `xcodebuild -showBuildSettings`.)

- [ ] **Step 3: Manual scenario matrix**

Run through this matrix in the simulator. For each row, verify the
expected behavior matches.

| # | Scenario | Expected |
|---|---|---|
| 1 | Open Settings tab | No toggle visible. Profile section + Status section + Test Connection button visible |
| 2 | No Provider → record (online) | Recording saves with raw text. No LLM call (`processWithLLM` returns early on `active == nil`). Detail view shows raw text + no title/summary/tags |
| 3 | Add a Provider (active) → record (online) | LLM call fires. Detail view shows optimized text + title + summary + tags |
| 4 | Add Provider (active) → record (offline via Airplane mode) | Recording saves with raw text; `llmProcessingStatus = .failed`. When Airplane mode is disabled, network-recovery task auto-runs `processWithLLM` (existing behavior, see `networkDidRecover`) |
| 5 | Add Provider → re-record with recognition forced to fail | `retryRecognitionFromFile` fires once |
| 6 | ProfileDetailView create mode | Top section "数据流向说明" / "Data flow" present with the three bullets |
| 7 | Quit + relaunch app | Old `audioNote:enableLLMOptimization` UserDefaults value (if any) is harmless; no crash, no toggle reappears |
| 8 | Reset Provider (delete + recreate) | Test Connection button works, returns success/failure as before |

- [ ] **Step 4: Final commit (if any verification-driven fixups)**

```bash
git add -A
git commit -m "fix: address issues found during end-to-end verification"
```

(Empty commit is fine if no fixups needed.)

---

## Done when

All four tasks above are checked off, simulator scenarios 1-8 pass, and
no references to `enableLLMOptimization` / the toggle remain in the
codebase (`grep -R enableLLMOptimization ios/` should return only commit
history references, not active code).