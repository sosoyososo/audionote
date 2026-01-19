# Contract: LanguageSelectorView

## 组件规格

### LanguageSelectorView

语言选择 Sheet 视图，用户点击后从底部弹出。

**属性**:
- `isPresented: Binding<Bool>` - 控制 Sheet 显示/隐藏
- `onLanguageSelected: (AppLanguage) -> Void` - 语言选择回调

**UI 结构**:

```swift
VStack(spacing: 0) {
    // 标题栏
    HStack {
        Text("language.selector.title".localized)
            .font(.headline)
        Spacer()
        Button("common.close".localized) {
            isPresented.wrappedValue = false
        }
    }
    .padding()
    
    Divider()
    
    // 语言选项列表
    ForEach(AppLanguage.allCases, id: \.self) { language in
        Button {
            onLanguageSelected(language)
            isPresented.wrappedValue = false
        } label: {
            HStack {
                Text(language.displayName)
                    .foregroundColor(.primary)
                Spacer()
                if language == currentLanguage {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }
}
.background(Color(.systemBackground))
```

### 语言切换入口按钮

**位置**: RecordingView 工具栏右侧

```swift
Button {
    showLanguageSelector = true
} label: {
    Image(systemName: "globe")
        .foregroundColor(.accentColor)
}
.sheet(isPresented: $showLanguageSelector) {
    LanguageSelectorView(
        isPresented: $showLanguageSelector,
        onLanguageSelected: { language in
            LanguageManager.shared.switch(to: language)
        }
    )
}
```

---

## 行为规格

| 场景 | 行为 |
|------|------|
| 打开 Sheet | 从底部滑入动画 |
| 选择语言 | 执行回调，关闭 Sheet |
| 点击关闭/遮罩 | 关闭 Sheet，不执行任何操作 |
| 语言切换 | 立即更新所有界面文本 |

---

## 样式规格

- 背景: 系统背景色 (`Color(.systemBackground)`)
- 圆角: 默认 Sheet 圆角
- 动画: 标准 SwiftUI sheet 动画
- 图标: SF Symbols (`globe`, `checkmark`)
