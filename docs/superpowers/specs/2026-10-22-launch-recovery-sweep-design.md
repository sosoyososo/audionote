# 启动时恢复扫描（launch recovery sweep）设计

| Field | Value |
|---|---|
| **Status** | PROPOSED |
| **Date** | 2026-10-22 |
| **Supersedes** | — |
| **Author** | — |
| **Related ADR** | ADR-0006（需新写）；扩展 ADR-0005 的 `networkDidRecover` 触发条件 |

## 1. 问题

一次飞行模式下的录音，音频确实写进了 Files app 的 `audionote/` 目录，列表里也**看得到**这条记录——但它永远停在「待识别」：没有转写文本，也没有任何东西会再去试一次。

### 1.1 根因（已在当前 `main` 复核）

恢复流水线**是有的**（ADR-0005 §4.6），缺的只是**触发器**。

| # | 位置 | 发生什么 |
|---|---|---|
| 1 | `NetworkMonitor.swift:43` | `onStatusChange` 只在「断开 → 连上」这个**跳变**时触发。`isConnected` 在 `init` 里就按当前 path 预置好了（`:28`），所以 path 的**第一次**更新永远不满足 `!wasConnected && isConnected` |
| 2 | `TranscriptionViewModel.swift:80-89` | `setupNetworkMonitor` 把 `onStatusChange` 接到 `networkDidRecover`，并 debounce |
| 3 | `TranscriptionViewModel.swift:260` | `assessAndEnhance` **只在保存路径**被调用。已落盘的记录不会被重新评估 |
| 4 | `AIProcessingService` | ADR-0001 §"Background caller" 和 ADR-0002 都把它列为「启动时跑 `processPendingRecords`」的角色。该文件在 `a421f63`（2026-09-24）作为死代码删除——而且是严格意义上的死代码：`processPendingRecords()` 在被删除的那一刻**没有任何调用方**，唯一的引用是它内部对 `processRecord` 的调用。**这个启动 sweep 从来没跑过。** |

**净效果**：一条搁浅的记录只能等用户在**本次会话内**恰好把网络断开关一次。带着好网络重新打开 app，什么都不会发生。

### 1.2 这不是「功能没写」，是「触发器没接」

恢复逻辑本身（`networkDidRecover` 的四步、`llmQueue` / `recognitionRetryQueue` 两个队列、ADR-0005 锁定的全部不变量）都在，测试也都在。**缺的只是一个调用点。**

这个区别决定了修法的形状：不是「加一个新功能」，是「给已有的东西接上电源」。

## 2. 目标

1. app 启动时，把**上一次会话遗留**的搁浅记录补上：音频在盘上没转写的、LLM 跑失败的。
2. 补的顺序和内容必须与网络恢复走**同一套队列**——`llmQueue` 与 `recognitionRetryQueue`（ADR-0005），不是另起一套判据。
3. 启动时补的**代价必须有上限**。网络恢复是用户在场时发生的，突发调用可以接受；启动是无人值守的，不能一次把整个历史库送出去。
4. 启动 sweep 与网络恢复 sweep **不得并发重叠**。同一条记录被两个 sweep 各处理一次 = 重复的 LLM 计费和重复写入。

## 3. 方案

### 3.1 触发点

`TranscriptionViewModel.init` 的既有 `Task` 里，`loadHistory()` 之后调用一次新的 `recoverStrandedRecords()`。

选这里而不是 `ContentView.onAppear`：VM 已经持有 `storage` / `speechRecognizer` / `llmService` 这些协作者，`networkDidRecover` 也在这里。放到 ContentView 会让 VM 之外多一个能触发恢复的入口——而 VM 之外没有 `pending` 判据可依据。

`loadHistory()` 在 `StorageCoordinator.isReady == false` 时会 bail（`:617`），所以**没选文件夹的用户不会跑 sweep**。这是对的：他们的库是空的，没有可补的东西。`recoverStrandedRecords()` 自己也要再查一次 `isReady`，因为 `loadHistory` 之后的任何时刻状态都可能变。

### 3.2 范围：两条 queue，不含第 2 步

启动 sweep 跑 `networkDidRecover` 的**第 1、3、4 步**（两条 queue），**不含第 2 步**。

第 2 步（`.onDevice` 记录 → `enhanceRecognition` 在线升级识别）用的是原始 filter，不是 ADR-0005 的两条 queue，而且它**不是恢复**——那些记录已经有转写文本了，升级只是锦上添花。把它算进来会让每次启动对全库的 on-device 记录发一轮在线识别请求。

### 3.3 代价上限

| 步骤 | 每次启动最多 | 为什么 |
|---|---|---|
| 第 3 步 重识别（`.pending` / `.failed`） | **不限** | 用的是 Apple 的语音识别，不是 LLM。**没有 API 费用**，只有时间。无限重试是 ADR-0005 §4.6 明确要求的（「重试无上限 —— 不加计数 / 退避 / 降级」），不能动 |
| 第 1 + 4 步 LLM | **10 条** | 唯一的花钱步骤 |

LLM 上限的**主要防线其实不是这个数字**，而是范围本身：

- 第 4 步只捞 `llmProcessingStatus == .failed` 的记录——那是**真的尝试过并且失败了**的。
- 第 1 步捞 `status == nil` 的记录。这里面混了两种：**离线时 on-device 录的**（真搁浅，该补）和**用户配置 provider 之前就录的**（不是搁浅）。后者今天也**会被送去 LLM**——`networkDidRecover` 第 1 步在第一次网络跳变时就会整批送出去。启动 sweep 没有制造新的这类账单，它只是把这笔账**提前并分批**。
- 真正没被上限覆盖住的风险是「LLM 一直失败」（限流 / 服务挂了）→ 记录停在 `.failed` → 每次启动重试。上限就是为这个准备的：每次启动最多 10 条，剩下的下次再说。

### 3.4 与网络恢复 sweep 的关系

**网络恢复 sweep 的行为一个字都不改。** 包括它现在的**无上限**。

这看起来不一致，但是对的：网络恢复是**用户在场**时发生的（他们刚把网络连上，在等结果），一次把积压清完是符合期待的；启动 sweep 是**无人值守**的，一次清完可能意味着一次意外的账单。

给网络恢复也加上限会更糟：用户要清 200 条积压，就得断网重连 20 次。那是把「等网络恢复」变成「反复折腾网络」。

> **已知问题（不在本设计范围内）**：`networkDidRecover` 的 LLM 步骤目前无上限，一次网络跳变可能触发整个积压的 LLM 调用。这是**既有行为**，不是本设计引入的。改动它会改变用户可见的语义（积压要靠多次跳变才能清完），需要单独决策。

### 3.5 不并发

两个 sweep 可能重叠：用户离线启动 app，随后网络恢复 → 启动 sweep 还在跑，网络 sweep 又来了。

`TranscriptionViewModel` 是 `@MainActor`，所以一个 `@MainActor` 上的布尔标志就够：进入时置位，`defer` 里复位。因为 `defer` 不需要 `await`（`RelatedNotesService` 里那个 `Gate` actor 存在的理由是 `defer` 里不能 `await`——这里不涉及），所以不会有「释放到了未调度的 Task 上」那种问题。

标志的粒度是**整个 sweep**，不是每一步——否则两个 sweep 会交错执行同一条记录，只是错开了步数。

## 4. 详细设计

### 4.1 `networkDidRecover` 拆成可复用的步

现在的四步是一整个方法。启动 sweep 要复用其中三步，所以拆成四个私有方法，两个 sweep 各自调用需要的那些：

```swift
private func runNeverProcessedLLM(records: [TranscriptionRecord]) async   // 第 1 步
private func runOnDeviceUpgrade(records: [TranscriptionRecord]) async       // 第 2 步
private func runRecognitionRetry(records: [TranscriptionRecord]) async      // 第 3 步
private func runFailedLLM(records: [TranscriptionRecord]) async             // 第 4 步
```

**顺序保持不变。** ADR-0005 把「第 1 步先于第 2 步」列为可自由改动（"The order and count of the four `networkDidRecover` steps, provided each still draws from its filtered queue"），但没有必要动它——拆方法不要求改顺序。

### 4.2 队列判据一行不改

第 1、3、4 步**必须**继续用 `PendingRecognitionPolicy.llmQueue` / `recognitionRetryQueue`。这是本设计的硬约束：

- `llmQueue` 排除 `.pending` 和 `isHandEdited` 的记录。**排除 `.pending` 是 ADR-0005 锁死的**——`.pending` 的 `content` 是空串，喂给 LLM 会得到一个自信的幻觉标题和摘要，然后被写回记录。
- `recognitionRetryQueue` 排除 `isHandEdited` 的记录，因为重识别会把结果**覆盖**到 `content` 上。

启动 sweep 是**另一个**触发器，不是新的策略来源。它复用同一批队列，就自动继承了全部不变量——包括那些「看起来像 belt-and-braces 其实承重」的过滤。

### 4.3 上限的实现位置

上限是**启动 sweep 独有的**，所以实现在启动 sweep 这一侧，不进队列函数。队列函数继续返回全部候选，**语义不变**（ADR-0005 锁死了它们）。

具体是 `.prefix(10)` 作用在 LLM 步骤的候选上。

**排序**：候选的顺序来自 `storage.loadAll()` 的返回顺序。为了让上限切掉的不是「随机一批」，应该有一个明确的优先级。倾向：**`.pending` / `.failed` 的重识别优先（免费且是数据损失），LLM 档按记录创建时间从旧到新**（旧的先补，因为它们搁置最久）。

### 4.4 可观测性

启动 sweep 跑的时候，界面上应该**看不出**它在动——它是个后台补录，不是一个用户正在等的操作。所以：

- **不**复用 `isLLMProcessing` / `isEnhancing` 这类「正在处理」的 UI 状态。`processWithLLM` 内部会设 `isLLMProcessing = true`，这会让录音页显示「正在处理…」——**这是现有行为**，`networkDidRecover` 也会触发它。启动时这个 spinner 闪一下是可以接受的，但它不该让 app 看起来卡住了。
- `llmProcessingFailed` 同理。
- 需要一条 `Logger` 记录，说明启动 sweep 补了几条、补的哪几档。

### 4.5 前置条件：存储必须可读

**sweep 只在 `StorageCoordinator.state == .ready` 时运行。**

这不是可选的礼貌检查。`state` 有三个取值（ADR-0007）：`.unconfigured`（没选过文件夹）、`.unreachable(reason)`（选过但现在够不着）、`.ready`。前两种状态下：

- `transcriptions.json` 根本读不到（`StorageCoordinator.jsonURL` 依赖 `resolvedRoot`），sweep 无从知道有哪些记录；
- 更糟的是 `.unreachable` 而 `resolvedRoot` 仍留着旧值时，读到的可能是**上一个**目录——对着一个用户已经不再使用的文件夹做恢复，然后往里写。

所以 sweep 的第一步是查 `state`，不是查 `isReady`（`isReady` 是 `state == .ready` 的计算属性，但直接读 `state` 能让「为什么不能跑」出现在日志里）。

`state` 为 `.ready` 但 `transcriptions.json` 损坏时，`storage.loadAll()` 会抛错 → sweep 自然 bail，不会写出任何东西。

## 5. 测试

`recoverStrandedRecords` 本身**不可单测**——`TranscriptionViewModel` 的协作者是 `private let` 单例，和 ADR-0005 里说的同一个问题。

所以可测的部分是**决策**：

| 决策 | 纯函数 | 断言 |
|---|---|---|
| 启动 sweep 补哪几档 | `PendingRecognitionPolicy` 新增一个 `launchLLMCandidates(from:limit:)` | 排除 `.pending`、排除 `isHandEdited`、`.pending`/`.failed` 的重识别候选不受 LLM 上限影响、LLM 候选按 `createdAt` 升序且被 `limit` 截断 |
| 上限只作用于 LLM 档 | 同上 | 重识别候选数不随 `limit` 变化 |
| 队列判据不变 | 现有的 `llmQueue` / `recognitionRetryQueue` 测试 | 已有测试继续通过（回归保证） |

**新增一条集成层面的断言**：启动 sweep 与网络恢复 sweep 走**同一批**队列函数——用一个共享的纯函数 `recoveryCandidates(from:)` 返回「第 1/3/4 步要处理什么」，两个 sweep 都调它。这样「两个 sweep 的判据不会漂移」这件事本身是**可测的**，而不是靠代码评审。

## 6. 明确不做的事

- **不改 `networkDidRecover` 的任何现有行为**，包括它现在的无上限。只把它拆成可复用的步。
- **不改队列判据**。`llmQueue` / `recognitionRetryQueue` 是 ADR-0005 锁死的。
- **不加计数、不加退避、不加降级**。ADR-0005 §4.6 明确要求重试无上限。
- **不加新的 `RecognitionMode`**，不改 `TranscriptionRecord` 的存储形状（不涉及迁移）。
- **不动第 2 步**（on-device 在线升级）。
- **不写 UI**。这是后台补录，不是一个用户可见的操作。

## 7. 待确认的决策点

1. **LLM 上限 10 条**——这个数字是我定的，理由见 §3.3。太小则积压清得慢，太大则单次启动的账单失控。可以在实现后调整，改一个常量即可。
2. **启动 sweep 是否也该跑第 2 步**——我按「不属于两条 queue、且不是恢复」排除了。若希望启动时也顺手把 on-device 记录升级成在线识别，把 `runOnDeviceUpgrade` 加进启动 sweep 即可。
3. **网络恢复 sweep 的无上限突发**（§3.4）——已知问题，本次不改。是否单独处理由用户定。
