# AI Optimization By Default — Design Spec

> **Date**: 2026-09-24
> **Status**: ACCEPTED
> **Author**: karsa
> **Supersedes-partially**: ADR-0001(assess-and-enhance dispatcher 中 `optimizationEnabled` gate)

## 1. Problem

`audioNote:enableLLMOptimization` 是一个 `UserDefaults` 布尔开关,在
`TranscriptionViewModel.assessAndEnhance`(`ios/AudioNote/ViewModels/TranscriptionViewModel.swift:237`)中
作为 LLM 调用的第三个 gate(与"有 Provider + 有网"并列)。

该 toggle 在 Settings UI(`ios/AudioNote/Views/SettingsView.swift:48-54`)作为
"启用录音内容优化" 控件暴露,带 `disabled(!canEnableOptimization)` 保护——未配 Provider 时
无法打开。

**核心问题**:

1. **产品价值层面**:APP 的核心价值 = "录音 → 结构化笔记(标题/摘要/标签)",
   没有 LLM 这步,产品形态不成立。
2. **隐式 consent 已成立**:用户装机即同意使用本产品 = 同意接受"录音文本会被整理",
   不需要在每条录音上再确认一次。
3. **opt-out 用户群体小**:真正能主动用 OFF 的 = "已配 Provider + 已配 API Key + 在线 +
   **故意**不想让本条录音上云"的用户。这个群体小,但诉求真实。
4. **副作用 bug**:`@State private var optimizeEnabled = false` 从未从 UserDefaults 读初值
   (`SettingsView.swift:14`),造成 UI 状态/真实状态不一致——用户开启 → 退出 → 重进 Settings
   显示 OFF,但 LLM 仍在跑。

## 2. Goal

- **移除 UI 开关**:消除用户认知负担与状态不一致 bug
- **简化 `assessAndEnhance`**:LLM 调用由"有 Provider + 有网"决定,**不再读 UserDefaults**
- **Consent 锚到 Provider 配置**:在 `ProfileDetailView` 顶部加清晰的数据流向披露段,
  用户配 Provider 时一次性看到
- **顺手优化 prompt**:为常见同音词错误("语音"→"200题"等)提供 anchor,
  提升 LLM 修复口误的稳定性

## 3. Non-Goals

- 不重做 LLM 调用逻辑(`LLMService.optimizeAndProcess` 本身不动)
- 不改 JSON schema(ADR-0002 锁定)
- 不动 Provider 数据模型与 LLMService 公共签名(ADR-0003 锁定)
- **不做** per-recording opt-out(决定:不值得为此保留 hidden switch;代价 > 价值)

## 4. Detailed Design

### 4.1 简化后的 `assessAndEnhance`

```swift
private func assessAndEnhance(record: TranscriptionRecord, originalText: String) async {
    switch record.recognitionMode {
    case .online:
        // 默认走 LLM;Provider 缺失 / 离线由 processWithLLM 自身处理
        await processWithLLM(recordId: record.id, originalText: originalText)

    case .onDevice:
        if NetworkMonitor.shared.checkConnectivity() {
            // 在线:直接走 LLM,processWithLLM 已覆盖 enhance 语义
            await processWithLLM(recordId: record.id, originalText: originalText)
        }
        // 离线:啥也不做(原文已落盘)

    case .failed:
        if NetworkMonitor.shared.checkConnectivity() {
            await retryRecognitionFromFile(recordId: record.id)
        }

    default:
        break
    }
}
```

### 4.2 UI 改动

**删除**(`ios/AudioNote/Views/SettingsView.swift`):
- `Section`("优化开关 + 测试连接",L40-64):包含 Toggle、Test 按钮、Header/Footer
- `@State private var optimizeEnabled: Bool = false`(L14)
- Toggle + `onChange`(L48-54)

**Test 连接按钮迁移**:并入 Provider profiles 段(成为该段 footer 上的 action),
保留可达性。**默认方案**:作为该段最下方一个独立的按钮行。

**新增**(`ios/AudioNote/Views/ProfileDetailView.swift`):
- 在 `mode == .create` 的表单顶部加 **"数据流向说明"** Section
- 文案(中英两份,`*localized` 形式):

> **数据流向说明**
>
> 配置 AI Provider 后,iOS 端将把**录音转成的文本**发送给该 Provider,
> 以生成优化文本 / 标题 / 摘要 / 标签。
>
> 原始**音频数据始终只与 Apple 通讯**(设备本地识别或 Apple Cloud 识别),
> **不会**发送给 AI Provider。
>
> 如不希望文本上云,请不要配置 Provider,此时录音文本仅做本地识别与保存。

### 4.3 代码清理清单

| 文件 | 改动 |
|---|---|
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:237` | 删 `let optimizationEnabled = ...` |
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:240-244` | `.online` 分支去掉 `if` 包裹 |
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:246-254` | `.onDevice` 分支简化 |
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift:336` | `retryRecognitionFromFile` 内嵌读取删 |
| `ios/AudioNote/Services/ProviderProfileStore.swift:146` | 删 `defaults.set(false, forKey: "audioNote:enableLLMOptimization")` |
| `ios/AudioNote/ViewModels/SettingsViewModel.swift:45-51` | 删 `canEnableOptimization` |
| `ios/AudioNote/Resources/*.lproj/Localizable.strings` | 删 `Settings.LLM.Optimize.Title/Header/Footer` |
| `docs/GLOSSARY.md` | 删 `enableLLMOptimization` 条目 |

### 4.4 不动的东西

- JSON schema(ADR-0002 锁定)
- LLMService 公共签名(ADR-0003 锁定)
- ProviderProfileStore 数据模型(ADR-0003 锁定)
- Prompt 文本本身不在"用户可配置"约束内(ADR-0003:lock 的是"不可让用户改",代码可改)

## 5. Prompt 修改

### 5.1 当前 prompt(`ios/AudioNote/Services/LLMService.swift:107-118`)

```
你是一个语音转录文本优化助手和笔记组织助手。原始文本由 iOS Speech SDK 生成,可能存在标点缺失、同音词错误等问题。

请完成以下任务:
1. 优化转录文本,修正标点和同音词错误
2. 为笔记提取标题(简短明了)
3. 生成50-100字的摘要
4. 提取3-5个标签,每个标签附带 0.0-1.0 的相关性分数(1.0=高度相关,0.0=边缘相关),按分数从高到低排序

请严格按照以下JSON格式返回,不要添加任何解释或 markdown 标记:
{"optimizedText": "...", "title": "...", "summary": "...", "tags": [{"name": "...", "score": 0.0}, ...]}
```

### 5.2 新 prompt(候选)

```
你是一个语音转录文本优化助手和笔记组织助手。原始文本由 iOS Speech SDK 生成,可能存在以下问题:

- 标点缺失或错误
- 同音/近音词错误(例如"语音"→"200题"、"摘要"→"简要"、"转录"→"转入"、"会议"→"回议")
- 重复词、无意义语气词("嗯"、"那个"、"然后那个"等)

请完成以下任务:

1. 优化转录文本:
   - 修正明显的标点和同音词错误,根据上下文推断正确用词
   - 不要翻译,保留原始语言(中文录音保持中文)
   - 不要过度修改用户措辞;不确定的内容保留原文
   - 保留原始语义和口语化风格
2. 为笔记提取标题(简短明了,8-20 字)
3. 生成 50-100 字摘要
4. 提取 3-5 个标签,每个标签附带 0.0-1.0 相关性分数(1.0=高度相关,0.0=边缘相关),按分数从高到低排序

请严格按照以下 JSON 格式返回,不要添加任何解释或 markdown 标记:
{"optimizedText": "...", "title": "...", "summary": "...", "tags": [{"name": "...", "score": 0.0}, ...]}
```

### 5.3 关键改进

| 改动 | 理由 |
|---|---|
| 列典型同音词 anchor | 模型识别率明显上升 |
| 加"不要翻译" | 阻止模型把中文录音当英文处理 |
| 加"不要过度修改" + "不确定保留原文" | 留容错,避免把对的也改错 |
| 加语气词清理 | 顺手提升文本质量 |
| 标题 8-20 字约束 | 防止标题过长 |

## 6. 验证清单(见 plan Task 4)

| 场景 | 预期 |
|---|---|
| 未配 Provider + 在线录音 | 原文保存,无 LLM 处理 |
| 已配 Provider + 在线录音 | 自动 LLM 处理(优化文本 / 标题 / 摘要 / 标签) |
| 已配 Provider + 离线录音 | 原文保存,`llmProcessingStatus=.failed`,网络恢复后补跑 |
| 已配 Provider + 识别失败 | `retryRecognitionFromFile` 走一遍 |
| 录音中改语言 | (无关,验证不回归) |
| 打开 Settings 看 UI | 看不到 toggle,看到 Profile 列表 + Status + Test 连接 |
| 创建 Provider | 顶部看到"数据流向说明" |
| 关闭 App 再开 | 旧 `audioNote:enableLLMOptimization` UserDefaults 值变孤儿,无影响 |

## 7. 迁移

无显式用户级迁移:

- 旧的 `audioNote:enableLLMOptimization` UserDefaults 值在重启后变成孤儿,**无功能影响**
  (再也没人读它)。
- `runLegacyTokenMigration` 的 `set false` 行一并删除(无后续引用)。
- **不弹 disclosure 重弹屏**:老用户的"已配 Provider"动作 = 已 consent,无需再问一次。
- 新用户首次启动 → 看到 Settings 时 toggle 已不存在。

## 8. 风险与开放问题

| 风险 | 缓解 |
|---|---|
| 老用户觉得"突然不工作了" | changelog / 提交说明明确讲:"取消开关,文本上云由 Provider 配置决定" |
| Provider 配置后才后悔,想退掉 | 简单删掉 Provider 即可(详见 §4.2 披露文案最后一句) |
| 测试覆盖空白 | 本次不改测试,因 ADR-0001 列出的 `assessAndEnhance` 测试集本来就未实现,沿用"see RISKS, not yet written"备注 |

## 9. 关联

- **ADR-0001**(assess-and-enhance pipeline)— 本 spec 部分 supersede:优化开关不再 gate
- **ADR-0002**(merged LLM call)— 不动
- **ADR-0003**(multi-provider LLM)— 不动(prompt 修改走代码而非用户配置)
- Spec: `docs/superpowers/specs/2026-09-23-library-search-tag-archive-design.md`(无交叉)
- ADR: 本次新增 `docs/decisions/0004-ai-optimization-by-default.md`
- Plan: `docs/superpowers/plans/2026-09-24-ai-optimization-by-default-plan.md`