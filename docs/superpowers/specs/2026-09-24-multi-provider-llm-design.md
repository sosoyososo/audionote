# 多 Provider LLM 配置(用户自管)

**Date**: 2026-09-24
**Status**: Draft
**Supersedes**: (none — replaces `llm.karsa.info` proxy pattern documented informally in ADR-0002 / spec 2026-04-09-merge-llm-calls-design.md / 记忆文件; see "过时文档清单" section)
**Related ADR**: 新写 `docs/decisions/0003-multi-provider-llm.md`(本 spec 通过后起草)

## Overview

当前 LLM 调用通过 `llm.karsa.info` proxy 走 `karsa` 私域 API server,token 由用户在 Settings 配一个全局 `audioNote:llmToken`。这种"服务端中转"模式不适合对外发布——用户用了我们 App 就要走我们的 server,既不隐私也不灵活,且 token 用量计费我们兜底。

本次设计**全面替换**为"用户自管 Provider Profile"模式:

1. 用户在 App 内直接配 N 个 **LLM Provider Profile**,每个 profile 含 `displayName` / `baseURL` / `model` / `requiresAPIKey` / `apiKey`(Keychain 存)
2. 协议:**OpenAI Chat Completions 兼容**(POST `<baseURL>/chat/completions`,Bearer auth,响应取 `choices[0].message.content`)。覆盖 OpenAI / DeepSeek / Groq / Together / Ollama / LM Studio / 任意兼容端点
3. 一次只能有一个 **active profile**,所有 LLM 调用走 active profile
4. **失败仅报错**,UI 提示;不自动 fallback
5. API Key 改存 **Keychain**(`kSecClassGenericPassword`),不再明文 UserDefaults
6. 现有数据结构 / prompt / 调度 / UI 框架**全部保留**,只换 LLM 调用的 provider 来源

### 范围边界(显式)

| 替换 | 不替换 |
|---|---|
| LLM HTTP 调用方(baseURL / model / auth) | `TranscriptionRecord` schema(包括 `tags: [TaggedItem]`) |
| Token 存储(UserDefaults 明文 → Keychain) | `LLMOptimizeAndProcessResult` 4 字段 JSON schema |
| Settings UI(token 单字段 → provider profile 列表+详情) | `TranscriptionViewModel.assessAndEnhance` 3-case 调度 |
| Settings 验证逻辑(token 测通 → profile ping) | `RecognitionMode` 枚举 |
| 老 token key 迁移路径 | `SpeechRecognizer` / `TranscriptionStorage` / `NetworkMonitor` |
| 删除死代码入口 | 3 份 prompt 文案(锁在 LLMService 内部) |

## Design Decisions(已通过 brainstorming 确认)

| 决策 | 选择 | 理由 |
|---|---|---|
| Provider 协议 | 仅 OpenAI Chat Completions 兼容 | 覆盖最广,实现最小;用户已熟悉 |
| 失败策略 | 仅报错,UI 提示 | 符合"用户自己负责"的产品定位 |
| Profile 数量 | 多 profile,可手动切换 active | 用户可能在本地 Ollama 和云端 DeepSeek 之间切换 |
| API Key 存储 | Keychain `kSecClassGenericPassword` | 安全;每个 profile 独立 |
| 旧 token 迁移 | 静默清除 + 一次性 toast 提示 | 不打扰用户,但告知 |
| Prompt 是否可配 | 不可配,写死在 `LLMService` 内部 | 保护 4 字段 schema 不被破坏;`extractFirstJSONObject` 兜底 |
| 重试 | 为 `optimizeAndProcess` 加 retry(从 1 次提到 3 次) | 本地模型启动慢,多给几次机会 |
| 死代码 | 删除 `process()` / `optimize()` / `callAPI()` / `callOptimizeAPI()` | 它们已无外部 caller(2026-09-24 codegraph 验证) |

## Data Model

### 新增 `LLMProviderProfile`

新文件:`ios/AudioNote/Models/LLMProviderProfile.swift`

```swift
struct LLMProviderProfile: Codable, Identifiable, Hashable {
    /// 主键。Keychain 用此 id 作为 account 字段。
    let id: UUID

    /// 用户起的名字。Settings 列表里显示这个,不是 URL。
    var displayName: String

    /// OpenAI 兼容端点的 chat completions URL。
    /// 例如:
    ///   https://api.openai.com/v1/chat/completions
    ///   https://api.deepseek.com/v1/chat/completions
    ///   http://localhost:11434/v1/chat/completions  (Ollama)
    ///   http://localhost:1234/v1/chat/completions   (LM Studio)
    var baseURL: URL

    /// 模型名,透传给 provider。例如 gpt-4o-mini / deepseek-chat / qwen2.5:7b
    var model: String

    /// 如果为 false,LLM 调用时不带 Authorization header(Ollama / LM Studio 默认如此)。
    /// 如果为 true,apiKey 必须非空,否则 LLMError.apiKeyRequired。
    var requiresAPIKey: Bool

    /// 创建时间。仅用于 UI 排序,不影响逻辑。
    var createdAt: Date
}
```

**约束**:
- `baseURL` 必须是 `https://` 或 `http://localhost`/`http://127.0.0.1`;非 https 远程 URL 应警告(防误粘贴公网明文 URL)
- `model` 非空
- `displayName` 长度 1..40

### 新增 `ProviderProfileStore`

新文件:`ios/AudioNote/Services/ProviderProfileStore.swift`

```swift
@MainActor
final class ProviderProfileStore: ObservableObject {
    @Published private(set) var profiles: [LLMProviderProfile]
    @Published private(set) var activeProfileId: UUID?

    static let shared = ProviderProfileStore()

    // MARK: - CRUD
    func add(_ profile: LLMProviderProfile, apiKey: String?) throws
    func update(_ profile: LLMProviderProfile, apiKey: String?) throws
    func delete(_ id: UUID) throws   // 同时从 Keychain 移除 apiKey

    // MARK: - Active
    func setActive(_ id: UUID) throws   // 校验 id 存在
    var active: LLMProviderProfile? { get }
    func apiKey(for id: UUID) -> String?   // 从 Keychain 读

    // MARK: - Migration
    /// App 启动时调用一次。检测旧 audioNote:llmToken,有则清除并标 needsSetup。
    static func runLegacyTokenMigration()
    var needsProviderSetup: Bool { get }   // 驱动一次性 toast
}
```

**存储布局**:
- `UserDefaults.standard`:
  - `audioNote:llmProfiles` → `[LLMProviderProfile]` 的 JSON 编码
  - `audioNote:activeLLMProfileId` → UUID 字符串(可选)
  - `audioNote:llmNeedsProviderSetup` → Bool(迁移期一次性提示,显示后置 false)
- Keychain:
  - service: `audioNote.llm`
  - account: `<profileId.uuidString>`
  - class: `kSecClassGenericPassword`
  - accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`

### 数据结构不变部分(显式)

- `ios/AudioNote/Models/TranscriptionRecord.swift` — 不动(包括 `tags: [TaggedItem]` 和 `score(forTagName:)`)
- `ios/AudioNote/Models/RecognitionMode.swift` — 不动
- `LLMOptimizeAndProcessResult`(4 字段 + `[TaggedItem]`) — 不动

## Architecture

### 组件职责

```
┌──────────────────────────────────────────────────────────────────┐
│ TranscriptionViewModel(改动 1 行)                                 │
│   └─ assessAndEnhance(不变,3-case 调度,per ADR-0001)              │
│      └─ processWithLLM(recordId, originalText)                   │
│         └─ let profile = ProviderProfileStore.shared.active       │
│            let key = ProviderProfileStore.shared.apiKey(for: ...) │
│            let result = try await LLMService.optimizeAndProcess( │
│               originalText, profile: profile, apiKey: key)        │
│         (其他逻辑不变:写回 record / loadHistory)                  │
└──────────────────────────────────────────────────────────────────┘
                ↓
┌──────────────────────────────────────────────────────────────────┐
│ LLMService(actor,重写)                                            │
│   - 签名变:optimizeAndProcess(text, profile, apiKey:)             │
│   - 新增:ping(profile, apiKey:)  ← "测试连接"用                  │
│   - 删除:process() / optimize() / callAPI() / callOptimizeAPI()  │
│          / LLMResponse / LLMResult                                │
│   - 内部:baseURL/profile.model/profile.requiresAPIKey → 请求      │
│   - 3 道闸保留(profile 完整 + 网络 + HTTP 200)                   │
│   - retry 3 次(从 optimize() 提取公共 helper)                    │
│   - extractFirstJSONObject 保留(markdown fence 兜底)             │
│   - 3 份 prompt 写死,不可配置                                    │
└──────────────────────────────────────────────────────────────────┘
                ↓
┌──────────────────────────────────────────────────────────────────┐
│ ProviderProfileStore                                              │
│   - profiles (UserDefaults)                                        │
│   - activeId (UserDefaults)                                       │
│   - apiKey (Keychain)                                              │
└──────────────────────────────────────────────────────────────────┘
                ↓
┌──────────────────────────────────────────────────────────────────┐
│ SettingsView(重写)                                                │
│   - ProviderProfilesSection:列表(每行 ✓/⚙/测试/删除)              │
│   - ProfileDetailView:表单(displayName/baseURL/model/apiKey)     │
│   - 优化开关(读 active != nil 控制 enabled)                      │
│   - 一次性 toast:首次启动时提示已迁移                              │
└──────────────────────────────────────────────────────────────────┘
```

### 调用链路不变的部分

- `RecordingView` → `TranscriptionViewModel.startRecording` → `SpeechRecognizer.startRecording` → 录音 → `stopRecording` → 存 `TranscriptionRecord` → `assessAndEnhance` → 这一整条链路**不动**
- `assessAndEnhance` 3-case 调度(`.online` / `.onDevice` / `.failed`)按 ADR-0001 锁定
- `SpeechRecognizer` / `TranscriptionStorage` / `NetworkMonitor` / `AudioRecorderService` 全部不动
- `TranscriptionDetailView` UI 框架不动,只在 `reprocessRecord` 改 2-3 行(读 profile 而非 token)
- `TagFlowView` / 详情页标签展示 / `score(forTagName:)` — 因为 `tags: [TaggedItem]` 不动,这些**全部不动**

### 待验证:删除 `AIProcessingService`

`ios/AudioNote/Services/AIProcessingService.swift:7` 的 `processRecord` 显示 1 个 caller,**就在它自己文件里**——基本确认为死代码。Plan 阶段第一件事是 grep 整个 codebase 确认无外部引用,然后删除整个文件。如果发现外部引用,**保留**并在 spec 里加注记。

## Flow

### Provider 创建流程

```
用户在 Settings → Provider Profiles
  ↓ 点 "+"
ProfileDetailView 弹出 sheet
  ├─ displayName (TextField)
  ├─ baseURL (TextField,placeholder: https://api.openai.com/v1/chat/completions)
  ├─ model (TextField)
  ├─ requiresAPIKey (Toggle,默认 true)
  └─ apiKey (SecureField,仅 requiresAPIKey=true 显示)
  ↓ 点 "测试连接"
  → ping(profile, apiKey) → "✓ 连接成功" / "✗ 失败原因..."
  ↓ 点 "保存"
  → ProviderProfileStore.add(profile, apiKey)
     ├─ profiles.append(profile) → UserDefaults
     └─ if apiKey != nil → Keychain.set(apiKey, account: profile.id)
  ↓ 点 "设为活动"
  → ProviderProfileStore.setActive(profile.id)
     └─ activeProfileId = profile.id → UserDefaults
```

### 录音后 LLM 调用流程

```
stopRecording()
  ↓
存 TranscriptionRecord
  ↓
assessAndEnhance(record)            ← ADR-0001 不动
  ↓ (按 RecognitionMode 分发)
processWithLLM(recordId, originalText) ← 改这 1 处
  ↓
let profile = ProviderProfileStore.shared.active
guard profile != nil else { return }    // 没配置就静默跳过
let key = ProviderProfileStore.shared.apiKey(for: profile.id)
  ↓
LLMService.optimizeAndProcess(originalText, profile: profile, apiKey: key)
  ↓
3 道闸:
  ① profile.baseURL/model 非空, requiresAPIKey → key 非空
  ② NetworkMonitor.shared.checkConnectivity()
  ③ HTTP 200..299
  ↓ (retry 3 次,指数退避 baseDelay=1s)
解码 APIResponse → content
  ↓
extractFirstJSONObject(content) → 解析 4 字段 schema
  ↓
写回 record:title / summary / tags / optimizedContent / llmProcessingStatus
  ↓
loadHistory()
```

### 迁移流程(首次启动)

```
App 启动
  ↓
ProviderProfileStore.runLegacyTokenMigration()
  ├─ if UserDefaults.string(forKey: "audioNote:llmToken") != nil
  │  ├─ UserDefaults.removeObject(forKey: "audioNote:llmToken")
  │  ├─ UserDefaults.set(false, forKey: "audioNote:enableLLMOptimization")
  │  └─ UserDefaults.set(true, forKey: "audioNote:llmNeedsProviderSetup")
  └─ else:do nothing
  ↓
SettingsView 启动
  ↓
if needsProviderSetup
  showToast("LLM 设置已迁移:请配置 Provider")
  needsProviderSetup = false  (标记已显示)
```

## UI Visualization

### SettingsView(主页面)

```
┌─────────────────────────────────────────────────┐
│ 设置                                            │
├─────────────────────────────────────────────────┤
│ LLM Provider                                    │
│ ┌─────────────────────────────────────────────┐ │
│ │ ✓ 我的 DeepSeek        [测试] [编辑] [删除] │ │ ← active profile
│ │   https://api.deepseek.com/v1/chat/completions│ │
│ │   model: deepseek-chat                       │ │
│ ├─────────────────────────────────────────────┤ │
│ │   本地 Ollama            [测试] [编辑] [删除]│ │ ← non-active
│ │   http://localhost:11434/v1/chat/completions │ │
│ │   model: qwen2.5:7b                         │ │
│ └─────────────────────────────────────────────┘ │
│ [+ 添加 Provider]                                │
├─────────────────────────────────────────────────┤
│ 启用录音内容优化              [○────●]            │ ← 优化开关
│ 开启后,录音结束后自动优化转录文本                │
│ 状态: ✅ 已配置(当前:我的 DeepSeek)               │
├─────────────────────────────────────────────────┤
│ (旧"LLM API Token" / "测试连接" 整体移除)        │
└─────────────────────────────────────────────────┘
```

### ProfileDetailView(添加/编辑)

```
┌─────────────────────────────────────────────────┐
│ < 添加 Provider                                  │
├─────────────────────────────────────────────────┤
│ 显示名称                                         │
│ ┌─────────────────────────────────────────────┐ │
│ │ 我的 DeepSeek                                │ │
│ └─────────────────────────────────────────────┘ │
│                                                  │
│ Base URL                                         │
│ ┌─────────────────────────────────────────────┐ │
│ │ https://api.deepseek.com/v1/chat/completions │ │
│ └─────────────────────────────────────────────┘ │
│ 必须是 OpenAI 兼容的 /chat/completions 端点     │
│                                                  │
│ 模型名称                                         │
│ ┌─────────────────────────────────────────────┐ │
│ │ deepseek-chat                                │ │
│ └─────────────────────────────────────────────┘ │
│                                                  │
│ 需要 API Key                              [●]    │
│ ┌─────────────────────────────────────────────┐ │
│ │ sk-*************************************** │ │
│ └─────────────────────────────────────────────┘ │
│                                                  │
│ [测试连接]                                       │
│                                                  │
│ [保存]                              [取消]       │
└─────────────────────────────────────────────────┘
```

### 状态:首次启动迁移提示

```
┌─────────────────────────────────────────────────┐
│ 设置                                            │
│                                                  │
│        ⓘ LLM 设置已迁移:请配置 Provider          │ ← toast (3s)
│                                                  │
│ ┌─────────────────────────────────────────────┐ │
│ │   ⚠️ 尚未配置                                 │ │
│ │   添加一个 Provider 后才能启用 LLM 优化       │ │
│ │   [+ 添加 Provider]                          │ │
│ └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

## Error Handling

### 新增错误

| Error | 触发条件 |
|---|---|
| `LLMError.profileIncomplete` | `profile.baseURL` 或 `profile.model` 为空 |
| `LLMError.apiKeyRequired` | `profile.requiresAPIKey == true && apiKey == nil/empty` |
| `LLMError.testConnectionFailed(reason)` | ping 专用,把 HTTP code / body 包成可读消息 |

### 保留错误

`LLMError.invalidURL` / `.httpError(Int)` / `.decodingError` / `.offline` / `.networkError(Error)` — 行为不变。

### 删除错误

`LLMError.tokenNotSet` — 语义被 `.apiKeyRequired` 覆盖。

### UI 错误展示

| 场景 | UI 表现 |
|---|---|
| 用户未配 provider,优化开关打开 | toast: "请先在设置中配置 LLM Provider" |
| 用户点击"测试连接"失败 | toast: "连接失败: <reason>"(具体到 HTTP code 或解析错误) |
| 录音后 LLM 调用失败 | 现有 `errorMessage` 机制不动(per `TranscriptionViewModel`) |
| 迁移提示未读 | `needsProviderSetup` 持久化,直到首次进入 Settings 才置 false |

## Constraints & Edge Cases

1. **HTTP vs HTTPS**:非 `https://` 且 host 不是 `localhost` / `127.0.0.1` 的 baseURL 在保存前显示警告(不强制阻止,用户可继续)。理由:允许局域网 IP(如 `http://192.168.1.10:11434`)但防误粘贴公网明文 URL
2. **空 profile 列表 + 优化开关打开**:`active == nil` 时优化开关实际不生效,LLM 调用静默跳过(no-op);UI 在开关旁显示"未配置"
3. **删除 active profile**:`setActive(nil)` 强制;开关自动关;其他 profile 不受影响
4. **Keychain 写入失败**:fallback 报错,UI toast;profile 仍保存到 UserDefaults(下次可重试 key 写入)
5. **ping 成功 ≠ optimizeAndProcess 一定成功**:ping 只验证 HTTP 200 + auth 通;不验证 JSON schema 遵从。UI 提示文案需诚实:"连接可达,完整功能请实际录音测试"
6. **JSON schema 不变**:`extractFirstJSONObject` 仍需保留,因为本地模型不严格按 JSON-only 返回的概率比云端高
7. **3 道闸保留**:①profile 完整 ②`NetworkMonitor.shared.checkConnectivity()`(per CLAUDE.md 全局约束) ③HTTP 200/2xx
8. **retry 行为**:5xx + network error 重试(指数退避 1s/2s/4s),4xx 不重试,`.offline` 不重试
9. **prompt 不可配**:用户改不了 prompt;`extractFirstJSONObject` 是兜底,本地模型可能要走这条路径
10. **`RecordingViewModel` 不存在**:per GLOSSARY,继续走 `TranscriptionViewModel`,不要新建任何 "ProfileViewModel" / "ProviderViewModel"
11. **新 `LLMProviderProfile` 是 public struct**:出现在 GLOSSARY,但不在 transcription-journal 等用户文档
12. **死代码审计**:Plan 阶段第一件事 grep 全 codebase 确认 `process()` / `optimize()` / `callAPI()` / `callOptimizeAPI()` / `LLMResult` / `LLMResponse` 无外部 caller,然后从 `LLMService.swift` 删除
13. **`AIProcessingService.processRecord` 死代码验证**:同上,如无外部 caller,删除整个文件 `ios/AudioNote/Services/AIProcessingService.swift`
14. **不在 Provider Profile 里存完整 baseURL 时去掉末尾斜杠**:保存前 `URL.absoluteString.trimmingCharacters(in: ["/"])` 规范化

## i18n 新增键

| Key | zh-Hans | en |
|---|---|---|
| `Settings.LLM.ProviderProfiles.Title` | `LLM Provider` | `LLM Provider` |
| `Settings.LLM.ProviderProfiles.Add` | `+ 添加 Provider` | `+ Add Provider` |
| `Settings.LLM.ProviderProfiles.NoneActive` | `尚未配置 — 添加一个 Provider 后才能启用 LLM 优化` | `Not configured — add a provider to enable LLM optimization` |
| `Settings.LLM.Provider.Active` | `当前:` | `Active:` |
| `Settings.LLM.Profile.New` | `添加 Provider` | `Add Provider` |
| `Settings.LLM.Profile.Edit` | `编辑 Provider` | `Edit Provider` |
| `Settings.LLM.Profile.DisplayName` | `显示名称` | `Display name` |
| `Settings.LLM.Profile.BaseURL` | `Base URL` | `Base URL` |
| `Settings.LLM.Profile.BaseURL.Hint` | `OpenAI 兼容的 /chat/completions 端点` | `OpenAI-compatible /chat/completions endpoint` |
| `Settings.LLM.Profile.Model` | `模型名称` | `Model name` |
| `Settings.LLM.Profile.RequiresAPIKey` | `需要 API Key` | `Requires API Key` |
| `Settings.LLM.Profile.APIKey` | `API Key` | `API Key` |
| `Settings.LLM.Profile.Test` | `测试连接` | `Test connection` |
| `Settings.LLM.Profile.SetActive` | `设为活动` | `Set active` |
| `Settings.LLM.Profile.Save` | `保存` | `Save` |
| `Settings.LLM.Profile.Cancel` | `取消` | `Cancel` |
| `Settings.LLM.Test.Success` | `✓ 连接成功` | `✓ Connection successful` |
| `Settings.LLM.Test.Fail` | `连接失败: %@` | `Connection failed: %@` |
| `Settings.LLM.Migration.Toast` | `LLM 设置已迁移:请配置 Provider` | `LLM settings migrated: please configure a provider` |
| `Settings.LLM.Migration.OptimizeOff` | `原 LLM 优化已关闭` | `Previous LLM optimization has been disabled` |
| `Common.Delete` | `删除` | `Delete` |
| `Common.Edit` | `编辑` | `Edit` |

旧 key 移除:`Settings.LLM.Title` / `Settings.LLM.Footer`(整体被 ProviderProfiles section 替换)。`Action.Save` 保留为通用,Profile 也复用。

## Files to Modify / Add / Remove

### 新增

| File | Purpose |
|---|---|
| `ios/AudioNote/Models/LLMProviderProfile.swift` | profile 结构定义 |
| `ios/AudioNote/Services/ProviderProfileStore.swift` | CRUD + Keychain + 迁移 |
| `ios/AudioNote/Services/KeychainStore.swift` | Keychain 通用 helper(service `audioNote.llm` 封装) |
| `ios/AudioNote/Views/ProfileDetailView.swift` | profile 添加/编辑表单 |
| `ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings` | 22 个新键 |
| `ios/AudioNote/Resources/en.lproj/Localizable.strings` | 22 个新键 |
| `docs/decisions/0003-multi-provider-llm.md` | 新 ADR,锁定 provider 数据模型 + Keychain + 签名 |

### 修改

| File | Change |
|---|---|
| `ios/AudioNote/Services/LLMService.swift` | 重写:删除 2 入口 + 2 helper + 2 结构;加 `ping`;签名变 `(text, profile, apiKey:)`;加 retry;`extractFirstJSONObject` 保留;3 份 prompt 写死 |
| `ios/AudioNote/ViewModels/SettingsViewModel.swift` | `llmToken` 相关字段删除;新增 `profileStore` 引用;`validateLLMConfiguration` / `testLLMConnection` 重写或删除 |
| `ios/AudioNote/Views/SettingsView.swift` | 重构 3 个 section:ProviderProfiles + 优化开关 + 状态指示 |
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` | `processWithLLM` 改 2-3 行:从 `ProviderProfileStore` 取 active profile + key,而非 UserDefaults token |
| `ios/AudioNote/Views/TranscriptionDetailView.swift` | `reprocessRecord` 改 2-3 行:同上 |
| `ios/AudioNote/App/AudioNoteApp.swift`(或 `@main` 入口) | 启动时调 `ProviderProfileStore.runLegacyTokenMigration()` |
| `docs/GLOSSARY.md` | 加 `LLMProviderProfile` / `ProviderProfileStore` / `LLMService.ping` 条目;更新 `LLMService` 描述;删除 `audioNote:llmToken` key 描述 |

### 删除(待死代码审计后确认)

| File | 条件 |
|---|---|
| `ios/AudioNote/Services/AIProcessingService.swift` | grep 全 codebase 确认 `processRecord` 无外部 caller |
| `ios/AudioNote/Services/LLMService.LLMResult` | grep 确认无外部 caller |
| `ios/AudioNote/Services/LLMService.LLMResponse` | grep 确认无外部 caller |

### Files NOT Modified(显式声明)

- `ios/AudioNote/Models/TranscriptionRecord.swift` — 包括 `TaggedItem` 和 `score(forTagName:)`
- `ios/AudioNote/Models/RecognitionMode.swift`
- `ios/AudioNote/Services/SpeechRecognizer.swift`
- `ios/AudioNote/Services/TranscriptionStorage.swift`
- `ios/AudioNote/Services/AudioRecorderService.swift`
- `ios/AudioNote/Services/AudioPlayerManager.swift`
- `ios/AudioNote/Utilities/NetworkMonitor.swift`
- `ios/AudioNote/Utilities/Logger.swift`
- `ios/AudioNote/Utilities/PermissionsManager.swift`
- `ios/AudioNote/Utilities/LanguageManager.swift`
- `ios/AudioNote/Views/ContentView.swift`
- `ios/AudioNote/Views/RecordingView.swift`
- `ios/AudioNote/Views/LibraryListView.swift`(及其子页面)
- `ios/AudioNote/Views/SharedComponents.swift`(`ToastView` 复用即可,不动)
- `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` 除 `processWithLLM` 外的所有方法(`assessAndEnhance` / `enhanceRecognition` / `retryRecognitionFromFile` / `stopRecording` / `startRecording` / `setLanguage` 等全部不动)
- 3 份 prompt 文案(锁在 `LLMService` 私有常量)

## 过时文档清单

下列文档/段落与"通过 `llm.karsa.info` proxy"模式强相关,新方案上线后**必须标注过时**:

### 必须加 SUPERSEDED banner

| 文档 | 处理 |
|---|---|
| `docs/decisions/0002-merge-llm-calls.md` | 顶部加 `> **SUPERSEDED by ADR-0003 (2026-09-24)** — multi-provider LLM. The endpoint-locked-by-proxy assumption no longer holds. Schema (4 fields + `[TaggedItem]`) and merged-call preference **are** still valid — see ADR-0003 §"What's locked"`. 正文保留 |
| `docs/superpowers/specs/2026-04-09-merge-llm-calls-design.md` | 顶部加同款 banner。Section 1/2 中所有提到 `llm.karsa.info` 的句子保留(历史)但加 `<!-- DEPRECATED -->` 注释 |
| `.remember/recent.md` 中 2026-09-21 / 2026-09-22 / 2026-09-23 三条 | 段落前加 `> [DEPRECATED 2026-09-24] ` 前缀;但历史事实(token 泄露、proxy 可达性测试)保留 |
| `.remember/archive.md` 中 Week of 2026-08-31 末尾 LLM 段落 | 同上 |

### 必须保留并补充

| 文档 | 处理 |
|---|---|
| `docs/decisions/0001-assess-enhance-llm-pipeline.md` | **保留**(调度本身不变)。如果正文提到"调用 karsa.info",改为"调用 active provider profile(per ADR-0003)" |
| `docs/ROADMAP.md` | 检查是否有"自管 provider"future item;如有则标记 done |
| `docs/GLOSSARY.md` | 更新见 "Files to Modify" 表 |

### 新写

| 文档 | 内容 |
|---|---|
| `docs/decisions/0003-multi-provider-llm.md` | 锁定:`LLMProviderProfile` 数据模型 / Keychain 存储布局 / `LLMService.optimizeAndProcess(text, profile:, apiKey:)` 签名 / 4 字段 schema 保留 / 3 道闸 / 3 次 retry / `extractFirstJSONObject` 兜底 / prompt 不可配 / 死代码清理 |

## Testing Strategy

### 单元测试(`ios/AudioNoteTests/` 新建或扩)

| Suite | 覆盖 |
|---|---|
| `ProviderProfileStoreTests` | CRUD / active 切换 / Keychain 读写真实走(测试环境 Keychain);`runLegacyTokenMigration` 三态:无旧 key / 有旧 key / 已迁移 |
| `LLMServiceTests`(用 `URLProtocol` mock) | `optimizeAndProcess` happy path / HTTP 4xx 不重试 / HTTP 5xx 重试 3 次 / network error 重试 / `.apiKeyRequired` / `.profileIncomplete` / `extractFirstJSONObject` 4 种边界(markdown fence / 嵌套 brace / 转义引号 / 末尾不闭合)|
| `LLMServicePingTests` | `ping` 200 成功 / 401 失败 / 5xx 失败 |
| `MigrationTests` | `runLegacyTokenMigration` 后,`audioNote:llmToken` 不存在 / `enableLLMOptimization == false` / `llmNeedsProviderSetup == true` |

### 集成 smoke

| Case | 期望 |
|---|---|
| 启动 app,旧 token 存在 → 进入 Settings | toast 显示一次,旧 token 已清除,优化开关关闭 |
| 创建 1 个 profile → 设为 active → 录音 → 优化开关开 | 录音结束后调用实际 provider(手工用 curl 验证) |
| 切到非 active profile 录音 | LLM 不调用(无 active) |
| 删除 active profile → 优化开关自动关闭 | UI 一致 |

### UI test(可选,不在第一轮 plan 范围)

profile 列表 → 详情 → 保存 → 切回列表 显示新条目。

## Test Coverage Required

任何 PR 触及 `LLMService` / `ProviderProfileStore` 必须覆盖:

1. `optimizeAndProcess` happy path → 返回 4 字段
2. `optimizeAndProcess` 空 token(profile.requiresAPIKey=true, apiKey=nil) → `LLMError.apiKeyRequired`
3. `optimizeAndProcess` 空 baseURL → `LLMError.profileIncomplete`
4. `optimizeAndProcess` offline → `LLMError.offline`,**不**重试
5. `optimizeAndProcess` HTTP 5xx → 重试 3 次后抛 `.httpError`
6. `optimizeAndProcess` HTTP 4xx → 立即抛 `.httpError`,**不**重试
7. `optimizeAndProcess` JSON 解析失败 → `extractFirstJSONObject` 兜底;仍失败 → `.decodingError`
8. `ping` HTTP 200 → 成功
9. `ping` HTTP 401 → `.testConnectionFailed("401 ...")`
10. `runLegacyTokenMigration` 三态

## Open Questions

(无——已通过 brainstorming 全部确认)

## Risks

| Risk | Mitigation |
|---|---|
| 本地模型不严格返回 JSON-only | `extractFirstJSONObject` 兜底 + 错误日志 |
| 局域网 baseURL 错误时诊断困难 | `ping` 提供具体 HTTP code + body 前 200 字符 |
| Keychain 写入失败 | UI toast,允许 retry;不阻塞 profile 保存 |
| 用户删除 active profile | `setActive(nil)`,优化开关自动关(在 SettingsViewModel 处理) |
| 旧 token 静默清除导致用户丢失配置 | 一次性 toast + 进入 Settings 自动滚动到 Provider section |

## Migration Checklist(实施时执行)

- [ ] grep 全 codebase 确认 `process` / `optimize` / `callAPI` / `callOptimizeAPI` / `LLMResult` / `LLMResponse` / `AIProcessingService.processRecord` 无外部 caller
- [ ] 创建 `LLMProviderProfile` / `ProviderProfileStore` / `KeychainStore`
- [ ] 重写 `LLMService`,保留 prompt / `extractFirstJSONObject` / 3 道闸,加 retry + ping
- [ ] 改 `TranscriptionViewModel.processWithLLM` 调新签名
- [ ] 改 `TranscriptionDetailView.reprocessRecord` 调新签名
- [ ] 重写 `SettingsViewModel` / `SettingsView` / 新增 `ProfileDetailView`
- [ ] 入口加 `runLegacyTokenMigration`
- [ ] 加本地化字符串(zh-Hans / en)
- [ ] 更新 `GLOSSARY.md`
- [ ] 起草 ADR-0003
- [ ] 给过时文档加 banner / 前缀
- [ ] 单元测试全部通过
- [ ] 在真机/模拟器跑集成 smoke(可选:挂个本地 Ollama / DeepSeek curl 验证)
