import Foundation
import Speech
import AVFoundation

enum PermissionStatus {
    case notDetermined
    case denied
    case restricted
    case authorized
}

final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published var speechAuthorizationStatus: PermissionStatus = .notDetermined
    @Published var microphoneAuthorizationStatus: PermissionStatus = .notDetermined

    private init() {
        updateStatuses()
    }

    func updateStatuses() {
        speechAuthorizationStatus = mapSpeechStatus(SFSpeechRecognizer.authorizationStatus())
        microphoneAuthorizationStatus = mapMicrophoneStatus(AVAudioSession.sharedInstance().recordPermission)
    }

    func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                let result = status == .authorized
                Task { @MainActor in
                    self.speechAuthorizationStatus = self.mapSpeechStatus(status)
                }
                continuation.resume(returning: result)
            }
        }
    }

    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                Task { @MainActor in
                    self.microphoneAuthorizationStatus = granted ? .authorized : .denied
                }
                continuation.resume(returning: granted)
            }
        }
    }

    func requestAllPermissions() async -> Bool {
        let speechGranted = await requestSpeechPermission()
        let micGranted = await requestMicrophonePermission()
        return speechGranted && micGranted
    }

    var isAllAuthorized: Bool {
        speechAuthorizationStatus == .authorized && microphoneAuthorizationStatus == .authorized
    }

    private func mapSpeechStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .authorized:
            return .authorized
        @unknown default:
            return .notDetermined
        }
    }

    private func mapMicrophoneStatus(_ status: AVAudioSession.RecordPermission) -> PermissionStatus {
        switch status {
        case .undetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .granted:
            return .authorized
        @unknown default:
            return .notDetermined
        }
    }
}
