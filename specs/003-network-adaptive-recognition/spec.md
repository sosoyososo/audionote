# Feature Specification: 网络自适应语音识别

**Feature Branch**: `003-network-adaptive-recognition`
**Created**: 2026-03-18
**Status**: Draft
**Input**: User description: "在录音开始时检测网络状态，自动选择使用在线或离线语音识别"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - 正常网络下的语音识别 (Priority: P1)

用户在有网络连接的情况下启动语音识别，系统自动选择在线识别模式，提供更准确的识别结果。

**Why this priority**: 在线识别准确性更高，是默认的最佳体验，必须优先保障

**Independent Test**: 在有网络环境下启动录音，观察识别结果是否使用在线模式（通过日志验证）

**Acceptance Scenarios**:

1. **Given** 设备已连接网络，**When** 用户启动语音识别，**Then** 系统使用在线识别模式
2. **Given** 设备已连接网络，**When** 语音识别进行中，**Then** 保持在线模式不切换

---

### User Story 2 - 无网络下的语音识别 (Priority: P1)

用户在无网络连接的情况下启动语音识别，系统自动切换到离线识别模式，确保功能可用。

**Why this priority**: 离线模式保证应用在没有网络时也能使用，是基本的可用性保障

**Independent Test**: 开启飞行模式后启动录音，观察识别是否正常工作

**Acceptance Scenarios**:

1. **Given** 设备未连接网络，**When** 用户启动语音识别，**Then** 系统使用离线识别模式
2. **Given** 设备未连接网络，**When** 语音识别进行中，**Then** 保持离线模式不切换

---

### User Story 3 - 网络状态变化后的新录音 (Priority: P2)

用户完成一次录音后，网络状态发生变化，下次启动录音时系统能正确感知并选择合适的识别模式。

**Why this priority**: 适应用户网络环境动态变化的场景，提供持续的良好体验

**Independent Test**: 在线模式下完成录音 → 切换到飞行模式 → 再次启动录音，观察是否使用离线模式

**Acceptance Scenarios**:

1. **Given** 上次录音使用在线模式，**When** 设备切换到无网络，**Then** 下次录音自动使用离线模式
2. **Given** 上次录音使用离线模式，**When** 设备切换到有网络，**Then** 下次录音自动使用在线模式

---

### Edge Cases

- **网络不稳定时的行为**: 在开始录音前进行一次性网络检测，不在录音过程中切换
- **同时有 WiFi 和蜂窝网络**: 视为有网络，使用在线模式
- **首次启动应用**: 默认检测当前网络状态
- **离线模型未下载**: 当选择离线识别但模型未下载时，回退到在线识别或提示用户

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: 系统必须在用户启动语音识别前检测当前网络状态
- **FR-002**: 系统必须在有网络时使用在线语音识别（`requiresOnDeviceRecognition = false`）
- **FR-003**: 系统必须在无网络时使用离线语音识别（`requiresOnDeviceRecognition = true`）
- **FR-004**: 系统必须在录音进行过程中保持识别模式不变，不进行动态切换
- **FR-005**: 系统必须在每次启动录音时重新检测网络状态，而非使用缓存结果

### Key Entities

- **网络状态**: 标识当前是否可访问网络（在线/离线）
- **识别模式**: 标识当前使用的识别模式（在线/离线）

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% 的语音识别会话在开始时正确选择识别模式
- **SC-002**: 在有网络环境下，识别模式为在线的准确率达到 Apple 官方在线识别的标准
- **SC-003**: 在无网络环境下，应用仍能正常进行语音识别，功能不中断
- **SC-004**: 用户无需手动配置，应用自动选择最优识别模式
