# 数据层架构：状态清单、生命周期、异常流程与 UI 契约

| Field | Value |
|---|---|
| **Status** | P0 IMPLEMENTED (2026-10-22, `be62b46` + follow-up); P1/P2 pending |
| **Date** | 2026-10-22 |
| **Supersedes** | — |
| **Related ADR** | 待写（ADR-0007） |
| **Related** | `2026-09-24-files-app-storage-design.md`（存储位置的选择）、`2026-10-22-launch-recovery-sweep-design.md`（启动 sweep） |

## 1. 摘要：先回答那个问题

**「APP 删了数据还在，APP 重新回来，数据还能不能在 APP 里体现？」**

**数据在。app 里一开始体现不出来；用户重新选一次那个文件夹，就全部回来了。**

分三步说：

| 步骤 | 发生什么 | 依据 |
|---|---|---|
| 删掉 app | `On My iPhone > AudioNote/` 里的文件**全部保留**——那是 Files app 自己的存储，不是 AudioNote 的沙盒 | 实测：设备上的 bookmark 解析到 `com.apple.FileProvider.LocalStorage//fid=...`，路径是 `File Provider Storage/audionote`，归属 Files app 的 provider |
| 重新装 app | **app 不知道数据在哪**。folder bookmark 和路径兜底都存在 `UserDefaults` 里，随 app 一起没了 → `resolveSync()` 返回 nil → `isReady == false` → 显示 OnboardingView | `StorageCoordinator.swift:5,12,68,117`；`ContentView.swift:12-16` |
| 用户重新选一次文件夹 | 记录、关系、音频**全部回来了** | 重新授权 = 重新拿到 bookmark |

**但这里有一个真实的坑，而且 app 目前完全无法察觉：**

app 不知道用户上次选的是哪个文件夹。用户重新装之后看到 OnboardingView，文案是「请选择一个文件夹用于保存录音转写数据。卸载 App 后数据仍会保留,并可通过"文件"App 查看。」——**这句话没有告诉用户「要选回同一个文件夹」**。如果用户新建了一个叫 `AudioNote` 的空文件夹，app 会正常地显示一个**空库**，用户会认为数据没了。真实数据在 Files app 里另一个 `AudioNote` 里躺着。

这是 iOS 的硬限制造成的：**没有 bookmark 就没有权限，app 无法主动扫描 Files 目录**。所以「自动找回」不可能做到，只能做到「让用户知道要找回什么」+「让 app 别把『够不着』显示成『空』」。

**而现在恰恰是后者没做到**（§4.3、§5.3）。

## 2. 状态清单：app 的全部状态住在哪

app 里的状态分三类存储，**三类的生命周期完全不同**：

### 2.1 用户选的文件夹（`On My iPhone > AudioNote/`）

生命周期 = **数据本身**。卸载 app 不影响。

| 文件 | 内容 | 写入方 |
|---|---|---|
| `transcriptions.json` | `[TranscriptionRecord]` 数组 | `TranscriptionStorage`（唯一的记录写入路径） |
| `relatedNotes.json` | `[NoteRelation]` 边集 | `RelatedNotesStorage` |
| `Recordings/{UUID}.m4a` | 音频 | `AudioRecorderService` |

### 2.2 UserDefaults（app 沙盒）

生命周期 = **app 安装**。卸载即消失。

| Key | 内容 | 谁写 |
|---|---|---|
| `audioNote:storage:audioNoteFolderBookmark` | security-scoped bookmark —— **访问凭证** | `StorageCoordinator` |
| `audioNote:storage:audioNoteFolderPathFallback` | 路径字符串兜底 | `StorageCoordinator` |
| `audioNote:llmProfiles` | `[LLMProviderProfile]` | `ProviderProfileStore` |
| `audioNote:activeLLMProfileId` | 当前启用的 profile | `ProviderProfileStore` |
| `audioNote:llmNeedsProviderSetup` | 一次性 toast 标志 | `ProviderProfileStore` |
| `audioNote:lastUsedLanguage` | 上次用的识别语言 | `TranscriptionViewModel:93,101` |
| `audioNote:language` | UI 语言 | `LanguageManager:87,94` |

### 2.3 Keychain

生命周期 = **设备**。跨卸载重装保留（Apple 未承诺，但实际行为如此）。

| 项 | 内容 | 谁写 |
|---|---|---|
| `kSecAttrAccount = profile.id.uuidString` | 每个 profile 一条 API key | `ProviderProfileStore:75`，读于 `:127` |

### 2.4 只在内存里

**每次启动都丢**：`isRecording` / `transcribedText` / `partialText` / `recordingDuration` / `currentRecordId` / `isOptimizing` / `isLLMProcessing` / `llmProcessingFailed` / `isTextOptimized` / `recognitionMode` / `isEnhancing` / `errorMessage` / `isArchiveMode` / 播放进度。

**这些是对的**——它们是「当前操作」而不是「持久状态」。记下来反而是 bug。

### 2.5 系统层（app 管不着，但值得记一笔）

| 状态 | 卸载重装后 |
|---|---|
| 麦克风 / 语音识别授权 | **保留**（系统级）。`PermissionsManager` 每次从系统重查，不自己存 |
| iOS 权限弹窗「上次问过没」 | 保留，所以重装后不会重新弹 |

## 3. 三条生命周期的错配

把 §2 叠在一起看，只有一句话：

> **数据跟着「文件夹」活，凭证跟着「app」活，密钥跟着「设备」活。**

于是所有异常流程都是这个错配的推论：

```
        卸载重装
  数据 ──────────► 还在        (Files app 的存储)
  凭证 ──────────► 没了        (UserDefaults 随 app 死)
  密钥 ──────────► 还在，但认不出了  (profile.id 随 UserDefaults 一起没了)
```

第三行值得单独说：API key 在 Keychain 里**活着**，但它的索引是 `profile.id`，而 profile 在 UserDefaults 里、已经没了。**结果：key 变成孤儿**——用户必须重新填一次 API key、重建一次 profile，尽管密钥本身一直在设备上。

## 4. 异常流程全景

「正常流程」= 选好文件夹 → 录音 → 保存 → 看列表。以下是**全部**已识别的分支。

### 4.1 数据层

| # | 异常 | 现在会怎样 | 应该怎样 |
|---|---|---|---|
| A1 | **卸载重装** | 数据在；app 回到 OnboardingView；**用户可能选错文件夹 → 看到空库 → 以为数据没了** | 明确告诉用户「选回同一个文件夹」；空库时给出提示 |
| A2 | **用户在 Files 里删掉 `AudioNote` 文件夹** | `resolveBookmarkSync` 发现 `fileExists == false` → **删掉 bookmark** → OnboardingView。数据已死，app 无从知晓 | 区分「文件夹没了」和「没配过」，给出可读的原因 |
| A3 | **用户在 Files 里移动/改名文件夹** | bookmark 跟随文件 ID，通常仍能解析 → app 无感。**若移动到 iCloud Drive** 可能解析失败 → 同 A2 | 可接受，但要能给出原因而不是空白引导页 |
| A4 | **`transcriptions.json` 损坏**（外部编辑 / iCloud 冲突 / 磁盘满） | `loadAll()` 抛 `decodingFailed` → `loadHistory` catch → `errorMessage` 设上、`historyRecords` 留空 → **思录页显示「没有记录」空状态**；`errorMessage` **只在录音页弹 alert**（`RecordingView.swift:85-86`） | 必须显示成「读取失败」，不能显示成「空」 |
| A5 | **文件夹可达但 `transcriptions.json` 不存在** | `loadAll()` 返回 `[]`（`:47`）→ 同样是「空」空状态。**无法区分「还没录过」和「文件被外部删了」** | 区分两者 |
| A6 | **有权限但访问被拒**（FileProvider 抽风） | 同 A2：bookmark 被丢弃 | 保留 bookmark，报告 `unreachable` |
| A7 | **`relatedNotes.json` 损坏** | `RelatedNotesStorage.loadAll()` 抛 → 调用方 `try?` 吞掉 → 关系静默消失（按设计，关系永不重算 → 永久丢失） | 至少不要影响主列表；可考虑随主文件一起备份 |
| A8 | **音频文件被外部删除** | 记录还在，播放失败。app 不校验 | 可选：列表标「音频丢失」 |
| A9 | **孤儿 `.m4a`**（JSON 丢了/坏了，音频还在） | app 看不见，也不清理。数据其实还在 | 可选：恢复时扫描 `Recordings/` 找回孤儿 |
| A10 | **磁盘满** | 录音写失败 / JSON 写失败 → `errorMessage` | 已有 |
| A11 | **多设备写同一个 iCloud 文件夹** | 整文件 last-writer-wins，互相覆盖 | 超出本 app 范围 |

### 4.2 配置层

| # | 异常 | 现在会怎样 | 应该怎样 |
|---|---|---|---|
| B1 | **卸载重装** | profile 没了 → 用户要重建 profile + **重填 API key**（尽管 key 在 Keychain 里还活着） | profile 跟着数据走 → 只需重填 key |
| B2 | **Keychain 条目残留**（profile 被删） | `ProviderProfileStore.delete` 会清 keychain ✓，但卸载重装后 profile 没了、key 留下 → 孤儿 | 孤儿 key 应可在「重填 API key」时按稳定 id 找回 |
| B3 | **识别语言 / UI 语言** | 随 app 死 → 重装后回默认 | **保持现状**，这是「偏好」不是「数据」 |

### 4.3 恢复层（与启动 sweep 文档合并考虑）

| # | 异常 | 现在会怎样 |
|---|---|---|
| C1 | **上次会话搁浅的记录**（`.pending` / LLM `.failed`） | 永远搁浅，除非本次会话内发生一次网络断→连跳变 → 见 `2026-10-22-launch-recovery-sweep-design.md` |

## 5. 数据层设计：存储状态机

### 5.1 现状：一个 Bool 承担了太多

`StorageCoordinator.isReady` 现在要同时表达五件不同的事：

| 它为 true 时，实际可能是 | 用户看到的 |
|---|---|
| 从没配过，但用户刚选好文件夹 | 正常主界面 |
| 配过，文件夹被删了 | OnboardingView（**无原因说明**） |
| 配过，bookmark 解析失败 | OnboardingView（**无原因说明**） |
| 配过，folder 存在但 `transcriptions.json` 坏了 | 主界面 + **空列表** |
| 配过，folder 存在但还没有 `transcriptions.json` | 主界面 + 空列表（**这个是对的**） |

`bootstrap()` 的失败分支（`:145-147`）只设 `isReady = false`，**不设 `errorMessage`** —— 所以用户看到的引导页不知道自己为什么被踢回来。

### 5.2 目标：一个显式的状态枚举

```swift
enum StorageState: Equatable {
    case unconfigured                 // 从没选过文件夹
    case unreachable(UnreachableReason)  // 选过，现在够不着
    case empty                        // 目录可达，里面没有 transcriptions.json
    case loaded                       // 正常
    case corrupted(underlying: Error)  // 文件在，解析失败
}
```

**关键点：`empty` 和 `corrupted` 必须是两个不同的状态。** 现在它们在 UI 上是同一个画面（空列表），而一个的意思是「你还没录过」，另一个的意思是「你的数据我读不出来」——后者如果显示成前者，用户会以为数据没了。

`unreachable` 要带原因，因为处置方式不同：

```swift
enum UnreachableReason {
    case bookmarkInvalid              // bookmark 解析不出来 → 需要重选
    case folderMissing                // 文件夹不在了 → 数据可能已被删除
    case accessDenied                 // 权限被拒 → 可能瞬时，可能要重选
    case notSecurityScoped            // 老版本留下的坏 bookmark → 重选
}
```

### 5.3 状态迁移

```
                    ┌─────────────────────────────────────────┐
                    │                                         │
              pick(folder)                                  │
   unconfigured ────────────► empty ───first save──► loaded ──┤
        ▲                       ▲                  │         │
        │                       │                  │         │ 文件被外部删
        │ 重选                  │ 文件被外部删      │ 损坏    ▼
        │                       │                  ▼      empty
        │                       └────────────  corrupted
        │                                    (显示错误)
        │
        └── 卸载重装 ──► unconfigured   ← 数据还在 Files 里，凭证没了
                         
   loaded ── 卸载重装 ──► unconfigured ── pick(同一个文件夹) ──► loaded  ← 数据全回来了
                                                        
                        └── pick(另一个文件夹) ──► empty  ← 「数据消失」的错觉
```

**最后两行就是这个设计的全部意义**：app 无法阻止用户在重装后选错文件夹，但可以让那一刻**不是静默的**。

### 5.4 「选错文件夹」怎么才能被发现

app 没有权限扫描 Files 目录，所以**做不到自动检测**。能做到的是三件事：

1. **重装后明确告诉用户「要选回同一个文件夹」**——需要 app 知道「这是重装」。
2. **用 Keychain 里的一个哨兵值判断「这是重装」**。Keychain 跨卸载重装保留 → 哨兵还在 → 知道之前装过 → 引导文案可以更具体：「你之前用过 AudioNote。数据保存在「文件」App 的 **AudioNote** 文件夹里，请再次选择**同一个**文件夹以找回数据。」
3. **在设置里显示当前数据目录的路径**，让用户随时能确认自己指对了地方。

## 6. UI 交互契约

现状和目标：

| 状态 | 现在的 UI | 目标 UI |
|---|---|---|
| `unconfigured` | OnboardingView，文案讲「怎么存」 | 首次：讲「怎么存」；**重装**：讲「怎么找回」 |
| `unreachable(.folderMissing)` | OnboardingView，无原因 | OnboardingView + 「上次使用的文件夹已不存在。数据可能已被删除，或被移到了别处。」+ 重新选择入口 |
| `unreachable(.accessDenied)` | OnboardingView，无原因 | OnboardingView + 「无法访问上次使用的文件夹。可能是 iCloud 未下载或权限被撤销。重试 / 重新选择」 |
| `empty` | 思录页「没有记录」空状态 | **保持**（这个是对的） |
| `corrupted` | 思录页「没有记录」空状态 + 录音页一个 alert | **思录页显示错误**：「无法读取记录文件（已损坏）。音频文件仍在文件夹中。」+ 恢复建议 |
| `loaded` | 列表 | 列表 |

**一条硬规则：`corrupted` 永远不能显示成空列表。** 空的含义是「没有数据」，损坏的含义是「有数据但我读不出来」——后者在用户看来等同于数据丢失，必须说出来。

## 7. 改造项分级

### P0：低代价、高收益

| # | 改动 | 位置 | 为什么 P0 |
|---|---|---|---|
| P0-1 | 引入 `StorageState`，替换 `isReady` 这个 Bool 的多重语义 | `StorageCoordinator` | 这是其余所有项的地基 |
| P0-2 | `corrupted` / `unreachable` 在**思录页**显示明确错误，不显示成空列表 | `LibraryListView` + `TranscriptionViewModel` | 消除「静默数据丢失」的错觉 |
| P0-3 | `bootstrap()` 失败时设 `errorMessage`，别让引导页无声 | `StorageCoordinator:145` | 一行 |
| P0-4 | `resolveBookmarkSync` 在**瞬时失败**时不要丢弃 bookmark | `StorageCoordinator:78,84,97` | 丢掉的是唯一的访问凭证，丢了用户必须重选 |
| P0-5 | OnboardingView 文案加「重新安装后请选回同一个文件夹」 | `OnboardingView` | 直接命中 A1 |
| P0-6 | 区分「空库」和「记录文件没了但音频还在」 | `TranscriptionStorage.loadOutcome` → `.noFileButAudioRemains(count)` | 命中 A5。见下 |

**P0-6 是写完代码后补的。** 复查时发现 `loadOutcome()` 的 `.noFile` 仍然把「还没录过」和「文件被外部删了」混在一起——这和规则 1 要消灭的是同一类错误：一个文件夹里有 47 个 `.m4a`、索引没了的用户，被告知「你还没录过任何东西」。`loadOutcome` 现在会数一遍 `Recordings/` 里的 `.m4a`，界面据此说「记录文件不见了，但 N 个录音还在」。

**实现时偏离初稿的地方**：初稿设想的是一个统一的 `StorageState`（含 `.corrupted`）。实现时拆成了两个枚举——`StorageCoordinator.StorageState` 管**访问**（能不能碰到目录），`TranscriptionStorage.LoadOutcome` 管**文件**（能不能解析）。因为两半落在**不同的界面**上（引导页 vs 思录页），而且「JSON 解析失败」是存储层的事，不该让目录协调器去关心。`isReady` 保留为计算属性 `state == .ready`，40 来个既有调用点一行没改。

### P1：需要一点工作量

| # | 改动 | 为什么 |
|---|---|---|
| P1-1 | **provider profiles 从 UserDefaults 搬到数据文件夹**（`AudioNote/providers.json`） | 让「数据 + 加工它的规则」同生共死。搬完之后卸载重装只需重填 API key，不需要重建 profile |
| P1-2 | **`transcriptions.json` 写 `.bak`**：写新文件前保留上一版；加载失败回退 | 把「一次损坏 = 全部记录消失」变成「丢最后一次写入」。写入已经是 `.atomic`，所以只需要加一层备份 |
| P1-3 | Keychain 哨兵值，用来识别「这是重装」 | 支撑 P0-5 的差异化文案 |
| P1-4 | API key 按**稳定 id**（如 provider 类型）存，不按随机 profile.id | 卸载重装后 key 能直接找回，不用重填 |
| P1-5 | 设置里显示当前数据目录路径 | 用户可自检 |

### P2-1 的否决理由（2026-10-22）

**检测**已经做了（P0-6：`loadOutcome()` 数 `Recordings/` 里的 `.m4a`，界面说「记录文件不见了，但 N 个录音还在」）。**重建**不做。

三条理由：

1. **触发频率低。** 让 `transcriptions.json` 消失的是「在 Files app 里误删」「iCloud 同步冲突」「磁盘满写坏」。前两种是低频意外；第三种被 `.atomic` 挡住了大半（写入要么整份落地要么不落地）。
2. **大多数情况下根本不需要重建。** 真机验证时确认了最常见的情形：文件是**被改名**而不是被删除——改回来，58 条记录连标题、摘要、标签一起原封不动地回来。检测 + 提示已经足够，用户自己就能救。
3. **重建的代价和它要救的东西不成比例。** 58 个孤儿文件要重建，就是 58 次在线识别 + 58 次 LLM 调用——一次批量 API 账单，换一个低频意外的兜底。

（技术上可行：文件名就是 `{UUID}.m4a`，UUID 与记录一一对应，重新跑一遍识别就能把正文写回去，`createdAt` 可用文件修改时间补。**不做不是因为做不到，是因为不值。**）

### P2：可选

| # | 改动 | 为什么 |
|---|---|---|
| P2-1 | ~~恢复时扫描 `Recordings/` 找孤儿音频，重建记录~~ | **已否决（2026-10-22）。** 见下 |
| P2-2 | 记录「音频文件已丢失」状态 | 外部删了音频 |
| P2-3 | `relatedNotes.json` 也做备份 | 关系永不重算，丢了就永久没了 |

### 明确不做

- **不做 iCloud 同步 / 跨设备**。`2026-09-24-files-app-storage-design.md` 锁定决策 #9 已明确排除。
- **不做导出/导入 UI**。同文档「Out of scope」已排除。
- **不把 API key 明文写进文件夹**。密钥留在 Keychain，只改它的索引方式（P1-4）。
- **不做自动扫描 Files 目录找回文件夹**。没有 bookmark 就没有权限，这是 iOS 的硬限制。

## 8. 与「启动 sweep」的关系

两份文档是**同一条问题线的两半**：

| | 启动 sweep 文档 | 本文档 |
|---|---|---|
| 问的问题 | 数据在，但**活没干完** | 数据在，但**app 够不着 / 读不出来** |
| 症状 | 记录停在「待识别」，直到用户碰巧断网重连 | 列表空、引导页重来、以为数据没了 |
| 解法 | 接上缺失的触发器 | 引入显式的存储状态机 + UI 契约 |

**接口**：启动 sweep 只应在 `StorageState == .loaded` 时运行。`corrupted` / `unreachable` 时跑 sweep 没有意义——数据都读不出来。改造时让 sweep 读 `StorageCoordinator.shared.state` 而不是 `isReady`。

**优先级**：本文件的 P0 是「用户以为数据没了」的解药，比启动 sweep 更该先做。启动 sweep 解决的是「数据在但没做完」，用户至少还能看到那条记录。

## 9. 真机验证结果（2026-10-22，iPhone Air / iOS 26.3）

| 场景 | 期望 | 实测 |
|---|---|---|
| 正常路径 | 思录页记录都在 | ✅ |
| 存储状态改造后仍正常 | 同上 | ✅ |
| 孤儿音频提示 | 思录页显示「记录文件不见了 / N 个录音还在」 | ✅ 数出 58 个 |
| 修复 #1（改文本不丢 LLM 元数据） | 详情页 title/summary/tags/「优化后」badge 仍在 | ✅ |

**P0 已验证通过。** P1/P2 未实现。

## 10. 现在的状态

- **P0 已实现并真机验证**（`be62b46` + `1f05039`），见 §9。
- 启动 sweep 的 spec（`2026-10-22-launch-recovery-sweep-design.md`）已写，其 §4.1 的四步拆分与本文件无冲突；§4.5 已补上「sweep 只在 `state == .ready` 时跑」的前置条件。
- 建议顺序：**启动 sweep → P1**。P1-1（profiles 搬进文件夹）会让「卸载重装」这条路彻底通顺，值得单独做一个 ADR。
