# Implementation Plan: 网络自适应语音识别

**Branch**: `003-network-adaptive-recognition` | **Date**: 2026-03-18 | **Spec**: [link](spec.md)

**Input**: Feature specification from `/specs/003-network-adaptive-recognition/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command.

## Summary

在语音识别开始前检测网络状态，自动选择使用在线或离线识别模式：
- 有网络 → 在线识别（更准确）
- 无网络 → 离线识别（保证可用性）
- 录音过程中不切换模式

## Technical Context

**Language/Version**: Swift 5.9
**Primary Dependencies**: Speech Framework, Network Framework (NWPathMonitor)
**Storage**: N/A（纯逻辑修改）
**Testing**: XCTest
**Target Platform**: iOS 16.0+
**Project Type**: iOS Mobile App
**Performance Goals**: 网络检测在 100ms 内完成
**Constraints**: 不影响现有录音功能，不在录音过程中切换模式
**Scale/Scope**: 单功能模块修改

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

本次修改为单文件修改（SpeechRecognizer.swift），不涉及架构变更，无需 Constitution 检查。

## Project Structure

### Documentation (this feature)

```
specs/003-network-adaptive-recognition/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
└── tasks.md            # Phase 2 output
```

### Source Code (repository root)

```
ios/AudioNote/
├── Services/
│   └── SpeechRecognizer.swift    # 需要修改的文件
└── ...
```

## Phase 0: Research

### 技术方案

**iOS 网络检测方案**:

| 方案 | 实现方式 | 优点 | 缺点 |
|------|---------|------|------|
| NWPathMonitor | `Network.framework` | 官方推荐，实时性好 | 需要额外导入 |
| URLSession | 检查特定 URL 可达性 | 简单 | 不够实时 |
| SCNetworkReachability | SystemConfiguration | 老旧 API | 已废弃 |

**推荐方案**: NWPathMonitor

### 实现步骤

1. 在 `SpeechRecognizer` 类中添加网络状态检测
2. 使用 `NWPathMonitor` 实时监听网络变化
3. 在 `startRecording()` 调用前检测当前网络状态
4. 根据网络状态设置 `requiresOnDeviceRecognition`

## Complexity Tracking

本次修改为现有模块的功能增强，不涉及架构变更。

| 变更 | 说明 |
|------|------|
| 新增 Network.framework 依赖 | iOS 系统自带，无需额外安装 |
| 修改 SpeechRecognizer.swift | 添加网络检测逻辑 |
