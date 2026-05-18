import Foundation
import Speech
import AVFoundation
import Network

enum SpeechRecognitionError: LocalizedError {
    case notAvailable
    case notAuthorized
    case audioEngineFailed(Error)
    case recognitionFailed(Error?)
    case cancelled
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "语音识别不可用"
        case .notAuthorized:
            return "未获得语音识别权限"
        case .audioEngineFailed(let error):
            return "音频引擎启动失败: \(error.localizedDescription)"
        case .recognitionFailed(let error):
            return "识别失败: \(error?.localizedDescription ?? "未知错误")"
        case .cancelled:
            return "识别已取消"
        case .noSpeechDetected:
            return "未检测到语音"
        }
    }
}

// MARK: - Speech Recognizer (Class-based for proper closure capture)

final class SpeechRecognizer: @unchecked Sendable {
    private var speechRecognizer: SFSpeechRecognizer?
    private var currentLanguage: RecognitionLanguage = .chinese
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var allRecognizedText: [String] = []
    private var isStreaming = false
    private var audioRecorder: AudioRecorderService?
    private var currentRecordingId: UUID?
    private(set) var recognitionMode: RecognitionMode = .online
    private var recognitionError: SpeechRecognitionError?

    // Serial queue for thread safety
    private let stateQueue = DispatchQueue(label: "info.karsa.app.ios.audionote.speechstate")

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: currentLanguage.locale)
        Logger.info("SpeechRecognizer initialized with language: \(currentLanguage.displayName)")
    }

    var availability: Bool {
        speechRecognizer?.isAvailable ?? false
    }

    var recognitionLanguage: RecognitionLanguage {
        get { currentLanguage }
        set {
            if newValue != currentLanguage {
                currentLanguage = newValue
                speechRecognizer = SFSpeechRecognizer(locale: newValue.locale)
                Logger.info("Language changed to: \(newValue.displayName), available: \(availability)")
            }
        }
    }

    func setRecognitionLanguage(_ language: RecognitionLanguage) {
        recognitionLanguage = language
    }

    func checkAuthorization() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    func requestAuthorization() async -> Bool {
        Logger.info("Requesting speech recognition authorization")
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                let isAuthorized = status == .authorized
                Logger.info("Speech authorization status: \(status.rawValue), authorized: \(isAuthorized)")
                continuation.resume(returning: isAuthorized)
            }
        }
    }

    func startRecording() async throws -> AsyncStream<String> {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            Logger.error("Speech recognition not available")
            recognitionMode = .failed
            recognitionError = .notAvailable
            throw SpeechRecognitionError.notAvailable
        }

        Logger.speechEvent("Starting recording", details: "Language: \(currentLanguage.displayName)")

        // Reset state
        stateQueue.sync {
            allRecognizedText = []
            isStreaming = true
        }

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            Logger.error("Failed to create recognition request")
            throw SpeechRecognitionError.audioEngineFailed(NSError(domain: "SpeechRecognizer", code: 1))
        }

        // T003, T004: Check network and set recognition mode
        let useOnDeviceRecognition = !NetworkMonitor.shared.checkConnectivity()
        recognitionMode = useOnDeviceRecognition ? .onDevice : .online
        recognitionError = nil
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = useOnDeviceRecognition

        let mode = useOnDeviceRecognition ? "offline (on-device)" : "online"
        Logger.speechEvent("Network check", details: "Using \(mode) recognition")

        // iOS 16+ 添加标点符号
        if #available(iOS 16.0, *) {
            recognitionRequest.addsPunctuation = true
        }

        // Get audio format for the input node
        let recordingFormat = audioEngine.inputNode.outputFormat(forBus: 0)

        Logger.info("Audio format: \(recordingFormat)")

        // Create AudioRecorderService
        currentRecordingId = UUID()
        guard let recordingId = currentRecordingId else {
            throw SpeechRecognitionError.audioEngineFailed(NSError(domain: "SpeechRecognizer", code: 2))
        }
        let fileUrl = AudioRecorderService.generateFileUrl(for: recordingId)
        audioRecorder = try AudioRecorderService(fileUrl: fileUrl, recordingFormat: recordingFormat)

        return AsyncStream { [weak self] continuation in
            guard let selfRef = self else {
                continuation.finish()
                return
            }

            Logger.debug("Creating recognition task")

            // Set up the recognition task
            selfRef.recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
                guard let selfStrong = self else { return }

                let shouldContinue: Bool = selfStrong.stateQueue.sync {
                    return selfStrong.isStreaming
                }

                guard shouldContinue else { return }

                if let result = result {
                    let text = result.bestTranscription.formattedString
                    let isFinal = result.isFinal

                    Logger.recognitionResult(text, isFinal: isFinal)

                    // Only accumulate final results (partial results already contain full text so far)
                    if isFinal {
                        selfStrong.stateQueue.sync {
                            if !text.isEmpty {
                                selfStrong.allRecognizedText.append(text)
                            }
                        }
                    }

                    continuation.yield(text)

                    if isFinal {
                        let finalText = selfStrong.stateQueue.sync {
                            selfStrong.allRecognizedText.joined(separator: " ")
                        }
                        Logger.speechEvent("Recognition complete", details: "Final text length: \(finalText.count)")
                        continuation.finish()
                    }
                }

                if let error = error as NSError? {
                    Logger.error("Recognition error: \(error.localizedDescription), code: \(error.code)")
                    selfStrong.recognitionError = .recognitionFailed(error)
                    // Don't cancel — let recording continue, audio is saved
                } else if error != nil {
                    Logger.warning("Unknown non-NSError in recognition task")
                    selfStrong.recognitionError = .recognitionFailed(nil)
                }
            }

            // Install tap on input node
            selfRef.audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                selfRef.recognitionRequest?.append(buffer)
                selfRef.audioRecorder?.appendBuffer(buffer)
            }

            // Start audio engine after everything is set up
            selfRef.audioEngine.prepare()
            do {
                try selfRef.audioEngine.start()
                Logger.info("Audio engine started")
            } catch {
                Logger.error("Failed to start audio engine: \(error.localizedDescription)")
            }

            continuation.onTermination = { @Sendable _ in
                Logger.debug("Stream terminated")
            }
        }
    }

    func stopRecording() {
        Logger.speechEvent("Stopping recording")

        stateQueue.sync {
            isStreaming = false
        }

        // Remove tap first
        audioEngine.inputNode.removeTap(onBus: 0)

        // Stop audio engine
        audioEngine.stop()

        // Finish audio recording
        audioRecorder?.finishRecording()
        audioRecorder = nil

        // End recognition request
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // Cancel recognition task
        recognitionTask?.cancel()
        recognitionTask = nil

        let finalText = stateQueue.sync {
            allRecognizedText.joined(separator: " ")
        }
        Logger.speechEvent("Recording stopped", details: "Accumulated text length: \(finalText.count)")

        // Determine final mode based on errors and results
        if recognitionError != nil && !finalText.isEmpty {
            // Had error but got text via framework fallback — keep current mode
        } else if recognitionError != nil && finalText.isEmpty {
            recognitionMode = .failed
        }
    }

    func getFinalText() -> String {
        stateQueue.sync {
            allRecognizedText.joined(separator: " ")
        }
    }

    func getAudioFileName() -> String? {
        guard let id = currentRecordingId else { return nil }
        return "\(id.uuidString).m4a"
    }

    /// Re-recognize a saved audio file using online recognition.
    /// Returns the recognized text.
    func recognizeFromFile(url: URL) async throws -> String {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechRecognitionError.notAvailable
        }

        guard NetworkMonitor.shared.checkConnectivity() else {
            Logger.warning("recognizeFromFile skipped: device is offline")
            throw SpeechRecognitionError.notAvailable
        }

        Logger.info("Starting file-based online recognition: \(url.path)")

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false  // Force online for upgrade
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            speechRecognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    Logger.error("File recognition error: \(error.localizedDescription)")
                    continuation.resume(throwing: SpeechRecognitionError.recognitionFailed(error))
                    return
                }

                if let result = result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    Logger.info("File recognition complete, text length: \(text.count)")
                    continuation.resume(returning: text)
                }
            }
        }
    }

    /// Whether the last recording session ended with a recognition error
    var hasRecognitionError: Bool {
        recognitionError != nil
    }

    /// The error from the last recognition session, if any
    var lastRecognitionError: SpeechRecognitionError? {
        recognitionError
    }
}
