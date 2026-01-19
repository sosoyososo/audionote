# Quickstart: iOS 多语言支持开发

## 前置条件

- Xcode 15+
- iOS 15.0+ 模拟器
- 已安装 XcodeGen (可通过 `brew install xcodegen` 安装)

## 开发步骤

### 步骤 1: 补充 Localizable.strings 文件

```bash
# 查看现有文件
cat ios/AudioNote/Resources/en.lproj/Localizable.strings
cat ios/AudioNote/Resources/zh-Hans.lproj/Localizable.strings

# 需要添加的 key 示例
# common.confirm = "确定";
# common.cancel = "取消";
# recording.title = "语音转文字";
# ...
```

### 步骤 2: 替换硬编码字符串

在以下文件中将硬编码字符串替换为 `.localized`:

```swift
// Views/RecordingView.swift
"需要权限" -> "permission.required".localized

// Views/HistoryListView.swift
"历史记录" -> "history.title".localized

// Views/TranscriptionDetailView.swift
"编辑内容" -> "detail.edit".localized
```

### 步骤 3: 修改 LanguageManager

1. 移除 `showLanguageChangedToast` 属性
2. 添加 `getEffectiveLanguage()` 方法
3. 实现系统语言检测逻辑

### 步骤 4: 创建语言选择页面

```swift
// Utilities/LanguageSelectorView.swift
import SwiftUI

struct LanguageSelectorView: View {
    @Binding var isPresented: Bool
    let onLanguageSelected: (AppLanguage) -> Void
    
    var body: some View {
        // 见 contracts/language-selector.md
    }
}
```

### 步骤 5: 在 RecordingView 添加入口

```swift
// Views/RecordingView.swift
@State private var showLanguageSelector = false

var body: some View {
    // 在工具栏添加语言切换按钮
    ToolbarItem(placement: .navigationBarTrailing) {
        Button {
            showLanguageSelector = true
        } label: {
            Image(systemName: "globe")
        }
    }
}
```

### 步骤 6: 编译验证

```bash
# 生成项目
cd ios && xcodegen generate

# 编译
xcodebuild -scheme AudioNote -destination 'generic/platform=iOS Simulator' build
```

---

## 测试检查清单

- [ ] 语言切换后所有文本立即更新
- [ ] 选择"跟随系统"时正确响应系统语言变化
- [ ] 系统语言为非中英文时默认英文
- [ ] 应用重启后语言设置保持
- [ ] 语音识别语言设置不受影响
- [ ] 编译通过，无警告

---

## 常用命令

```bash
# 启动模拟器
xcrun simctl boot "iPhone 15"

# 打开应用
xcrun simctl install booted build/AudioNote.app
xcrun simctl launch booted info.karsa.app.ios.audionote
```
