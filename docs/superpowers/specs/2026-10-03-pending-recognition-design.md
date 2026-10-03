# 待识别（pending recognition）设计

| Field | Value |
|---|---|
| **Status** | PROPOSED |
| **Date** | 2026-10-03 |
| **Supersedes** | — |
| **Author** | — |
| **Related ADR** | ADR-0001（需新写 ADR-0004 扩展其 switch） |

## 1. 问题

飞行模式下录音：计时器正常走、`.m4a` 确实写进了 Files app 的 `AudioNote/` 目录、但**列表里没有对应记录**。录音录进去了却被静默丢弃。

### 1.1 根因（已在当前 `main` 复核）

四步链条，最后一步是**已经算对了却扔掉**：

| # | 位置 | 发生什么 |
|---|---|---|
| 1 | `SpeechRecognizer.swift:118-122` | 离线时**无条件**设 `requiresOnDeviceRecognition = true`，从不查 `speechRecognizer.supportsOnDeviceRecognition`。`zh-CN` 离线模型未预下载 → 请求立即失败 |
| 2 | `SpeechRecognizer.swift:189-196` | 错误回调只设 `recognitionError`，**既不 `continuation.yield` 也不 `continuation.finish()`** → `AsyncStream` 永远挂着，`partialText` 恒为空 |
| 3 | `SpeechRecognizer.swift:253-255` | `recognitionError != nil && finalText.isEmpty` → `recognitionMode = .failed`（**这一步是对的**） |
| 4 | `TranscriptionViewModel.swift:195-202` | VM 独立复算：`hasRecognitionError && trimmedContent.isEmpty` → `mode = .failed`（**也是对的**） |
| 5 | **`TranscriptionViewModel.swift:210-214`** | `trimmedContent.isEmpty` → `return`。**record 从未创建、从未落盘**。`:203` 刚算出的 `.failed` 被丢弃 |
| 6 | `SpeechRecognizer.swift:234` | 但 `audioRecorder?.finishRecording()` 早调过了 → **孤立 `.m4a` 留在磁盘上，App 里看不见** |

第 4 步和第 5 步相邻：**判据已经算出来了，就差没用它。**

### 1.2 已排除的路径

- **A** — `SpeechRecognizer.swift:90` 的 `isAvailable == false` throw。排除：用户看到计时器在走，说明没 throw。
- **C** — `NetworkMonitor` 飞行模式误报有网。排除：裸 `NWPathMonitor`，无 interface 过滤，飞行模式必然 `.unsatisfied`。

**置信度高但非直证** — 未拿到真实 error code（设备走 `localNetwork` 非 USB，飞行模式一开 `devicectl` 即断连）。代码路径 + 用户三个观察推出来的。§4 的修复 1 本身就是这条的确认手段：修完后离线录音应当**当场被拦下并给出明确文案**，而不是录完才失败。

## 2. 目标

1. 离线且当前语言不支持离线识别时，**在开始录音前**就告诉用户，不让用户白录。
2. 其他一切导致「有录音、无识别结果」的情况，record **必须落盘**，并在 UI 上可见。
3. 网络恢复后自动跑完：重新识别 → 大模型 → 算笔记相关度。

## 3. 非目标

- 不改 `assessAndEnhance` 三 case dispatch 的**形状**（ADR-0001 §30 锁死）。只按其规定**新增一个 switch arm**。
- 不给 `TranscriptionRecord` 加字段。
- 不做重试上限 / 退避 / 降级策略。
- 不做独立「待识别」页面、筛选片、置顶分组。
- 不清理磁盘上**已经**存在的孤立 `.m4a`（无 record 可挂靠，无从判断归属）。

## 4. 设计

### 4.1 修复 1 — 离线前拦下（`SpeechRecognizer.startRecording`）

离线时先查 `supportsOnDeviceRecognition`。为 `false`（`zh-CN` 未下载离线模型即此情况）则**立即 throw，不开始录音**：

```swift
let useOnDeviceRecognition = !NetworkMonitor.shared.checkConnectivity()
if useOnDeviceRecognition && !speechRecognizer.supportsOnDeviceRecognition {
    recognitionError = .onDeviceUnsupported(currentLanguage)
    throw SpeechRecognitionError.onDeviceUnsupported(currentLanguage)
}
recognitionMode = useOnDeviceRecognition ? .onDevice : .online
```

`SpeechRecognitionError` 新增一个 case，带 `errorDescription`，`RecordingView` 已经会把它显示到 `errorMessage`（`startRecording` catch 块，`:176`）。

同时修 §1.1 第 2 步——错误回调不 `finish()` 导致 `AsyncStream` 永久悬挂：加 `continuation.finish()`。这不是本次 bug 的直接成因（`stopRecording` 会 cancel task），但它让 `partialText` 能在失败后拿到最后的部分结果，减少进入 `.pending` 的概率。

### 4.2 修复 2 — 不丢弃 record（`TranscriptionViewModel.stopRecording`）

`:210` 的空文本检查改为**分流**，而不是无条件 `return`：

```swift
// 空白判定（trim 后）
if trimmedContent.isEmpty {
    // 用户真的什么都没说 → 照旧丢弃（保留 2026-04-09 spec 的意图）
    if mode != .failed { return }
    // mode == .failed → 识别器挂了但用户可能说了话 → 存下来
    // 见 §4.3：判据精确，不需音频时长/文件大小启发式
}
```

record 用 `mode = .pending` 落盘，`content = ""`。

**判据为什么是免费的** — `mode == .failed` 的定义已经是「识别器报错 **且** 没吐出文字」（`:195`）。用户真沉默但识别器没报错时，`:201` 落到 `speechRecognizer.recognitionMode`（`.onDevice` / `.online`），**不是 `.failed`**，照旧走 `return`。所以不需要记忆里担心的「音频时长 / 文件大小」启发式——`.failed` 这个判据本身已经精确区分了「用户没说话」和「说了但识别器挂了」。

### 4.3 状态建模 — `RecognitionMode.pending`

```swift
enum RecognitionMode: String, Codable {
    case online
    case onDevice
    case enhanced
    case failed
    case pending   // 有录音、无识别结果，等联网补
}
```

**枚举 case，不是新字段** —— 满足「`TranscriptionRecord` 不加字段」的约束。`Codable` 合成不变，旧 JSON 无需迁移。

`.pending` 与 `.failed` 的区别：

| | `.failed` | `.pending` |
|---|---|---|
| 含义 | 这次尝试失败了 | 从来没拿到过结果，等联网 |
| 进入路径 | `retryRecognitionFromFile` 抛错后仍是它 | `stopRecording` 识别器挂了但有音频 |
| 有文字吗 | 可能有（partial 落盘） | 一定没有 |
| 自动重试 | 是（`networkDidRecover` 第 3 步） | 是（同一路） |

**按 ADR-0001 §30，新增 case MUST 扩展 `assessAndEnhance` switch → 需写 `docs/decisions/0004-pending-recognition-mode.md`。** 那个 switch 现有 `default: break`，加一个 arm 即可。

### 4.4 数据流

```
离线录音
  │
  ├─ 不支持离线识别 → §4.1 throw → startRecording catch → errorMessage，不录音
  │
  └─ 支持 → 正常录 → stopRecording
              │
              ├─ 有文字 → mode = .onDevice → 照旧（ADR-0001 arm 2）
              │
              ├─ 无文字 + 识别器没报错（真沉默）→ return，不存
              │
              └─ 无文字 + 识别器报错 → mode = .pending → 存盘
                     │
                     │  联网
                     ↓
                 networkDidRecover
                     ├─ 第 1 步 LLM 队列：排除 .pending  ← §4.5 关键
                     ├─ 第 2 步 onDevice 升级：不匹配
                     ├─ 第 3 步 .failed 重试：.pending 一并匹配  ← §4.6
                     └─ retryRecognitionFromFile
                          → recognizeFromFile → 存回 content → mode = .enhanced
                          → processWithLLM → 末尾 relatedNotesService.link(for:) 算相关度
```

恢复流水线**现成**，本设计只补 record 落盘这一步。

### 4.5 `networkDidRecover` 第 1 步必须排除 `.pending`

`:454` 现在是 `$0.llmProcessingStatus == nil`。新建的 `.pending` record 满足这个条件，且 `content` 是空串 → 会被捞走，把**空字符串喂给大模型**，正是 `2026-04-09-skip-empty-transcription-design.md` 当初要防的幻觉。

```swift
let pendingLLM = records.filter {
    $0.llmProcessingStatus == nil && $0.recognitionMode != .pending
}
```

**这是本设计里最容易漏、后果最严重的一处。** 它是 §4.4 里 `.pending` 排除在第 1 步之外、只走第 3 步的原因。

第 4 步（`.failed` 的 LLM 重试）同理需排除——见 §4.6。

### 4.6 第 3 步纳入 `.pending`

```swift
let failedRecords = records.filter {
    ($0.recognitionMode == .failed || $0.recognitionMode == .pending)
        && $0.audioFileName != nil
}
```

**重试无上限** —— 与 `.failed` 完全一致。每次网络恢复都重试。不加计数 / 退避 / 降级。

第 4 步（重试 LLM）必须排除 `.pending`，否则 `record.content` 空串会被喂给大模型：

```swift
let failedLLM = records.filter {
    $0.llmProcessingStatus == .failed && $0.recognitionMode != .pending
}
```

**排除 `.pending` 不会漏掉它。** 第 3 步处理成功后 `retryRecognitionFromFile:333` 把 `recognitionMode` 置为 `.enhanced`，随后 `processWithLLM` 在同一次调用内完成 LLM —— 第 4 步根本没有介入的机会。若第 3 步**失败**，record 仍是 `.pending`，此时重试 LLM 本来就无意义（没有文字）。两个方向都自洽。

### 4.6.1 `enhanceRecognition` 不受影响

`enhanceRecognition:288` 有「用户编辑过就跳过」的保护（`optimizedContent != nil && content != optimizedContent`）。`.pending` record 的 `optimizedContent` 是 nil（从未走过 LLM），保护不触发 —— 正确，用户没有可保护的手工编辑。第 2 步的 filter（`:462`）只匹配 `.onDevice`，`.pending` 不在其中，无需改动。

### 4.7 UI

**合入主列表，不置顶、不分组。** 待识别 record 就在它录的那天那个 Section 里，与普通条目完全同级。

`RecordRowView` 需要一个占位标题——待识别 record 的 `title` 和 `content` **都是空的**，`:315-323` 直接渲染这两个字段，不处理的话 N 条待识别会渲染成 N 行空白，除时间外毫无区别。

| 位置 | 改动 |
|---|---|
| `RecognitionModeStyle`（`SharedComponents.swift:84-113`） | 加 `.pending` 的 color（琥珀）/ icon / label（"待识别"） |
| `RecordRowView.displayTitle`（`:379-385`） | `title` 为 nil/空且 `content` 为空时，回落为 `RecognitionModeStyle(.pending).label`（否则返回空串） |
| `RecordRowView.displaySummary`（`:387-396`） | `content` 为空时回落到 `History.PendingSummary`。**注意它现有末尾已回落到 `record.preview`**，而 `preview`（`:383` 同源）同样基于 `content` 切片 → 对空 `content` 返回空串，所以必须显式加回落 |
| `TranscriptionDetailView` actionsSection（`:281-283`） | `(mode == .onDevice \|\| mode == .failed)` 扩到含 `.pending` → 「在线升级识别」按钮 → `upgradeRecognition()`（`:345`）→ `reRecognizeOnline` → `retryRecognitionFromFile`，正是 §4.6 的重试路径，**无需新写触发逻辑** |
| `TranscriptionDetailView`（`:258, :266`） | `.failed` 的图标/文案 arm 加 `.pending` |

**详情页内容区**对 `.pending` 渲染一个占位块（提示「此录音尚未识别，联网后会自动补识别」+ 播放按钮），而不是空白的 `contentSection`。

**`RelatedNotesService:144` 无需改动** —— 候选只收 `llmProcessingStatus == .completed`，`.pending` record 天然被排除，不会污染相关度图。

### 4.8 本地化

`zh-Hans.lproj` + `en.lproj` 各加：

```
"Recognition.Pending"        = "待识别" / "Pending recognition"
"History.PendingSummary"     = "录音待联网识别" / "Recording awaiting recognition"
"Detail.Pending.Hint"        = "此录音尚未识别，联网后会自动补识别" / "This recording hasn't been transcribed yet. It will be processed automatically once you're back online."
"Error.OnDeviceUnsupported"  = "当前语言（%@）不支持离线识别" / "Offline recognition isn't available for %@"
```

## 5. 错误处理

| 情况 | 行为 |
|---|---|
| 离线 + 不支持离线识别 | `startRecording` throw → `errorMessage` 显示 → `isRecording` 归 false，无残留状态 |
| 离线 + 支持，识别仍失败 | record 存为 `.pending` |
| `.pending` 重试成功 | → `.enhanced` + content + LLM + 相关度 |
| `.pending` 重试失败 | 留 `.pending`，下次网络恢复再试（无上限） |
| 音频文件被用户从 Files 删了 | `retryRecognitionFromFile` `guard` 挡住（`:316-320`），留 `.pending`，不再重试（record 的 `audioFileName` 仍非 nil 但文件不存在 → 每��重试都静默返回） |
| 存储写入失败 | 沿用 `:238-240` 现有 `errorMessage` 路径 |

## 6. 测试

新增 `AudioNoteTests/PendingRecognitionTests.swift`。

| # | 测试 | 断言 |
|---|---|---|
| 1 | 离线 + `supportsOnDeviceRecognition == false` → `startRecording` | throw `.onDeviceUnsupported`，`recognitionMode != .onDevice` |
| 2 | 离线 + 支持 | 不 throw，`requiresOnDeviceRecognition == true` |
| 3 | 识别错误回调 | `continuation.finish()` 被调用（`AsyncStream` 结束） |
| 4 | `stopRecording` 无文字 + `hasRecognitionError == true` | record **落盘**，`recognitionMode == .pending`，`content == ""` |
| 5 | `stopRecording` 无文字 + **无** error（真沉默） | **不落盘**，`storage.loadAll()` 数量不变 |
| 6 | `networkDidRecover` 第 1 步 | `.pending` record **不进** LLM 队列（核心回归防线） |
| 7 | `networkDidRecover` 第 4 步 | `.pending` record **不进** LLM 队列 |
| 8 | `networkDidRecover` 第 3 步 | `.pending` record **进**重识别队列 |
| 9 | 端到端：`.pending` + 联网 | content 被填上、mode → `.enhanced`、`llmProcessingStatus == .completed` |
| 10 | 旧 JSON 缺 `recognitionMode` | 解码不崩，落到 `nil`（`Codable` 合成不变，无迁移） |
| 11 | `RecognitionMode.pending` 往返 | JSON 编码/解码稳定（`String` raw value） |
| 12 | `assessAndEnhance` 对 `.pending` | 走新 arm，**不**调 `processWithLLM`（ADR-0001 §30 合规） |
| 13 | 第 3 步成功后的 mode | `recognitionMode == .enhanced`（而非仍为 `.pending`）—— 防止第 3、4 步重复处理同一条 |

**每个过滤类测试（#6/#7）必须有 teeth** —— 断言的是「没被调用」容易 vacuous pass：先确认在**不加**排除条件时该测试会失败。

## 7. 决策记录

| # | 决定 | 理由 |
|---|---|---|
| D1 | 修 §1.1 第 1 步（离线前拦下）**和** 建待识别列表 | 用户不该白录 3 分钟才看到失败；但权限/超时等其他失败路径仍需兜底 |
| D2 | 新增 `RecognitionMode.pending` 枚举 case，而非复用 `LLMStatus.pending` | `LLMStatus` 那个 case 确实从未被用过，但语义是「LLM 未处理」，而 `.pending` 说的是「**识别**未完成」——LLM 那时根本还没开始。混淆两者会让 `llmProcessingStatus` 变成一个既表示「等识别」又表示「等大模型」的字段，破坏它作为相关度候选过滤器（`RelatedNotesService:144`）的语义 |
| D3 | 待识别 record 合入主列表，不置顶、不分组、不做独立页 | N 条待识别自然散在各自日期段里；置顶会打乱日期语义，独立页/筛选片是用户没要求的额外 UI |
| D4 | 重试无上限，与 `.failed` 一致 | 加计数需要新字段（与约束冲突）。误触的短录音被反复重试的代价，远小于「真录了 3 分钟却因为超限而永远不补」的代价 |
| D5 | 不需要音频时长/文件大小启发式 | `.failed` 判据已精确区分「真沉默」与「识别器挂」，见 §4.2 |
| D6 | 枚举 case 满足「不加字段」约束 | `RecognitionMode` 是 enum，加 case 不改 `TranscriptionRecord` 的存储形状，`Codable` 合成不变，无迁移 |

## 8. 文档产出

- `docs/decisions/0004-pending-recognition-mode.md` — 按 ADR-0001 的模板，**`Status` 初始为 `PROPOSED`**
- 更新 `docs/GLOSSARY.md` — `RecognitionMode.pending` 的语义
- 更新 `CLAUDE.md` 「Locked decisions」 — 记录 `.pending` 扩展了 ADR-0001 的 switch
- 顺带结掉 `docs/ROADMAP.md:9` 的命名撞车（占位的「ADR-0003: Skip-empty-transcription」vs 真的 `0003-multi-provider-llm.md`）—— 本设计碰到了 skip-empty 那块检查

## 9. 待验证（真机）

1. 飞行模式 + 中文 → 点录音，**当场**看到「当前语言（中文）不支持离线识别」，未开始录制
2. 下载好离线模型后飞行模式 → 录音正常，离线识别成功
3. 断网（不关飞行模式）→ 触发 §1.1 第 2 步的路径 → 记录以 `.pending` 落盘，列表出现「待识别 · 时长」行
4. 联网 → 该行变为正常条目，文案已补全，相关思考区出现
5. 连续录 3 条失败 → 列表出现 3 行，日期/时长各异，可区分
6. `.pending` 详情页 → 有占位提示 + 播放按钮 + 「在线升级识别」可用
7. 飞行模式下**真沉默**录音 → 列表**不新增**条目
