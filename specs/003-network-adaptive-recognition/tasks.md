# Tasks: 网络自适应语音识别

**Feature**: `003-network-adaptive-recognition`
**Generated**: 2026-03-18

## Summary

| 指标 | 值 |
|------|-----|
| 总任务数 | 4 |
| 用户故事数 | 3 |
| 并行机会 | 无 |

## MVP Scope

只需实现 User Story 1 即可交付基础功能：
- 在录音开始时检测网络状态
- 有网络 → 在线识别

User Story 2 和 3 可在后续迭代中完成。

---

## Phase 1: Setup

- [ ] T001 创建 NetworkMonitor 网络检测工具类

## Phase 2: Foundational

- [ ] T002 [P] 在 SpeechRecognizer 中集成网络检测逻辑

## Phase 3: User Story 1 - 正常网络下的语音识别 (P1)

**Goal**: 在有网络时使用在线识别模式

**Independent Test**: 在有网络环境下启动录音，观察日志确认使用在线模式

- [ ] T003 [P] [US1] 修改 startRecording() 在开始前检测网络并设置 requiresOnDeviceRecognition

## Phase 4: User Story 2 - 无网络下的语音识别 (P1)

**Goal**: 在无网络时使用离线识别模式

**Independent Test**: 开启飞行模式后启动录音，观察识别是否正常工作

- [ ] T004 [P] [US2] 验证离线识别在无网络环境下正常工作

## Phase 5: User Story 3 - 网络状态变化后的新录音 (P2)

**Goal**: 每次启动录音时重新检测网络状态

**Independent Test**: 完成一次录音后切换网络状态，再次启动录音观察模式变化

- [ ] T005 [US3] 确保每次 startRecording 都重新检测网络（非缓存）

## Dependencies

```
T001 (创建 NetworkMonitor)
    ↓
T002 (集成到 SpeechRecognizer)
    ↓
T003, T004 (US1, US2 - 可并行)
    ↓
T005 (US3)
```

## Parallel Execution

- T003 和 T004 可以并行执行（不同用户故事，但都依赖 T002）
- T001 和 T002 为串行（T002 依赖 T001 的类）

## Implementation Strategy

1. **MVP (T001 + T003)**: 实现核心功能 - 网络检测 + 在线识别
2. **Incremental (T004)**: 添加离线识别支持
3. **Polish (T005)**: 确保每次都重新检测
