# 标签词表 · 方向 A（抽取时优先复用）实现计划

> **For agentic workers:** steps use checkbox (`- [x]`) syntax for tracking. Spec: `docs/superpowers/specs/2026-10-26-tag-vocabulary-maintenance-design.md` §3 方向 A —— the plan argues from the spec, so the spec travels with it; executors read both.

**Goal:** 让模型在抽标签时看到**和本条内容相关**的已有标签，而不只是「最常见的 30 个」。长尾里那些恰好对得上本条的词（`会议纪要` vs 一条讲会议的笔记）也要有机会被复用，而不是因为它只用过一次就永远被挡在词表外。

**Architecture:** 词表的**选择**从「按频次取前 N」改成「**先取与本条文本相关的（内部按频次排），再用高频词补满**」。选择逻辑抽成一个纯静态类型 `TagVocabularySelector`——纯函数才好测（`TranscriptionViewModel` 的协作者是 `private let` 单例，本身不可测）。调用点把「本条文本」传进选择器。**先埋点、后改选择**：没有基线，改完也说不清有没有用。

**Tech Stack:** Swift 5.9, SwiftUI, iOS 16+, XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-26-tag-vocabulary-maintenance-design.md` —— §2.2（为什么现在的选择是自我实现的闭环）、§3 方向 A（目标行为）、§8.2（这一轮不做什么）。

## Global Constraints

- **任何在线调用前必须先过 `NetworkMonitor.shared.checkConnectivity()`。** 无例外。（项目 CLAUDE.md 锁定决策。）本计划不新增任何调用点 ✓，只改**已经要调用的那次**的入参 ✓。
- **ADR-0003 冻结了 prompt 的措辞。** 本计划**一个字都不动 prompt** ✓ —— 改的只是「哪些标签进这个词表」✓。`LLMService.optimizeAndProcessPrompt` 保持逐字节不变 ✓。
- **ADR-0002 冻结了 `optimizeAndProcess` 的四字段响应 schema。** 本计划不改 schema ✓，埋点只是多打一行日志 ✓。
- **`TagIdentity` 是「同一个标签」的唯一权威。** 选择器**不做身份判定** ✓ —— 只判断「相关不相关」和「谁排前面」✓。理由现成的：`existingTagVocabulary` 的注释已经写明「大小写不在这里折叠，因为那会把模型正要修的拼写漂移藏起来」✓ —— 选择器要是偷偷归一化，就犯的是同一个错 ✓。
- **不新增任何用户可见字符串。** 这一轮不碰任何 UI ✓。
- **不写任何数据文件。** 这一轮只读记录、调 LLM、打日志 ✓。
- **新增文件后必须 `xcodegen --spec project.yml`，且退出码为 0**，否则新文件不在 target 里 ✓。
- Deployment target is iOS 16.0. Swift 5.9.

### Commands (run from `ios/`)

```sh
xcodegen --spec project.yml

xcodebuild test -project AudioNote.xcodeproj -scheme AudioNote \
  -destination 'platform=iOS Simulator,id=2E1E592B-9BBD-461F-B6CD-2134BD7CBB0D' \
  -only-testing:AudioNoteTests -derivedDataPath .build/DerivedData
```

## File Structure

| 文件 | 动作 | 说明 |
|---|---|---|
| `ios/AudioNote/Utilities/TagVocabularySelector.swift` | **新增** | 纯静态选择器 ✓ |
| `ios/AudioNoteTests/TagVocabularySelectorTests.swift` | **新增** | 选择器的测试 ✓ |
| `ios/AudioNote/Services/LLMService.swift` | 改 | 埋点 ✓（唯一同时看得到「词表」和「模型返回的标签」的地方 ✓） |
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` | 改 | `existingTagVocabulary` 从无参属性变成带文本的函数 ✓ |
| `ios/AudioNote/Views/TranscriptionDetailView.swift` | 改 | 调用点跟着改 ✓ |
| `ios/AudioNote/Services/LLMService.swift` 的 prompt | **不动** | ADR-0003 ✓ |
| `ios/AudioNote/Resources/*/Localizable.strings` | **不动** | 没有新字符串 ✓ |

## Review Focus

- **相关度算错 → 该被复用的标签没进词表。** 这是这一轮唯一的失败模式 ✓ —— 宁可多给几个不相关的 ✓，也别把相关的挡在外面 ✓。测试要专门盖这一条 ✓。
- **选择器偷偷做了身份归一** ✓ → 那会把模型正要修的拼写漂移藏起来 ✓（同 `existingTagVocabulary` 的既有约束 ✓）。selector **不调用** `TagIdentity.normalized` ✓（它只用来做**大小写无关的比较** ✓，不改变送进 prompt 的写法 ✓）。
- **埋点泄露了 API key 或正文** ✓ → 只记标签名和计数 ✓✓。正文一个字都不进日志 ✓。
- **把「相关」写成了「语义相同」** ✓ → 相关是**字面相关**（本条文本里出现过这个词）✓；语义等价（`工作` / `工作项`）是方向 B 的事 ✓。

---

### Task 1: 埋点 —— 先量后改

**为什么排第一**：没有基线，改完也说不清有没有用 ✓。这个任务**不改行为** ✓，只加一行日志 ✓。

- [x] 在 `LLMService.optimizeAndProcess` 里，`existingTagVocabulary` 和 `result` 都在手 ✓，在那里打一行 ✓
- [x] 记的内容 ✓（**只有标签和数字** ✓）：
  - 词表的大小 ✓（`existingTagVocabulary.count` ✓）
  - 模型返回的标签数 ✓（`result.tags.count` ✓）
  - **返回的标签里，有几个是词表给过的** ✓（按 `TagIdentity.normalized` 比较 ✓，只为比较 ✓，不改返回值 ✓）
  - 返回的标签本身（名字 + 分数）✓ —— 只有这几个字，不含正文 ✓
- [x] 用 `Logger.info` ✓（DEBUG 下走 `print` ✓，真机 Debug 包可以在控制台看到 ✓）
- [x] **不新增测试** ✓ —— 这一步没有可测的纯逻辑 ✓（测「日志打了」没有意义 ✓）

### Task 2: `TagVocabularySelector` —— 相关优先，频次补位

- [x] 新建 `ios/AudioNote/Utilities/TagVocabularySelector.swift` ✓
- [x] 纯静态类型 ✓，一个方法 ✓：

```swift
enum TagVocabularySelector {
    /// `counts`: 标签写法 → 库里出现的次数（全库，含归档 ✓）
    /// `text`: 本条笔记的文本（用来判断相关 ✓）
    /// 返回：送给模型的标签，最多 `limit` 个 ✓
    static func select(counts: [String: Int], text: String, limit: Int) -> [String]
}
```

- [x] **相关**的判定 ✓（字面相关 ✓，不是语义等价 ✓）：
  - 标签本身出现在本条文本里 ✓ → 相关 ✓（大小写无关 ✓，空白忽略 ✓）
  - 中文标签与文本**共享一个 2 字子串** ✓ → 相关 ✓（`会议纪要` vs 文本里有「会议」✓）
  - 英文标签与文本**共享一个 ≥3 字母的单词** ✓ → 相关 ✓
- [x] **排序** ✓：
  1. 相关的在前 ✓，内部按次数降序 ✓、再按字典序 ✓（稳定 ✓）
  2. 不相关的在后 ✓，按次数降序 ✓、再按字典序 ✓（即「高频词补位」✓ —— 头部那批通用词仍然留着 ✓，因为复用最划算的地方在那儿 ✓）
- [x] 截断到 `limit` ✓
- [x] 边界 ✓：`limit <= 0` → 空数组 ✓；`counts` 为空 → 空数组 ✓；`text` 为空 → 退化成纯频次排序 ✓（**冷启动和空文本都不崩** ✓）

### Task 3: 接进调用点

- [x] `TranscriptionViewModel.existingTagVocabulary` ✓：从无参属性改成函数 ✓，带上文本 ✓
  - **保留它现有的语义** ✓：全库（含归档 ✓）、按 `TagIdentity.normalized` 计数 ✓、**大小写不折叠**（送进 prompt 的写法不变 ✓ —— 这是既有约束 ✓）
  - 排序交给选择器 ✓，但**频次那一段的算法不能变** ✓（次数降序 + 字典序 ✓）
- [x] `TranscriptionViewModel.processWithLLM` 的调用点 ✓：传本条的文本 ✓
- [x] `TranscriptionDetailView` 的调用点 ✓：传那条记录的文本 ✓
- [x] `LLMService.maxTagVocabulary` **保持 30** ✓ —— 它的理由（词表和转写文本抢注意力 ✓）依然成立 ✓；要调等有了 Task 1 的数据再说 ✓

### Task 4: 测试

- [x] 新建 `ios/AudioNoteTests/TagVocabularySelectorTests.swift` ✓
- [x] 必须盖住的用例 ✓：
  - **相关的低频标签能挤掉不相关的高频标签** ✓（本轮的核心 ✓）
  - 完全不相关时，退化成纯频次排序 ✓
  - `limit` 生效 ✓
  - 中文共享 2 字子串 → 相关 ✓；不共享 → 不相关 ✓
  - 英文共享 ≥3 字母单词 → 相关 ✓
  - 大小写无关 ✓（`Work` 与 `work` 的判断 ✓）
  - **返回的写法保持原样** ✓（不折叠大小写 ✓）
  - 空输入不崩 ✓（空 counts ✓、空 text ✓、limit 0 ✓）

### Task 5: 文档

- [x] `docs/GLOSSARY.md` ✓：加 `TagVocabularySelector` 一行 ✓；更新 `TagIdentity` 那一行里关于「词表上限 30 / 长尾到不了模型」的描述 ✓（因为选择方式变了 ✓）
- [x] spec 的 §2.2 补一句「选择方式已改，见 plan」✓
- [x] `CLAUDE.md` 的 **Open work** ✓：方向 A 的那一行补上进展 ✓（注意：**B 还没做，这行不能删** ✓）

---

## Not in scope

- **方向 B 的全部** ✓ —— 新 LLM 调用、建议清单 UI、归并映射的存放 ✓。等 A 的数据出来再设计 ✓（§8.1 ✓）
- **结果侧归一化** ✓ —— 把模型返回的标签映射回词表 ✓（语义等价 ✓，属于 B ✓）
- **改 prompt 的措辞** ✓ —— ADR-0003 冻结了 ✓
- **词表变成一等公民** ✓（像 `profiles.json` ✓）—— 第三个话题 ✓
- **给词表加一个文件** ✓ —— 词表现在是**算出来的** ✓，不是一个存起来的文件 ✓；要不要存起来是 §5 的待答问题 ✓
