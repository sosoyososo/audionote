# 思录 (Library): Search, Tag Filter, Archive

**Date**: 2026-09-23
**Status**: Draft

## Overview

历史 tab 累积条目后缺乏高效的浏览与查找手段。本次设计引入以下核心功能：

1. **重命名**：`历史` tab → `思录`（zh）/ `Library`（en），传达"重见文件库"的隐喻
2. **全文搜索**：在标题、摘要、标签、内容（原文本）上做大小写无关子串匹配
3. **标签筛选**：横向 chips 列表，多选、OR 语义、每个 chip 显示当前筛选条件下的命中数
4. **归档**：详情页加归档按钮；归档记录默认从列表中隐藏，但保留搜索/筛选命中可见性（通过 banner）
5. **筛选交互**：搜索与标签筛选同步作用（AND）；选中标签时按"标签命中数 desc"排序，否则按时间倒序

## Data Model

### TranscriptionRecord 新增字段

```swift
struct TranscriptionRecord: Codable, Identifiable, Equatable {
    // ... existing fields ...

    /// 是否已归档。归档记录在文库列表中默认隐藏，但搜索/标签筛选命中时会在 banner 中提示
    var archived: Bool = false

    /// 归档时间。nil 表示未归档。与 `archived` 配合：归档时同时设置 `archived = true` + `archivedAt = now()`；取消归档时 `archived = false` + `archivedAt = nil`
    var archivedAt: Date? = nil
}
```

**Schema migration**：现有 JSON 文件无这两个字段，`Codable` 自动解码为默认值（`false` / `nil`）。无需手动迁移。

## Architecture

### Component Responsibilities

```
TranscriptionViewModel (扩展)
├── 新 Published state:
│   ├── searchQuery: String           ← 搜索框内容
│   ├── selectedTags: Set<String>    ← 当前选中的标签（多选、OR）
│   ├── archivedHitCount: Int        ← 当前搜索/标签命中的归档记录数
│   └── archivedHitIDs: [UUID]       ← 命中的归档记录 ID 列表（用于未来扩展）
├── 计算属性:
│   ├── availableTags: [String]      ← 当前 active 记录中出现的 tags（按字母序，去重）
│   ├── displayedRecords: [TranscriptionRecord]  ← 搜索∩标签∩active（非归档）
│   ├── tagCounts: [String: Int]     ← 每个 tag 在当前筛选下的命中数
│   └── archivedHitIDs: [UUID]       ← 当前筛选下命中的 archived 记录 ID
├── 动作:
│   ├── setSearchQuery(_ s: String)  ← 触发刷新
│   ├── toggleTag(_ tag: String)     ← 选中/取消
│   ├── clearFilters()               ← 清除搜索 + 标签
│   ├── archiveRecord(id: UUID)      ← 设为 archived + archivedAt = now()
│   └── unarchiveRecord(id: UUID)    ← 反向
└── 排序:
    └── displayedRecords 内部：选中标签 → 命中数 desc → time desc；未选 → time desc

LibraryListView (HistoryListView 重命名)
├── 顶部 sticky: 搜索栏
├── 标签 chips 横滑栏（始终可见）
├── archived 命中 banner（仅 archivedHitCount > 0）
└── 列表行: 标题 + 摘要预览 2 行 + ……
└── 列表为空: 无匹配/暂无记录提示

TranscriptionDetailView (扩展)
├── 新增 actionsSection 右侧按钮: archive/unarchive
└── 按钮双状态: active 显示 "归档"，archived 显示 "已归档 ✓"

LibraryArchivedMatchesView (新)
└── NavigationLink-pushed 子页面：仅显示当前搜索/标签下命中的 archived 记录（复用 LibraryListView 的行组件）
```

## Flow

### 主列表筛选流程

```
用户输入搜索词 / 切换标签
  ↓
searchQuery / selectedTags 变化
  ↓ (150ms 防抖，仅搜索)
VM 重算 displayedRecords：
  records.filter { record in
    record.archived == false              // active only
    && searchQuery 子串匹配 (title|summary|tags|content)  // 大小写无关
    && (selectedTags.isEmpty || selectedTags.contains(where: record.tags?.contains ?? false))  // OR
  }
  ↓
若 selectedTags 非空 → 排序: tag-match-count desc → createdAt desc
否则 → 排序: createdAt desc
  ↓
VM 重算 archivedHitIDs：
  同样筛选逻辑，但 archive == true，记录 IDs
  ↓
VM 重算 tagCounts：
  对每个 tag，count = 满足 (searchQuery ∩ active) 且 tag in record.tags 的记录数
  ↓
UI 刷新：列表 + chips 数字 + banner
```

### 详情页归档流程

```
用户在详情页点击归档按钮
  ↓
VM.archiveRecord(id):
  record.archived = true
  record.archivedAt = Date()
  storage.save(record)
  ↓
若该记录是当前 displayedRecords 之一 → 立刻从列表消失
若该记录在 archivedHitIDs 中 → banner 数 +1
按钮文字变 "已归档 ✓"

用户再次点击 (取消归档)
  ↓
VM.unarchiveRecord(id):
  record.archived = false
  record.archivedAt = nil
  storage.save(record)
  ↓
若该记录满足当前筛选 → 重新出现在列表中
按钮文字恢复 "归档"
```

### Banner 点击流程

```
用户点击 "已归档 N 条匹配"
  ↓
NavigationLink push 到 LibraryArchivedMatchesView
  ↓
复用同一筛选条件 (searchQuery + selectedTags)
  ↓
只显示 archived == true 且命中的记录
  ↓
顶部 "归档命中" + 返回按钮
  ↓
用户在子页面点记录 → 正常进入详情页
```

## UI Visualization

### LibraryListView (主界面)

```
┌─────────────────────────────────────────────┐
│  🔍  搜索标题、摘要、标签、原文... │ ✕      │  ← 搜索栏 (sticky)
├─────────────────────────────────────────────┤
│  [工作 12] [想法 7] [会议 4] [待办 9] ...     │  ← 标签 chips (横滑)
├─────────────────────────────────────────────┤
│  ⓘ  已归档 3 条匹配 · 点击查看                │  ← archived 命中 banner (仅 >0)
├─────────────────────────────────────────────┤
│  周会纪要                                    │  ← 第 1 行: 标题
│  今天讨论了Q4规划，三个要点：营收增长、新产品...│  ← 第 2 行: 摘要 (2 行 + …)
├─────────────────────────────────────────────┤
│  超市购物清单                                │
│  买了牛奶、面包、苹果、鸡蛋，还买了一瓶酱油... │
└─────────────────────────────────────────────┘
```

### 状态：搜索 + 标签筛选激活

```
┌─────────────────────────────────────────────┐
│  🔍  Q4规划│ ✕                              │
├─────────────────────────────────────────────┤
│  [工作 2] [想法 1] [会议 1] [待办 0] ...     │  ← chip 数字反映搜索后命中
├─────────────────────────────────────────────┤
│  ⓘ  已归档 1 条匹配 · 点击查看                │
├─────────────────────────────────────────────┤
│  周会纪要                                    │  ← 含 2 个选中 tag，rank 1
│  今天讨论了Q4规划，三个要点：营收增长、新产品... │
├─────────────────────────────────────────────┤
│  想法速记                                    │  ← 含 1 个选中 tag，rank 2
│  下周想尝试新的产品方向...                     │
└─────────────────────────────────────────────┘
```

### 状态：无 LLM 分析的记录（无标签）

```
┌─────────────────────────────────────────────┐
│  🔍  搜索...                                │
├─────────────────────────────────────────────┤
│  暂无标签 — 分析记录后可启用筛选              │  ← 标签区提示文案
├─────────────────────────────────────────────┤
│  Q4 规划速记                                 │  ← title fallback (content[:30]+…)
│  今天讨论了...（content[30:80]）             │
└─────────────────────────────────────────────┘
```

### TranscriptionDetailView 档案按钮位置

```
┌─────────────────────────────────────────────┐
│  [☁ 在线升级识别]              [📦 归档]   │  ← HStack: 左=在线，右=归档
└─────────────────────────────────────────────┘
```

归档后：
```
┌─────────────────────────────────────────────┐
│  [☁ 在线升级识别]              [📦 已归档 ✓] │  ← 归档按钮填充态
└─────────────────────────────────────────────┘
```

## List Row Fallback（关键决策）

| 字段来源 | 有 LLM (record.title / summary 非空) | 无 LLM |
|---|---|---|
| 第 1 行（标题） | `record.title` | `String(record.content.prefix(30)) + "…"` |
| 第 2 行（摘要） | `record.summary` (2 行 + …) | `String(record.content.dropFirst(30).prefix(50)) + "…"` |
| 完全无内容 | "(无内容)" | "(无内容)" |

使用 `Text(…).lineLimit(2)` + `.truncationMode(.tail)` 实现截断。

## Error Handling

| 场景 | 行为 |
|---|---|
| 搜索词导致 0 active 命中 + 0 archived 命中 | 显示 "无匹配记录" + "清除筛选" 按钮 |
| 搜索词导致 0 active 命中 + N archived 命中 | 显示 banner "已归档 N 条匹配 · 点击查看" + 空列表 |
| 用户归档了一条记录但当前搜索命中它 | 记录从主列表消失；banner +1（若原本未在 banner 中） |
| 用户取消归档了一条当前命中的记录 | 记录重新出现在主列表顶部；banner -1 |
| 用户切到 Library tab 后立刻输入搜索 | 150ms 防抖后重算；中途再打字则重置定时器 |
| 搜索词仅匹配 archived，0 active | banner 显示 "已归档 N 条匹配"，空列表下方加 "查看归档命中" 按钮 |

## Constraints & Edge Cases

1. **schema 兼容：`Codable` 自动迁移** — 旧 JSON 文件无 `archived` / `archivedAt` 字段，解码为默认 `false` / `nil`，无需手动 migration。
2. **搜索性能：O(n × m)** — n=记录数，m=平均文本长度。当前数据量（< 几百条）下无需倒排索引。若未来 > 5000 条记录再考虑 SQLite FTS。
3. **filter 不跨 session 持久化** — 搜索词和选中标签只在当前 session 保留，App 冷启动后重置。归档状态持久化（写入 JSON）。
4. **archived 记录不参与 tagCounts 计算** — chip 上的数字仅基于 active 记录。
5. **chip 显示的 0 命中态** — chip 数字为 0 时仍显示（不变灰也不隐藏），维持 chip 列表顺序稳定。
6. **多 tag 选中 + 排序** — 命中数 = 记录 tags 与 selectedTags 的交集大小。例如：selectedTags={a,b,c}, record.tags=[a,c,e] → 命中数=2。
7. **空 tags 记录** — `record.tags == nil` 或 `[]` 时：搜索词命中 tags 字段视为空（不影响其他字段）；tag 筛选中视为"不含任何标签"（即不命中任何 tag filter，除非 0 selected）。
8. **archive 与 LLM 处理的关系** — 归档不影响 LLM 处理状态；已 completed 的归档记录仍显示其 title/summary/tags。
9. **archive 与 audio 的关系** — 归档按钮在所有记录上都显示（不依赖 audio file），与"在线升级识别"按钮的出现条件解耦。
10. **不存在 `RecordingViewModel`** — 不要新建。仅扩展现有 `TranscriptionViewModel`（per GLOSSARY）。
11. **不存在新 RecognitionMode** — 归档不影响 `assessAndEnhance` 调度（per ADR-0001）。

## i18n 新增键

| Key | zh-Hans | en |
|---|---|---|
| `Tab.Library` | `思录` | `Library` |
| `Library.Search.Placeholder` | `搜索标题、摘要、标签、原文` | `Search title, summary, tags, content` |
| `Library.NoResults` | `无匹配记录` | `No matching records` |
| `Library.NoTags` | `暂无标签 — 分析记录后可启用筛选` | `No tags yet — analyze records to enable filtering` |
| `Library.ArchivedBanner` | `已归档 %d 条匹配 · 点击查看` | `%d archived matches · tap to view` |
| `Library.ArchivedSublistTitle` | `归档命中` | `Archived matches` |
| `Library.ClearFilters` | `清除筛选` | `Clear filters` |
| `Detail.Action.Archive` | `归档` | `Archive` |
| `Detail.Action.Unarchive` | `取消归档` | `Unarchive` |
| `Detail.Action.Archived` | `已归档 ✓` | `Archived ✓` |

> Tab.History 旧键保留为 alias，引用处全部迁移到 Tab.Library。

## Files to Modify

| File | Change |
|---|---|
| `ios/AudioNote/Models/TranscriptionRecord.swift` | 新增 `archived: Bool` 和 `archivedAt: Date?` 字段 |
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` | 新增 search/filter state、计算属性、archive 动作 |
| `ios/AudioNote/Views/HistoryListView.swift` → `LibraryListView.swift` | 重命名 + 搜索栏 + chips + banner + 新行布局；新增 `LibraryArchivedMatchesView`（同文件内） |
| `ios/AudioNote/Views/ContentView.swift` | `Tab.History` → `Tab.Library` |
| `ios/AudioNote/Views/TranscriptionDetailView.swift` | actionsSection 加归档按钮（所有记录） |
| `ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings` | 新增 10 个键 |
| `ios/AudioNote/Resources/en.lproj/Localizable.strings` | 新增 10 个键 |
| `docs/GLOSSARY.md` | 新增 "思录 / Library"、"archived / archivedAt" 词条 |

## Files NOT Modified

- `ios/AudioNote/ViewModels/SettingsViewModel.swift`
- `ios/AudioNote/Services/*`（无 LLM 改动；归档不影响 SDK）
- `ios/AudioNote/Utilities/*`（NetworkMonitor、Logger 等）
- `ios/AudioNote/Models/RecognitionLanguage.swift`、`LLMStatus` 等
- 任何 ADR — 此设计不锁定新决策，不创建新 ADR