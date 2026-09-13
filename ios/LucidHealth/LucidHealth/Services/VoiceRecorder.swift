import Foundation
import AVFoundation
import Speech

/// On-device voice capture + transcription using Apple Speech framework.
/// German default locale; Apple Speech handles English code-switching reasonably.
///
/// Requires `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`
/// in Info.plist (both added).
@MainActor
final class VoiceRecorder: ObservableObject {

    @Published var isRecording = false
    @Published var transcript = ""
    @Published var error: String?
    @Published var audioLevel: Float = 0   // 0–1, drives the waveform halo

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init(locale: Locale = Locale(identifier: "de-DE")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    /// Request mic + speech permissions. Call once on first capture.
    func requestAuthorization() async -> Bool {
        let speech: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        let mic: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        return speech && mic
    }

    func start() throws {
        stop()  // cancel any in-flight
        transcript = ""
        error = nil

        guard let recognizer, recognizer.isAvailable else {
            throw NSError(
                domain: "VoiceRecorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable for this locale"]
            )
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        self.request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)

            // Audio level for waveform halo (RMS, scaled)
            guard let channel = buffer.floatChannelData?[0] else { return }
            let length = Int(buffer.frameLength)
            var sumSq: Float = 0
            for i in 0..<length { sumSq += channel[i] * channel[i] }
            let rms = sqrt(sumSq / Float(max(length, 1)))
            let level = min(max(rms * 6, 0), 1)
            Task { @MainActor in self?.audioLevel = level }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            guard let self else { return }
            if let result {
                Task { @MainActor in
                    self.transcript = result.bestTranscription.formattedString
                }
            }
            if let err {
                Task { @MainActor in
                    self.error = err.localizedDescription
                    self.stop()
                }
            }
        }
    }

    func stop() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isRecording = false
        audioLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
