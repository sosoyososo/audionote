# 合并 LLM 调用设计文档

## 概述

将录音结束后分别调用 LLM 优化文本和提取标签的两个独立操作，合并为一次 LLM 调用完成。

## 现有结构

| 操作 | 文件 | 方法 | 返回 |
|------|------|------|------|
| 优化文本 | TranscriptionViewModel | `optimizeTranscription()` | 优化后的文本 |
| 提取标签 | AIProcessingService | `processRecord()` | title, summary, tags |

## 设计方案

### 1. LLMService 新增统一方法

**文件**: `ios/AudioNote/Services/LLMService.swift`

新增方法 `optimizeAndProcess()`:
- 调用一次 LLM
- 系统提示词同时包含优化文本和提取元数据两个目的
- 返回统一 JSON 结构

**返回格式**:
```json
{
  "optimizedText": "优化后的完整文本",
  "title": "提取的标题",
  "summary": "提取的摘要",
  "tags": ["标签1", "标签2", "标签3"]
}
```

**提示词设计**:
```
你是一个语音转录文本优化助手和笔记组织助手。原始文本由 iOS Speech SDK 生成，可能存在标点缺失、同音词错误等问题。

请完成以下任务：
1. 优化转录文本，修正标点和同音词错误
2. 为笔记提取标题（简短明了）
3. 生成50-100字的摘要
4. 提取3-5个标签

请严格按照以下JSON格式返回，不要添加任何解释或标记：
{"optimizedText": "...", "title": "...", "summary": "...", "tags": [...]}
```

保留原有的 `optimize()` 和 `process()` 方法，暂不删除。

### 2. 调用时机与数据更新

**文件**: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`

**修改 `stopRecording()` 方法**:
- 检查 `enableLLMOptimization` 设置
- 调用 `llmService.optimizeAndProcess()` 替代原来的 `optimizeTranscription()`
- 更新记录：
  - `optimizedContent` = 原始转录文本
  - `content` = 优化后文本
  - `title` = LLM 返回的标题
  - `summary` = LLM 返回的摘要
  - `tags` = LLM 返回的标签数组

### 3. 重试机制

- LLM 调用失败后自动重试最多 2 次（总共 3 次尝试）
- 3 次都失败时：
  - 记录 `llmProcessingStatus` 设为 `.failed`
  - 保留原始文本（不更新 content）
  - 保留 `optimizedContent` 为 nil

### 4. UI 变化

#### RecordingView

| 状态 | 显示 |
|------|------|
| LLM 调用中 | Loading 指示器 |
| 3次失败后 | 重试按钮 + 失败提示 |
| 成功后 | 文本标注"优化后" |

#### TranscriptionDetailView

| 状态 | 显示 |
|------|------|
| 成功后 | 内容区域标注"优化后"，标题/摘要/标签正常显示 |
| 失败后 | 显示重试按钮 |

### 5. 设置保持不变

现有的"启用录音内容优化"开关（`enableLLMOptimization`）继续控制是否自动调用 LLM。

## 修改文件清单

1. `ios/AudioNote/Services/LLMService.swift` - 新增 `optimizeAndProcess()` 方法
2. `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` - 修改 `stopRecording()` 和相关方法
3. `ios/AudioNote/Views/RecordingView.swift` - 添加 Loading/重试按钮/优化标注
4. `ios/AudioNote/Views/TranscriptionDetailView.swift` - 添加重试按钮和优化标注
5. `ios/AudioNote/Services/AIProcessingService.swift` - 可选清理（移除不再使用的调用）

## 风险与注意事项

- LLM 返回的 JSON 需严格解析，失败时需有降级处理
- 录音期间不应触发 LLM 调用，避免资源竞争
- 保留 `optimizedContent` 字段用于存储原始文本，供用户对比
