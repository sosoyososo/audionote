# 标签词表 · 方向 B（智能合并标签）实现计划

> **For agentic workers:** steps use checkbox (`- [x]`) syntax for tracking. Spec: `docs/superpowers/specs/2026-10-26-tag-vocabulary-maintenance-design.md` §3 方向 B —— the plan argues from the spec, so the spec travels with it; executors read both.

**Goal:** 在标签列表页加一个「智能合并标签」的操作：让大模型指出哪些标签语义相同、可以并成一个，给出一份**建议清单**；用户可以整份同意，也可以删掉几条再同意剩下的；**只有用户明确允许，合并才会执行**。

**Architecture:** 一次**新的** LLM 调用 `proposeTagMerges`（不碰 `optimizeAndProcess` 的四字段 schema ✓ —— ADR-0002 锁死了 ✓），输入是全库标签和它们的次数，输出是一组「目标名 + 要并进去的标签」的建议。一个新的 sheet 把建议变成可勾选、可删改的清单，用户确认后走一条**批量**落地路径：读一次库、依次套用、写一次盘 ✓。

**Tech Stack:** Swift 5.9, SwiftUI, iOS 16+, XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-26-tag-vocabulary-maintenance-design.md` —— §3 方向 B（含 2026-10-29 定下的七件事 ✓）、§6 动手时必须遵守的约束 ✓。

## Global Constraints

- **任何在线调用前必须先过 `NetworkMonitor.shared.checkConnectivity()`。** 无例外。（项目 CLAUDE.md 锁定决策。）新增的调用走和现有调用**同一套**门禁与重试策略 ✓。
- **ADR-0002 冻结了 `optimizeAndProcess` 的四字段响应 schema。** 本计划**不改它** ✓，而是新增一次调用 ✓，并为新调用写一份 ADR ✓（ADR-0010 ✓）。
- **ADR-0003 冻结了 prompt 的措辞。** 新调用有**自己的** prompt ✓，与现有两个互不影响 ✓。
- **在线调用走现有的 provider profile**（ADR-0003 ✓），不新增第二套 LLM 通道 ✓；API key 只在 Keychain 里 ✓，绝不写进文件夹 ✓（ADR-0008 ✓）。
- **模型只提建议，不执行合并。** 合并必须由用户明确允许 ✓（CLAUDE.md「Locked decisions」级的约束 ✓）。
- **`TagIdentity` 是「同一个标签」的唯一权威。** 建议里的标签名要按 identity 核对 ✓ —— 模型可能给出大小写不同的写法 ✓，那是同一个标签 ✓，不能当成两个 ✓。
- **写盘走 `TranscriptionStorage` 类**，不直接碰 JSON ✓。
- **每一条用户可见的字符串，两个 `Localizable.strings` 都要有，key 相同** ✓。
- **新增文件后必须 `xcodegen --spec project.yml`，且退出码为 0** ✓。
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
| `ios/AudioNote/Services/LLMService.swift` | 改 | 新调用 `proposeTagMerges` ✓ + 它的 prompt ✓ + 响应类型 ✓ |
| `ios/AudioNote/Models/TagMergeProposal.swift` | **新增** | 建议的数据类型 ✓（`Equatable` ✓ / `Identifiable` ✓） |
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` | 改 | `proposeTagMerges()` ✓ + `applyTagMerges(_:)` ✓ |
| `ios/AudioNote/Services/TranscriptionStorage.swift` | 改 | 批量合并入口 ✓（读一次、写一次 ✓） |
| `ios/AudioNote/Views/TagPickerSheet.swift` | 改 | 「智能合并标签」入口 ✓ |
| `ios/AudioNote/Views/TagMergeProposalSheet.swift` | **新增** | 建议清单 ✓ |
| `ios/AudioNote/Resources/{zh-Hans,en}.lproj/Localizable.strings` | 改 | 新字符串 ✓ |
| `ios/AudioNoteTests/TagMergeProposalTests.swift` | **新增** | 解析 ✓ + 落地 ✓ |
| `ios/AudioNoteTests/TagMergeProposalUITests.swift` | **新增** | 清单的取舍逻辑 ✓ |
| `docs/decisions/0010-tag-merge-proposal.md` | **新增** | ADR ✓（新的调用 + 「模型只提建议」✓） |
| `docs/GLOSSARY.md` | 改 | 新类型 ✓ |

## Review Focus

- **建议能不能绕过用户直接落地** ✓ —— 不能 ✓。这是这一轮唯一不可协商的约束 ✓。
- **模型返回的标签名不在库里怎么办** ✓ —— 丢掉 ✓（模型可能编出库里没有的标签 ✓）。**更要紧的是**：模型可能返回**同一个标签的两种大小写** ✓ —— 按 identity 核对 ✓，当成一个 ✓。
- **一次写盘** ✓ —— 30 组建议不能是 30 次全库重写 ✓。
- **建议之间重叠** ✓ —— 后一组用到已被前一组吃掉的标签时**跳过**，并如实告诉用户跳过了几条 ✓。
- **prompt 里不要出现笔记正文** ✓ —— 只给标签和次数 ✓。

---

### Task 1: 建议的数据类型

- [x] 新建 `ios/AudioNote/Models/TagMergeProposal.swift` ✓
- [x] 一条建议 = **目标名** + **要并进去的标签** ✓：
  ```swift
  struct TagMergeProposal: Identifiable, Equatable {
      let id: UUID
      var target: String        // 合并后的名字 ✓
      var sources: [String]     // 要并进去的标签 ✓
      var counts: [String: Int] // 每个标签出现在多少条笔记里 ✓（给用户看代价 ✓）
  }
  ```
- [x] `counts` 是**显示用的上下文** ✓，不参与落地 ✓ —— 落地只需要 target + sources ✓✓

### Task 2: 新的 LLM 调用

- [x] 在 `LLMService` 里加 `proposeTagMerges(tags: [(name: String, count: Int)]) async throws -> [TagMergeProposal]` ✓
- [x] **走和现有调用同一套门禁** ✓：`validateProfile` ✓、`NetworkMonitor` ✓、`retryingRequest` ✓ —— 不新造一套 ✓✓
- [x] 自己的 prompt ✓（`tagMergePrompt` ✓），内容 ✓：
  - 全库标签和次数 ✓
  - 只指出**语义相同**、可以并成一个的标签 ✓
  - **不要合并只是相关但不同的标签** ✓（这条要在 prompt 里写死 ✓ —— 模型很容易把「相关」当成「相同」✓）
  - 每条给出**合并后的名字** ✓（用最常用、最准确的那个 ✓）
  - 严格 JSON ✓，格式 `{"merges":[{"target":"...","sources":["..."]}]}` ✓
- [x] 响应解析 ✓：容错 ✓ —— 缺字段的条目丢掉 ✓✓，**不要整份失败** ✓
- [x] **过滤掉不在库里的标签名** ✓（模型编出来的 ✓），并按 identity 去重 ✓
- [x] 一次最多返回 N 条建议 ✓（比如 30 ✓），超出的丢掉 ✓
- [x] 测试 ✓：合法响应 ✓、缺字段 ✓、编造的标签名 ✓、大小写不同的同一个标签 ✓、空响应 ✓

### Task 3: 批量落地

- [x] `TranscriptionStorage` 加批量入口 ✓：
  ```swift
  func mergeTags(_ groups: [(target: String, sources: [String])]) async throws
  ```
  **读一次 ✓ → 依次套用 `TagMerger.merge` ✓ → 写一次 ✓**✓
- [x] **重叠检测** ✓：维护一个「已被吃掉的标签」集合 ✓；后一组如果用到了已被吃掉的标签 → **整组跳过** ✓，并把跳过的条数报回去 ✓
- [x] `TranscriptionViewModel.applyTagMerges(_ proposals:)` ✓：
  - 过滤掉 sources 为空或 sources 只含 target 自己的 ✓
  - 调用 storage 的批量入口 ✓
  - 成功后 `selectedTags` 用 `TagMerger.remappedSelection` 重映射 ✓（和 `mergeTag` 一致 ✓）
  - `await loadHistory()` ✓
- [x] 测试 ✓：一次写盘（**不能**调用 N 次 ✓）、重叠跳过 ✓、空输入不写盘 ✓、落地后记录上的标签正确 ✓

### Task 4: 建议清单界面

- [x] 新建 `ios/AudioNote/Views/TagMergeProposalSheet.swift` ✓
- [x] 每条建议一行 ✓：
  - 目标名 ✓（**可改** ✓ —— 模型给的名字未必是你想要的 ✓）
  - 要并进去的标签 ✓（每个带出现次数 ✓ —— 用户要能看见代价 ✓）
  - 一个勾选框 ✓（默认**勾上** ✓，用户可以取消 ✓）
  - 一个删除按钮 ✓（= 拒绝这条建议 ✓）
- [x] 底部两个动作 ✓：
  - 「全部同意」✓（把所有还在的建议都勾上 ✓）
  - 「合并 N 组」✓（**只合并勾选且没被删掉的** ✓，N 要显示 ✓）
- [x] **执行前**显示这次会改写多少条笔记 ✓（合并的代价 ✓）
- [x] `TagPickerSheet` 的工具栏加「智能合并标签」✓（在「清除」和「完成」之间 ✓）
- [x] 点它之后 ✓：调用 LLM ✓（要有 loading 态 ✓）→ 拿到建议 → 弹出清单 ✓；**没有建议时**给一句话就完了 ✓（不是错误 ✓）
- [x] **网络失败 / 没有 profile** → 一句人话 ✓，不是崩溃 ✓
- [x] 字符串两个语言都要有 ✓

### Task 5: 测试

- [x] `TagMergeProposalTests` ✓：LLM 解析 ✓、过滤 ✓、批量落地 ✓
- [x] 清单的取舍逻辑要能测 ✓：把「哪些建议会被执行」抽成一个纯函数 ✓（勾选 + 删除 + 重叠之后剩什么 ✓），对它测 ✓

### Task 6: 文档

- [x] `docs/decisions/0010-tag-merge-proposal.md` ✓：新的 LLM 调用 ✓ + 它的 schema ✓ + 「模型只提建议，用户拍板」✓ + 「不存归并映射，记录就是映射」✓
- [x] `docs/GLOSSARY.md` ✓：`TagMergeProposal` ✓
- [x] spec 的 Status ✓：方向 B 实现后改成 IMPLEMENTED ✓（或标出还差什么 ✓）
- [x] `CLAUDE.md` 的 **Open work** ✓：标签那一行 ✓（A 和 B 都完成了才删 ✓）

---

## Not in scope

- **不把标签词表变成一等公民** ✓（`profiles.json` 那种 ✓）—— 另一个话题 ✓
- **不做后台扫描** ✓ —— 用户手动触发 ✓（§3 ① ✓）
- **不存同义词词典** ✓ —— 记录上的标签就是映射 ✓（§3 ④ ✓）
- **不做「合并并撤销」** ✓ —— 合并是破坏性的 ✓，靠**预览 + 逐条确认**来控制，不靠撤销 ✓
- **不改 `optimizeAndProcess`** ✓（ADR-0002 ✓）、**不改现有 prompt** ✓（ADR-0003 ✓）
