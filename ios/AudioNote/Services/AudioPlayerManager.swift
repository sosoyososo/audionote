import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayerManager()

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var progress: Double = 0

    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var currentFileName: String?

    private override init() {
        super.init()
    }

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
