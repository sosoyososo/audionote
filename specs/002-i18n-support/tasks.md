# Tasks: iOS 应用多语言支持

**Input**: Design documents from `/specs/002-i18n-support/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US4)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: 扩展 LanguageManager 基础设施，为多语言功能做准备

- [ ] T001 [P] Extend AppLanguage enum with displayName properties in ios/AudioNote/Utilities/LanguageManager.swift
- [ ] T002 [P] Add getEffectiveLanguage() method to LanguageManager in ios/AudioNote/Utilities/LanguageManager.swift
- [ ] T003 [P] Add detectSystemLanguage() private method to LanguageManager in ios/AudioNote/Utilities/LanguageManager.swift
- [ ] T004 Remove showLanguageChangedToast property and toast logic from LanguageManager in ios/AudioNote/Utilities/LanguageManager.swift

**Checkpoint**: LanguageManager 基础设施准备就绪

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: 核心字符串资源准备完成前，其他用户故事无法完整测试

**CRITICAL**: 必须先完成 US4（本地化字符串），其他故事才能正确测试

- [ ] T005 [P] [US4] Add common.* keys to Localizable.strings files (confirm, cancel, close, etc.) in ios/AudioNote/Resources/en.lproj/Localizable.strings and ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings
- [ ] T006 [P] [US4] Add recording.* keys to Localizable.strings files (title, permission, etc.) in ios/AudioNote/Resources/en.lproj/Localizable.strings and ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings
- [ ] T007 [P] [US4] Add history.* keys to Localizable.strings files (title, empty, delete, etc.) in ios/AudioNote/Resources/en.lproj/Localizable.strings and ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings
- [ ] T008 [P] [US4] Add detail.* keys to Localizable.strings files (edit, save, etc.) in ios/AudioNote/Resources/en.lproj/Localizable.strings and ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings
- [ ] T009 [P] [US4] Add permission.* and error.* keys to Localizable.strings files in ios/AudioNote/Resources/en.lproj/Localizable.strings and ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings
- [ ] T010 [P] [US4] Add language.selector.* keys to Localizable.strings files in ios/AudioNote/Resources/en.lproj/Localizable.strings and ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings

**Checkpoint**: 本地化字符串资源准备就绪

---

## Phase 3: User Story 4 - 所有界面文本本地化 (Priority: P1) MVP

**Goal**: 替换所有硬编码字符串为本地化字符串，实现 100% 文本本地化

**Independent Test**: 切换语言后遍历所有页面，验证所有文本是否正确显示

### Implementation for User Story 4

- [ ] T011 [US4] Replace hardcoded strings with .localized in Views/RecordingView.swift
- [ ] T012 [US4] Replace hardcoded strings with .localized in Views/HistoryListView.swift
- [ ] T013 [US4] Replace hardcoded strings with .localized in Views/TranscriptionDetailView.swift
- [ ] T014 [US4] Replace hardcoded strings with .localized in Views/SharedComponents.swift
- [ ] T015 [US4] Replace hardcoded strings with .localized in Services/SpeechRecognizer.swift
- [ ] T016 [US4] Replace hardcoded strings with .localized in Services/TranscriptionStorage.swift
- [ ] T017 [US4] Replace hardcoded strings with .localized in Models/RecognitionLanguage.swift
- [ ] T018 [US4] Replace hardcoded strings with .localized in Models/TranscriptionRecord.swift

**Checkpoint**: US4 完成 - 所有 UI 文本已本地化，可独立测试验证

---

## Phase 4: User Story 2 - 访问语言设置入口 (Priority: P1)

**Goal**: 创建语言选择 Sheet 页面，并在录音页面添加入口按钮

**Independent Test**: 打开应用 → 点击语言切换按钮 → 弹出语言选择页面 → 验证页面显示

### Implementation for User Story 2

- [ ] T019 [P] [US2] Create LanguageSelectorView in ios/AudioNote/Utilities/LanguageSelectorView.swift
- [ ] T020 [P] [US2] Add globe icon button to RecordingView toolbar in ios/AudioNote/Views/RecordingView.swift
- [ ] T021 [US2] Connect sheet presentation to LanguageSelectorView in ios/AudioNote/Views/RecordingView.swift

**Checkpoint**: US2 完成 - 用户可以找到并打开语言选择入口

---

## Phase 5: User Story 1 - 切换应用界面语言 (Priority: P1)

**Goal**: 用户选择语言后界面立即更新，无需重启

**Independent Test**: 选择"English" → 验证界面变为英文 → 选择"中文" → 验证界面变为中文

### Implementation for User Story 1

- [ ] T022 [US1] Ensure LanguageManager broadcasts language change notification in ios/AudioNote/Utilities/LanguageManager.swift
- [ ] T023 [US1] Verify String.localized extension uses getEffectiveLanguage() in ios/AudioNote/Utilities/LanguageManager.swift
- [ ] T024 [US1] Test language switching works with "Follow System" option
- [ ] T025 [US1] Test system language is non-Chinese/English defaults to English

**Checkpoint**: US1 完成 - 用户可以切换语言，界面实时更新

---

## Phase 6: User Story 3 - 语言设置持久化 (Priority: P2)

**Goal**: 语言设置在应用重启后保持不变

**Independent Test**: 设置语言为英文 → 关闭应用 → 重新打开 → 验证语言仍为英文

### Implementation for User Story 3

- [ ] T026 [US3] Verify UserDefaults persistence works in LanguageManager in ios/AudioNote/Utilities/LanguageManager.swift
- [ ] T027 [US3] Verify LanguageManager loads saved language on app launch in ios/AudioNote/Utilities/LanguageManager.swift

**Checkpoint**: US3 完成 - 语言设置持久化验证通过

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: 收尾工作和整体验证

- [ ] T028 [P] Run xcodegen to regenerate project file
- [ ] T029 [P] Build project with xcodebuild to verify compilation
- [ ] T030 Verify all success criteria from spec.md are met:
  - [ ] SC-001: User can switch language within 3 clicks
  - [ ] SC-002: Language switch updates UI within 500ms
  - [ ] SC-003: 100% of user-visible text is localized
  - [ ] SC-004: Language setting persists after app restart
  - [ ] SC-005: Non-Chinese/English system language defaults to English
  - [ ] SC-006: Speech recognition language is independent of UI language

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS user stories
- **User Stories (Phase 3-6)**: All depend on Foundational (US4) completion
  - US4 (本地化) 必须在其他故事之前完成
  - US2 (入口) 和 US1 (切换) 可以并行
  - US3 (持久化) 可在 US1 完成后验证
- **Polish (Phase 7)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 4 (P1)**: 必须最先完成 - 为其他所有故事提供本地化资源
- **User Story 2 (P1)**: US4 完成后即可开始
- **User Story 1 (P1)**: US4 完成后即可开始
- **User Story 3 (P2)**: US1 完成后验证持久化

### Parallel Opportunities

- Phase 1 的所有 T001-T004 可以并行
- Phase 2 的所有 T005-T010 可以并行
- US4 的 T011-T018 可以按视图文件并行
- US2 的 T019-T021 可以并行（T019 完成后 T020 和 T021 可同时进行）

---

## Parallel Example

```bash
# Phase 1 可以并行执行：
Task: T001 - Extend AppLanguage enum
Task: T002 - Add getEffectiveLanguage() method
Task: T003 - Add detectSystemLanguage() method
Task: T004 - Remove toast logic

# Phase 2 可以并行执行：
Task: T005 - Add common.* keys
Task: T006 - Add recording.* keys
Task: T007 - Add history.* keys
Task: T008 - Add detail.* keys
Task: T009 - Add permission.* keys
Task: T010 - Add language.selector.* keys
```

---

## Implementation Strategy

### MVP First (User Story 4 + User Story 2)

1. 完成 Phase 1: Setup
2. 完成 Phase 2: Foundational (US4 本地化资源)
3. 完成 Phase 3: US4 (本地化字符串替换)
4. 完成 Phase 4: US2 (语言选择入口)
5. **STOP and VALIDATE**: 测试基础多语言功能
6. 部署/演示 MVP

### Incremental Delivery

1. 完成 Setup + Foundational → 基础就绪
2. 添加 US4 → 测试 → 部署 (本地化完成)
3. 添加 US2 → 测试 → 部署 (入口完成)
4. 添加 US1 → 测试 → 部署 (切换功能完成)
5. 添加 US3 → 测试 → 部署 (持久化完成)

---

## Notes

- [P] tasks = 不同文件，无依赖，可并行
- [Story] 标签将任务映射到特定用户故事，便于追踪
- 每个用户故事应可独立完成和测试
- US4 (本地化) 是其他所有故事的基础，必须最先完成
- 验证测试在实现前失败
- 每个任务后提交代码
- 在任何检查点停止以独立验证故事
- 避免：模糊任务、相同文件冲突、破坏独立性的跨故事依赖
