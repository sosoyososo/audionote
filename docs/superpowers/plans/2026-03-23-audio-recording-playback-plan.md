# 音频录制与播放功能实现计划

**目标:** 录音时同步保存 M4A 音频文件，详情页支持播放控制

**架构:** 使用 AVAudioEngine 捕获麦克风输入，同时写入 M4A 文件并传输给语音识别服务。详情页使用 AVAudioPlayer 实现播放控制。

**技术栈:** Swift 5.9, AVFoundation, Speech Framework, SwiftUI

---

## 文件变更映射

| 文件 | 操作 | 职责 |
|------|------|------|
| `ios/AudioNote/Models/TranscriptionRecord.swift` | 修改 | 添加 audioFileName 字段 |
| `ios/AudioNote/Services/AudioRecorderService.swift` | 创建 | M4A 音频文件写入 |
| `ios/AudioNote/Services/SpeechRecognizer.swift` | 修改 | 集成 AudioRecorderService |
| `ios/AudioNote/Services/AudioPlayerManager.swift` | 创建 | 音频播放控制单例 |
| `ios/AudioNote/ViewModels/TranscriptionViewModel.swift` | 修改 | 传递 audioFileName |
| `ios/AudioNote/Views/TranscriptionDetailView.swift` | 修改 | 添加播放控制条 UI |
| `ios/AudioNote/Views/SharedComponents.swift` | 修改 | 添加 PlaybackControlBar 组件 |

---

## Task 1: 模型添加音频文件名

**Files:**
- Modify: `ios/AudioNote/Models/TranscriptionRecord.swift:1-51`

- [ ] **Step 1: 添加 audioFileName 字段**

修改 `TranscriptionRecord` 结构体，在 `language` 字段后添加:

```swift
var audioFileName: String?
```

- [ ] **Step 2: 更新 init 方法**

在 init 中添加 `audioFileName` 参数，默认值为 nil

- [ ] **Step 3: Commit**

```bash
git add ios/AudioNote/Models/TranscriptionRecord.swift
git commit -m "feat: add audioFileName field to TranscriptionRecord"
```

---

## Task 2: 创建 AudioRecorderService

**Files:**
- Create: `ios/AudioNote/Services/AudioRecorderService.swift`

- [ ] **Step 1: 创建 AudioRecorderService 类**

```swift
import Foundation
import AVFoundation

final class AudioRecorderService: @unchecked Sendable {
    private var audioFile: AVAudioFile?
    private let fileUrl: URL
    private let recordingFormat: AVAudioFormat
    private let queue = DispatchQueue(label: "info.karsa.app.ios.audionote.audiorecorder")

    init(fileUrl: URL, recordingFormat: AVAudioFormat) throws {
        self.fileUrl = fileUrl
        self.recordingFormat = recordingFormat

        // 创建目录
        let directory = fileUrl.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 创建音频文件
        self.audioFile = try AVAudioFile(
            forWriting: fileUrl,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: recordingFormat.sampleRate,
                AVNumberOfChannelsKey: recordingFormat.channelCount
            ]
        )
        Logger.info("AudioRecorderService created: \(fileUrl.path)")
    }

    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self = self, let file = self.audioFile else { return }
            do {
                try file.write(from: buffer)
            } catch {
                Logger.error("Failed to write audio buffer: \(error.localizedDescription)")
            }
        }
    }

    func finishRecording() {
        queue.sync {
            audioFile = nil
            Logger.info("Audio recording finished: \(fileUrl.path)")
        }
    }

    static func generateFileUrl(for id: UUID) -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let recordingsDir = documentsPath.appendingPathComponent("Recordings", isDirectory: true)
        return recordingsDir.appendingPathComponent("\(id.uuidString).m4a")
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/AudioNote/Services/AudioRecorderService.swift
git commit -m "feat: add AudioRecorderService for M4A recording"
```

---

## Task 3: 修改 SpeechRecognizer 集成录音功能

**Files:**
- Modify: `ios/AudioNote/Services/SpeechRecognizer.swift:1-239`

- [ ] **Step 1: 添加 AudioRecorderService 属性**

在 `SpeechRecognizer` 类中添加:

```swift
private var audioRecorder: AudioRecorderService?
private var currentRecordingId: UUID?
```

- [ ] **Step 2: 修改 startRecording 方法**

在方法开始处创建 AudioRecorderService:

```swift
currentRecordingId = UUID()
guard let recordingId = currentRecordingId else { return }
let fileUrl = AudioRecorderService.generateFileUrl(for: recordingId)
audioRecorder = try AudioRecorderService(fileUrl: fileUrl, recordingFormat: recordingFormat)
```

- [ ] **Step 3: 修改 installTap 回调**

在写入 recognitionRequest 的同时写入音频文件:

```swift
selfRef.audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
    selfRef.recognitionRequest?.append(buffer)
    selfRef.audioRecorder?.appendBuffer(buffer)
}
```

- [ ] **Step 4: 修改 stopRecording 方法**

在方法末尾添加:

```swift
audioRecorder?.finishRecording()
audioRecorder = nil
```

- [ ] **Step 5: 添加返回 audioFileName 的方法**

```swift
func getAudioFileName() -> String? {
    guard let id = currentRecordingId else { return nil }
    return "\(id.uuidString).m4a"
}
```

- [ ] **Step 6: Commit**

```bash
git add ios/AudioNote/Services/SpeechRecognizer.swift
git commit -m "feat: integrate AudioRecorderService into SpeechRecognizer"
```

---

## Task 4: 修改 TranscriptionViewModel 传递 audioFileName

**Files:**
- Modify: `ios/AudioNote/ViewModels/TranscriptionViewModel.swift`

- [ ] **Step 1: 在 stopRecording 中保存 audioFileName**

修改 `stopRecording` 方法中的 record 创建:

```swift
let audioFileName = speechRecognizer.getAudioFileName()

let record = TranscriptionRecord(
    id: currentRecordId ?? UUID(),
    content: contentToSave,
    createdAt: recordingStartTime ?? Date(),
    duration: duration,
    language: selectedLanguage.rawValue,
    audioFileName: audioFileName
)
```

- [ ] **Step 2: Commit**

```bash
git add ios/AudioNote/ViewModels/TranscriptionViewModel.swift
git commit -m "feat: save audioFileName when creating record"
```

---

## Task 5: 创建 AudioPlayerManager

**Files:**
- Create: `ios/AudioNote/Services/AudioPlayerManager.swift`

- [ ] **Step 1: 创建 AudioPlayerManager 单例**

```swift
import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioPlayerManager: ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayerManager()

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var progress: Double = 0

    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var currentFileName: String?

    private init() {}

    func play(fileName: String) {
        guard fileName != currentFileName else {
            audioPlayer?.play()
            isPlaying = true
            startTimer()
            return
        }

        stop()
        currentFileName = fileName

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileUrl = documentsPath.appendingPathComponent("Recordings").appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: fileUrl.path) else {
            Logger.error("Audio file not found: \(fileUrl.path)")
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            audioPlayer = try AVAudioPlayer(contentsOf: fileUrl)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            duration = audioPlayer?.duration ?? 0
            audioPlayer?.play()
            isPlaying = true
            startTimer()
            Logger.info("Playing audio: \(fileName)")
        } catch {
            Logger.error("Failed to play audio: \(error.localizedDescription)")
        }
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentTime = 0
        progress = 0
        duration = 0
        currentFileName = nil
        stopTimer()
    }

    func seek(to progress: Double) {
        guard let player = audioPlayer else { return }
        let targetTime = player.duration * progress
        player.currentTime = targetTime
        self.progress = progress
        currentTime = targetTime
    }

    func togglePlayPause(fileName: String) {
        if isPlaying && currentFileName == fileName {
            pause()
        } else {
            play(fileName: fileName)
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateProgress()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateProgress() {
        guard let player = audioPlayer else { return }
        currentTime = player.currentTime
        if player.duration > 0 {
            progress = player.currentTime / player.duration
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stop()
            Logger.info("Audio playback finished")
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/AudioNote/Services/AudioPlayerManager.swift
git commit -m "feat: add AudioPlayerManager for audio playback"
```

---

## Task 6: 创建播放控制条组件

**Files:**
- Modify: `ios/AudioNote/Views/SharedComponents.swift`

- [ ] **Step 1: 添加 PlaybackControlBar 组件**

```swift
struct PlaybackControlBar: View {
    @ObservedObject var playerManager = AudioPlayerManager.shared
    let audioFileName: String

    private var formattedCurrentTime: String {
        formatTime(playerManager.currentTime)
    }

    private var formattedDuration: String {
        formatTime(playerManager.duration)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        HStack(spacing: 16) {
            Button {
                playerManager.togglePlayPause(fileName: audioFileName)
            } label: {
                Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
            }

            Slider(value: Binding(
                get: { playerManager.progress },
                set: { playerManager.seek(to: $0) }
            ))
            .tint(.accentColor)

            Text("\(formattedCurrentTime)/\(formattedDuration)")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/AudioNote/Views/SharedComponents.swift
git commit -m "feat: add PlaybackControlBar component"
```

---

## Task 7: 修改 TranscriptionDetailView 添加播放控制条

**Files:**
- Modify: `ios/AudioNote/Views/TranscriptionDetailView.swift`

- [ ] **Step 1: 添加播放控制条**

在 body 的 VStack 末尾添加:

```swift
if let audioFileName = record.audioFileName {
    PlaybackControlBar(audioFileName: audioFileName)
        .padding(.top, 8)
}
```

完整代码片段替换:

```swift
ScrollView {
    VStack(alignment: .leading, spacing: 16) {
        metadataSection

        Divider()

        contentSection

        if let audioFileName = record.audioFileName {
            PlaybackControlBar(audioFileName: audioFileName)
                .padding(.top, 8)
        }
    }
    .padding()
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/AudioNote/Views/TranscriptionDetailView.swift
git commit -m "feat: add playback control bar to TranscriptionDetailView"
```

---

## Task 8: 构建验证

- [ ] **Step 1: 运行 Xcode build**

```bash
cd /Users/karsa/proj/audionote/ios && xcodebuild -project AudioNote.xcodeproj -scheme AudioNote -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -30
```

**预期:** BUILD SUCCEEDED

- [ ] **Step 2: Commit 所有更改**

```bash
git add -A && git status
```

---

## 执行选项

**1. Subagent-Driven (推荐)** - 每个 Task 由独立子 agent 执行，任务间有检查点，快速度迭代

**2. Inline Execution** - 在当前 session 内顺序执行所有任务

**选择哪个方式？**
