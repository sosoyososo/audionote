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
