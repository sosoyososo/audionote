# Feature Specification: iOS 语音转文字

**Feature Branch**: `001-voice-transcription`
**Created**: 2025-01-18
**Updated**: 2025-01-18
**Status**: Draft
**Input**: User description: "创建 iOS 语音转文字 app，使用 SwiftUI + Speech SDK，核心 MVP 功能：语音识别、识别结果管理、文本分享和拷贝，无需登录"

## User Scenarios & Testing

### User Story 1 - 语音录制与实时转文字 (Priority: P1)

用户打开应用后，可以点击录音按钮开始录制语音，选择语音语言（中文/英文），系统实时将语音转换为文字并显示。

**Why this priority**: 这是应用的核心功能，用户使用应用的主要目的就是语音转文字，没有此功能应用毫无价值。

**Independent Test**: 可以通过模拟录音操作，验证转写结果是否正确显示。

**Acceptance Scenarios**:

1. **Given** 用户打开应用，**When** 选择语言后点击开始录音按钮，**Then** 应用开始录音并显示录音状态指示。
2. **Given** 正在录音中，**When** 用户说话，**Then** 屏幕上实时显示识别出的文字。
3. **Given** 录音完成，**When** 点击停止按钮，**Then** 录音停止，最终转写结果保存并显示。

---

### User Story 2 - 查看历史转写记录 (Priority: P1)

用户可以查看之前所有的转写记录列表，点击可查看详情。

**Why this priority**: 用户需要回顾之前的转写内容，这是基本的使用场景。

**Independent Test**: 可以通过创建多条转写记录，验证列表是否正确显示历史记录。

**Acceptance Scenarios**:

1. **Given** 用户有多条转写记录，**When** 打开历史记录页面，**Then** 显示按时间倒序排列的记录列表。
2. **Given** 记录列表不为空，**When** 点击某条记录，**Then** 跳转到详情页显示完整内容。
3. **Given** 没有转写记录，**When** 打开历史记录页面，**Then** 显示空状态提示。

---

### User Story 3 - 复制转写文本 (Priority: P2)

用户可以将转写文本复制到剪贴板，方便在其他应用中使用。

**Why this priority**: 复制功能是文本处理的常用需求，提升用户效率。

**Independent Test**: 可以通过点击复制按钮，验证文本是否成功复制到剪贴板。

**Acceptance Scenarios**:

1. **Given** 用户查看了转写详情，**When** 点击复制按钮，**Then** 文本被复制到剪贴板并显示成功提示。
2. **Given** 剪贴板已有内容，**When** 点击复制按钮，**Then** 剪贴板内容被新文本替换。

---

### User Story 4 - 分享转写文本 (Priority: P2)

用户可以通过系统分享功能将转写文本分享到其他应用。

**Why this priority**: 分享是移动端的重要交互模式，方便用户将结果发送到微信、邮件等。

**Independent Test**: 可以通过点击分享按钮，验证系统分享面板是否正确弹出。

**Acceptance Scenarios**:

1. **Given** 用户查看了转写详情，**When** 点击分享按钮，**Then** 弹出系统分享面板。
2. **Given** 分享面板已打开，**When** 选择目标应用并完成分享，**Then** 文本被发送到目标应用。

---

### User Story 5 - 删除转写记录 (Priority: P3)

用户可以删除不需要的转写记录。

**Why this priority**: 管理历史记录的需求，保持记录列表整洁。

**Independent Test**: 可以通过删除操作，验证记录是否从列表中移除。

**Acceptance Scenarios**:

1. **Given** 历史记录列表不为空，**When** 用户删除某条记录，**Then** 该记录从列表中移除。
2. **Given** 删除记录后，**When** 记录数为零，**Then** 显示空状态提示。

---

### Edge Cases

- 麦克风权限被拒绝时如何引导用户开启？
- 录音过程中来电如何处理？
- 网络不可用时语音识别如何工作？
- 转写内容为空时如何处理？
- 语音识别无结果返回时如何处理？

## Requirements

### Functional Requirements

- **FR-001**: 系统 MUST 提供录音功能，支持开始、暂停、停止操作。
- **FR-002**: 系统 MUST 提供语言选择功能，支持中文和英文，中文默认选中。
- **FR-003**: 系统 MUST 使用设备语音识别能力将语音实时转换为文字。
- **FR-004**: 系统 MUST 在录音过程中实时显示识别出的文字内容。
- **FR-005**: 系统 MUST 保存每次转写的完整内容和时间戳。
- **FR-006**: 用户 MUST 能查看历史转写记录列表，按时间倒序排列。
- **FR-007**: 用户 MUST 能查看单条转写记录的详细内容。
- **FR-008**: 用户 MUST 能将转写文本复制到系统剪贴板。
- **FR-009**: 用户 MUST 能通过系统分享面板分享转写文本。
- **FR-010**: 用户 MUST 能删除不需要的转写记录。
- **FR-011**: 系统 MUST 在首次使用时请求麦克风权限。
- **FR-012**: 系统 MUST 处理麦克风权限被拒绝的情况。
- **FR-013**: 系统 MUST 记录详细的日志用于调试语音识别过程。

### Key Entities

- **TranscriptionRecord**: 表示一条转写记录
  - `id`: 唯一标识符
  - `content`: 转写的完整文本
  - `createdAt`: 创建时间
  - `duration`: 录音时长（可选）
  - `language`: 识别语言

- **RecognitionLanguage**: 识别语言选项
  - `zh-CN`: 中文
  - `en-US`: 英文

## Success Criteria

### Measurable Outcomes

- **SC-001**: 用户可以在 30 秒内完成一次完整的语音转文字操作。
- **SC-002**: 语音识别准确率达到 90% 以上（在标准普通话发音条件下）。
- **SC-003**: 90% 的用户能成功完成首次录音转写。
- **SC-004**: 文本复制和分享操作的成功率达到 99% 以上。
- **SC-005**: 用户满意度评分达到 4.0 分以上（满分 5 分）。

## Assumptions

- 用户使用标准普通话或英语进行语音输入。
- 设备支持 Speech Framework（iOS 10+）。
- 录音环境噪音在合理范围内。
- 用户授权麦克风权限后应用正常工作。

## Out of Scope

- 用户登录和账户系统。
- 云端同步和跨设备共享。
- 语音翻译功能。
- 实时翻译。
- 音频文件导入。
- 高级编辑功能。
- AI 分析和摘要生成。
