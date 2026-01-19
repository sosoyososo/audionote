# Implementation Plan: iOS 应用多语言支持

**Branch**: `002-i18n-support` | **Date**: 2026-01-19 | **Spec**: [spec.md](../spec.md)
**Input**: Feature specification from `/specs/002-i18n-support/spec.md`

## Summary

为 AudioNote iOS 应用添加完整的多语言支持。基于现有的 LanguageManager 基础设施，扩展其功能以支持实时语言切换、移除 toast 提示、添加语言选择入口页面，并将所有硬编码字符串替换为本地化字符串。语音识别语言设置与界面语言完全独立。

## Technical Context

**Language/Version**: Swift 5.9 (CLAUDE.md 标准)  
**Primary Dependencies**: SwiftUI, UserDefaults (持久化), Foundation (语言检测)  
**Storage**: UserDefaults (key: `audioNote:language`)  
**Testing**: XCTest  
**Target Platform**: iOS 15.0+  
**Performance Goals**: 语言切换后界面在 500ms 内完成刷新  
**Constraints**: 本地化资源离线可用；语音识别语言独立于界面语言  
**Scale/Scope**: 3 种语言选项，约 50+ 字符串需要本地化

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

本项目 constitution 为模板，无特殊约束。标准 iOS 开发实践适用。

## Project Structure

### Documentation (this feature)

```text
specs/002-i18n-support/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
ios/AudioNote/
├── App/
│   └── AudioNoteApp.swift
├── Utilities/
│   ├── LanguageManager.swift      # 扩展：添加语言切换入口、移除 toast
│   └── LanguageSelectorView.swift # 新建：语言选择 Sheet 页面
├── Views/
│   ├── RecordingView.swift        # 添加语言切换入口
│   └── SharedComponents.swift     # 更新 LocalizedText 使用
├── Resources/
│   ├── en.lproj/
│   │   └── Localizable.strings    # 补充所有缺失的 key
│   └── zh-Hans.lproj/
│       └── Localizable.strings    # 补充所有缺失的 key
└── Supporting Files/
    └── Info.plist
```

**Structure Decision**: 基于现有 iOS 项目结构，新增 `LanguageSelectorView.swift` 视图，其他修改在现有文件中进行。

## Phase 0: Research & Clarifications

### Unknowns to Resolve

1. **语言检测逻辑**: 如何准确检测系统首选语言是否为中文或英文
2. **SwiftUI 实时刷新**: 确认 `@Published` + `@EnvironmentObject` 能否实现实时语言切换
3. **硬编码字符串列表**: 确认所有需要本地化的字符串 key

### Research Tasks

- [Task 1] SwiftUI 语言切换最佳实践
- [Task 2] iOS 系统语言检测 API (Locale.preferredLanguages)
- [Task 3] 现有 Localizable.strings 覆盖范围

### Phase 0 Output

**research.md** (生成中)

## Phase 1: Design

### Entities

1. **AppLanguage** (扩展)
   - `system` - 跟随系统
   - `chinese` - 简体中文
   - `english` - 英文

2. **LanguageManager** (修改)
   - 属性: `currentLanguage: AppLanguage`, `showLanguageChangedToast: Bool` (移除)
   - 方法: `switch(to: AppLanguage)`, `getEffectiveLanguage() -> AppLanguage`
   - 通知: `languageChanged`

3. **LocalizedStrings** (扩展)
   - 约 50+ key-value 对，中英文对照

### Contracts

- 语言选择 Sheet 视图规格 (见 contracts/language-selector.md)

### Quickstart

开发步骤概览:
1. 补充 Localizable.strings 文件
2. 替换所有硬编码字符串为 `.localized`
3. 移除 LanguageManager 中的 toast 逻辑
4. 创建 LanguageSelectorView
5. 在 RecordingView 添加入口按钮
6. 编译测试

## Complexity Tracking

> 本功能不涉及复杂度超标的设计决策。

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| N/A | N/A | N/A |
