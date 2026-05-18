# Network-Aware Speech Recognition & LLM Processing

**Date**: 2026-05-18
**Status**: Draft

## Overview

当前语音识别和 LLM 处理流程对网络变化的处理不够完善。本设计引入以下核心能力：

1. **录制过程中绝不中断**：无论网络如何变化，录音始终继续，音频文件始终保存
2. **识别模式可视化**：用户始终知道当前使用的是在线识别还是离线识别
3. **事后升级识别**：离线识别完成后，网络恢复时可自动/手动升级为在线识别
4. **LLM 自动处理**：识别成功后自动触发 LLM 信息提取，无网时等待网络恢复
5. **网络恢复自动重试**：网络从无到有时自动处理 pending 的识别升级和 LLM 任务

## Data Model

### TranscriptionRecord 新增字段

```swift
enum RecognitionMode: String, Codable {
    case online      // 在线服务端识别
    case onDevice    // 设备端离线识别
    case enhanced    // 从离线/失败升级到在线识别成功
    case failed      // 识别失败
}

// TranscriptionRecord 新增：
var recognitionMode: RecognitionMode?  // 识别模式，nil = 未设置（旧数据）
```

### LLMStatus 保持不变

`llmProcessingStatus: LLMStatus?` 已存在（nil/pending/processing/completed/failed），无需修改。

## Architecture

### Component Responsibilities

```
NetworkMonitor (基础设施)
├── App 启动即 startMonitoring()
├── checkConnectivity() — 同步查询
├── onStatusChange 回调 — 供 VM 监听恢复
└── 修复: isConnected 初始值使用 lastKnownState 或等待首个 path 更新

SpeechRecognizer (识别层)
├── startRecording() — 根据网络选模式，返回 streaming text
├── recognizeFromFile(url:) — 用 SFSpeechURLRecognitionRequest 重识别
├── recognitionMode: RecognitionMode — 当前/最近一次使用的模式
└── 录制期间网络变化仅 log，不切换

TranscriptionViewModel (编排层)
├── stopRecording() → save → assess → enhance → LLM
├── networkDidRecover() → auto-process pending items
├── reRecognizeOnline(recordId:) — 手动升级入口
├── retryLLM(recordId:) — 手动 LLM 重试
└── processWithLLM() 重试区分 .offline（不重试）

AIProcessingService (批量处理)
├── processPendingRecords() — 仅在线时执行
└── 网络恢复时被 VM 触发

LLMService (LLM 调用)
├── process/optimize/optimizeAndProcess — 入口 guard 已加入
├── .offline 错误不重试
└── 其他错误按既有重试策略
```

## Flow: Recording → Recognition → Enhancement → LLM

### Phase 1: Recording (实时)

```
startRecording()
  ├─ 保存音频到文件 (AudioRecorderService)
  ├─ 检查网络
  │   ├─ online  → requiresOnDeviceRecognition = false
  │   └─ offline → requiresOnDeviceRecognition = true
  ├─ 记录 recognitionMode
  ├─ UI 显示模式标记 (●在线识别 / ○离线识别)
  └─ 启动 streaming 识别
       ├─ partial results → 实时显示
       ├─ error → 记录但不中断录音
       └─ 完成 → 获得最终文本 + 模式标记
```

### Phase 2: Post-Recording (stopRecording 内)

```
stopRecording()
  ├─ 获取最终文本
  ├─ 空内容检查 (已有)
  ├─ 保存 TranscriptionRecord
  │   └─ 包含 recognitionMode 字段
  ├─ assess recognition quality:
  │   ├─ .online 成功 → 展示文本，模式标记: ●在线识别
  │   │   └─ → Phase 3 (LLM)
  │   ├─ .onDevice 成功 → 展示文本，模式标记: ○离线识别
  │   │   ├─ 现在有网 → 自动 online re-recognition (后台)
  │   │   │   └─ 成功 → 覆盖文本，模式升级为 .enhanced
  │   │   └─ 现在无网 → 标记 pending + Phase 3 等待
  │   └─ .failed → 展示错误，模式标记: ❌识别失败
  │       ├─ 现在有网 → 自动 retry from file
  │       └─ 现在无网 → 等待网络恢复
  └─ → Phase 3 (LLM) if recognition has text
```

### Phase 3: LLM Processing

```
processWithLLM (条件: 有文本内容 + 用户开启 LLM 优化)
  ├─ 检查网络
  │   ├─ online → 调用 llmService.optimizeAndProcess()
  │   │   ├─ 成功 → 更新 record (title/summary/tags/optimizedText)
  │   │   │   └─ UI: 显示结构化结果，模式: 🟢在线识别
  │   │   └─ 失败(.offline) → 标记 llmProcessingStatus = .failed，不重试
  │   │   └─ 失败(其他) → 重试 3 次
  │   └─ offline → 标记 llmProcessingStatus = .failed，原因 offline
  │       └─ 监听网络恢复后自动重试
  └─ 更新 UI
```

### Phase 4: Network Recovery Auto-Processing

```
NetworkMonitor.onStatusChange: disconnected → connected
  └─ TranscriptionViewModel.networkDidRecover()
       ├─ 扫描 records where:
       │   ├─ llmProcessingStatus == nil → processPendingRecords()
       │   ├─ recognitionMode == .onDevice && 未增强 → 自动在线升级
       │   ├─ recognitionMode == .failed → 重试识别
       │   └─ llmProcessingStatus == .failed (offline 导致) → 重试 LLM
       └─ 批量处理，逐个更新 UI
```

## UI Visualization

### RecordingView (录音中)

```
   ┌─────────────────────────────────┐
   │  00:15.3                        │
   │  正在录制...                     │
   │                                 │
   │  ●在线识别  (或 ○离线识别)        │  ← 新增: 模式标记
   │                                 │
   │  实时文本流显示...                │
   └─────────────────────────────────┘
```

录音结束后，模式标记保留在文本区域上方直到 LLM 处理完成。

### TranscriptionDetailView (详情页)

```
   ┌─────────────────────────────────┐
   │ 标题: 今天会议纪要                │  ← LLM 生成
   │                                 │
   │ 🟢在线识别  (颜色图标区分模式)     │  ← 新增: 识别模式标签
   │   在线 / ○离线 / 🔄已升级 / ❌失败 │
   │                                 │
   │ 摘要: 讨论了Q2产品规划...          │  ← LLM 生成
   │                                 │
   │ 标签: [工作] [规划] [产品]        │  ← LLM 生成
   │                                 │
   │ ┌─ 转录文本 ──────────────────┐ │
   │ │ (优化后或原始文本内容)        │ │
   │ └────────────────────────────┘ │
   │                                 │
   │ [在线升级识别] ← 仅离线/失败时    │  ← 新增: 操作按钮
   │ [重新 LLM 处理] ← 仅失败时       │  ← 新增: 操作按钮
   └─────────────────────────────────┘
```

### Recognition Mode 视觉规范

| 模式 | 图标 | 颜色 | 文案 |
|------|------|------|------|
| online | `wifi` | 绿色 | 在线识别 |
| onDevice | `antenna.radiowaves.left.and.right.slash` | 黄色 | 离线识别 |
| enhanced | `arrow.up.doc` | 蓝色 | 已在线升级 |
| failed | `exclamationmark.triangle` | 红色 | 识别失败 |

## NetworkMonitor Fixes

### 问题: isConnected 初始值竞态

`isConnected` 默认 `true`，但 NWPathMonitor 的第一个 path 更新是异步的。如果在更新到达前调用 `checkConnectivity()` 可能得到错误的 true。

### 修复

```swift
private(set) var isConnected: Bool?
// nil = 尚未收到首个 path 更新

func checkConnectivity() -> Bool {
    isConnected ?? true  // 首次更新前假定在线，让首次体验最优
}
```

或者在 `startMonitoring()` 中同步获取当前 path：

```swift
let currentPath = monitor.currentPath
isConnected = currentPath.status == .satisfied
```

采用 `monitor.currentPath` 同步初始化，确保首次调用即准确。

## Error Handling

### Recognition Errors 处理策略

| Error | Recording 行为 | Post-hoc 行为 |
|-------|---------------|---------------|
| notAvailable | 阻止录音 | 提示不可用 |
| notAuthorized | 阻止录音 | 引导设置 |
| audioEngineFailed | 中断录音，保存已有音频 | 尝试从文件重识别 |
| recognitionFailed | 继续录音（音频仍保存） | 从文件重识别 |
| noSpeechDetected | 继续录音 | 不处理（无内容） |
| 网络中断（在线模式中） | 继续录音，log 错误 | 从文件重识别 |

### LLM Errors 处理策略

| Error | 行为 |
|-------|------|
| offline | 不重试，标记 failed，等网络恢复 |
| networkError | 重试 3 次（指数退避） |
| httpError 5xx | 重试 3 次 |
| httpError 4xx | 不重试 |
| tokenNotSet | 不重试 |

## Constraints & Edge Cases

1. **录音期间不切换识别模式**：SFSpeechRecognizer 不支持运行时切换，切换需重建 task 会丢失上下文。事后从文件升级是更好的路径。

2. **音频文件是安全网**：所有场景都依赖已保存的 m4a 文件进行重试/升级。AudioRecorderService 已实现，无需改动。注意 `SFSpeechURLRecognitionRequest` 对 on-device 识别有约 1 分钟时长限制，在线识别无此限制。

3. **自动 > 手动**：网络恢复后自动处理 pending 任务，但用户始终可以手动触发。

4. **LLM 依赖网络但不阻塞识别**：识别和 LLM 是解耦的两个阶段。离线识别结果立即可用，LLM 处理等待网络恢复。

5. **用户编辑保护**：如果用户手动编辑过转录文本，自动在线升级不会覆盖已编辑内容。通过对比 `content == originalRecognizedText` 判断。

6. **网络恢复防抖**：NWPathMonitor 可能在网络切换时短时间内触发多次回调。`networkDidRecover()` 加入 2 秒防抖，避免重复处理。

7. **Phase 2 vs Phase 4 的自动升级不冲突**：Phase 2 是 stopRecording 后立即执行（如果当时有网）；Phase 4 是后续网络恢复时执行。同一条记录只升级一次（通过 recognitionMode 已变为 .enhanced 来判断）。

8. **LLM 失败原因追踪**：LLMStatus 已有 .failed，不再单独增加 reason 字段。通过检查失败时的 NetworkMonitor 状态判断是否需要网络恢复后重试。

## Files to Modify

| File | Change |
|------|--------|
| `NetworkMonitor.swift` | 修复初始值竞态，新增 onStatusChange 回调 |
| `SpeechRecognizer.swift` | 新增 RecognitionMode 跟踪，新增 recognizeFromFile() |
| `TranscriptionRecord.swift` | 新增 recognitionMode 字段 |
| `TranscriptionViewModel.swift` | 重写 stopRecording 流程，新增增强/恢复逻辑 |
| `AIProcessingService.swift` | 已完成（guard 已添加） |
| `LLMService.swift` | 已完成（guard 已添加，retry 已修改） |
| `RecordingView.swift` | 新增识别模式标记 UI |
| `TranscriptionDetailView.swift` | 新增识别模式标签 + 操作按钮 |
