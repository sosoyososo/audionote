# Research: iOS 应用多语言支持

## Q1: iOS 系统语言检测 - 如何判断系统语言是否为中文或英文？

**Decision**: 使用 `Locale.preferredLanguages.first` 获取系统首选语言，通过 `Locale.Language.Code` 判断

```swift
// 检测系统首选语言代码
if let preferredLanguage = Locale.preferredLanguages.first {
    let languageCode = Locale.Language.Code(identifier: preferredLanguage)
    let language = Locale.Language(identifier: preferredLanguage)
    
    // 判断语言脚本
    let languageCodeString = preferredLanguage.lowercased()
    
    if languageCodeString.hasPrefix("zh") {
        return .chinese
    } else if languageCodeString.hasPrefix("en") {
        return .english
    } else {
        return .english // 默认英文
    }
}
```

**Rationale**: 
- `Locale.preferredLanguages` 返回系统语言优先级列表，第一个是首选语言
- 语言标识符格式: `zh-Hans`, `zh-Hant`, `en-US`, `en-GB` 等
- `hasPrefix("zh")` 可匹配所有中文变体（简体、繁体）
- `hasPrefix("en")` 可匹配所有英文变体

**Alternatives considered**:
- `Locale.current.language.languageCode?.identifier` - 只能获取语言代码，无法区分脚本
- `NSBundle.mainBundle.preferredLocalizations.first` - 已废弃

---

## Q2: SwiftUI 实时语言切换 - 如何实现界面即时刷新？

**Decision**: 使用 `@Published` + `@EnvironmentObject` + `String.localized` 扩展

```swift
// LanguageManager.swift
class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    
    @Published var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "audioNote:language")
            NotificationCenter.default.post(name: .languageChanged, object: nil)
        }
    }
    
    // 获取实际使用的语言（处理 system 情况）
    func getEffectiveLanguage() -> AppLanguage {
        switch currentLanguage {
        case .system:
            return detectSystemLanguage()
        case .chinese, .english:
            return currentLanguage
        }
    }
    
    private func detectSystemLanguage() -> AppLanguage {
        guard let preferred = Locale.preferredLanguages.first?.lowercased() else {
            return .english
        }
        if preferred.hasPrefix("zh") { return .chinese }
        if preferred.hasPrefix("en") { return .english }
        return .english
    }
}

// String 扩展
extension String {
    var localized: String {
        let lm = LanguageManager.shared
        let effectiveLang = lm.getEffectiveLanguage()
        return localized(for: effectiveLang)
    }
}
```

**Rationale**:
- `@Published` 属性变化会自动触发所有使用 `@EnvironmentObject` 的视图刷新
- `String.localized` 扩展让所有字符串使用统一接口
- `didSet` 配合 `NotificationCenter` 确保所有视图同步更新

**Alternatives considered**:
- `View.invalidateIntrinsicMeasurement()` - 只刷新特定视图，无法全局生效
- `@StateObject` - 需要每个视图单独创建实例，不适合全局单例

---

## Q3: 现有 Localizable.strings 覆盖范围

**Decision**: 基于代码探索结果，补充约 50+ 个缺失的 key

**发现**:
- 已有文件: `en.lproj/Localizable.strings`, `zh-Hans.lproj/Localizable.strings`
- 已有基础设施: `LanguageManager` 单例、`LocalizedText` 视图组件
- 需要补充的硬编码字符串: 约 50+ 处

**覆盖策略**:
1. 按视图文件组织 key 前缀 (recording., history., detail., shared.)
2. 按功能组织 (permission., error., action.)

---

## 实施决策总结

| 问题 | 最终方案 |
|------|----------|
| 系统语言检测 | `Locale.preferredLanguages.first` + `hasPrefix` 判断 |
| 实时刷新 | `@Published` + `@EnvironmentObject` + `String.localized` |
| 字符串管理 | 扩展 Localizable.strings，使用 `.localized` 扩展方法 |
| 语言切换入口 | RecordingView 工具栏添加语言切换按钮，弹出 Sheet 选择 |
| Toast 提示 | 根据需求移除，仅静默切换 |
