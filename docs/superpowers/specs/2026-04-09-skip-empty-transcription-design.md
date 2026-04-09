# 跳过空文本转录设计文档

## 概述

录音结束后，如果未识别到有效文本（内容为空或仅包含空白字符），则不保存记录，也不调用大模型。

## 问题

当前录音结束时，即使没有识别到任何语音内容，也会保存记录并调用大模型。这导致：
1. 无意义的记录被保存
2. 大模型收到空文本，可能返回幻觉信息

## 设计方案

### 修改位置

`ios/AudioNote/ViewModels/TranscriptionViewModel.swift`

### 修改逻辑

在 `stopRecording()` 方法中，计算 `contentToSave` 后：

```swift
let trimmedContent = contentToSave.trimmingCharacters(in: .whitespacesAndNewlines)
if trimmedContent.isEmpty {
    // 无有效文本，不保存，不调用LLM
    speechRecognizer.stopRecording()
    isRecording = false
    stopDurationTimer()
    transcribedText = ""
    return
}
```

### 行为变化

| 场景 | 修改前 | 修改后 |
|------|--------|--------|
| 无语音输入 | 保存空记录 + 调用LLM | 不保存，不调用LLM |
| 有语音输入 | 正常保存 + 调用LLM | 正常保存 + 调用LLM |

## 修改文件清单

1. `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` - 在 `stopRecording()` 中添加空文本检查
