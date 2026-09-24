# Related Notes(相关思考)— Backlog Stub

> **状态:Backlog / 暂缓**
> **创建日期**:2026-09-24
> **决策延后**:核心计算策略未敲定,本文档只描述意图与待决项,不进入实现阶段。

---

## 1. 目标

在笔记详情页(`TranscriptionDetailView`)新增一个**"相关思考"**区块,展示与当前笔记相关的其它笔记列表,点击可跳转到对应详情。

**产品意图**:把单条录音笔记连成"思考网络",让用户从一个想法能跳回过去相关的想法,强化回溯与联想体验。

---

## 2. 验收标准(占位,设计未敲定前不细化)

- [ ] 详情页可见"相关思考"区块
- [ ] 默认展示 N 条相关笔记(N 待定)
- [ ] 每条显示:标题 / 时间 / 一行预览 / 与当前笔记的相似度信号(可选)
- [ ] 点击跳转到对应详情
- [ ] 离线行为已定义(见 §4 待决项)

---

## 3. 关键设计待决项(下次回到此 feature 必须先回答)

### 3.1 相关性如何计算 ← **核心决策**

候选策略:

| 方案 | 思路 | 成本 | 离线 | 局限 |
|---|---|---|---|---|
| A. 写入时 LLM 一次算 | 扩展现有 `optimizeAndProcess` 调用,让模型同时返回相关 ID 列表,持久化到 record | 0 额外 API(合并) | 离线时该字段为空 | 必须有激活 Provider;老笔记无相关数据 |
| B. 本地标签重叠 | 按 tags 重叠数排序 | 0 | ✅ | 只看标签不看正文,漏主题相关但 tag 不同 |
| C. 本地初筛 + LLM 重排 top-K | tags 重叠初筛 top-20,LLM 重排 top-5 | 每次详情 1 次额外 API | 离线降级为 B | 慢,烧 token |
| D. 本地 embedding / BM25 | 本地算文本相似度 | 0 | ✅ | 工程量大,需引入 embedding 模型或自实现 BM25 |

### 3.2 何时计算

- 写入时一次性算好缓存 vs. 详情页打开时实时算 vs. 后台定期算

### 3.3 缓存与失效

- 是否新增 `relatedIDs: [UUID]?` 字段到 `TranscriptionRecord`
- 新笔记产生 / 编辑 / 归档后,是否触发相关笔记的关联刷新
- 旧笔记怎么办:首次打开时回填?接受空相关?

### 3.4 UI 摆放

- 区块位置:在"标题/摘要/标签"之下、"原始 vs 优化后"对照之上/之下
- 是否可折叠
- 是否显示相似度数字 / 共用 tag 高亮

### 3.5 数量与排序

- 展示数量上限(3 / 5 / 10)
- 排序:相关性 desc / 时间 desc / 混合

### 3.6 跳转行为

- `NavigationLink` push 堆叠 vs. 替换当前详情

### 3.7 离线 / 加载态 / 错误态

- 离线时:隐藏区块?显示空状态?仅展示已缓存结果?
- 计算中(方案 A/C):loading 骨架屏?
- 计算失败:toast?静默降级?

---

## 4. 受影响的现有代码(粗扫,未细化)

| 文件 | 改动类型 |
|---|---|
| `Models/TranscriptionRecord.swift` | 可能新增 `relatedIDs` 字段(Codable + 默认值 + 旧数据兼容) |
| `Services/LLMService.swift` | 方案 A/C 需扩展 `optimizeAndProcess` 响应 schema |
| `ViewModels/TranscriptionViewModel.swift` | 新增相关笔记计算/获取逻辑,可能新增 `networkDidRecover` 后的回填路径 |
| `Views/TranscriptionDetailView.swift` | 新增"相关思考"区块 + 跳转 |
| `Views/SharedComponents.swift` | 可能抽出可复用的 `RelatedNotesList` |
| `docs/GLOSSARY.md` | 新增术语条目 |
| `docs/decisions/` | 写入时锁定新决策(策略选定后) |

---

## 5. 关联

- `2026-09-23-library-search-tag-archive-design.md` — 思录标签体系,本功能的标签重叠方案依赖其 `TaggedItem` 数据形状
- `2026-09-24-multi-provider-llm-design.md` — LLM Provider 配置,本功能的方案 A/C 依赖其 Provider 体系
- `2026-04-09-merge-llm-calls-design.md` — 单次 LLM 调用合并多个输出,本功能的方案 A 需要扩展此契约
- ADR-0001(assess-and-enhance 调度)— 若在写入路径加计算,需评估是否纳入调度

---

## 6. 下一步

回到此 feature 时:

1. 先答 §3.1 计算策略(决定其它所有决策)
2. 答完后再细化验收标准 + 写完整 spec
3. 走完整 brainstorming → spec → plan → implement 流程